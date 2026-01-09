const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("ghostty.zig").Action;
const args = @import("args.zig");
const configpkg = @import("../config.zig");
const font = @import("../font/main.zig");
const getConstraint = @import("../font/nerd_font_attributes.zig").getConstraint;
const cellpkg = @import("../renderer/cell.zig");
const terminal = @import("../terminal/main.zig");
const tui = @import("tui.zig");
const vaxis = @import("vaxis");

const Config = configpkg.Config;

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

    /// If true, print without formatting even if printing to a tty.
    plain: bool = false,

    /// If true, record preview trace to a file in the current directory.
    timings: bool = false,

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

const VariationAxis = struct {
    id: font.face.Variation.Id,
    name: []const u8,
    min: f64,
    max: f64,
    def: f64,
};

const FontEntry = struct {
    family: []const u8,
    name: []const u8,
    style: []const u8,
    path: ?[]const u8,
    face: font.DeferredFace,

    fn lessThan(_: void, lhs: FontEntry, rhs: FontEntry) bool {
        const family_order = std.mem.order(u8, lhs.family, rhs.family);
        if (family_order != .eq) return family_order == .lt;
        return std.mem.order(u8, lhs.name, rhs.name) == .lt;
    }
};

const preview_lines = [_][]const u8{
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
    "abcdefghijklmnopqrstuvwxyz",
    "0123456789  !@#$%^&*()_+-=[]{}",
    "The quick brown fox jumps over the lazy dog.",
    "office fi fl ffi ffl",
    "=> != == >= <= :: ++ -- **",
};

const preview_debounce_ms: i64 = 120;
const trace_default_path = "ghostty-list-fonts.trace";

const PreviewSize = struct {
    cols: usize,
    rows: usize,
    xdpi: u16,
    ydpi: u16,
};

const PreviewImage = struct {
    pixels: []const u8,
    width: u16,
    height: u16,
};

const TraceWriter = struct {
    file: std.fs.File,
    start: std.time.Instant,

    pub fn init(path: []const u8) !TraceWriter {
        var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        errdefer file.close();
        return .{
            .file = file,
            .start = try std.time.Instant.now(),
        };
    }

    pub fn deinit(self: *TraceWriter) void {
        self.file.close();
    }

    pub fn log(
        self: *TraceWriter,
        kind: []const u8,
        entry: ?*const FontEntry,
        size: ?PreviewSize,
        value: ?u64,
        value2: ?u64,
        message: ?[]const u8,
    ) void {
        const now = std.time.Instant.now() catch return;
        const rel_ms = nsToMs(now.since(self.start));
        const epoch_ms = std.time.milliTimestamp();
        var buf: [1024]u8 = undefined;
        var writer = self.file.writer(&buf);
        const out = &writer.interface;
        out.print("[+{d:.2}ms @ {d}] {s}", .{ rel_ms, epoch_ms, kind }) catch return;

        if (entry) |font_entry| {
            const style_value = if (font_entry.style.len > 0) font_entry.style else "unknown";
            out.print(
                " font=\"{s}\" family=\"{s}\" style=\"{s}\"",
                .{ font_entry.name, font_entry.family, style_value },
            ) catch return;
        }

        if (size) |trace_size| {
            out.print(
                " cols={d} rows={d} dpi={d}x{d}",
                .{ trace_size.cols, trace_size.rows, trace_size.xdpi, trace_size.ydpi },
            ) catch return;
        }

        if (value) |val| {
            out.print(" value={d}", .{val}) catch return;
        }

        if (value2) |val2| {
            out.print(" value2={d}", .{val2}) catch return;
        }

        if (message) |msg| {
            out.print(" msg=\"{s}\"", .{msg}) catch return;
        }

        out.writeAll("\n") catch return;
        out.flush() catch {};
    }
};

const PreviewOutput = struct {
    image: ?PreviewImage,
    axes: []const VariationAxis,
    err_msg: ?[]const u8,
};

const PreviewCache = struct {
    font_index: usize,
    size: PreviewSize,
    output: PreviewOutput,
    image: ?vaxis.Image,
};

