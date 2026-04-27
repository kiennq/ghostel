/// RenderState-based terminal rendering to Emacs buffers.
///
/// Reads rows/cells from the ghostty render state, extracts text and
/// style attributes, and inserts propertized text into the current
/// Emacs buffer.  See `redraw' below for the per-redraw algorithm
/// (viewport parking, scrollback sync, dirty-row reuse).
const std = @import("std");
const emacs = @import("emacs");
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
    hyperlink: bool = false,

    fn eql(a: CellStyle, b: CellStyle) bool {
        return colorEql(a.fg, b.fg) and
            colorEql(a.bg, b.bg) and
            a.bold == b.bold and
            a.italic == b.italic and
            a.faint == b.faint and
            a.underline == b.underline and
            colorEql(a.underline_color, b.underline_color) and
            a.strikethrough == b.strikethrough and
            a.inverse == b.inverse and
            a.hyperlink == b.hyperlink;
    }

    fn isDefault(self: CellStyle) bool {
        return self.fg == null and
            self.bg == null and
            !self.bold and
            !self.italic and
            !self.faint and
            self.underline == 0 and
            !self.strikethrough and
            !self.inverse and
            !self.hyperlink;
    }
};

/// Track style runs for propertizing after insertion.
/// Positions are in characters (codepoints), not bytes, because
/// Emacs put-text-property works with character positions.
const RunInfo = struct {
    start_char: usize,
    end_char: usize,
    style: CellStyle,
};

fn colorEql(a: ?gt.ColorRgb, b: ?gt.ColorRgb) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.r == b.?.r and a.?.g == b.?.g and a.?.b == b.?.b;
}

