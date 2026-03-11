const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("ghostty.zig").Action;
const args = @import("args.zig");

const whitespace = " \t\r\n";
const message_terminator = "\n\n";

pub const Options = struct {
    /// This is set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    /// URL to open in the browser split.
    url: ?[:0]const u8 = null,

    /// Focus the browser split after ensuring it exists.
    focus: bool = false,

    /// Close the browser split instead of opening or navigating it.
    close: bool = false,

    /// Explicit target terminal surface UUID.
    @"terminal-id": ?[:0]const u8 = null,

    /// Explicit Unix socket path for the owning Ghostty instance.
    @"socket-path": ?[:0]const u8 = null,

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    /// Enables `-h` and `--help` to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

const SocketResponse = struct {
    ok: bool,
    message: ?[]const u8,
};

/// The `browser-split` command controls the browser pane attached to a running
/// macOS Ghostty terminal.
///
/// This is intended to be called from inside Ghostty itself. The command
/// targets the current terminal by reading `GHOSTTY_SURFACE_ID` unless
/// `--terminal-id` is provided explicitly. The owning Ghostty instance is
/// resolved from `GHOSTTY_BROWSER_SPLIT_SOCKET` unless `--socket-path` is
/// provided.
///
/// If `--close` is not set, the browser split is created if needed. If `--url`
/// is set, the browser is navigated to that location. If `--focus` is set, the
/// browser receives focus afterwards.
///
/// Only supported on macOS.
///
/// Flags:
///
///   * `--url=<url>`: Open the given URL in the browser split.
///   * `--focus`: Focus the browser split after opening it.
///   * `--close`: Close the browser split.
///   * `--terminal-id=<uuid>`: Target a specific terminal surface.
///   * `--socket-path=<path>`: Target a specific Ghostty process socket.
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();

    var buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&buffer);
    const stderr = &stderr_writer.interface;

    const result = runArgs(alloc, &iter, stderr);
    stderr.flush() catch {};
    return result;
}

fn runArgs(
    alloc_gpa: Allocator,
    args_iter: anytype,
    stderr: *std.Io.Writer,
) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    args.parse(Options, alloc_gpa, &opts, args_iter) catch |err| switch (err) {
        error.ActionHelpRequested => return err,
        else => {
            try stderr.print("Error parsing args: {}\n", .{err});
            return 1;
        },
    };

    if (builtin.os.tag != .macos) {
        try stderr.print("+browser-split is not supported on this platform.\n", .{});
        return 1;
    }

    const alloc = opts._arena.?.allocator();
    const terminal_id = resolveStringOption(
        opts.@"terminal-id",
        try getEnvVarOwnedOrNull(alloc, "GHOSTTY_SURFACE_ID"),
        null,
    ) orelse {
        try stderr.writeAll(
            "Unable to determine the target terminal. Run this inside Ghostty or pass --terminal-id.\n",
        );
        return 1;
    };
    const socket_path = resolveStringOption(
        opts.@"socket-path",
        try getEnvVarOwnedOrNull(alloc, "GHOSTTY_BROWSER_SPLIT_SOCKET"),
        null,
    ) orelse {
        try stderr.writeAll(
            "Unable to determine the target Ghostty instance. Run this inside a Ghostty build with browser split support or pass --socket-path.\n",
        );
        return 1;
    };

    if (!isLineSafe(terminal_id)) {
        try stderr.writeAll("Invalid terminal id for browser-split.\n");
        return 1;
    }
    if (opts.url) |url| if (!isLineSafe(url)) {
        try stderr.writeAll("Invalid URL for browser-split.\n");
        return 1;
    };

    const request = try buildSocketRequest(
        alloc,
        terminal_id,
        opts.url,
        opts.focus,
        opts.close,
    );
    defer alloc.free(request);

    return try sendSocketRequest(alloc, socket_path, request, stderr);
}

fn buildSocketRequest(
    alloc: Allocator,
    terminal_id: []const u8,
    url: ?[]const u8,
    focus: bool,
    close: bool,
) Allocator.Error![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "terminal-id:{s}\nclose:{s}\nfocus:{s}\nurl:{s}\n\n",
        .{
            terminal_id,
            boolArg(close),
            boolArg(focus),
            url orelse "",
        },
    );
}

