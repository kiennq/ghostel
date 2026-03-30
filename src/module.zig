/// Ghostel — Emacs dynamic module entry point.
///
/// This is the top-level file compiled into ghostel-module.so/.dylib.
/// It exports emacs_module_init (the C entry point Emacs calls on load)
/// and registers all Elisp-callable functions.
const std = @import("std");
const emacs = @import("emacs.zig");
const Terminal = @import("terminal.zig");
const gt = @import("ghostty.zig");

const c = emacs.c;

// ---------------------------------------------------------------------------
// Module entry point
// ---------------------------------------------------------------------------

/// Emacs calls this when loading the dynamic module.
export fn emacs_module_init(runtime: *c.struct_emacs_runtime) callconv(.c) c_int {
    if (runtime.size < @sizeOf(c.struct_emacs_runtime)) {
        return 1; // ABI mismatch
    }

    const raw_env = runtime.get_environment.?(runtime);
    const env = emacs.Env.init(raw_env);

    // Register functions
    env.bindFunction("ghostel--new", 2, 3, &fnNew, "Create a new ghostel terminal.\n\n(ghostel--new ROWS COLS &optional MAX-SCROLLBACK)");
    env.bindFunction("ghostel--write-input", 2, 2, &fnWriteInput, "Write raw bytes to the terminal.\n\n(ghostel--write-input TERM DATA)");
    env.bindFunction("ghostel--set-size", 3, 3, &fnSetSize, "Resize the terminal.\n\n(ghostel--set-size TERM ROWS COLS)");
    env.bindFunction("ghostel--get-title", 1, 1, &fnGetTitle, "Get the terminal title.\n\n(ghostel--get-title TERM)");
    env.bindFunction("ghostel--redraw", 1, 1, &fnRedraw, "Redraw dirty regions of the terminal into the current buffer.\n\n(ghostel--redraw TERM)");
    env.bindFunction("ghostel--scroll", 2, 2, &fnScroll, "Scroll the terminal viewport by DELTA lines.\n\n(ghostel--scroll TERM DELTA)");

    env.provide("ghostel-module");
    return 0;
}

// ---------------------------------------------------------------------------
// Plugin version — required by Emacs >= 27
// ---------------------------------------------------------------------------

export const plugin_is_GPL_compatible: c_int = 0;

// ---------------------------------------------------------------------------
// Exported Elisp functions
// ---------------------------------------------------------------------------

/// (ghostel--new ROWS COLS &optional MAX-SCROLLBACK)
fn fnNew(raw_env: ?*c.emacs_env, nargs: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const rows: u16 = @intCast(env.extractInteger(args[0]));
    const cols: u16 = @intCast(env.extractInteger(args[1]));
    const max_scrollback: usize = if (nargs > 2 and env.isNotNil(args[2]))
        @intCast(env.extractInteger(args[2]))
    else
        10000;

    const term = std.heap.c_allocator.create(Terminal) catch {
        env.signalError("ghostel: out of memory");
        return env.nil();
    };

    term.* = Terminal.init(cols, rows, max_scrollback) catch {
        std.heap.c_allocator.destroy(term);
        env.signalError("ghostel: failed to create terminal");
        return env.nil();
    };

    // Register callbacks
    term.setUserdata(term);
    term.setWritePty(&writePtyCallback);
    term.setBell(&bellCallback);
    term.setTitleChanged(&titleChangedCallback);

    // Set default colors (light gray on black)
    const default_fg = gt.ColorRgb{ .r = 204, .g = 204, .b = 204 };
    const default_bg = gt.ColorRgb{ .r = 0, .g = 0, .b = 0 };
    term.setColorForeground(&default_fg);
    term.setColorBackground(&default_bg);

    return env.makeUserPtr(&Terminal.emacsFinalize, term);
}

/// (ghostel--write-input TERM DATA)
fn fnWriteInput(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(Terminal, args[0]) orelse {
        env.signalError("ghostel: invalid terminal handle");
        return env.nil();
    };

    // Extract string data
    var buf: [65536]u8 = undefined;
    const data = env.extractString(args[1], &buf) orelse {
        env.signalError("ghostel: failed to extract input data");
        return env.nil();
    };

    // Stash env for callbacks
    term.env = env;
    defer term.env = null;

    term.vtWrite(data);
    return env.nil();
}

/// (ghostel--set-size TERM ROWS COLS)
fn fnSetSize(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(Terminal, args[0]) orelse {
        env.signalError("ghostel: invalid terminal handle");
        return env.nil();
    };

    const rows: u16 = @intCast(env.extractInteger(args[1]));
    const cols: u16 = @intCast(env.extractInteger(args[2]));

    term.resize(cols, rows) catch {
        env.signalError("ghostel: resize failed");
        return env.nil();
    };

    return env.nil();
}