/// Blend a foreground color toward a background color to produce a "dim" effect.
/// Uses ~65% foreground / ~35% background weighting.
fn dimColor(fg: gt.ColorRgb, bg: gt.ColorRgb) gt.ColorRgb {
    return .{
        .r = @intCast((@as(u16, fg.r) * 166 + @as(u16, bg.r) * 90) / 256),
        .g = @intCast((@as(u16, fg.g) * 166 + @as(u16, bg.g) * 90) / 256),
        .b = @intCast((@as(u16, fg.b) * 166 + @as(u16, bg.b) * 90) / 256),
    };
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
fn readCellStyle(cells: gt.RenderStateRowCells, raw: gt.c.GhosttyCell) CellStyle {
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
    var gs: gt.Style = undefined;
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

    var hl: bool = undefined;
    if (gt.c.ghostty_cell_get(raw, gt.c.GHOSTTY_CELL_DATA_HAS_HYPERLINK, @ptrCast(&hl)) == gt.SUCCESS) {
        style.hyperlink = hl;
    }

    return style;
}

/// Apply face properties to a region of the buffer.
/// Uses (put-text-property START END 'face PLIST).
fn applyStyle(env: emacs.Env, start: i64, end: i64, style: CellStyle, default_colors: *const BgFg) void {
    if (style.isDefault()) return;
    if (start >= end) return;

    var face_props: [24]emacs.Value = undefined;
    var face_prop_count: usize = 0;
    const start_val = env.makeInteger(start);
    const end_val = env.makeInteger(end);

    var fg_buf: [7]u8 = undefined;
    var bg_buf: [7]u8 = undefined;
    var dim_buf: [7]u8 = undefined;

    const bg = style.bg orelse default_colors.bg;
    const fg = style.fg orelse default_colors.fg;
    const effective_fg = if (style.inverse) bg else fg;
    const effective_bg = if (style.inverse) fg else bg;

    const s = &emacs.sym;

    if (style.faint) {
        // Dim text: blend foreground toward background to reduce intensity.
        // Always set :foreground since we modify the color itself.
        const dimmed = dimColor(effective_fg, effective_bg);
        const dim_str = formatColor(dimmed, &dim_buf);
        face_props[face_prop_count] = s.@":foreground";
        face_prop_count += 1;
        face_props[face_prop_count] = env.makeString(dim_str);
        face_prop_count += 1;
    } else if (!colorEql(style.fg, null) or style.inverse) {
        const fg_str = formatColor(effective_fg, &fg_buf);
        face_props[face_prop_count] = s.@":foreground";
        face_prop_count += 1;
        face_props[face_prop_count] = env.makeString(fg_str);
        face_prop_count += 1;
    }

    if (!colorEql(style.bg, null) or style.inverse) {
        const bg_str = formatColor(effective_bg, &bg_buf);
        face_props[face_prop_count] = s.@":background";
        face_prop_count += 1;
        face_props[face_prop_count] = env.makeString(bg_str);
        face_prop_count += 1;
    }

    if (style.bold) {
        face_props[face_prop_count] = s.@":weight";
        face_prop_count += 1;
        face_props[face_prop_count] = s.bold;
        face_prop_count += 1;
    }

    if (style.italic) {
        face_props[face_prop_count] = s.@":slant";
        face_prop_count += 1;
        face_props[face_prop_count] = s.italic;
        face_prop_count += 1;
    }

    if (style.underline != 0) {
        face_props[face_prop_count] = s.@":underline";
        face_prop_count += 1;
        if (style.underline == 1 and style.underline_color == null) {
            face_props[face_prop_count] = env.t();
        } else {
            var ul_props: [4]emacs.Value = undefined;
            var ul_count: usize = 0;

            ul_props[ul_count] = s.@":style";
            ul_count += 1;
            ul_props[ul_count] = switch (style.underline) {
                3 => s.wave,
                2 => s.@"double-line",
                4 => s.dot,
                5 => s.dash,
                else => s.line,
            };
            ul_count += 1;

            if (style.underline_color) |uc| {
                var uc_buf: [7]u8 = undefined;
                ul_props[ul_count] = s.@":color";
                ul_count += 1;
                ul_props[ul_count] = env.makeString(formatColor(uc, &uc_buf));
                ul_count += 1;
            }

            face_props[face_prop_count] = env.funcall(s.list, ul_props[0..ul_count]);
        }
        face_prop_count += 1;
    }

    if (style.strikethrough) {
        face_props[face_prop_count] = s.@":strike-through";
        face_prop_count += 1;
        face_props[face_prop_count] = env.t();
        face_prop_count += 1;
    }

    if (face_prop_count > 0) {
        const face = env.funcall(s.list, face_props[0..face_prop_count]);
        env.putTextProperty(start_val, end_val, s.face, face);
    }

    if (style.hyperlink) {
        env.putTextProperty(start_val, end_val, s.@"help-echo", s.@"ghostel--native-link-help-echo");
        env.putTextProperty(start_val, end_val, s.@"mouse-face", s.highlight);
        env.putTextProperty(start_val, end_val, s.keymap, env.call1(s.@"symbol-value", s.@"ghostel-link-map"));
    }
}

/// Check if the current row in the iterator is soft-wrapped.
fn isRowWrapped(term: *Terminal) bool {
    var raw_row: gt.c.GhosttyRow = undefined;
    if (gt.c.ghostty_render_state_row_get(term.row_iterator, gt.c.GHOSTTY_RENDER_STATE_ROW_DATA_RAW, @ptrCast(&raw_row)) != gt.SUCCESS) {
        return false;
    }
    var wrapped: bool = false;
    _ = gt.c.ghostty_row_get(raw_row, gt.ROW_DATA_WRAP, @ptrCast(&wrapped));
    return wrapped;
}

/// Check if the current row in the iterator is a semantic prompt.
fn isRowPrompt(term: *Terminal) bool {
    var raw_row: gt.c.GhosttyRow = undefined;
    if (gt.c.ghostty_render_state_row_get(term.row_iterator, gt.c.GHOSTTY_RENDER_STATE_ROW_DATA_RAW, @ptrCast(&raw_row)) != gt.SUCCESS) {
        return false;
    }
    var semantic: c_int = 0;
    _ = gt.c.ghostty_row_get(raw_row, gt.ROW_DATA_SEMANTIC_PROMPT, @ptrCast(&semantic));
    return semantic != 0;
}

/// Whether the row at `cy` would render to no visible buffer content.
///
/// Assumes the caller has refreshed the render state (via
/// `ghostty_render_state_update`). Drives the row iterator, so callers
/// must not rely on iterator position after this call.
pub fn isRowEmptyAt(term: *Terminal, cy: u16) bool {
    if (gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_ROW_ITERATOR, @ptrCast(&term.row_iterator)) != gt.SUCCESS) {
        return false;
    }

    var ri: u16 = 0;
    while (ri <= cy) : (ri += 1) {
        if (!gt.c.ghostty_render_state_row_iterator_next(term.row_iterator)) {
            return false;
        }
    }

    if (gt.c.ghostty_render_state_row_get(term.row_iterator, gt.RS_ROW_DATA_CELLS, @ptrCast(&term.row_cells)) != gt.SUCCESS) {
        return false;
    }

    while (gt.c.ghostty_render_state_row_cells_next(term.row_cells)) {
        var graphemes_len: u32 = 0;
        if (gt.c.ghostty_render_state_row_cells_get(term.row_cells, gt.RS_CELLS_DATA_GRAPHEMES_LEN, @ptrCast(&graphemes_len)) == gt.SUCCESS and graphemes_len > 0) {
            return false;
        }

        var raw_cell: gt.c.GhosttyCell = undefined;
        if (gt.c.ghostty_render_state_row_cells_get(term.row_cells, gt.c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, @ptrCast(&raw_cell)) == gt.SUCCESS) {
            var wide: c_int = gt.c.GHOSTTY_CELL_WIDE_NARROW;
            _ = gt.c.ghostty_cell_get(raw_cell, gt.c.GHOSTTY_CELL_DATA_WIDE, @ptrCast(&wide));
            if (wide == gt.c.GHOSTTY_CELL_WIDE_SPACER_TAIL) continue;
            if (!readCellStyle(term.row_cells, raw_cell).isDefault()) return false;
        }
    }

    return true;
}

