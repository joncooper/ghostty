const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("ghostty.zig").Action;
const args = @import("args.zig");
const tui = @import("tui.zig");
const font = @import("../font/main.zig");
const vaxis = @import("vaxis");
const zf = @import("zf");

const log = std.log.scoped(.list_fonts);

pub const Options = struct {
    /// This is set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    /// The font family to search for. If this is set, then only fonts
    /// matching this family will be listed.
    family: ?[:0]const u8 = null,

    /// The style name to search for.
    style: ?[:0]const u8 = null,

    /// Font styles to search for. If this is set, then only fonts that
    /// match the given styles will be listed.
    bold: bool = false,
    italic: bool = false,

    /// If true, force a plain list of fonts.
    plain: bool = false,

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

const FontListElement = struct {
    family_name: []const u8,
    font_name: []const u8,
    deferred_face: font.DeferredFace,
    path: ?[]const u8,

    fn lessThan(_: void, lhs: @This(), rhs: @This()) bool {
        // Sort by family first, then by font name
        const family_cmp = std.ascii.orderIgnoreCase(lhs.family_name, rhs.family_name);
        if (family_cmp != .eq) return family_cmp == .lt;
        return std.ascii.orderIgnoreCase(lhs.font_name, rhs.font_name) == .lt;
    }
};

/// The `list-fonts` command is used to list all the available fonts for
/// Ghostty. This uses the exact same font discovery mechanism Ghostty uses to
/// find fonts to use.
///
/// When executed from a TTY, an interactive TUI browser will be shown that
/// allows you to navigate fonts, see details, and preview how they render.
/// Press `F1` or `?` for help, `ESC` or `q` to quit.
///
/// When executed with no arguments, this will list all available fonts, sorted
/// by family name, then font name. If a family name is given with `--family`,
/// the sorting will be disabled and the results instead will be shown in the
/// same priority order Ghostty would use to pick a font.
///
/// Flags:
///
///   * `--bold`: Filter results to specific bold styles. It is not guaranteed
///     that only those styles are returned. They are only prioritized.
///
///   * `--italic`: Filter results to specific italic styles. It is not guaranteed
///     that only those styles are returned. They are only prioritized.
///
///   * `--style`: Filter results based on the style string advertised by a font.
///     It is not guaranteed that only those styles are returned. They are only
///     prioritized.
///
///   * `--family`: Filter results to a specific font family. The family handling
///     is identical to the `font-family` set of Ghostty configuration values, so
///     this can be used to debug why your desired font may not be loading.
///
///   * `--plain`: Force a plain listing of fonts (no TUI preview).
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();
    return try runArgs(alloc, &iter);
}

fn runArgs(alloc_gpa: Allocator, argsIter: anytype) !u8 {
    var config: Options = .{};
    defer config.deinit();
    try args.parse(Options, alloc_gpa, &config, argsIter);

    // Use an arena for all our memory allocs
    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Its possible to build Ghostty without font discovery!
    if (comptime font.Discover == void) {
        var buffer: [1024]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&buffer);
        const stderr = &stderr_writer.interface;
        try stderr.print(
            \\Ghostty was built without a font discovery mechanism. This is a compile-time
            \\option. Please review how Ghostty was built from source, contact the
            \\maintainer to enable a font discovery mechanism, and try again.
        ,
            .{},
        );
        try stderr.flush();
        return 1;
    }

    var stdout_file: std.fs.File = .stdout();

    // Discover all fonts
    var fonts: std.ArrayList(FontListElement) = .empty;
    var disco = font.Discover.init();
    defer disco.deinit();
    var disco_it = try disco.discover(alloc, .{
        .family = config.family,
        .style = config.style,
        .bold = config.bold,
        .italic = config.italic,
        .monospace = config.family == null,
    });
    defer disco_it.deinit();

    while (try disco_it.next()) |face| {
        var buf: [1024]u8 = undefined;

        const family_buf = face.familyName(&buf) catch |err| {
            log.err("failed to get font family name: {}", .{err});
            continue;
        };
        const family = try alloc.dupe(u8, family_buf);

        const full_name_buf = face.name(&buf) catch |err| {
            log.err("failed to get font name: {}", .{err});
            continue;
        };
        const full_name = try alloc.dupe(u8, full_name_buf);

        // Get path if available
        const path: ?[]const u8 = getPath(alloc, face) catch null;

        try fonts.append(alloc, .{
            .family_name = family,
            .font_name = full_name,
            .deferred_face = face,
            .path = path,
        });
    }

    if (fonts.items.len == 0) {
        var buffer: [1024]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&buffer);
        const stderr = &stderr_writer.interface;
        try stderr.print("No fonts found.\n", .{});
        try stderr.flush();
        return 1;
    }

    // Sort fonts
    if (config.family == null) {
        std.mem.sortUnstable(FontListElement, fonts.items, {}, FontListElement.lessThan);
    }

    // Check if we should show TUI or plain output
    if (tui.can_pretty_print and !config.plain and stdout_file.isTty()) {
        try preview(alloc_gpa, fonts.items);
        return 0;
    }

    // Plain output
    var buffer: [2048]u8 = undefined;
    var stdout_writer = stdout_file.writer(&buffer);
    const stdout = &stdout_writer.interface;

    var current_family: ?[]const u8 = null;
    for (fonts.items) |f| {
        // Group by family
        if (current_family == null or !std.mem.eql(u8, current_family.?, f.family_name)) {
            if (current_family != null) {
                try stdout.print("\n", .{});
            }
            try stdout.print("{s}\n", .{f.family_name});
            current_family = f.family_name;
        }
        try stdout.print("  {s}\n", .{f.font_name});
    }

    try stdout.flush();
    return 0;
}