const PreviewRenderer = struct {
    gpa: Allocator,
    lib: font.Library,
    shaper: font.Shaper,
    config: *const Config,
    metric_modifiers: font.Metrics.ModifierSet,
    freetype_load_flags: font.face.FreetypeLoadFlags = font.face.freetype_load_flags_default,
    trace: ?*TraceWriter,

    pub fn init(gpa: Allocator, config: *const Config, trace: ?*TraceWriter) !PreviewRenderer {
        var lib = try font.Library.init(gpa);
        errdefer lib.deinit();

        var shaper = try font.Shaper.init(gpa, .{
            .features = config.@"font-feature".list.items,
        });
        errdefer shaper.deinit();

        var metric_modifiers: font.Metrics.ModifierSet = .{};
        errdefer metric_modifiers.deinit(gpa);
        if (config.@"adjust-cell-width") |m| try metric_modifiers.put(gpa, .cell_width, m);
        if (config.@"adjust-cell-height") |m| try metric_modifiers.put(gpa, .cell_height, m);
        if (config.@"adjust-font-baseline") |m| try metric_modifiers.put(gpa, .cell_baseline, m);
        if (config.@"adjust-underline-position") |m| try metric_modifiers.put(gpa, .underline_position, m);
        if (config.@"adjust-underline-thickness") |m| try metric_modifiers.put(gpa, .underline_thickness, m);
        if (config.@"adjust-strikethrough-position") |m| try metric_modifiers.put(gpa, .strikethrough_position, m);
        if (config.@"adjust-strikethrough-thickness") |m| try metric_modifiers.put(gpa, .strikethrough_thickness, m);
        if (config.@"adjust-overline-position") |m| try metric_modifiers.put(gpa, .overline_position, m);
        if (config.@"adjust-overline-thickness") |m| try metric_modifiers.put(gpa, .overline_thickness, m);
        if (config.@"adjust-cursor-thickness") |m| try metric_modifiers.put(gpa, .cursor_thickness, m);
        if (config.@"adjust-cursor-height") |m| try metric_modifiers.put(gpa, .cursor_height, m);
        if (config.@"adjust-box-thickness") |m| try metric_modifiers.put(gpa, .box_thickness, m);
        if (config.@"adjust-icon-height") |m| try metric_modifiers.put(gpa, .icon_height, m);

        const freetype_load_flags: font.face.FreetypeLoadFlags =
            if (font.face.FreetypeLoadFlags != void)
                config.@"freetype-load-flags"
            else
                font.face.freetype_load_flags_default;

        return .{
            .gpa = gpa,
            .lib = lib,
            .shaper = shaper,
            .config = config,
            .metric_modifiers = metric_modifiers,
            .freetype_load_flags = freetype_load_flags,
            .trace = trace,
        };
    }

    pub fn deinit(self: *PreviewRenderer) void {
        self.shaper.deinit();
        self.metric_modifiers.deinit(self.gpa);
        self.lib.deinit();
    }

    fn traceEvent(
        self: *PreviewRenderer,
        kind: []const u8,
        entry: ?*const FontEntry,
        size: ?PreviewSize,
        value: ?u64,
        value2: ?u64,
        message: ?[]const u8,
    ) void {
        if (self.trace) |trace| {
            trace.log(kind, entry, size, value, value2, message);
        }
    }

    pub fn render(
        self: *PreviewRenderer,
        alloc: Allocator,
        entry: *FontEntry,
        size: PreviewSize,
    ) !PreviewOutput {
        var output: PreviewOutput = .{
            .image = null,
            .axes = &.{},
            .err_msg = null,
        };

        const result = self.renderInternal(alloc, entry, size) catch |err| {
            self.traceEvent("render_error", entry, size, null, null, @errorName(err));
            output.err_msg = try std.fmt.allocPrint(
                alloc,
                "Preview error: {}",
                .{err},
            );
            return output;
        };
        return result;
    }

    fn renderInternal(
        self: *PreviewRenderer,
        alloc: Allocator,
        entry: *FontEntry,
        size: PreviewSize,
    ) !PreviewOutput {
        var scratch = ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const scratch_alloc = scratch.allocator();
        defer self.shaper.endFrame();

        self.traceEvent("render_start", entry, size, null, null, null);
        self.traceEvent("load_start", entry, size, null, null, null);

        const font_size: font.face.DesiredSize = .{
            .points = self.config.@"font-size",
            .xdpi = size.xdpi,
            .ydpi = size.ydpi,
        };

        var face_owned = true;
        var face = try entry.face.load(self.lib, .{
            .size = font_size,
            .freetype_load_flags = self.freetype_load_flags,
        });
        errdefer if (face_owned) face.deinit();

        self.traceEvent("load_end", entry, size, null, null, null);
        self.traceEvent("axes_start", entry, size, null, null, null);

        const axes = try getVariationAxes(alloc, &face);

        self.traceEvent("axes_end", entry, size, null, null, null);

        if (size.cols < 4 or size.rows < 2) {
            self.traceEvent("render_error", entry, size, null, null, "preview area too small");
            return .{
                .image = null,
                .axes = axes,
                .err_msg = try std.fmt.allocPrint(
                    alloc,
                    "Preview area too small ({d}x{d})",
                    .{ size.cols, size.rows },
                ),
            };
        }

        var collection = font.Collection.init();
        collection.load_options = .{
            .library = self.lib,
            .size = font_size,
            .freetype_load_flags = self.freetype_load_flags,
        };
        collection.metric_modifiers = self.metric_modifiers;

        self.traceEvent("collection_start", entry, size, null, null, null);

        _ = try collection.add(
            scratch_alloc,
            face,
            .{
                .style = .regular,
                .fallback = false,
                .size_adjustment = .none,
            },
        );
        face_owned = false;

        self.traceEvent("collection_end", entry, size, null, null, null);

        const resolver: font.CodepointResolver = .{
            .collection = collection,
        };

        self.traceEvent("grid_start", entry, size, null, null, null);

        var grid = try font.SharedGrid.init(scratch_alloc, resolver);
        defer grid.deinit(scratch_alloc);

        self.traceEvent("grid_end", entry, size, null, null, null);

        const cell_width: usize = grid.metrics.cell_width;
        const cell_height: usize = grid.metrics.cell_height;

        var max_line_len: usize = 0;
        for (preview_lines) |line| {
            max_line_len = @max(max_line_len, line.len);
        }

        const max_cols = @min(size.cols, max_line_len);
        const max_rows = @min(preview_lines.len, size.rows);
        if (max_cols == 0 or max_rows == 0) {
            self.traceEvent("render_error", entry, size, null, null, "preview area too small");
            return .{
                .image = null,
                .axes = axes,
                .err_msg = try std.fmt.allocPrint(
                    alloc,
                    "Preview area too small ({d}x{d})",
                    .{ size.cols, size.rows },
                ),
            };
        }

        const src_width = max_cols * cell_width;
        const src_height = max_rows * cell_height;
        if (src_width > std.math.maxInt(u16) or src_height > std.math.maxInt(u16)) {
            self.traceEvent("render_error", entry, size, null, null, "preview area too large");
            return .{
                .image = null,
                .axes = axes,
                .err_msg = try std.fmt.allocPrint(
                    alloc,
                    "Preview area too large ({d}x{d})",
                    .{ size.cols, size.rows },
                ),
            };
        }

        const img_width: u16 = @intCast(src_width);
        const img_height: u16 = @intCast(src_height);

        const pixels = try alloc.alloc(u8, src_width * src_height * 4);
        const pixel_bytes: u64 = @intCast(pixels.len);
        const bg = self.config.background;
        const fg = self.config.foreground;
        const bg_rgba = [4]u8{ bg.r, bg.g, bg.b, 0xff };
        const fg_rgba = [4]u8{ fg.r, fg.g, fg.b, 0xff };

        self.traceEvent("raster_start", entry, size, pixel_bytes, null, null);

        for (0..src_width * src_height) |i| {
            const idx = i * 4;
            pixels[idx] = bg_rgba[0];
            pixels[idx + 1] = bg_rgba[1];
            pixels[idx + 2] = bg_rgba[2];
            pixels[idx + 3] = bg_rgba[3];
        }

        for (preview_lines[0..max_rows], 0..) |line, row| {
            const slice = line[0..@min(line.len, max_cols)];
            var cells = try buildCells(scratch_alloc, slice, max_cols);
            defer cells.deinit(scratch_alloc);

            const run_opts: font.shape.RunOptions = .{
                .grid = &grid,
                .cells = cells.slice(),
                .selection = null,
                .cursor_x = null,
            };

            const cells_slice = cells.slice();
            const cells_raw = cells_slice.items(.raw);
            const cols = cells_raw.len;

            var run_iter = self.shaper.runIterator(run_opts);
            while (try run_iter.next(scratch_alloc)) |text_run| {
                const shaped = try self.shaper.shape(text_run);
                for (shaped) |sh_cell| {
                    const cell_x: usize = text_run.offset + sh_cell.x;
                    if (cell_x >= cols) continue;
                    const raw_cell = cells_raw[cell_x];
                    const cp = raw_cell.codepoint();
                    const glyph_render = try grid.renderGlyph(
                        scratch_alloc,
                        text_run.font_index,
                        sh_cell.glyph_index,
                        .{
                            .grid_metrics = grid.metrics,
                            .thicken = self.config.@"font-thicken",
                            .thicken_strength = self.config.@"font-thicken-strength",
                            .cell_width = raw_cell.gridWidth(),
                            .constraint = getConstraint(cp) orelse
                                if (cellpkg.isSymbol(cp)) .{ .size = .fit } else .none,
                            .constraint_width = cellpkg.constraintWidth(cells_raw, cell_x, cols),
                        },
                    );
                    if (glyph_render.glyph.width == 0 or glyph_render.glyph.height == 0) continue;

                    const atlas = switch (glyph_render.presentation) {
                        .emoji => &grid.atlas_color,
                        .text => &grid.atlas_grayscale,
                    };

                    drawGlyphRgba(
                        pixels,
                        src_width,
                        src_height,
                        cell_width,
                        cell_height,
                        cell_x,
                        row,
                        glyph_render.glyph,
                        glyph_render.presentation,
                        atlas,
                        sh_cell.x_offset,
                        sh_cell.y_offset,
                        fg_rgba,
                    );
                }
            }
        }

        self.traceEvent("raster_end", entry, size, pixel_bytes, null, null);
        self.traceEvent("render_end", entry, size, pixel_bytes, null, null);

        return .{
            .image = .{
                .pixels = pixels,
                .width = img_width,
                .height = img_height,
            },
            .axes = axes,
            .err_msg = null,
        };
    }
};