/// Result from buildRowContent: byte length for make_string, char count for properties.
const RowContent = struct {
    byte_len: usize,
    char_len: usize,
    /// Number of leading characters that are semantic prompt content.
    /// Zero if the row has no prompt cells.
    prompt_char_len: usize,
    /// True when the row contains at least one wide (2-cell) character.
    has_wide: bool,
};

/// Build text content and style runs for the current row in the iterator.
/// Style runs use character (codepoint) offsets for Emacs put-text-property.
///
/// Trailing blank cells — spaces with the default cell style — are
/// trimmed off the end of the row so the Emacs buffer does not carry
/// libghostty's full-width viewport padding. A cell is NOT blank if
/// its character is non-space, or if its style has any non-default
/// attribute (e.g. a colored background, underline, etc.), so visibly-
/// styled blanks are preserved. Style runs extending past the trim
/// point are clipped to the new length by `insertAndStyle'.
fn buildRowContent(
    term: *Terminal,
    text_buf: []u8,
    runs: []RunInfo,
    run_count: *usize,
) RowContent {
    var text_len: usize = 0; // byte offset
    var char_len: usize = 0; // character (codepoint) offset
    // Position at the end of the last non-blank cell; final row length
    // is trimmed back to this. Any run of blank cells past the end is
    // discarded along with their default-style trailing padding.
    var trim_text_len: usize = 0;
    var trim_char_len: usize = 0;
    var prompt_char_len: usize = 0; // chars that are semantic prompt
    var in_prompt: bool = true; // track contiguous leading prompt cells
    var has_wide: bool = false;
    run_count.* = 0;
    var current_style: CellStyle = .{};
    var run_start_char: usize = 0;

    while (gt.c.ghostty_render_state_row_cells_next(term.row_cells)) {
        var graphemes_len: u32 = 0;
        if (gt.c.ghostty_render_state_row_cells_get(term.row_cells, gt.RS_CELLS_DATA_GRAPHEMES_LEN, @ptrCast(&graphemes_len)) != gt.SUCCESS) {
            continue;
        }
        var raw_cell: gt.c.GhosttyCell = undefined;
        if (gt.c.ghostty_render_state_row_cells_get(term.row_cells, gt.c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, @ptrCast(&raw_cell)) != gt.SUCCESS) {
            continue;
        }

        // Track leading prompt characters via cell-level semantic content.
        if (in_prompt) {
            var semantic: c_int = 0; // GHOSTTY_CELL_SEMANTIC_OUTPUT
            _ = gt.c.ghostty_cell_get(raw_cell, gt.c.GHOSTTY_CELL_DATA_SEMANTIC_CONTENT, @ptrCast(&semantic));
            if (semantic != gt.c.GHOSTTY_CELL_SEMANTIC_PROMPT) {
                in_prompt = false;
            }
        }

        const cell_style = readCellStyle(term.row_cells, raw_cell);

        // Flush run on style change
        if (char_len > run_start_char and !cell_style.eql(current_style)) {
            if (run_count.* < runs.len) {
                runs[run_count.*] = .{
                    .start_char = run_start_char,
                    .end_char = char_len,
                    .style = current_style,
                };
                run_count.* += 1;
            }
            run_start_char = char_len;
            current_style = cell_style;
        } else if (char_len == run_start_char) {
            current_style = cell_style;
        }

        if (graphemes_len == 0) {
            // Wide-character spacer tails occupy a terminal cell but must
            // not produce output — the preceding wide cell already accounts
            // for 2 visual columns in Emacs.
            var wide: c_int = gt.c.GHOSTTY_CELL_WIDE_NARROW;
            _ = gt.c.ghostty_cell_get(raw_cell, gt.c.GHOSTTY_CELL_DATA_WIDE, @ptrCast(&wide));
            if (wide == gt.c.GHOSTTY_CELL_WIDE_SPACER_TAIL) {
                has_wide = true;
                continue;
            }
            if (text_len < text_buf.len) {
                text_buf[text_len] = ' ';
                text_len += 1;
                char_len += 1;
            }
            if (in_prompt) prompt_char_len = char_len;
            // Empty cells are blank for trim purposes unless their
            // style has a visible attribute (e.g. colored background).
            if (!cell_style.isDefault()) {
                trim_text_len = text_len;
                trim_char_len = char_len;
            }
            continue;
        }

        var codepoints: [16]u32 = undefined;
        const cp_count = @min(graphemes_len, 16);
        if (gt.c.ghostty_render_state_row_cells_get(term.row_cells, gt.RS_CELLS_DATA_GRAPHEMES_BUF, @ptrCast(&codepoints)) != gt.SUCCESS) {
            continue;
        }

        for (0..cp_count) |i| {
            const cp: u21 = @intCast(codepoints[i]);
            const remaining = text_buf[text_len..];
            if (remaining.len < 4) break;
            const encoded_len = std.unicode.utf8Encode(cp, remaining) catch continue;
            text_len += encoded_len;
            char_len += 1; // one codepoint = one Emacs character
        }
        if (in_prompt) prompt_char_len = char_len;
        // Any cell that libghostty stored a grapheme for was written
        // explicitly by the terminal, so it anchors the trim point —
        // even if the grapheme happens to be a space (e.g. the space
        // in a \"$ \" prompt, or a space the shell intentionally
        // emitted as part of a layout). Only unwritten padding cells
        // (the `graphemes_len == 0' branch above) are considered blank.
        trim_text_len = text_len;
        trim_char_len = char_len;
    }

    // Trim trailing blank cells. Cap `prompt_char_len' at the new
    // `char_len' so the "leading prompt" region never extends past the
    // trimmed text. Style runs extending past the trim point are
    // clipped by `insertAndStyle' via its `content.char_len' cap.
    text_len = trim_text_len;
    char_len = trim_char_len;
    if (prompt_char_len > char_len) prompt_char_len = char_len;

    // Close final run
    if (char_len > run_start_char and run_count.* < runs.len) {
        runs[run_count.*] = .{
            .start_char = run_start_char,
            .end_char = char_len,
            .style = current_style,
        };
        run_count.* += 1;
    }

    return .{ .byte_len = text_len, .char_len = char_len, .prompt_char_len = prompt_char_len, .has_wide = has_wide };
}