fn getPath(alloc: Allocator, face: font.DeferredFace) ![]const u8 {
    _ = alloc;
    // For CoreText, try to get the URL
    if (font.Discover == font.discovery.CoreText) {
        if (face.ct) |ct| {
            const url = ct.font.copyAttribute(.url) orelse return error.NoPath;
            defer url.release();
            const path = url.copyPath() orelse return error.NoPath;
            defer path.release();
            var buf: [1024]u8 = undefined;
            const path_str = path.cstringPtr(.utf8) orelse
                path.cstring(&buf, .utf8) orelse return error.NoPath;
            return path_str;
        }
    }
    return error.NoPath;
}

// Sample text for font preview
const sample_lines = [_][]const u8{
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
    "abcdefghijklmnopqrstuvwxyz",
    "0123456789  !@#$%^&*()_+-=[]{}",
    "The quick brown fox jumps over the lazy dog.",
    "-> => != === |> <| :: ... ++ -- **",
    "Ambiguous: 0O 1lI ()[]{}",
};

const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    color_scheme: vaxis.Color.Scheme,
    winsize: vaxis.Winsize,
};

const Preview = struct {
    allocator: Allocator,
    should_quit: bool,
    tty: vaxis.Tty,
    vx: vaxis.Vaxis,
    mouse: ?vaxis.Mouse,
    fonts: []FontListElement,
    filtered: std.ArrayList(usize),
    current: usize,
    window: usize,
    mode: enum {
        normal,
        help,
        search,
    },
    color_scheme: vaxis.Color.Scheme,
    text_input: vaxis.widgets.TextInput,

    // Font rendering for preview
    font_lib: font.Library,
    cached_font_idx: ?usize,
    cached_image_id: ?u32,

    pub fn init(
        allocator: Allocator,
        fonts: []FontListElement,
        buf: []u8,
    ) !*Preview {
        const self = try allocator.create(Preview);

        self.* = .{
            .allocator = allocator,
            .should_quit = false,
            .tty = try .init(buf),
            .vx = try vaxis.init(allocator, .{}),
            .mouse = null,
            .fonts = fonts,
            .filtered = try .initCapacity(allocator, fonts.len),
            .current = 0,
            .window = 0,
            .mode = .normal,
            .color_scheme = .light,
            .text_input = .init(allocator),
            .font_lib = try font.Library.init(allocator),
            .cached_font_idx = null,
            .cached_image_id = null,
        };

        try self.updateFiltered();

        return self;
    }

    pub fn deinit(self: *Preview) void {
        const allocator = self.allocator;
        // Free cached image if any
        if (self.cached_image_id) |img_id| {
            self.vx.freeImage(self.tty.writer(), img_id);
        }
        self.font_lib.deinit();
        self.filtered.deinit(allocator);
        self.text_input.deinit();
        self.vx.deinit(allocator, self.tty.writer());
        self.tty.deinit();
        allocator.destroy(self);
    }

    pub fn run(self: *Preview) !void {
        var loop: vaxis.Loop(Event) = .{
            .tty = &self.tty,
            .vaxis = &self.vx,
        };
        try loop.init();
        try loop.start();

        const writer = self.tty.writer();

        try self.vx.enterAltScreen(writer);
        try self.vx.setTitle(writer, "👻 Ghostty Font Browser 👻");
        try self.vx.queryTerminal(writer, 1 * std.time.ns_per_s);
        try self.vx.setMouseMode(writer, true);
        if (self.vx.caps.color_scheme_updates)
            try self.vx.subscribeToColorSchemeUpdates(writer);

        while (!self.should_quit) {
            var frame_arena = ArenaAllocator.init(self.allocator);
            defer frame_arena.deinit();
            const alloc = frame_arena.allocator();

            loop.pollEvent();
            while (loop.tryEvent()) |event| {
                try self.update(event);
            }
            try self.draw(alloc);

            try self.vx.render(writer);
            try writer.flush();
        }
    }

    fn updateFiltered(self: *Preview) !void {
        self.filtered.clearRetainingCapacity();

        if (self.text_input.buf.realLength() > 0) {
            const first_half = self.text_input.buf.firstHalf();
            const second_half = self.text_input.buf.secondHalf();

            const buffer = try self.allocator.alloc(u8, first_half.len + second_half.len);
            defer self.allocator.free(buffer);

            @memcpy(buffer[0..first_half.len], first_half);
            @memcpy(buffer[first_half.len..], second_half);

            const string = try std.ascii.allocLowerString(self.allocator, buffer);
            defer self.allocator.free(string);

            var tokens: std.ArrayList([]const u8) = .empty;
            defer tokens.deinit(self.allocator);

            var it = std.mem.tokenizeScalar(u8, string, ' ');
            while (it.next()) |token| try tokens.append(self.allocator, token);

            for (self.fonts, 0..) |f, i| {
                // Search both font name and family name
                const name_rank = zf.rank(f.font_name, tokens.items, .{
                    .to_lower = true,
                    .plain = true,
                });
                const family_rank = zf.rank(f.family_name, tokens.items, .{
                    .to_lower = true,
                    .plain = true,
                });
                if (name_rank != null or family_rank != null) {
                    try self.filtered.append(self.allocator, i);
                }
            }
        } else {
            for (0..self.fonts.len) |i| {
                try self.filtered.append(self.allocator, i);
            }
        }

        // Reset selection if needed
        if (self.filtered.items.len == 0) {
            self.current = 0;
            self.window = 0;
        } else if (self.current >= self.filtered.items.len) {
            self.current = self.filtered.items.len - 1;
        }
    }

    fn up(self: *Preview, count: usize) void {
        if (self.filtered.items.len == 0) {
            self.current = 0;
            return;
        }
        self.current -|= count;
    }

    fn down(self: *Preview, count: usize) void {
        if (self.filtered.items.len == 0) {
            self.current = 0;
            return;
        }
        self.current += count;
        if (self.current >= self.filtered.items.len)
            self.current = self.filtered.items.len - 1;
    }

    pub fn update(self: *Preview, event: Event) !void {
        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true }))
                    self.should_quit = true;
                switch (self.mode) {
                    .normal => {
                        if (key.matchesAny(&.{ 'q', vaxis.Key.escape }, .{}))
                            self.should_quit = true;
                        if (key.matchesAny(&.{ '?', vaxis.Key.f1 }, .{}))
                            self.mode = .help;
                        if (key.matches('h', .{ .ctrl = true }))
                            self.mode = .help;
                        if (key.matches('/', .{}))
                            self.mode = .search;
                        if (key.matchesAny(&.{ 'x', '/' }, .{ .ctrl = true })) {
                            self.text_input.buf.clearRetainingCapacity();
                            try self.updateFiltered();
                        }
                        if (key.matchesAny(&.{ vaxis.Key.home, vaxis.Key.kp_home }, .{}))
                            self.current = 0;
                        if (key.matchesAny(&.{ vaxis.Key.end, vaxis.Key.kp_end }, .{})) {
                            if (self.filtered.items.len > 0) {
                                self.current = self.filtered.items.len - 1;
                            }
                        }
                        if (key.matchesAny(&.{ 'j', vaxis.Key.down, vaxis.Key.kp_down }, .{}))
                            self.down(1);
                        if (key.matchesAny(&.{ vaxis.Key.page_down, vaxis.Key.kp_page_down }, .{}))
                            self.down(20);
                        if (key.matchesAny(&.{ 'k', vaxis.Key.up, vaxis.Key.kp_up }, .{}))
                            self.up(1);
                        if (key.matchesAny(&.{ vaxis.Key.page_up, vaxis.Key.kp_page_up }, .{}))
                            self.up(20);
                    },
                    .help => {
                        if (key.matches('q', .{}))
                            self.should_quit = true;
                        if (key.matchesAny(&.{ '?', vaxis.Key.escape, vaxis.Key.f1 }, .{}))
                            self.mode = .normal;
                        if (key.matches('h', .{ .ctrl = true }))
                            self.mode = .normal;
                    },
                    .search => search: {
                        if (key.matchesAny(&.{ vaxis.Key.escape, vaxis.Key.enter }, .{})) {
                            self.mode = .normal;
                            break :search;
                        }
                        if (key.matchesAny(&.{ 'x', '/' }, .{ .ctrl = true })) {
                            self.text_input.clearRetainingCapacity();
                            try self.updateFiltered();
                            break :search;
                        }
                        try self.text_input.update(.{ .key_press = key });
                        try self.updateFiltered();
                    },
                }
            },
            .color_scheme => |color_scheme| self.color_scheme = color_scheme,
            .mouse => |mouse| self.mouse = mouse,
            .winsize => |ws| try self.vx.resize(self.allocator, self.tty.writer(), ws),
        }
    }

    pub fn ui_fg(self: *Preview) vaxis.Color {
        return switch (self.color_scheme) {
            .light => .{ .rgb = [_]u8{ 0x00, 0x00, 0x00 } },
            .dark => .{ .rgb = [_]u8{ 0xff, 0xff, 0xff } },
        };
    }

    pub fn ui_bg(self: *Preview) vaxis.Color {
        return switch (self.color_scheme) {
            .light => .{ .rgb = [_]u8{ 0xff, 0xff, 0xff } },
            .dark => .{ .rgb = [_]u8{ 0x00, 0x00, 0x00 } },
        };
    }

    pub fn ui_standard(self: *Preview) vaxis.Style {
        return .{
            .fg = self.ui_fg(),
            .bg = self.ui_bg(),
        };
    }

    pub fn ui_hover_bg(self: *Preview) vaxis.Color {
        return switch (self.color_scheme) {
            .light => .{ .rgb = [_]u8{ 0xbb, 0xbb, 0xbb } },
            .dark => .{ .rgb = [_]u8{ 0x22, 0x22, 0x22 } },
        };
    }

    pub fn ui_highlighted(self: *Preview) vaxis.Style {
        return .{
            .fg = self.ui_fg(),
            .bg = self.ui_hover_bg(),
        };
    }

    pub fn ui_selected_fg(self: *Preview) vaxis.Color {
        return switch (self.color_scheme) {
            .light => .{ .rgb = [_]u8{ 0x00, 0xaa, 0x00 } },
            .dark => .{ .rgb = [_]u8{ 0x00, 0xaa, 0x00 } },
        };
    }

    pub fn ui_selected_bg(self: *Preview) vaxis.Color {
        return switch (self.color_scheme) {
            .light => .{ .rgb = [_]u8{ 0xaa, 0xaa, 0xaa } },
            .dark => .{ .rgb = [_]u8{ 0x33, 0x33, 0x33 } },
        };
    }

    pub fn ui_selected(self: *Preview) vaxis.Style {
        return .{
            .fg = self.ui_selected_fg(),
            .bg = self.ui_selected_bg(),
        };
    }

    pub fn ui_dim(self: *Preview) vaxis.Style {
        return switch (self.color_scheme) {
            .light => .{
                .fg = .{ .rgb = [_]u8{ 0x66, 0x66, 0x66 } },
                .bg = self.ui_bg(),
            },
            .dark => .{
                .fg = .{ .rgb = [_]u8{ 0x88, 0x88, 0x88 } },
                .bg = self.ui_bg(),
            },
        };
    }

    pub fn draw(self: *Preview, alloc: Allocator) !void {
        const win = self.vx.window();
        win.clear();

        self.vx.setMouseShape(.default);

        // Calculate layout - three columns
        const list_width: u16 = @min(40, win.width / 3);
        const details_width: u16 = @min(35, (win.width - list_width) / 2);
        const preview_width: u16 = win.width - list_width - details_width;

        // Font list panel
        const font_list = win.child(.{
            .x_off = 0,
            .y_off = 0,
            .width = list_width,
            .height = win.height,
        });

        var highlight: ?usize = null;

        if (self.mouse) |mouse| {
            self.mouse = null;
            if (self.mode == .normal) {
                if (mouse.button == .wheel_up) {
                    self.up(1);
                }
                if (mouse.button == .wheel_down) {
                    self.down(1);
                }
                if (font_list.hasMouse(mouse)) |_| {
                    if (mouse.button == .left and mouse.type == .release) {
                        const selection = self.window + mouse.row - 2; // Account for header
                        if (selection < self.filtered.items.len) {
                            self.current = selection;
                        }
                    }
                    if (mouse.row >= 2) {
                        highlight = mouse.row - 2;
                    }
                }
            }
        }

        // Update scroll window
        if (self.filtered.items.len == 0) {
            self.current = 0;
            self.window = 0;
        } else {
            const visible_height = font_list.height -| 3; // Header + border
            const start = self.window;
            const end = self.window + visible_height -| 1;
            if (self.current > end)
                self.window = self.current -| visible_height + 1;
            if (self.current < start)
                self.window = self.current;
            if (self.window >= self.filtered.items.len)
                self.window = self.filtered.items.len -| 1;
        }

        font_list.fill(.{ .style = self.ui_standard() });

        // Header
        _ = font_list.printSegment(
            .{
                .text = " Fonts",
                .style = .{
                    .fg = self.ui_fg(),
                    .bg = self.ui_bg(),
                    .bold = true,
                },
            },
            .{
                .row_offset = 0,
                .col_offset = 0,
            },
        );

        // Show count
        const count_text = try std.fmt.allocPrint(alloc, "({d})", .{self.filtered.items.len});
        _ = font_list.printSegment(
            .{
                .text = count_text,
                .style = self.ui_dim(),
            },
            .{
                .row_offset = 0,
                .col_offset = 7,
            },
        );

        // Separator
        for (0..list_width) |i| {
            _ = font_list.printSegment(
                .{
                    .text = "─",
                    .style = self.ui_dim(),
                },
                .{
                    .row_offset = 1,
                    .col_offset = @intCast(i),
                },
            );
        }

        // Font list
        const visible_height = font_list.height -| 3;
        for (0..visible_height) |row_capture| {
            const row: u16 = @intCast(row_capture);
            const index = self.window + row;
            if (index >= self.filtered.items.len) break;

            const f = self.fonts[self.filtered.items[index]];

            const style: enum { normal, highlighted, selected } = style: {
                if (index == self.current) break :style .selected;
                if (highlight) |h| if (h == row) break :style .highlighted;
                break :style .normal;
            };

            const display_row = row + 2; // After header and separator

            if (style == .selected) {
                _ = font_list.printSegment(
                    .{
                        .text = "❯ ",
                        .style = self.ui_selected(),
                    },
                    .{
                        .row_offset = display_row,
                        .col_offset = 0,
                    },
                );
            }

            // Truncate font name if needed
            const max_name_len = list_width -| 4;
            var name_buf: [128]u8 = undefined;
            const display_name = if (f.font_name.len > max_name_len) blk: {
                @memcpy(name_buf[0 .. max_name_len - 1], f.font_name[0 .. max_name_len - 1]);
                name_buf[max_name_len - 1] = 0xe2; // UTF-8 ellipsis
                name_buf[max_name_len] = 0x80;
                name_buf[max_name_len + 1] = 0xa6;
                break :blk name_buf[0 .. max_name_len + 2];
            } else f.font_name;

            _ = font_list.printSegment(
                .{
                    .text = display_name,
                    .style = switch (style) {
                        .normal => self.ui_standard(),
                        .highlighted => self.ui_highlighted(),
                        .selected => self.ui_selected(),
                    },
                },
                .{
                    .row_offset = display_row,
                    .col_offset = 2,
                },
            );
        }

        // Draw details panel
        try self.drawDetails(alloc, win, list_width, details_width);

        // Draw preview panel
        try self.drawPreview(alloc, win, list_width + details_width, preview_width);

        // Mode-specific overlays
        switch (self.mode) {
            .normal => {
                win.hideCursor();
            },
            .help => {
                win.hideCursor();
                self.drawHelp(win);
            },
            .search => {
                const child = win.child(.{
                    .x_off = 20,
                    .y_off = win.height - 5,
                    .width = win.width - 40,
                    .height = 3,
                    .border = .{
                        .where = .all,
                        .style = self.ui_standard(),
                    },
                });
                child.fill(.{ .style = self.ui_standard() });
                self.text_input.drawWithStyle(child, self.ui_standard());
            },
        }
    }

    fn drawDetails(self: *Preview, alloc: Allocator, win: vaxis.Window, x_off: u16, width: u16) !void {
        const panel = win.child(.{
            .x_off = x_off,
            .y_off = 0,
            .width = width,
            .height = win.height,
        });

        panel.fill(.{ .style = self.ui_standard() });

        // Header
        _ = panel.printSegment(
            .{
                .text = " Details",
                .style = .{
                    .fg = self.ui_fg(),
                    .bg = self.ui_bg(),
                    .bold = true,
                },
            },
            .{
                .row_offset = 0,
                .col_offset = 0,
            },
        );

        // Separator
        for (0..width) |i| {
            _ = panel.printSegment(
                .{
                    .text = "─",
                    .style = self.ui_dim(),
                },
                .{
                    .row_offset = 1,
                    .col_offset = @intCast(i),
                },
            );
        }

        if (self.filtered.items.len == 0) {
            _ = panel.printSegment(
                .{
                    .text = " No fonts found",
                    .style = self.ui_dim(),
                },
                .{
                    .row_offset = 3,
                    .col_offset = 0,
                },
            );
            return;
        }

        const f = self.fonts[self.filtered.items[self.current]];

        var row: u16 = 3;

        // Family
        _ = panel.printSegment(
            .{
                .text = " Family:",
                .style = self.ui_dim(),
            },
            .{
                .row_offset = row,
                .col_offset = 0,
            },
        );
        row += 1;
        const family_display = try truncateText(alloc, f.family_name, width - 2);
        _ = panel.printSegment(
            .{
                .text = family_display,
                .style = self.ui_standard(),
            },
            .{
                .row_offset = row,
                .col_offset = 1,
            },
        );
        row += 2;

        // Full Name
        _ = panel.printSegment(
            .{
                .text = " Name:",
                .style = self.ui_dim(),
            },
            .{
                .row_offset = row,
                .col_offset = 0,
            },
        );
        row += 1;
        const name_display = try truncateText(alloc, f.font_name, width - 2);
        _ = panel.printSegment(
            .{
                .text = name_display,
                .style = self.ui_standard(),
            },
            .{
                .row_offset = row,
                .col_offset = 1,
            },
        );
        row += 2;

        // Path (if available)
        if (f.path) |path| {
            _ = panel.printSegment(
                .{
                    .text = " Path:",
                    .style = self.ui_dim(),
                },
                .{
                    .row_offset = row,
                    .col_offset = 0,
                },
            );
            row += 1;

            // Wrap path over multiple lines
            var path_remaining = path;
            while (path_remaining.len > 0 and row < panel.height - 1) {
                const chunk_len = @min(path_remaining.len, width - 2);
                _ = panel.printSegment(
                    .{
                        .text = path_remaining[0..chunk_len],
                        .style = self.ui_dim(),
                    },
                    .{
                        .row_offset = row,
                        .col_offset = 1,
                    },
                );
                path_remaining = path_remaining[chunk_len..];
                row += 1;
            }
        }
    }

    fn drawPreview(self: *Preview, alloc: Allocator, win: vaxis.Window, x_off: u16, width: u16) !void {
        const panel = win.child(.{
            .x_off = x_off,
            .y_off = 0,
            .width = width,
            .height = win.height,
        });

        panel.fill(.{ .style = self.ui_standard() });

        // Header
        _ = panel.printSegment(
            .{
                .text = " Preview",
                .style = .{
                    .fg = self.ui_fg(),
                    .bg = self.ui_bg(),
                    .bold = true,
                },
            },
            .{
                .row_offset = 0,
                .col_offset = 0,
            },
        );

        // Separator
        for (0..width) |i| {
            _ = panel.printSegment(
                .{
                    .text = "─",
                    .style = self.ui_dim(),
                },
                .{
                    .row_offset = 1,
                    .col_offset = @intCast(i),
                },
            );
        }

        if (self.filtered.items.len == 0) {
            return;
        }

        const font_idx = self.filtered.items[self.current];

        // Try to render with Kitty graphics
        if (try self.renderFontPreview(alloc, font_idx)) |img| {
            // Display the image
            const preview_win = panel.child(.{
                .x_off = 1,
                .y_off = 3,
                .width = width -| 2,
                .height = panel.height -| 5,
            });
            try img.draw(preview_win, .{ .scale = .contain });

            // Add hint about actual rendering below the image
            const hint_row = 3 + (try img.cellSize(preview_win)).rows + 1;
            if (hint_row < panel.height - 2) {
                _ = panel.printSegment(
                    .{
                        .text = " To use: font-family = <name>",
                        .style = self.ui_dim(),
                    },
                    .{
                        .row_offset = hint_row,
                        .col_offset = 0,
                    },
                );
            }
        } else {
            // Fallback: show sample text in terminal font
            var row: u16 = 3;
            for (sample_lines) |line| {
                if (row >= panel.height - 1) break;

                // Truncate line if needed
                const display_len = @min(line.len, width - 2);
                _ = panel.printSegment(
                    .{
                        .text = line[0..display_len],
                        .style = self.ui_standard(),
                    },
                    .{
                        .row_offset = row,
                        .col_offset = 1,
                    },
                );
                row += 1;
            }

            // Add hint about actual rendering
            row += 2;
            if (row < panel.height - 2) {
                _ = panel.printSegment(
                    .{
                        .text = " (Kitty graphics not available)",
                        .style = self.ui_dim(),
                    },
                    .{
                        .row_offset = row,
                        .col_offset = 0,
                    },
                );
                row += 1;
                _ = panel.printSegment(
                    .{
                        .text = " To use: font-family = <name>",
                        .style = self.ui_dim(),
                    },
                    .{
                        .row_offset = row,
                        .col_offset = 0,
                    },
                );
            }
        }
    }

    /// Render the selected font using Ghostty's rendering pipeline.
    /// Returns a vaxis.Image if successful, null if Kitty graphics is unavailable
    /// or if rendering fails.
    fn renderFontPreview(self: *Preview, alloc: Allocator, font_idx: usize) !?vaxis.Image {
        // Check if already cached
        if (self.cached_font_idx == font_idx) {
            if (self.cached_image_id) |img_id| {
                // Return the cached image
                return vaxis.Image{
                    .id = img_id,
                    .width = 0, // These will be looked up from terminal state
                    .height = 0,
                };
            }
        }

        // Free old cached image
        if (self.cached_image_id) |img_id| {
            self.vx.freeImage(self.tty.writer(), img_id);
            self.cached_image_id = null;
        }
        self.cached_font_idx = font_idx;

        // Check Kitty graphics support
        if (!self.vx.caps.kitty_graphics) return null;

        const f = &self.fonts[font_idx];

        // 1. Load font face using Ghostty's DeferredFace.load()
        var deferred = f.deferred_face;
        var face = deferred.load(self.font_lib, .{ .size = .{ .points = 16.0 } }) catch return null;
        defer face.deinit();

        // 2. Get metrics using Ghostty's Metrics.calc()
        const face_metrics = face.getMetrics();
        const grid_metrics = font.Metrics.calc(face_metrics);
        const cell_width: u32 = grid_metrics.cell_width;
        const cell_height: u32 = grid_metrics.cell_height;

        // 3. Calculate image dimensions
        const num_lines = sample_lines.len;
        const max_chars: usize = 32; // Max chars per line
        const img_width: u32 = cell_width * @as(u32, @intCast(max_chars));
        const img_height: u32 = cell_height * @as(u32, @intCast(num_lines));

        if (img_width == 0 or img_height == 0) return null;

        // 4. Create RGBA output buffer (4 bytes per pixel)
        const rgba = try alloc.alloc(u8, img_width * img_height * 4);
        defer alloc.free(rgba);

        // Fill with background color
        const bg: [4]u8 = switch (self.color_scheme) {
            .dark => .{ 0x1a, 0x1a, 0x1a, 0xff },
            .light => .{ 0xf5, 0xf5, 0xf5, 0xff },
        };
        for (0..img_width * img_height) |i| {
            rgba[i * 4 + 0] = bg[0];
            rgba[i * 4 + 1] = bg[1];
            rgba[i * 4 + 2] = bg[2];
            rgba[i * 4 + 3] = bg[3];
        }

        // 5. Create atlas using Ghostty's Atlas
        var atlas = font.Atlas.init(alloc, 512, .grayscale) catch return null;
        defer atlas.deinit(alloc);

        // 6. Render each line
        const fg: [4]u8 = switch (self.color_scheme) {
            .dark => .{ 0xe0, 0xe0, 0xe0, 0xff },
            .light => .{ 0x20, 0x20, 0x20, 0xff },
        };
        const render_opts: font.face.RenderOptions = .{ .grid_metrics = grid_metrics };

        for (sample_lines, 0..) |line, line_num| {
            var x: i32 = 0;
            const line_y: i32 = @intCast(line_num * cell_height);

            for (line) |char| {
                if (x >= @as(i32, @intCast(img_width))) break;

                // Get glyph index using Face.glyphIndex()
                const glyph_id = face.glyphIndex(@intCast(char)) orelse continue;

                // Render glyph using Face.renderGlyph() - Ghostty's pipeline!
                const glyph = face.renderGlyph(alloc, &atlas, glyph_id, render_opts) catch continue;

                // Composite glyph to RGBA buffer
                compositeGlyph(rgba, img_width, &atlas, glyph, x, line_y, cell_height, fg);

                x += @intCast(cell_width);
            }
        }

        // 7. Base64 encode for Kitty graphics
        const b64_size = std.base64.standard.Encoder.calcSize(rgba.len);
        const b64_buf = try alloc.alloc(u8, b64_size);
        defer alloc.free(b64_buf);
        const encoded = std.base64.standard.Encoder.encode(b64_buf, rgba);

        // 8. Transmit via Kitty graphics
        const img = self.vx.transmitPreEncodedImage(
            self.tty.writer(),
            encoded,
            @intCast(img_width),
            @intCast(img_height),
            .rgba,
        ) catch return null;

        self.cached_image_id = img.id;
        return img;
    }

    fn drawHelp(self: *Preview, win: vaxis.Window) void {
        const width = 50;
        const height = 16;
        const child = win.child(
            .{
                .x_off = win.width / 2 -| width / 2,
                .y_off = win.height / 2 -| height / 2,
                .width = width,
                .height = height,
                .border = .{
                    .where = .all,
                    .style = self.ui_standard(),
                },
            },
        );

        child.fill(.{ .style = self.ui_standard() });

        const key_help = [_]struct { keys: []const u8, help: []const u8 }{
            .{ .keys = "^C, q, ESC", .help = "Quit." },
            .{ .keys = "F1, ?, ^H", .help = "Toggle help window." },
            .{ .keys = "k, ↑", .help = "Move up 1 font." },
            .{ .keys = "j, ↓", .help = "Move down 1 font." },
            .{ .keys = "PgUp", .help = "Move up 20 fonts." },
            .{ .keys = "PgDown", .help = "Move down 20 fonts." },
            .{ .keys = "Home", .help = "Go to start of list." },
            .{ .keys = "End", .help = "Go to end of list." },
            .{ .keys = "/", .help = "Start search." },
            .{ .keys = "^X, ^/", .help = "Clear search." },
            .{ .keys = "ESC, ⏎", .help = "Close search." },
        };

        for (key_help, 0..) |help, captured_i| {
            const i: u16 = @intCast(captured_i);
            _ = child.printSegment(
                .{
                    .text = help.keys,
                    .style = self.ui_standard(),
                },
                .{
                    .row_offset = i + 1,
                    .col_offset = 2,
                },
            );
            _ = child.printSegment(
                .{
                    .text = "—",
                    .style = self.ui_standard(),
                },
                .{
                    .row_offset = i + 1,
                    .col_offset = 14,
                },
            );
            _ = child.printSegment(
                .{
                    .text = help.help,
                    .style = self.ui_standard(),
                },
                .{
                    .row_offset = i + 1,
                    .col_offset = 16,
                },
            );
        }
    }
};