fn buildCells(
    alloc: Allocator,
    line: []const u8,
    cols: usize,
) !std.MultiArrayList(terminal.RenderState.Cell) {
    var cells: std.MultiArrayList(terminal.RenderState.Cell) = .{};
    errdefer cells.deinit(alloc);

    var view = std.unicode.Utf8View.init(line) catch {
        return cells;
    };
    var it = view.iterator();
    var count: usize = 0;
    while (it.nextCodepoint()) |cp| {
        if (count >= cols) break;
        const cell = terminal.page.Cell.init(@intCast(cp));
        try cells.append(alloc, .{
            .raw = cell,
            .grapheme = &.{},
            .style = .{},
        });
        count += 1;
    }

    while (count < cols) : (count += 1) {
        const cell = terminal.page.Cell.init(0);
        try cells.append(alloc, .{
            .raw = cell,
            .grapheme = &.{},
            .style = .{},
        });
    }

    return cells;
}

fn drawGlyphRgba(
    buffer: []u8,
    width: usize,
    height: usize,
    cell_width: usize,
    cell_height: usize,
    cell_x: usize,
    cell_y: usize,
    glyph: font.Glyph,
    presentation: font.Presentation,
    atlas: *font.Atlas,
    x_offset: i16,
    y_offset: i16,
    fg_rgba: [4]u8,
) void {
    const bearings_x: i32 = glyph.offset_x + @as(i32, x_offset);
    const bearings_y: i32 = glyph.offset_y + @as(i32, y_offset);

    const base_x: i32 = @intCast(cell_x * cell_width);
    const base_y: i32 = @intCast(cell_y * cell_height);

    const glyph_x: i32 = base_x + bearings_x;
    const glyph_y: i32 = base_y + @as(i32, @intCast(cell_height)) - bearings_y;

    const glyph_w: usize = @intCast(glyph.width);
    const glyph_h: usize = @intCast(glyph.height);
    const atlas_size: usize = @intCast(atlas.size);
    const depth: usize = atlas.format.depth();

    for (0..glyph_h) |row| {
        const dst_y = glyph_y + @as(i32, @intCast(row));
        if (dst_y < 0 or dst_y >= @as(i32, @intCast(height))) continue;

        const src_row = (glyph.atlas_y + @as(u32, @intCast(row))) * @as(u32, @intCast(atlas_size));
        const src_row_start: usize = @intCast(src_row * @as(u32, @intCast(depth)));

        const dst_row_start: usize = @as(usize, @intCast(dst_y)) * width * 4;

        for (0..glyph_w) |col| {
            const dst_x = glyph_x + @as(i32, @intCast(col));
            if (dst_x < 0 or dst_x >= @as(i32, @intCast(width))) continue;

            const src_index = src_row_start +
                (@as(usize, @intCast(glyph.atlas_x)) + col) * depth;
            const dst_index = dst_row_start + @as(usize, @intCast(dst_x)) * 4;
            switch (presentation) {
                .text => {
                    const coverage = atlas.data[src_index];
                    if (coverage == 0) continue;
                    blendPixel(buffer, dst_index, fg_rgba, coverage);
                },
                .emoji => {
                    if (atlas.format != .bgra and atlas.format != .bgr) continue;
                    const b = atlas.data[src_index];
                    const g = atlas.data[src_index + 1];
                    const r = atlas.data[src_index + 2];
                    const a: u8 = if (atlas.format == .bgra)
                        atlas.data[src_index + 3]
                    else
                        0xff;
                    if (a == 0) continue;
                    blendPixel(buffer, dst_index, .{ r, g, b, 0xff }, a);
                },
            }
        }
    }
}