/// Insert row text and apply style runs.
fn insertAndStyle(
    env: emacs.Env,
    term: *Terminal,
    default_colors: *const BgFg,
) ?RowContent {
    if (gt.c.ghostty_render_state_row_get(term.row_iterator, gt.RS_ROW_DATA_CELLS, @ptrCast(&term.row_cells)) != gt.SUCCESS) {
        return null;
    }

    var runs: [512]RunInfo = undefined;
    var text_buf: [16384]u8 = undefined;
    var run_count: usize = 0;
    var content = buildRowContent(term, text_buf[0..], runs[0..], &run_count);

    // Append the trailing newline to the row buffer so the row
    // text + newline insert through a single env.insert call
    // instead of two. This saves one Elisp FFI round-trip per
    // inserted row, which is the dominant per-row cost in this
    // hot loop. Style runs only cover the row's cells, so the
    // unstyled trailing \n is harmless to insertAndStyle. If the
    // row exactly filled text_buf, fall back to a separate
    // env.insert("\n") so the "one row per line" invariant
    // (relied on by the `after_insert - 1` property math below)
    // always holds.
    const newline_in_buf = content.byte_len < text_buf.len;
    if (newline_in_buf) {
        text_buf[content.byte_len] = '\n';
        content.byte_len += 1;
        content.char_len += 1;
    }

    const row_start = env.extractInteger(env.point());
    env.insert(text_buf[0..content.byte_len]);

    for (runs[0..run_count]) |run| {
        if (run.start_char >= content.char_len) break;
        const run_end = @min(run.end_char, content.char_len);
        if (run_end <= run.start_char) continue;

        const prop_start = row_start + @as(i64, @intCast(run.start_char));
        const prop_end = row_start + @as(i64, @intCast(run_end));
        applyStyle(env, prop_start, prop_end, run.style, default_colors);
    }

    if (!newline_in_buf) {
        env.insert("\n");
    }
    const after_insert = env.extractInteger(env.point());
    if (isRowWrapped(term)) {
        // Mark newlines from soft-wrapped rows so copy mode can filter them
        const point = env.point();
        const nl_pos = env.makeInteger(env.extractInteger(point) - 1);
        env.putTextProperty(nl_pos, point, emacs.sym.@"ghostel-wrap", env.t());
    }

    if (content.prompt_char_len > 0) {
        env.putTextProperty(
            env.makeInteger(row_start),
            env.makeInteger(row_start + @as(i64, @intCast(content.prompt_char_len))),
            emacs.sym.@"ghostel-prompt",
            env.t(),
        );
    } else if (isRowPrompt(term)) {
        env.putTextProperty(
            env.makeInteger(row_start),
            env.makeInteger(after_insert - 1), // exclude trailing newline
            emacs.sym.@"ghostel-prompt",
            env.t(),
        );
    }

    return content;
}

