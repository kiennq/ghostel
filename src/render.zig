/// RenderState-based terminal rendering to Emacs buffers.
///
/// Reads dirty rows/cells from the ghostty render state, extracts
/// text and style attributes, and inserts propertized text into the
/// current Emacs buffer.
const std = @import("std");
const emacs = @import("emacs.zig");
const gt = @import("ghostty.zig");
const Terminal = @import("terminal.zig");

/// Style attributes for a run of text.
const CellStyle = struct {
    fg: ?gt.ColorRgb = null,
    bg: ?gt.ColorRgb = null,
    bold: bool = false,
    italic: bool = false,
    faint: bool = false,
    underline: c_int = 0, // 0=none, 1=single, 2=double, 3=curly, 4=dotted, 5=dashed
    underline_color: ?gt.ColorRgb = null,
    strikethrough: bool = false,
    inverse: bool = false,

    fn eql(a: CellStyle, b: CellStyle) bool {
        return colorEql(a.fg, b.fg) and
            colorEql(a.bg, b.bg) and
            a.bold == b.bold and
            a.italic == b.italic and
            a.faint == b.faint and
            a.underline == b.underline and
            colorEql(a.underline_color, b.underline_color) and
            a.strikethrough == b.strikethrough and
            a.inverse == b.inverse;
    }

    fn isDefault(self: CellStyle) bool {
        return self.fg == null and
            self.bg == null and
            !self.bold and
            !self.italic and
            !self.faint and
            self.underline == 0 and
            !self.strikethrough and
            !self.inverse;
    }
};

fn colorEql(a: ?gt.ColorRgb, b: ?gt.ColorRgb) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.r == b.?.r and a.?.g == b.?.g and a.?.b == b.?.b;
}

/// Format an RGB color as "#RRGGBB" into a buffer.
fn formatColor(color: gt.ColorRgb, buf: *[7]u8) []const u8 {
    const hex = "0123456789abcdef";
    buf[0] = '#';
    buf[1] = hex[color.r >> 4];
    buf[2] = hex[color.r & 0xf];
    buf[3] = hex[color.g >> 4];
    buf[4] = hex[color.g & 0xf];
    buf[5] = hex[color.b >> 4];
    buf[6] = hex[color.b & 0xf];
    return buf[0..7];
}

/// Read the style for the current cell from the render state.
fn readCellStyle(cells: gt.RenderStateRowCells) CellStyle {
    var style: CellStyle = .{};

    // Read resolved FG color
    var fg: gt.ColorRgb = undefined;
    if (gt.c.ghostty_render_state_row_cells_get(cells, gt.RS_CELLS_DATA_FG_COLOR, @ptrCast(&fg)) == gt.SUCCESS) {
        style.fg = fg;
    }

    // Read resolved BG color
    var bg: gt.ColorRgb = undefined;
    if (gt.c.ghostty_render_state_row_cells_get(cells, gt.RS_CELLS_DATA_BG_COLOR, @ptrCast(&bg)) == gt.SUCCESS) {
        style.bg = bg;
    }

    // Read style attributes
    var gs: gt.Style = std.mem.zeroes(gt.Style);
    gs.size = @sizeOf(gt.Style);
    if (gt.c.ghostty_render_state_row_cells_get(cells, gt.RS_CELLS_DATA_STYLE, @ptrCast(&gs)) == gt.SUCCESS) {
        style.bold = gs.bold;
        style.italic = gs.italic;
        style.faint = gs.faint;
        style.underline = gs.underline;
        style.strikethrough = gs.strikethrough;
        style.inverse = gs.inverse;

        // Underline color
        if (gs.underline_color.tag == gt.c.GHOSTTY_STYLE_COLOR_RGB) {
            style.underline_color = gs.underline_color.value.rgb;
        }
    }

    return style;
}