fn blendPixel(buffer: []u8, dst_index: usize, src_rgba: [4]u8, alpha: u8) void {
    const inv_alpha: u16 = 255 - alpha;
    buffer[dst_index] = @intCast((@as(u16, src_rgba[0]) * alpha + @as(u16, buffer[dst_index]) * inv_alpha) / 255);
    buffer[dst_index + 1] = @intCast((@as(u16, src_rgba[1]) * alpha + @as(u16, buffer[dst_index + 1]) * inv_alpha) / 255);
    buffer[dst_index + 2] = @intCast((@as(u16, src_rgba[2]) * alpha + @as(u16, buffer[dst_index + 2]) * inv_alpha) / 255);
    buffer[dst_index + 3] = 0xff;
}

fn getVariationAxes(alloc: Allocator, face: *font.Face) ![]VariationAxis {
    return switch (font.options.backend) {
        .freetype, .fontconfig_freetype, .coretext_freetype => blk: {
            if (!face.face.hasMultipleMasters()) break :blk &.{};

            const mm = try face.face.getMMVar();
            defer face.lib.lib.doneMMVar(mm);

            const count: usize = @intCast(mm.num_axis);
            if (count == 0) break :blk &.{};

            var axes = try alloc.alloc(VariationAxis, count);
            for (0..count) |i| {
                const axis = mm.axis[i];
                const id_raw = std.math.cast(c_int, axis.tag) orelse 0;
                const id: font.face.Variation.Id = @bitCast(id_raw);
                const name = std.mem.sliceTo(axis.name, 0);
                axes[i] = .{
                    .id = id,
                    .name = try alloc.dupe(u8, name),
                    .min = @as(f64, @floatFromInt(axis.minimum)) / 65536.0,
                    .max = @as(f64, @floatFromInt(axis.maximum)) / 65536.0,
                    .def = @as(f64, @floatFromInt(axis.def)) / 65536.0,
                };
            }

            break :blk axes;
        },

        .coretext, .coretext_harfbuzz, .coretext_noshape => blk: {
            if (face.font.copyAttribute(.variation_axes)) |axes_cf| {
                defer axes_cf.release();

                const count = axes_cf.getCount();
                if (count == 0) break :blk &.{};

                var axes = try alloc.alloc(VariationAxis, count);
                const Key = @import("macos").text.FontVariationAxisKey;
                var buf: [256]u8 = undefined;
                for (0..count) |i| {
                    const dict = axes_cf.getValueAtIndex(@import("macos").foundation.Dictionary, i);
                    const cf_name = dict.getValue(Key.name.Value(), Key.name.key()).?;
                    const cf_id = dict.getValue(Key.identifier.Value(), Key.identifier.key()).?;
                    const cf_min = dict.getValue(Key.minimum_value.Value(), Key.minimum_value.key()).?;
                    const cf_max = dict.getValue(Key.maximum_value.Value(), Key.maximum_value.key()).?;
                    const cf_def = dict.getValue(Key.default_value.Value(), Key.default_value.key()).?;

                    const name = cf_name.cstring(&buf, .utf8) orelse "";

                    var id_raw: c_int = 0;
                    _ = cf_id.getValue(.int, &id_raw);
                    const id: font.face.Variation.Id = @bitCast(id_raw);

                    var min: f64 = 0;
                    _ = cf_min.getValue(.double, &min);
                    var max: f64 = 0;
                    _ = cf_max.getValue(.double, &max);
                    var def: f64 = 0;
                    _ = cf_def.getValue(.double, &def);

                    axes[i] = .{
                        .id = id,
                        .name = try alloc.dupe(u8, name),
                        .min = min,
                        .max = max,
                        .def = def,
                    };
                }

                break :blk axes;
            }

            break :blk &.{};
        },

        .web_canvas => &.{},
    };
}