/// Convert a terminal column to an Emacs character offset by iterating
/// the row's cells.  Returns `true` and positions point on success;
/// `false` if the cell data is unavailable (caller should fall back to
/// `move-to-column`).
///
/// This avoids relying on Emacs' `char-width`, which can disagree with
/// the terminal's column width for certain characters (e.g. box-drawing
/// glyphs on CJK/pgtk systems where `char-width` returns 2 but the
/// terminal treats them as single-width).
fn positionCursorByCell(env: emacs.Env, term: *Terminal, cx: u16, cy: u16) bool {
    if (cx == 0) return true; // already at column 0

    if (gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_ROW_ITERATOR, @ptrCast(&term.row_iterator)) != gt.SUCCESS) {
        return false;
    }

    // Advance iterator to cursor row cy.
    {
        var ri: u16 = 0;
        while (ri <= cy) : (ri += 1) {
            if (!gt.c.ghostty_render_state_row_iterator_next(term.row_iterator)) {
                return false;
            }
        }
    }

    if (gt.c.ghostty_render_state_row_get(term.row_iterator, gt.RS_ROW_DATA_CELLS, @ptrCast(&term.row_cells)) != gt.SUCCESS) {
        return false;
    }

    // Walk cells 0..cx-1, counting Emacs characters.
    var col: u16 = 0;
    var char_count: i64 = 0;
    while (col < cx) : (col += 1) {
        if (!gt.c.ghostty_render_state_row_cells_next(term.row_cells)) break;

        var graphemes_len: u32 = 0;
        _ = gt.c.ghostty_render_state_row_cells_get(term.row_cells, gt.RS_CELLS_DATA_GRAPHEMES_LEN, @ptrCast(&graphemes_len));

        if (graphemes_len == 0) {
            // Spacer tails produce no Emacs character.
            var raw_cell: gt.c.GhosttyCell = undefined;
            var wide: c_int = gt.c.GHOSTTY_CELL_WIDE_NARROW;
            if (gt.c.ghostty_render_state_row_cells_get(term.row_cells, gt.c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, @ptrCast(&raw_cell)) == gt.SUCCESS) {
                _ = gt.c.ghostty_cell_get(raw_cell, gt.c.GHOSTTY_CELL_DATA_WIDE, @ptrCast(&wide));
            }
            if (wide == gt.c.GHOSTTY_CELL_WIDE_SPACER_TAIL) {
                continue;
            }
            char_count += 1; // empty cell → space
        } else {
            char_count += @intCast(@min(graphemes_len, 16));
        }
    }

    // Cap at end of line so we never jump past it into the next row
    // (can happen when cursor is on a trimmed trailing blank).
    const pt = env.extractInteger(env.point());
    const eol = env.extractInteger(env.lineEndPosition());
    const max_chars = eol - pt;
    env.gotoCharN(pt + @min(char_count, max_chars));
    return true;
}

const BgFg = struct {
    bg: gt.ColorRgb,
    fg: gt.ColorRgb,
};

fn getDefaultColors(term: *Terminal) BgFg {
    var bgfg = BgFg{ .fg = gt.ColorRgb{ .r = 204, .g = 204, .b = 204 }, .bg = gt.ColorRgb{ .r = 0, .g = 0, .b = 0 } };
    const color_keys = [_]gt.c.GhosttyRenderStateData{
        gt.RS_DATA_COLOR_FOREGROUND,
        gt.RS_DATA_COLOR_BACKGROUND,
    };
    var color_values = [_]?*anyopaque{
        @ptrCast(&bgfg.fg),
        @ptrCast(&bgfg.bg),
    };
    _ = gt.c.ghostty_render_state_get_multi(term.render_state, color_keys.len, &color_keys, @ptrCast(&color_values), null);

    return bgfg;
}

fn temporarilyWritableBuffer(env: emacs.Env) bool {
    const was_read_only = env.bufferReadOnly();
    if (was_read_only) env.setBufferReadOnly(false);
    return was_read_only;
}