fn sendSocketRequest(
    alloc: Allocator,
    socket_path: []const u8,
    request: []const u8,
    stderr: *std.Io.Writer,
) !u8 {
    const stream = std.net.connectUnixSocket(socket_path) catch |err| switch (err) {
        error.FileNotFound => {
            try stderr.print(
                "browser-split failed: no Ghostty command socket at {s}\n",
                .{socket_path},
            );
            return 1;
        },
        else => {
            try stderr.print("browser-split failed: {}\n", .{err});
            return 1;
        },
    };
    defer stream.close();

    try writeAll(stream, request);

    var response_buf: std.ArrayList(u8) = .empty;
    defer response_buf.deinit(alloc);

    var buffer: [512]u8 = undefined;
    while (true) {
        const n = try stream.read(&buffer);
        if (n == 0) break;
        try response_buf.appendSlice(alloc, buffer[0..n]);
        if (std.mem.indexOf(u8, response_buf.items, message_terminator) != null) break;
    }

    const response = parseSocketResponse(response_buf.items) catch |err| {
        try stderr.print("browser-split failed: invalid response ({})\n", .{err});
        return 1;
    };

    if (!response.ok) {
        if (response.message) |message| {
            try stderr.print("browser-split was rejected: {s}\n", .{message});
        } else {
            try stderr.writeAll("browser-split was rejected by the running Ghostty instance.\n");
        }
        return 1;
    }

    return 0;
}

fn parseSocketResponse(response: []const u8) !SocketResponse {
    const payload = if (std.mem.indexOf(u8, response, message_terminator)) |index|
        response[0..index]
    else
        std.mem.trim(u8, response, whitespace);

    var ok: ?bool = null;
    var error_message: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, payload, '\n');
    while (lines.next()) |line_untrimmed| {
        const line = std.mem.trimRight(u8, line_untrimmed, "\r");
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "ok:")) {
            ok = parseBoolValue(line["ok:".len..]) catch return error.InvalidResponse;
            continue;
        }

        if (std.mem.startsWith(u8, line, "error:")) {
            const message = line["error:".len..];
            error_message = if (message.len == 0) null else message;
            continue;
        }

        return error.InvalidResponse;
    }

    return .{
        .ok = ok orelse return error.InvalidResponse,
        .message = error_message,
    };
}

fn writeAll(stream: std.net.Stream, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        offset += try std.posix.write(stream.handle, bytes[offset..]);
    }
}

fn parseBoolValue(value: []const u8) error{InvalidBoolean}!bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidBoolean;
}

fn isLineSafe(value: []const u8) bool {
    return std.mem.indexOfAny(u8, value, "\r\n") == null;
}

fn getEnvVarOwnedOrNull(alloc: Allocator, key: []const u8) !?[]const u8 {
    return std.process.getEnvVarOwned(alloc, key) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        error.InvalidWtf8 => null,
        else => return err,
    };
}

fn resolveStringOption(
    explicit: ?[]const u8,
    env_value: ?[]const u8,
    fallback: ?[]const u8,
) ?[]const u8 {
    if (explicit) |value| return value;
    if (env_value) |value| return value;
    return fallback;
}

fn boolArg(value: bool) []const u8 {
    return if (value) "true" else "false";
}

test "resolve string option prefers explicit value" {
    try std.testing.expectEqualStrings(
        "explicit",
        resolveStringOption("explicit", "env", "fallback").?,
    );
}

test "resolve string option falls back to env then default" {
    try std.testing.expectEqualStrings(
        "env",
        resolveStringOption(null, "env", "fallback").?,
    );
    try std.testing.expectEqualStrings(
        "fallback",
        resolveStringOption(null, null, "fallback").?,
    );
    try std.testing.expect(resolveStringOption(null, null, null) == null);
}

test "build socket request includes all command fields" {
    const alloc = std.testing.allocator;
    const request = try buildSocketRequest(
        alloc,
        "surface-id",
        "https://ghostty.org",
        true,
        false,
    );
    defer alloc.free(request);

    try std.testing.expectEqualStrings(
        "terminal-id:surface-id\nclose:false\nfocus:true\nurl:https://ghostty.org\n\n",
        request,
    );
}

test "socket response parser accepts success and error replies" {
    const success = try parseSocketResponse("ok:true\nerror:\n\n");
    try std.testing.expect(success.ok);
    try std.testing.expect(success.message == null);

    const failure = try parseSocketResponse("ok:false\nerror:missing terminal\n\n");
    try std.testing.expect(!failure.ok);
    try std.testing.expectEqualStrings("missing terminal", failure.message.?);
}

test "socket response parser rejects malformed replies" {
    try std.testing.expectError(error.InvalidResponse, parseSocketResponse("oops\n\n"));
    try std.testing.expectError(error.InvalidResponse, parseSocketResponse("ok:maybe\n\n"));
}