/// (ghostel--get-title TERM)
fn fnGetTitle(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(Terminal, args[0]) orelse return env.nil();

    if (term.getTitle()) |title| {
        return env.makeString(title);
    }
    return env.nil();
}

/// (ghostel--redraw TERM)
/// Reads the render state and updates the current Emacs buffer.
fn fnRedraw(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(Terminal, args[0]) orelse return env.nil();

    // Update render state from terminal
    if (gt.c.ghostty_render_state_update(term.render_state, term.terminal) != gt.SUCCESS) {
        return env.nil();
    }

    // Check dirty state
    var dirty: c_int = gt.DIRTY_FALSE;
    if (gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_DIRTY, @ptrCast(&dirty)) != gt.SUCCESS) {
        return env.nil();
    }

    if (dirty == gt.DIRTY_FALSE) {
        return env.nil(); // Nothing to redraw
    }

    // Erase buffer and redraw everything for now (Phase 2: plain text only)
    _ = env.call0(env.intern("erase-buffer"));

    // Get row iterator
    if (gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_ROW_ITERATOR, @ptrCast(&term.row_iterator)) != gt.SUCCESS) {
        return env.nil();
    }

    // Iterate rows
    var text_buf: [16384]u8 = undefined;
    while (gt.c.ghostty_render_state_row_iterator_next(term.row_iterator)) {
        // Get cells for this row
        if (gt.c.ghostty_render_state_row_get(term.row_iterator, gt.RS_ROW_DATA_CELLS, @ptrCast(&term.row_cells)) != gt.SUCCESS) {
            continue;
        }

        // Build text for this row
        var text_len: usize = 0;
        while (gt.c.ghostty_render_state_row_cells_next(term.row_cells)) {
            // Get grapheme length
            var graphemes_len: u32 = 0;
            if (gt.c.ghostty_render_state_row_cells_get(term.row_cells, gt.RS_CELLS_DATA_GRAPHEMES_LEN, @ptrCast(&graphemes_len)) != gt.SUCCESS) {
                continue;
            }

            if (graphemes_len == 0) continue; // Empty/spacer cell

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
                if (remaining.len < 4) break; // Buffer full
                const encoded_len = std.unicode.utf8Encode(cp, remaining) catch continue;
                text_len += encoded_len;
            }
        }

        // Insert the row text
        if (text_len > 0) {
            _ = env.call1(env.intern("insert"), env.makeString(text_buf[0..text_len]));
        }
        // Insert newline between rows
        _ = env.call1(env.intern("insert"), env.makeString("\n"));
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

        // Move point to cursor position: (goto-char (+ 1 (* (1+ cols) cy) cx))
        // Each row is cols chars + 1 newline = (cols+1) chars per line
        const pos: i64 = 1 + @as(i64, cy) * @as(i64, term.cols + 1) + @as(i64, cx);
        _ = env.call1(env.intern("goto-char"), env.makeInteger(pos));
    }

    return env.nil();
}

/// (ghostel--scroll TERM DELTA)
fn fnScroll(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(Terminal, args[0]) orelse return env.nil();

    const delta = env.extractInteger(args[1]);
    term.scrollViewport(gt.SCROLL_DELTA, @intCast(delta));

    return env.nil();
}

// ---------------------------------------------------------------------------
// Ghostty callbacks — invoked synchronously during vtWrite
// ---------------------------------------------------------------------------

/// Called when the terminal needs to write response data back to the PTY.
fn writePtyCallback(_: gt.Terminal, userdata: ?*anyopaque, data: [*c]const u8, len: usize) callconv(.c) void {
    const term: *Terminal = @ptrCast(@alignCast(userdata));
    const env = term.env orelse return;

    if (len == 0) return;
    const str = env.makeString(data[0..len]);
    _ = env.call1(env.intern("ghostel--flush-output"), str);
}

/// Called when the terminal receives BEL.
fn bellCallback(_: gt.Terminal, userdata: ?*anyopaque) callconv(.c) void {
    const term: *Terminal = @ptrCast(@alignCast(userdata));
    const env = term.env orelse return;

    _ = env.call0(env.intern("ding"));
}

/// Called when the terminal title changes.
fn titleChangedCallback(_: gt.Terminal, userdata: ?*anyopaque) callconv(.c) void {
    const term: *Terminal = @ptrCast(@alignCast(userdata));
    const env = term.env orelse return;

    if (term.getTitle()) |title| {
        _ = env.call1(env.intern("ghostel--set-title"), env.makeString(title));
    }
}