pub fn render(env: emacs.Env, term: *Terminal, render_state: gt.RenderState, skip: usize, force_full: bool) void {
    const default_colors = getDefaultColors(term);

    // Check dirty state.
    // force_full overrides: the buffer may have been erased by scrollback
    // sync / resize / rotation above, so we must rebuild even if
    // libghostty considers the cells clean.
    var dirty: c_int = gt.DIRTY_FALSE;
    _ = gt.c.ghostty_render_state_get(render_state, gt.RS_DATA_DIRTY, @ptrCast(&dirty));
    var has_wide_chars: bool = false;

    if (dirty != gt.DIRTY_FALSE or force_full) {
        // Set buffer default face
        var fg_hex: [7]u8 = undefined;
        var bg_hex: [7]u8 = undefined;
        _ = env.call2(
            emacs.sym.@"ghostel--set-buffer-face",
            env.makeString(formatColor(default_colors.fg, &fg_hex)),
            env.makeString(formatColor(default_colors.bg, &bg_hex)),
        );

        // Get row iterator
        if (gt.c.ghostty_render_state_get(render_state, gt.RS_DATA_ROW_ITERATOR, @ptrCast(&term.row_iterator)) != gt.SUCCESS) {
            return;
        }

        // Incremental redraw: only update dirty rows when possible.
        // force_full bypasses partial mode to avoid stale rows after scrolls.
        const dirty_full = force_full or dirty == gt.DIRTY_FULL;
        var row_count: usize = 0;
        while (gt.c.ghostty_render_state_row_iterator_next(term.row_iterator)) : (row_count += 1) {
            defer {
                // Clear per-row dirty flag
                const row_clean: bool = false;
                _ = gt.c.ghostty_render_state_row_set(term.row_iterator, gt.RS_ROW_OPT_DIRTY, @ptrCast(&row_clean));
            }

            if (row_count < skip) continue;

            // Only process dirty rows
            var dirty_row: bool = dirty_full;
            if (!dirty_full) {
                _ = gt.c.ghostty_render_state_row_get(term.row_iterator, gt.RS_ROW_DATA_DIRTY, @ptrCast(&dirty_row));
            }

            if (dirty_row) {
                env.deleteRegion(env.point(), env.lineBeginningPosition2());
                if (insertAndStyle(env, term, &default_colors)) |content| {
                    has_wide_chars |= content.has_wide;
                }
            } else {
                _ = env.forwardLine(1);
            }
        }

        // If there's anything left below the viewport, delete it
        env.deleteRegion(env.point(), env.pointMax());

        // Reset dirty state
        const dirty_false: c_int = gt.DIRTY_FALSE;
        _ = gt.c.ghostty_render_state_set(render_state, gt.RS_OPT_DIRTY, @ptrCast(&dirty_false));
    }

    // Plain-text URL/file detection is deferred and coalesced from Elisp
    // after redraw so interactive typing does not pay the regex/property
    // application cost inline. OSC-8 hyperlinks still stay native here.
    if (dirty != gt.DIRTY_FALSE) {
        if (has_wide_chars) {
            _ = env.call2(env.intern("set"), emacs.sym.@"ghostel--has-wide-chars", env.t());
        }
    }
}

pub fn renderCursor(env: emacs.Env, term: *Terminal) void {

    // Walk to the current viewport start
    env.gotoChar(env.pointMax());
    _ = env.forwardLine(-@as(i64, @intCast(term.rows)));
    const viewport_start_int = env.extractInteger(env.point());

    // Batch-fetch cursor style/visibility (always available).
    var cursor_visible: bool = true;
    var cursor_style: c_int = gt.CURSOR_BLOCK;
    {
        const cursor_keys = [_]gt.c.GhosttyRenderStateData{
            gt.RS_DATA_CURSOR_VISIBLE,
            gt.RS_DATA_CURSOR_VISUAL_STYLE,
        };
        var cursor_values = [_]?*anyopaque{
            @ptrCast(&cursor_visible),
            @ptrCast(&cursor_style),
        };
        _ = gt.c.ghostty_render_state_get_multi(term.render_state, cursor_keys.len, &cursor_keys, @ptrCast(&cursor_values), null);
    }

    // Position cursor (viewport-relative row -> absolute line).
    // X/Y are only valid when HAS_VALUE is true, so query separately
    // to avoid stopping the style batch above on NO_VALUE.
    var cursor_has_value: bool = false;
    _ = gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_CURSOR_VIEWPORT_HAS_VALUE, @ptrCast(&cursor_has_value));
    if (cursor_has_value) {
        var cx: u16 = 0;
        var cy: u16 = 0;
        _ = gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_CURSOR_VIEWPORT_X, @ptrCast(&cx));
        _ = gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_CURSOR_VIEWPORT_Y, @ptrCast(&cy));

        env.gotoCharN(viewport_start_int);
        _ = env.forwardLine(@as(i64, cy));
        if (!positionCursorByCell(env, term, cx, cy)) {
            env.moveToColumn(@as(i64, cx));
        }
    }

    _ = env.call2(
        emacs.sym.@"ghostel--set-cursor-style",
        env.makeInteger(@as(i64, cursor_style)),
        if (cursor_visible) env.t() else env.nil(),
    );
}