/// Apply face properties to a region of the buffer.
/// Uses (put-text-property START END 'face PLIST).
fn applyStyle(env: emacs.Env, start: i64, end: i64, style: CellStyle, default_fg: gt.ColorRgb, default_bg: gt.ColorRgb) void {
    if (style.isDefault()) return;
    if (start >= end) return;

    // Build face property list
    // We construct it as: (list :foreground "..." :background "..." :weight 'bold ...)
    var props: [24]emacs.Value = undefined;
    var prop_count: usize = 0;

    var fg_buf: [7]u8 = undefined;
    var bg_buf: [7]u8 = undefined;

    // Foreground color
    const effective_fg = if (style.inverse) (style.bg orelse default_bg) else (style.fg orelse default_fg);
    const effective_bg = if (style.inverse) (style.fg orelse default_fg) else (style.bg orelse default_bg);

    // Only set FG if it differs from default (accounting for inverse)
    if (!colorEql(style.fg, null) or style.inverse) {
        const fg_str = formatColor(effective_fg, &fg_buf);
        props[prop_count] = env.intern(":foreground");
        prop_count += 1;
        props[prop_count] = env.makeString(fg_str);
        prop_count += 1;
    }

    // Only set BG if it differs from default (accounting for inverse)
    if (!colorEql(style.bg, null) or style.inverse) {
        const bg_str = formatColor(effective_bg, &bg_buf);
        props[prop_count] = env.intern(":background");
        prop_count += 1;
        props[prop_count] = env.makeString(bg_str);
        prop_count += 1;
    }

    // Bold
    if (style.bold) {
        props[prop_count] = env.intern(":weight");
        prop_count += 1;
        props[prop_count] = env.intern("bold");
        prop_count += 1;
    }

    // Faint/dim
    if (style.faint) {
        props[prop_count] = env.intern(":weight");
        prop_count += 1;
        props[prop_count] = env.intern("light");
        prop_count += 1;
    }

    // Italic
    if (style.italic) {
        props[prop_count] = env.intern(":slant");
        prop_count += 1;
        props[prop_count] = env.intern("italic");
        prop_count += 1;
    }

    // Underline
    if (style.underline != 0) {
        props[prop_count] = env.intern(":underline");
        prop_count += 1;
        // For simple single underline without color, use t
        if (style.underline == 1 and style.underline_color == null) {
            props[prop_count] = env.t();
        } else {
            // Build underline spec: (:style wave/line :color "...")
            var ul_props: [4]emacs.Value = undefined;
            var ul_count: usize = 0;

            ul_props[ul_count] = env.intern(":style");
            ul_count += 1;
            ul_props[ul_count] = switch (style.underline) {
                3 => env.intern("wave"), // curly
                2 => env.intern("double-line"),
                4 => env.intern("dot"),
                5 => env.intern("dash"),
                else => env.intern("line"),
            };
            ul_count += 1;

            if (style.underline_color) |uc| {
                var uc_buf: [7]u8 = undefined;
                ul_props[ul_count] = env.intern(":color");
                ul_count += 1;
                ul_props[ul_count] = env.makeString(formatColor(uc, &uc_buf));
                ul_count += 1;
            }

            props[prop_count] = env.funcall(env.intern("list"), ul_props[0..ul_count]);
        }
        prop_count += 1;
    }

    // Strikethrough
    if (style.strikethrough) {
        props[prop_count] = env.intern(":strike-through");
        prop_count += 1;
        props[prop_count] = env.t();
        prop_count += 1;
    }

    if (prop_count == 0) return;

    // Create the face plist: (list :foreground "..." ...)
    const face = env.funcall(env.intern("list"), props[0..prop_count]);

    // (put-text-property START END 'face FACE)
    _ = env.call4(
        env.intern("put-text-property"),
        env.makeInteger(start),
        env.makeInteger(end),
        env.intern("face"),
        face,
    );
}