fn discoverFonts(alloc: Allocator, opts: Options) !std.ArrayList(FontEntry) {
    var fonts: std.ArrayList(FontEntry) = .empty;

    var disco = font.Discover.init();
    defer disco.deinit();
    var disco_it = try disco.discover(alloc, .{
        .family = opts.family,
        .style = opts.style,
        .bold = opts.bold,
        .italic = opts.italic,
        .monospace = opts.family == null,
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

        const style_buf = face.styleName(&buf) catch |err| blk: {
            log.err("failed to get font style name: {}", .{err});
            break :blk "unknown";
        };
        const style = try alloc.dupe(u8, style_buf);

        const path = face.filePath(&buf) catch |err| blk: {
            log.err("failed to get font path: {}", .{err});
            break :blk null;
        };

        try fonts.append(alloc, .{
            .family = family,
            .name = full_name,
            .style = style,
            .path = if (path) |p| try alloc.dupe(u8, p) else null,
            .face = face,
        });
    }

    return fonts;
}

fn deinitFonts(fonts: *std.ArrayList(FontEntry), alloc: Allocator) void {
    for (fonts.items) |*entry| entry.face.deinit();
    fonts.deinit(alloc);
}

fn printPlain(stdout: *std.Io.Writer, fonts: []const FontEntry) !void {
    if (fonts.len == 0) return;

    var current_family: ?[]const u8 = null;
    for (fonts) |entry| {
        if (current_family == null or !std.mem.eql(u8, current_family.?, entry.family)) {
            if (current_family != null) try stdout.print("\n", .{});
            current_family = entry.family;
            try stdout.print("{s}\n", .{entry.family});
        }
        try stdout.print("  {s}\n", .{entry.name});
    }
    try stdout.print("\n", .{});
}

fn loadPreviewConfig(alloc: Allocator, stderr: *std.Io.Writer) !Config {
    const config = Config.load(alloc) catch |err| {
        try stderr.print(
            "Unable to load config for preview ({}). Using defaults.\n",
            .{err},
        );
        return try Config.default(alloc);
    };

    return config;
}

fn truncateText(alloc: Allocator, input: []const u8, max_cols: usize) ![]const u8 {
    if (input.len <= max_cols) return input;
    if (max_cols <= 3) return input[0..max_cols];

    var view = std.unicode.Utf8View.init(input) catch return input[0..max_cols];
    var it = view.iterator();
    var count: usize = 0;
    var end: usize = 0;
    while (it.nextCodepointSlice()) |_| {
        if (count + 1 > max_cols - 3) break;
        end = it.i;
        count += 1;
    }

    return try std.fmt.allocPrint(alloc, "{s}...", .{input[0..end]});
}

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, std.time.ns_per_ms);
}

fn cellPixelSize(win: vaxis.Window) struct { x: u16, y: u16 } {
    const width = win.screen.width;
    const height = win.screen.height;
    const width_pix = win.screen.width_pix;
    const height_pix = win.screen.height_pix;
    if (width == 0 or height == 0 or width_pix == 0 or height_pix == 0) {
        return .{ .x = 0, .y = 0 };
    }

    const xextra = width_pix % width;
    const yextra = height_pix % height;
    const xcell = (width_pix - xextra) / width;
    const ycell = (height_pix - yextra) / height;
    return .{ .x = xcell, .y = ycell };
}

fn previewDpi(config: *const Config, win: vaxis.Window) u16 {
    const cell_px = cellPixelSize(win);
    if (cell_px.y == 0) return font.face.default_dpi;

    const font_size = config.@"font-size";
    if (font_size <= 0) return font.face.default_dpi;

    const dpi_f = (@as(f32, @floatFromInt(cell_px.y)) * 72.0) / font_size;
    if (!std.math.isFinite(dpi_f) or dpi_f <= 0) return font.face.default_dpi;
    if (dpi_f > @as(f32, @floatFromInt(std.math.maxInt(u16)))) return font.face.default_dpi;

    const rounded = @round(dpi_f);
    if (rounded < 1) return font.face.default_dpi;
    return @intFromFloat(rounded);
}

const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
};