/// Redraw the terminal into the current Emacs buffer.
///
/// The Emacs buffer is a permanent record: all materialized scrollback sits
/// above the active viewport and is never evicted, even when libghostty
/// rotates rows out at the scrollback cap.
///
/// Detection relies on parking the libghostty viewport at `max_offset - 1`
/// at the end of every render (see bottom of this function).  On the next
/// call the parked position tells us two things:
///   - If scrollback was cleared, the viewport will have snapped back to the
///     bottom (`offset + len == total`), so we erase and rebuild.
///   - Otherwise, advancing the viewport by 1 lands exactly at the new
///     active area, and `total - offset` tells us how many rows to render.
///
/// When `force_full` is true, the viewport region is fully re-rendered
/// instead of using the incremental dirty-row path.
pub fn redraw(env: emacs.Env, term: *Terminal, force_full_arg: bool) void {
    const was_read_only = temporarilyWritableBuffer(env);
    defer if (was_read_only) env.setBufferReadOnly(true);
    // Snapshot the buffer's mark across the destructive ops below.  Both
    // paths — full (eraseBuffer / deleteRegion over the viewport) and
    // partial (per-row deleteRegion + insert) — move every marker in the
    // buffer by standard Emacs marker rules.  Point is owned by the
    // renderer and is placed at the TUI cursor on exit, but mark is user
    // state (C-SPC, region commands) and must survive the redraw.  Other
    // markers (e.g. evil's visual-beginning/end) remain the caller's
    // responsibility to preserve in elisp.
    const saved_mark: ?i64 = blk: {
        const pos = env.markerPosition(env.markMarker());
        if (!env.isNotNil(pos)) break :blk null;
        break :blk env.extractInteger(pos);
    };
    defer {
        if (saved_mark) |pos| {
            const pmax = env.extractInteger(env.pointMax());
            const clamped: i64 = if (pos > pmax) pmax else pos;
            _ = env.setMarker(env.markMarker(), env.makeInteger(clamped));
        }
    }

    var force_full = force_full_arg;

    // ---- Scrollback validity ------------------------------------------------
    // There are three cases where we clear scrollback:
    // 1. It was explicitly requested through `rebuild_pending`
    // 2. We had some scrollback but the scrollbar was reset from the parked
    //    MAX - 1 position. This indicates that libghostty cleared its
    //    scrollback and we follow after by clearing too.
    // 3. We had some scrollback but the scrollbar ended up at offset = 0, which
    //    means that we got so much scrolling that we scrolled all the way up
    //    and do not know how much we missed.
    var scrollbar = term.getScrollbar() orelse return;
    const scrollbar_reset = term.scrollback_in_buffer > 0 and scrollbar.len + scrollbar.offset == scrollbar.total;
    const scrollbar_hit_cap = term.scrollback_in_buffer > 0 and scrollbar.offset == 0;
    if (term.rebuild_pending or scrollbar_reset or scrollbar_hit_cap) {
        env.eraseBuffer();
        term.scrollback_in_buffer = 0;
        force_full = true;
        term.rebuild_pending = false;
    }

    // Unpark the viewport. When we have scrollback the viewport is sitting at
    // `max_offset - 1`; advance by 1 to reach the old active area, which is
    // also where the Emacs buffer currently ends. When we have no scrollback
    // there was no parking, so go to the top instead.
    if (term.scrollback_in_buffer > 0) {
        term.scrollViewport(gt.SCROLL_DELTA, 1);
        scrollbar.offset += 1;
        env.gotoChar(env.pointMax());
        _ = env.forwardLine(-@as(i64, @intCast(scrollbar.len)));
    } else {
        term.scrollViewport(gt.SCROLL_TOP, 0);
        scrollbar.offset = 0;
        env.gotoChar(env.pointMin());
    }

    if (scrollbar.len == 0) return;
    const offset_max = scrollbar.total - scrollbar.len;
    // Walk from the current viewport position to offset_max in viewport-sized
    // steps, rendering each chunk into the Emacs buffer. Consecutive positions
    // overlap by `scrollbar.len - step` rows when the remaining range is
    // smaller than a full viewport; `skip` tracks how many leading rows of the
    // next position were already rendered at the tail of the previous one.
    // After the loop the viewport sits at offset_max (the active area).
    const total_range = scrollbar.total - scrollbar.offset;
    const num_viewports = (total_range + scrollbar.len - 1) / scrollbar.len;
    var skip: usize = 0;
    var rendered_rows: usize = 0;
    for (0..num_viewports) |_| {
        if (gt.c.ghostty_render_state_update(term.render_state, term.terminal) != gt.SUCCESS) {
            return;
        }
        render(env, term, term.render_state, skip, force_full);
        rendered_rows += (scrollbar.len - skip);

        const max_step = offset_max - scrollbar.offset;
        const step = @min(max_step, scrollbar.len);
        skip = scrollbar.len - step;

        scrollbar.offset += step;
        term.scrollViewport(gt.SCROLL_DELTA, @intCast(step));
    }
    // rendered_rows covers all rows from the old active area to the new bottom,
    // so subtracting one viewport's worth gives the count of newly added
    // scrollback rows.
    term.scrollback_in_buffer += (rendered_rows - scrollbar.len);

    // Evict old scrollback if libghostty also did
    const libghostty_scrollback = term.getScrollbackRows();
    if (libghostty_scrollback < term.scrollback_in_buffer) {
        env.gotoChar(env.pointMin());
        _ = env.forwardLine(@as(i64, @intCast(term.scrollback_in_buffer - libghostty_scrollback)));
        env.deleteRegion(env.pointMin(), env.point());
        term.scrollback_in_buffer = libghostty_scrollback;
    }

    renderCursor(env, term);

    // Update working directory from OSC 7
    if (term.getPwd()) |pwd| {
        _ = env.call1(emacs.sym.@"ghostel--update-directory", env.makeString(pwd));
    }

    // Park the viewport one row above the bottom. On the next render, if
    // libghostty has cleared its scrollback the viewport will have snapped back
    // to the bottom (`offset + len == total`), which we treat as the rebuild
    // signal. If scrollback only grew, the parked position naturally points at
    // the old active area, and advancing by 1 reaches the new one.
    term.scrollViewport(gt.SCROLL_BOTTOM, 0);
    term.scrollViewport(gt.SCROLL_DELTA, -1);
}