/// Redraw the terminal into the current Emacs buffer.
pub fn redraw(env: emacs.Env, term: *Terminal) void {
    // Update render state from terminal
    if (gt.c.ghostty_render_state_update(term.render_state, term.terminal) != gt.SUCCESS) {
        return;
    }

    // Check dirty state
    var dirty: c_int = gt.DIRTY_FALSE;
    if (gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_DIRTY, @ptrCast(&dirty)) != gt.SUCCESS) {
        return;
    }

    if (dirty == gt.DIRTY_FALSE) {
        return; // Nothing to redraw
    }

    // Get default colors for inverse video fallback
    var default_fg = gt.ColorRgb{ .r = 204, .g = 204, .b = 204 };
    var default_bg = gt.ColorRgb{ .r = 0, .g = 0, .b = 0 };
    _ = gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_COLOR_FOREGROUND, @ptrCast(&default_fg));
    _ = gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_COLOR_BACKGROUND, @ptrCast(&default_bg));

    // Set the buffer's default face to terminal colors so that
    // unstyled text (default fg/bg) is always visible regardless
    // of the user's Emacs theme.
    var fg_hex: [7]u8 = undefined;
    var bg_hex: [7]u8 = undefined;
    _ = env.call2(
        env.intern("ghostel--set-buffer-face"),
        env.makeString(formatColor(default_fg, &fg_hex)),
        env.makeString(formatColor(default_bg, &bg_hex)),
    );

    // Erase buffer and redraw everything
    _ = env.call0(env.intern("erase-buffer"));

    // Get row iterator
    if (gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_ROW_ITERATOR, @ptrCast(&term.row_iterator)) != gt.SUCCESS) {
        return;
    }

    // Track style runs for propertizing after insertion
    const RunInfo = struct {
        start_byte: usize, // byte offset in the row's text buffer
        end_byte: usize,
        style: CellStyle,
    };
    var runs: [512]RunInfo = undefined;
    var text_buf: [16384]u8 = undefined;

    var row_count: usize = 0;
    while (gt.c.ghostty_render_state_row_iterator_next(term.row_iterator)) {
        // Get cells for this row
        if (gt.c.ghostty_render_state_row_get(term.row_iterator, gt.RS_ROW_DATA_CELLS, @ptrCast(&term.row_cells)) != gt.SUCCESS) {
            continue;
        }

        // Insert newline between rows (not before first row)
        if (row_count > 0) {
            _ = env.call1(env.intern("insert"), env.makeString("\n"));
        }
        row_count += 1;

        // Build text and track style runs for this row
        var text_len: usize = 0;
        var run_count: usize = 0;
        var current_style: CellStyle = .{};
        var run_start: usize = 0;

        while (gt.c.ghostty_render_state_row_cells_next(term.row_cells)) {
            // Get grapheme length
            var graphemes_len: u32 = 0;
            if (gt.c.ghostty_render_state_row_cells_get(term.row_cells, gt.RS_CELLS_DATA_GRAPHEMES_LEN, @ptrCast(&graphemes_len)) != gt.SUCCESS) {
                continue;
            }

            // Read style for this cell
            const cell_style = readCellStyle(term.row_cells);

            // Check if style changed — flush current run
            if (text_len > run_start and !cell_style.eql(current_style)) {
                if (run_count < runs.len) {
                    runs[run_count] = .{
                        .start_byte = run_start,
                        .end_byte = text_len,
                        .style = current_style,
                    };
                    run_count += 1;
                }
                run_start = text_len;
                current_style = cell_style;
            } else if (text_len == run_start) {
                current_style = cell_style;
            }

            if (graphemes_len == 0) {
                // Empty cell — render as space
                if (text_len < text_buf.len) {
                    text_buf[text_len] = ' ';
                    text_len += 1;
                }
                continue;
            }

            // Get grapheme codepoints
            var codepoints: [16]u32 = undefined;
            const cp_count = @min(graphemes_len, 16);
            if (gt.c.ghostty_render_state_row_cells_get(term.row_cells, gt.RS_CELLS_DATA_GRAPHEMES_BUF, @ptrCast(&codepoints)) != gt.SUCCESS) {
                continue;
            }

            // Encode codepoints to UTF-8
            for (0..cp_count) |i| {
                const cp: u21 = @intCast(codepoints[i]);
                const remaining = text_buf[text_len..];
                if (remaining.len < 4) break;
                const encoded_len = std.unicode.utf8Encode(cp, remaining) catch continue;
                text_len += encoded_len;
            }
        }

        // Close final run
        if (text_len > run_start and run_count < runs.len) {
            runs[run_count] = .{
                .start_byte = run_start,
                .end_byte = text_len,
                .style = current_style,
            };
            run_count += 1;
        }

        // Don't trim trailing spaces — terminal content is column-aligned
        // and the cursor must be positionable at any column.
        if (text_len == 0) continue;

        // Record buffer position before insertion for property offsets
        const insert_start = env.extractInteger(env.call0(env.intern("point")));

        // Insert the row text (full width, no trimming)
        _ = env.call1(env.intern("insert"), env.makeString(text_buf[0..text_len]));

        // Apply face properties to each style run
        for (runs[0..run_count]) |run| {
            if (run.start_byte >= text_len) break;
            const run_end = @min(run.end_byte, text_len);
            if (run_end <= run.start_byte) continue;

            const prop_start = insert_start + @as(i64, @intCast(run.start_byte));
            const prop_end = insert_start + @as(i64, @intCast(run_end));

            applyStyle(env, prop_start, prop_end, run.style, default_fg, default_bg);
        }
    }

    // Reset dirty state
    const dirty_false: c_int = gt.DIRTY_FALSE;
    _ = gt.c.ghostty_render_state_set(term.render_state, gt.RS_OPT_DIRTY, @ptrCast(&dirty_false));

    // Position cursor
    var cursor_has_value: bool = false;
    _ = gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_CURSOR_VIEWPORT_HAS_VALUE, @ptrCast(&cursor_has_value));
    if (cursor_has_value) {
        var cx: u16 = 0;
        var cy: u16 = 0;
        _ = gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_CURSOR_VIEWPORT_X, @ptrCast(&cx));
        _ = gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_CURSOR_VIEWPORT_Y, @ptrCast(&cy));

        _ = env.call1(env.intern("goto-char"), env.makeInteger(1));
        _ = env.call1(env.intern("forward-line"), env.makeInteger(@as(i64, cy)));
        _ = env.call1(env.intern("move-to-column"), env.makeInteger(@as(i64, cx)));
    }

    // Update cursor style
    var cursor_visible: bool = true;
    _ = gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_CURSOR_VISIBLE, @ptrCast(&cursor_visible));

    var cursor_style: c_int = gt.CURSOR_BLOCK;
    _ = gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_CURSOR_VISUAL_STYLE, @ptrCast(&cursor_style));

    _ = env.call2(
        env.intern("ghostel--set-cursor-style"),
        env.makeInteger(@as(i64, cursor_style)),
        if (cursor_visible) env.t() else env.nil(),
    );
}