const Browser = struct {
    allocator: Allocator,
    tty: vaxis.Tty,
    vx: vaxis.Vaxis,
    fonts: []FontEntry,
    current: usize,
    window: usize,
    should_quit: bool,
    list_height: usize,
    preview_arena: ArenaAllocator,
    preview_cache: ?PreviewCache,
    preview_renderer: PreviewRenderer,
    preview_pending: bool,
    preview_pending_at_ms: i64,
    trace: ?TraceWriter,

    pub fn init(
        allocator: Allocator,
        fonts: []FontEntry,
        config: *const Config,
        buf: []u8,
        timings: bool,
    ) !*Browser {
        const self = try allocator.create(Browser);
        errdefer allocator.destroy(self);

        var tty = try vaxis.Tty.init(buf);
        errdefer tty.deinit();
        var vx = try vaxis.init(allocator, .{});
        errdefer vx.deinit(allocator, tty.writer());

        var trace: ?TraceWriter = null;
        if (timings) {
            trace = try TraceWriter.init(trace_default_path);
        }
        errdefer if (trace) |*t| t.deinit();

        var preview_renderer = try PreviewRenderer.init(allocator, config, null);
        errdefer preview_renderer.deinit();

        self.* = .{
            .allocator = allocator,
            .tty = tty,
            .vx = vx,
            .fonts = fonts,
            .current = 0,
            .window = 0,
            .should_quit = false,
            .list_height = 0,
            .preview_arena = ArenaAllocator.init(allocator),
            .preview_cache = null,
            .preview_renderer = preview_renderer,
            .preview_pending = false,
            .preview_pending_at_ms = 0,
            .trace = trace,
        };

        if (self.trace) |*t| {
            self.preview_renderer.trace = t;
        }

        return self;
    }

    pub fn deinit(self: *Browser) void {
        self.clearPreviewImage();
        if (self.trace) |*trace| trace.deinit();
        self.preview_renderer.deinit();
        self.preview_arena.deinit();
        self.vx.deinit(self.allocator, self.tty.writer());
        self.tty.deinit();
        self.allocator.destroy(self);
    }

    fn clearPreviewImage(self: *Browser) void {
        if (self.preview_cache) |*cache| {
            if (cache.image) |img| {
                self.vx.freeImage(self.tty.writer(), img.id);
                cache.image = null;
            }
        }
    }

    fn markPreviewDirty(self: *Browser) void {
        self.preview_pending = true;
        self.preview_pending_at_ms = std.time.milliTimestamp();
    }

    fn traceEvent(
        self: *Browser,
        kind: []const u8,
        entry: ?*const FontEntry,
        size: ?PreviewSize,
        value: ?u64,
        value2: ?u64,
        message: ?[]const u8,
    ) void {
        if (self.trace) |*trace| {
            trace.log(kind, entry, size, value, value2, message);
        }
    }

    pub fn runLoop(self: *Browser) !void {
        var loop: vaxis.Loop(Event) = .{
            .tty = &self.tty,
            .vaxis = &self.vx,
        };
        try loop.init();
        try loop.start();

        const writer = self.tty.writer();
        try self.vx.enterAltScreen(writer);
        try self.vx.setTitle(writer, "Ghostty Font Browser");
        try self.vx.queryTerminal(writer, 1 * std.time.ns_per_s);
        try self.vx.setMouseMode(writer, true);

        while (!self.should_quit) {
            var arena = ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            if (self.preview_pending) {
                const now_ms = std.time.milliTimestamp();
                const elapsed_ms = now_ms - self.preview_pending_at_ms;
                if (elapsed_ms < preview_debounce_ms) {
                    const remaining_ms = preview_debounce_ms - elapsed_ms;
                    const sleep_ms: u64 = @intCast(@min(remaining_ms, 16));
                    std.Thread.sleep(sleep_ms * std.time.ns_per_ms);
                }
            } else {
                loop.pollEvent();
            }
            while (loop.tryEvent()) |event| {
                try self.update(event);
            }
            try self.draw(alloc);

            try self.vx.render(writer);
            try writer.flush();
        }
    }

    fn update(self: *Browser, event: Event) !void {
        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    self.should_quit = true;
                    return;
                }

                if (key.matchesAny(&.{ 'q', vaxis.Key.escape }, .{})) {
                    self.should_quit = true;
                    return;
                }

                const step = if (self.list_height > 0) self.list_height else 10;

                if (key.matchesAny(&.{ 'k', vaxis.Key.up, vaxis.Key.kp_up }, .{})) {
                    self.moveUp(1);
                } else if (key.matchesAny(&.{ 'j', vaxis.Key.down, vaxis.Key.kp_down }, .{})) {
                    self.moveDown(1);
                } else if (key.matchesAny(&.{ vaxis.Key.page_up, vaxis.Key.kp_page_up }, .{})) {
                    self.moveUp(step);
                } else if (key.matchesAny(&.{ vaxis.Key.page_down, vaxis.Key.kp_down }, .{})) {
                    self.moveDown(step);
                } else if (key.matchesAny(&.{ vaxis.Key.home, vaxis.Key.kp_home }, .{})) {
                    const before = self.current;
                    self.current = 0;
                    if (self.current != before) self.markPreviewDirty();
                } else if (key.matchesAny(&.{ vaxis.Key.end, vaxis.Key.kp_end }, .{})) {
                    const before = self.current;
                    if (self.fonts.len > 0) self.current = self.fonts.len - 1;
                    if (self.current != before) self.markPreviewDirty();
                }
            },
            .winsize => |ws| {
                try self.vx.resize(self.allocator, self.tty.writer(), ws);
                self.markPreviewDirty();
            },
            .mouse => {},
        }
    }

    fn moveUp(self: *Browser, count: usize) void {
        if (self.fonts.len == 0) return;
        const before = self.current;
        self.current -|= count;
        if (self.current != before) self.markPreviewDirty();
    }

    fn moveDown(self: *Browser, count: usize) void {
        if (self.fonts.len == 0) return;
        const before = self.current;
        self.current += count;
        if (self.current >= self.fonts.len) self.current = self.fonts.len - 1;
        if (self.current != before) self.markPreviewDirty();
    }

    fn ensureVisible(self: *Browser) void {
        if (self.list_height == 0) return;
        if (self.current < self.window) self.window = self.current;
        if (self.current >= self.window + self.list_height) {
            self.window = self.current - self.list_height + 1;
        }
    }

    fn ensurePreview(self: *Browser, size: PreviewSize) !void {
        if (self.fonts.len == 0) return;

        if (self.preview_cache) |cache| {
            if (cache.font_index == self.current and
                cache.size.cols == size.cols and
                cache.size.rows == size.rows and
                cache.size.xdpi == size.xdpi and
                cache.size.ydpi == size.ydpi)
            {
                return;
            }
        }

        self.clearPreviewImage();
        self.preview_arena.deinit();
        self.preview_arena = ArenaAllocator.init(self.allocator);
        const alloc = self.preview_arena.allocator();

        self.traceEvent("preview_request", &self.fonts[self.current], size, null, null, null);
        var output = try self.preview_renderer.render(
            alloc,
            &self.fonts[self.current],
            size,
        );

        var image: ?vaxis.Image = null;
        if (output.image) |bitmap| {
            if (!self.vx.caps.kitty_graphics) {
                self.traceEvent(
                    "encode_skip",
                    &self.fonts[self.current],
                    size,
                    null,
                    null,
                    "kitty graphics not supported",
                );
                output.err_msg = output.err_msg orelse "Kitty graphics not supported.";
            } else {
                self.traceEvent(
                    "encode_start",
                    &self.fonts[self.current],
                    size,
                    @intCast(bitmap.pixels.len),
                    null,
                    null,
                );
                const encoded_len = std.base64.standard.Encoder.calcSize(bitmap.pixels.len);
                const encoded = try alloc.alloc(u8, encoded_len);
                const encoded_slice = std.base64.standard.Encoder.encode(encoded, bitmap.pixels);
                self.traceEvent(
                    "encode_end",
                    &self.fonts[self.current],
                    size,
                    @intCast(encoded_len),
                    null,
                    null,
                );
                self.traceEvent(
                    "transmit_start",
                    &self.fonts[self.current],
                    size,
                    null,
                    null,
                    null,
                );
                image = try self.vx.transmitPreEncodedImage(
                    self.tty.writer(),
                    encoded_slice,
                    bitmap.width,
                    bitmap.height,
                    .rgba,
                );
                self.traceEvent(
                    "transmit_end",
                    &self.fonts[self.current],
                    size,
                    image.?.id,
                    null,
                    null,
                );
            }
        }

        self.preview_cache = .{
            .font_index = self.current,
            .size = size,
            .output = output,
            .image = image,
        };
    }

    fn draw(self: *Browser, alloc: Allocator) !void {
        const win = self.vx.window();
        win.clear();

        const width: usize = @intCast(win.width);
        const height: usize = @intCast(win.height);

        if (width < 50 or height < 10) {
            _ = win.printSegment(
                .{ .text = "Window too small for font browser." },
                .{ .col_offset = 0, .row_offset = 0 },
            );
            return;
        }

        const header_row: usize = 0;
        const footer_row: usize = height - 1;
        const list_height = height - 2;
        self.list_height = list_height;
        self.ensureVisible();

        var list_width = width / 3;
        const min_list: usize = 24;
        const max_list: usize = width - 20;
        if (list_width < min_list) list_width = min_list;
        if (list_width > max_list) list_width = max_list;
        const detail_x: usize = list_width + 1;
        const detail_width: usize = width - detail_x;

        const current_index = if (self.fonts.len == 0) 0 else self.current + 1;
        const header = try std.fmt.allocPrint(
            alloc,
            "Ghostty Font Browser ({d}/{d})",
            .{ current_index, self.fonts.len },
        );
        _ = win.printSegment(
            .{ .text = header },
            .{ .col_offset = 0, .row_offset = @intCast(header_row) },
        );

        const list_panel = win.child(.{
            .x_off = 0,
            .y_off = 1,
            .width = @intCast(list_width + 1),
            .height = @intCast(list_height),
            .border = .{
                .where = .right,
            },
        });
        const list_win = list_panel.child(.{
            .x_off = 0,
            .y_off = 0,
            .width = @intCast(list_width),
            .height = @intCast(list_height),
        });

        const end = @min(self.fonts.len, self.window + list_height);
        for (self.window..end) |i| {
            const entry = &self.fonts[i];
            const row = i - self.window;
            const prefix = if (i == self.current) "> " else "  ";
            const max_name = list_width - prefix.len;
            const name = try truncateText(alloc, entry.name, max_name);
            const line = try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, name });
            _ = list_win.printSegment(
                .{ .text = line },
                .{ .col_offset = 0, .row_offset = @intCast(row) },
            );
        }

        if (self.fonts.len == 0) {
            _ = win.printSegment(
                .{ .text = "No fonts found." },
                .{ .col_offset = @intCast(detail_x), .row_offset = 1 },
            );
            return;
        }

        const entry = &self.fonts[self.current];
        const detail_rows = 5;
        const max_variation_lines: usize = 3;
        const reserved_rows = detail_rows + max_variation_lines + 1;
        const preview_rows = if (list_height > reserved_rows)
            list_height - reserved_rows
        else
            0;

        const dpi = previewDpi(self.preview_renderer.config, win);
        var cache_valid = false;
        if (self.preview_cache) |cache| {
            cache_valid = cache.font_index == self.current and
                cache.size.cols == detail_width and
                cache.size.rows == preview_rows and
                cache.size.xdpi == dpi and
                cache.size.ydpi == dpi;
        }

        if (!cache_valid) {
            const now_ms = std.time.milliTimestamp();
            const should_render = self.preview_cache == null or
                !self.preview_pending or
                now_ms - self.preview_pending_at_ms >= preview_debounce_ms;
            if (should_render) {
                try self.ensurePreview(.{
                    .cols = detail_width,
                    .rows = preview_rows,
                    .xdpi = dpi,
                    .ydpi = dpi,
                });
                self.preview_pending = false;
                if (self.preview_cache) |cache| {
                    cache_valid = cache.font_index == self.current and
                        cache.size.cols == detail_width and
                        cache.size.rows == preview_rows and
                        cache.size.xdpi == dpi and
                        cache.size.ydpi == dpi;
                }
            }
        }

        var detail_row: usize = 1;
        const title = try truncateText(alloc, entry.name, detail_width);
        _ = win.printSegment(
            .{ .text = title },
            .{ .col_offset = @intCast(detail_x), .row_offset = @intCast(detail_row) },
        );
        detail_row += 1;

        const family = try std.fmt.allocPrint(alloc, "Family: {s}", .{entry.family});
        _ = win.printSegment(
            .{ .text = try truncateText(alloc, family, detail_width) },
            .{ .col_offset = @intCast(detail_x), .row_offset = @intCast(detail_row) },
        );
        detail_row += 1;

        const style_value = if (entry.style.len > 0) entry.style else "unknown";
        const style = try std.fmt.allocPrint(alloc, "Style: {s}", .{style_value});
        _ = win.printSegment(
            .{ .text = try truncateText(alloc, style, detail_width) },
            .{ .col_offset = @intCast(detail_x), .row_offset = @intCast(detail_row) },
        );
        detail_row += 1;

        const path_value = entry.path orelse "n/a";
        const path = try std.fmt.allocPrint(alloc, "Path: {s}", .{path_value});
        _ = win.printSegment(
            .{ .text = try truncateText(alloc, path, detail_width) },
            .{ .col_offset = @intCast(detail_x), .row_offset = @intCast(detail_row) },
        );
        detail_row += 1;

        if (!cache_valid) {
            _ = win.printSegment(
                .{ .text = "Variations: loading..." },
                .{ .col_offset = @intCast(detail_x), .row_offset = @intCast(detail_row) },
            );
            detail_row += 1;
        } else if (self.preview_cache.?.output.axes.len == 0) {
            _ = win.printSegment(
                .{ .text = "Variations: none" },
                .{ .col_offset = @intCast(detail_x), .row_offset = @intCast(detail_row) },
            );
            detail_row += 1;
        } else {
            _ = win.printSegment(
                .{ .text = "Variations:" },
                .{ .col_offset = @intCast(detail_x), .row_offset = @intCast(detail_row) },
            );
            detail_row += 1;

            const axes = self.preview_cache.?.output.axes;
            const axis_lines = @min(axes.len, max_variation_lines);
            for (axes[0..axis_lines]) |axis| {
                const tag = axis.id.str();
                const axis_line = try std.fmt.allocPrint(
                    alloc,
                    "  {s} {s} {d:.2}-{d:.2} def {d:.2}",
                    .{ tag[0..], axis.name, axis.min, axis.max, axis.def },
                );
                _ = win.printSegment(
                    .{ .text = try truncateText(alloc, axis_line, detail_width) },
                    .{ .col_offset = @intCast(detail_x), .row_offset = @intCast(detail_row) },
                );
                detail_row += 1;
            }
        }

        detail_row += 1;

        if (preview_rows > 0) {
            const preview_win = win.child(.{
                .x_off = @intCast(detail_x),
                .y_off = @intCast(detail_row),
                .width = @intCast(detail_width),
                .height = @intCast(preview_rows),
            });
            if (cache_valid) {
                const cache = self.preview_cache.?;
                if (cache.image) |img| {
                    try img.draw(preview_win, .{ .scale = .contain });
                } else {
                    const msg = cache.output.err_msg orelse "Preview unavailable.";
                    const truncated = try truncateText(alloc, msg, detail_width);
                    _ = preview_win.printSegment(
                        .{ .text = truncated },
                        .{ .col_offset = 0, .row_offset = 0 },
                    );
                }
            } else {
                _ = preview_win.printSegment(
                    .{ .text = "Loading preview..." },
                    .{ .col_offset = 0, .row_offset = 0 },
                );
            }
        }

        _ = win.printSegment(
            .{ .text = "q/esc quit  j/k or arrows navigate" },
            .{ .col_offset = 0, .row_offset = @intCast(footer_row) },
        );

    }
};