/// Composite a glyph from the atlas to the RGBA buffer using alpha blending.
/// The atlas stores grayscale coverage values which we use as alpha for blending.
fn compositeGlyph(
    rgba: []u8,
    img_width: u32,
    atlas: *font.Atlas,
    glyph: font.Glyph,
    dest_x: i32,
    line_y: i32,
    cell_height: u32,
    fg: [4]u8,
) void {
    if (glyph.width == 0 or glyph.height == 0) return;

    // offset_y is distance from BOTTOM of cell to TOP of glyph
    // Convert to top-down coordinates
    const glyph_top: i32 = line_y + @as(i32, @intCast(cell_height)) - glyph.offset_y;
    const glyph_left: i32 = dest_x + glyph.offset_x;

    for (0..glyph.height) |gy| {
        for (0..glyph.width) |gx| {
            const dst_x = glyph_left + @as(i32, @intCast(gx));
            const dst_y = glyph_top + @as(i32, @intCast(gy));

            if (dst_x < 0 or dst_y < 0) continue;
            if (dst_x >= @as(i32, @intCast(img_width))) continue;

            // Get coverage from atlas (grayscale = alpha)
            const atlas_idx = (glyph.atlas_y + @as(u32, @intCast(gy))) * atlas.size +
                (glyph.atlas_x + @as(u32, @intCast(gx)));
            if (atlas_idx >= atlas.data.len) continue;
            const coverage = atlas.data[atlas_idx];
            if (coverage == 0) continue;

            // Calculate pixel index
            const px_idx = (@as(usize, @intCast(dst_y)) * img_width + @as(usize, @intCast(dst_x))) * 4;
            if (px_idx + 3 >= rgba.len) continue;

            // Alpha blend
            const alpha = @as(u16, coverage);
            const inv_alpha = 255 - alpha;
            rgba[px_idx + 0] = @intCast((@as(u16, fg[0]) * alpha + @as(u16, rgba[px_idx + 0]) * inv_alpha) / 255);
            rgba[px_idx + 1] = @intCast((@as(u16, fg[1]) * alpha + @as(u16, rgba[px_idx + 1]) * inv_alpha) / 255);
            rgba[px_idx + 2] = @intCast((@as(u16, fg[2]) * alpha + @as(u16, rgba[px_idx + 2]) * inv_alpha) / 255);
            rgba[px_idx + 3] = 0xff;
        }
    }
}

fn truncateText(alloc: Allocator, text: []const u8, max_len: usize) ![]const u8 {
    if (text.len <= max_len) return text;
    const buf = try alloc.alloc(u8, max_len);
    @memcpy(buf[0 .. max_len - 3], text[0 .. max_len - 3]);
    buf[max_len - 3] = '.';
    buf[max_len - 2] = '.';
    buf[max_len - 1] = '.';
    return buf;
}

fn preview(allocator: Allocator, fonts: []FontListElement) !void {
    var buf: [4096]u8 = undefined;
    var app = try Preview.init(
        allocator,
        fonts,
        &buf,
    );
    defer app.deinit();
    try app.run();
}