pub fn redrawFullScrollback(env: emacs.Env, term: *Terminal) i64 {
    const total_rows = term.getTotalRows();
    if (total_rows == 0) return 1;

    // Save current viewport position
    const sb = term.getScrollbar() orelse return 1;
    const saved_offset = sb.offset;

    if (gt.c.ghostty_render_state_update(term.render_state, term.terminal) != gt.SUCCESS) {
        return 1;
    }
    const was_read_only = temporarilyWritableBuffer(env);
    defer if (was_read_only) env.setBufferReadOnly(true);
    const default_colors = getDefaultColors(term);

    // Set buffer default face
    var fg_hex: [7]u8 = undefined;
    var bg_hex: [7]u8 = undefined;
    _ = env.call2(
        emacs.sym.@"ghostel--set-buffer-face",
        env.makeString(formatColor(default_colors.fg, &fg_hex)),
        env.makeString(formatColor(default_colors.bg, &bg_hex)),
    );

    // Erase buffer
    env.eraseBuffer();

    // Scroll to top of scrollback
    term.scrollViewport(gt.SCROLL_TOP, 0);

    var rendered: usize = 0;

    while (rendered < total_rows) {
        // Query actual viewport position
        const cur_sb = term.getScrollbar() orelse break;
        const viewport_start = cur_sb.offset;

        // Update render state for current viewport
        if (gt.c.ghostty_render_state_update(term.render_state, term.terminal) != gt.SUCCESS) {
            break;
        }

        // Get row iterator
        if (gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_ROW_ITERATOR, @ptrCast(&term.row_iterator)) != gt.SUCCESS) {
            break;
        }

        // How many rows to skip (already rendered from previous page overlap)
        const viewport_rows: usize = term.rows;
        const skip: usize = if (rendered > viewport_start) rendered - viewport_start else 0;
        if (skip >= viewport_rows) break; // no new rows in this viewport
        // How many rows to take from this viewport
        const take: usize = @min(viewport_rows - skip, total_rows - rendered);
        if (take == 0) break; // no progress possible

        var row_in_page: usize = 0;
        while (gt.c.ghostty_render_state_row_iterator_next(term.row_iterator)) {
            defer row_in_page += 1;

            if (row_in_page < skip) {
                continue;
            }
            if (row_in_page >= skip + take) {
                break;
            }

            if (insertAndStyle(env, term, &default_colors) == null) {
                rendered += 1;
                continue;
            }
            rendered += 1;
        }

        if (rendered >= total_rows) break;

        // Scroll down by viewport size for next page
        term.scrollViewport(gt.SCROLL_DELTA, @intCast(term.rows));
    }

    // Restore viewport to saved position
    term.scrollViewport(gt.SCROLL_TOP, 0);
    if (saved_offset > 0) {
        term.scrollViewport(gt.SCROLL_DELTA, @intCast(saved_offset));
    }

    // Return 1-based line number of the original viewport top
    return @as(i64, @intCast(saved_offset)) + 1;
}