fn preview(allocator: Allocator, fonts: []FontEntry, config: *const Config, timings: bool) !void {
    var buf: [1024]u8 = undefined;
    var browser = try Browser.init(allocator, fonts, config, &buf, timings);
    defer browser.deinit();
    if (browser.trace) |*trace| {
        trace.log("session_start", null, null, @intCast(fonts.len), null, null);
    }
    try browser.runLoop();
    if (browser.trace) |*trace| {
        trace.log("session_end", null, null, null, null, null);
    }
}

/// The `list-fonts` command is used to list all the available fonts for
/// Ghostty. This uses the exact same font discovery mechanism Ghostty uses to
/// find fonts to use.
///
/// When executed with no arguments, this will list all available fonts, sorted
/// by family name, then font name. If a family name is given with `--family`,
/// the sorting will be disabled and the results instead will be shown in the
/// same priority order Ghostty would use to pick a font.
///
/// If this command is run from a TTY, an interactive browser will be shown
/// unless `--plain` is set.
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
///   * `--plain`: Force the non-interactive list output.
///
///   * `--timings`: Write a timestamped preview trace to `ghostty-list-fonts.trace`.
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();
    return try runArgs(alloc, &iter);
}

fn runArgs(alloc_gpa: Allocator, argsIter: anytype) !u8 {
    var opts: Options = .{};
    defer opts.deinit();
    try args.parse(Options, alloc_gpa, &opts, argsIter);

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

    var fonts = try discoverFonts(alloc, opts);
    defer deinitFonts(&fonts, alloc);

    if (opts.family == null) {
        std.mem.sortUnstable(FontEntry, fonts.items, {}, FontEntry.lessThan);
    }

    var stdout_file: std.fs.File = .stdout();
    if (tui.can_pretty_print and !opts.plain and stdout_file.isTty()) {
        var stderr_buf: [1024]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
        const stderr = &stderr_writer.interface;

        var config = try loadPreviewConfig(alloc_gpa, stderr);
        defer config.deinit();

        try preview(alloc_gpa, fonts.items, &config, opts.timings);
        return 0;
    }

    var buffer: [2048]u8 = undefined;
    var stdout_writer = stdout_file.writer(&buffer);
    const stdout = &stdout_writer.interface;

    try printPlain(stdout, fonts.items);
    try stdout.flush();
    return 0;
}
