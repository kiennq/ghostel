/// Zig bindings for the libghostty-vt C API.
const std = @import("std");

pub const c = @cImport({
@cInclude("ghostty/vt.h");
});

// Re-export commonly used types
pub const Terminal = c.GhosttyTerminal;
pub const TerminalOptions = c.GhosttyTerminalOptions;
pub const TerminalOption = c.GhosttyTerminalOption;
pub const TerminalData = c.GhosttyTerminalData;
pub const TerminalScrollViewport = c.GhosttyTerminalScrollViewport;
pub const TerminalScrollViewportTag = c.GhosttyTerminalScrollViewportTag;

pub const RenderState = c.GhosttyRenderState;
pub const RenderStateRowIterator = c.GhosttyRenderStateRowIterator;
pub const RenderStateRowCells = c.GhosttyRenderStateRowCells;
pub const RenderStateDirty = c.GhosttyRenderStateDirty;
pub const RenderStateData = c.GhosttyRenderStateData;
pub const RenderStateRowData = c.GhosttyRenderStateRowData;
pub const RenderStateRowCellsData = c.GhosttyRenderStateRowCellsData;
pub const RenderStateOption = c.GhosttyRenderStateOption;
pub const RenderStateRowOption = c.GhosttyRenderStateRowOption;
pub const RenderStateColors = c.GhosttyRenderStateColors;
pub const RenderStateCursorVisualStyle = c.GhosttyRenderStateCursorVisualStyle;

pub const Style = c.GhosttyStyle;
pub const StyleColor = c.GhosttyStyleColor;
pub const ColorRgb = c.GhosttyColorRgb;
pub const GhosttyString = c.GhosttyString;
pub const Result = c.GhosttyResult;

pub const WritePtyFn = c.GhosttyTerminalWritePtyFn;
pub const BellFn = c.GhosttyTerminalBellFn;
pub const TitleChangedFn = c.GhosttyTerminalTitleChangedFn;
pub const DeviceAttributesFn = c.GhosttyTerminalDeviceAttributesFn;
pub const DeviceAttributes = c.GhosttyDeviceAttributes;
pub const SizeFn = c.GhosttyTerminalSizeFn;
pub const SizeReportSize = c.GhosttySizeReportSize;

// Result constants
pub const SUCCESS = c.GHOSTTY_SUCCESS;
pub const OUT_OF_MEMORY = c.GHOSTTY_OUT_OF_MEMORY;
pub const INVALID_VALUE = c.GHOSTTY_INVALID_VALUE;
pub const NO_VALUE = c.GHOSTTY_NO_VALUE;

// Terminal option constants
pub const OPT_USERDATA = c.GHOSTTY_TERMINAL_OPT_USERDATA;
pub const OPT_WRITE_PTY = c.GHOSTTY_TERMINAL_OPT_WRITE_PTY;
pub const OPT_BELL = c.GHOSTTY_TERMINAL_OPT_BELL;
pub const OPT_TITLE_CHANGED = c.GHOSTTY_TERMINAL_OPT_TITLE_CHANGED;
pub const OPT_DEVICE_ATTRIBUTES = c.GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES;
pub const OPT_XTVERSION = c.GHOSTTY_TERMINAL_OPT_XTVERSION;
pub const OPT_SIZE = c.GHOSTTY_TERMINAL_OPT_SIZE;
pub const OPT_PWD = c.GHOSTTY_TERMINAL_OPT_PWD;
pub const OPT_COLOR_FOREGROUND = c.GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND;
pub const OPT_COLOR_BACKGROUND = c.GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND;
pub const OPT_COLOR_PALETTE = c.GHOSTTY_TERMINAL_OPT_COLOR_PALETTE;
pub const DATA_COLOR_PALETTE = c.GHOSTTY_TERMINAL_DATA_COLOR_PALETTE;
pub const DATA_COLOR_FOREGROUND = c.GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND;
pub const DATA_COLOR_BACKGROUND = c.GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND;

// Kitty graphics terminal options
pub const OPT_KITTY_IMAGE_STORAGE_LIMIT = c.GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT;
pub const OPT_KITTY_IMAGE_MEDIUM_FILE = c.GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_FILE;
pub const OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE = c.GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE;
pub const OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM = c.GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM;
pub const DATA_KITTY_GRAPHICS = c.GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS;

// Kitty graphics types
pub const KittyGraphics = c.GhosttyKittyGraphics;
pub const KittyGraphicsImage = c.GhosttyKittyGraphicsImage;
pub const KittyGraphicsPlacementIterator = c.GhosttyKittyGraphicsPlacementIterator;
pub const KittyGraphicsPlacementRenderInfo = c.GhosttyKittyGraphicsPlacementRenderInfo;
pub const KittyImageFormat = c.GhosttyKittyImageFormat;
pub const KittyImageCompression = c.GhosttyKittyImageCompression;

// Terminal data constants
pub const DATA_COLS = c.GHOSTTY_TERMINAL_DATA_COLS;
pub const DATA_ROWS = c.GHOSTTY_TERMINAL_DATA_ROWS;
pub const DATA_TITLE = c.GHOSTTY_TERMINAL_DATA_TITLE;
pub const DATA_PWD = c.GHOSTTY_TERMINAL_DATA_PWD;
pub const DATA_MOUSE_TRACKING = c.GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING;
pub const DATA_CURSOR_PENDING_WRAP = c.GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP;

// Render state data constants
pub const RS_DATA_DIRTY = c.GHOSTTY_RENDER_STATE_DATA_DIRTY;
pub const RS_DATA_COLS = c.GHOSTTY_RENDER_STATE_DATA_COLS;
pub const RS_DATA_ROWS = c.GHOSTTY_RENDER_STATE_DATA_ROWS;
pub const RS_DATA_ROW_ITERATOR = c.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR;
pub const RS_DATA_COLOR_BACKGROUND = c.GHOSTTY_RENDER_STATE_DATA_COLOR_BACKGROUND;
pub const RS_DATA_COLOR_FOREGROUND = c.GHOSTTY_RENDER_STATE_DATA_COLOR_FOREGROUND;
pub const RS_DATA_CURSOR_VISUAL_STYLE = c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE;
pub const RS_DATA_CURSOR_VISIBLE = c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE;
pub const RS_DATA_CURSOR_BLINKING = c.GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING;
pub const RS_DATA_CURSOR_VIEWPORT_HAS_VALUE = c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE;
pub const RS_DATA_CURSOR_VIEWPORT_X = c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X;
pub const RS_DATA_CURSOR_VIEWPORT_Y = c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y;

// Render state row data constants
pub const RS_ROW_DATA_DIRTY = c.GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY;
pub const RS_ROW_DATA_CELLS = c.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS;

// Raw row data constants (from screen API, via ROW_DATA_RAW)
pub const ROW_DATA_WRAP = c.GHOSTTY_ROW_DATA_WRAP;
pub const ROW_DATA_SEMANTIC_PROMPT = c.GHOSTTY_ROW_DATA_SEMANTIC_PROMPT;
pub const ROW_DATA_HYPERLINK = c.GHOSTTY_ROW_DATA_HYPERLINK;
// Render state row cells data constants
pub const RS_CELLS_DATA_STYLE = c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE;
pub const RS_CELLS_DATA_GRAPHEMES_LEN = c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN;
pub const RS_CELLS_DATA_GRAPHEMES_BUF = c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF;
pub const RS_CELLS_DATA_BG_COLOR = c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR;
pub const RS_CELLS_DATA_FG_COLOR = c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR;

// Render state option constants
pub const RS_OPT_DIRTY = c.GHOSTTY_RENDER_STATE_OPTION_DIRTY;
pub const RS_ROW_OPT_DIRTY = c.GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY;

// Dirty constants
pub const DIRTY_FALSE: c_int = c.GHOSTTY_RENDER_STATE_DIRTY_FALSE;
pub const DIRTY_PARTIAL: c_int = c.GHOSTTY_RENDER_STATE_DIRTY_PARTIAL;
pub const DIRTY_FULL: c_int = c.GHOSTTY_RENDER_STATE_DIRTY_FULL;

// Cursor visual style constants
pub const CURSOR_BAR: c_int = c.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR;
pub const CURSOR_BLOCK: c_int = c.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK;
pub const CURSOR_UNDERLINE: c_int = c.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE;
pub const CURSOR_BLOCK_HOLLOW: c_int = c.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW;

// Scroll viewport constants
pub const SCROLL_TOP: c_int = c.GHOSTTY_SCROLL_VIEWPORT_TOP;
pub const SCROLL_BOTTOM: c_int = c.GHOSTTY_SCROLL_VIEWPORT_BOTTOM;
pub const SCROLL_DELTA: c_int = c.GHOSTTY_SCROLL_VIEWPORT_DELTA;

// Point types
pub const Point = c.GhosttyPoint;
pub const PointTag = c.GhosttyPointTag;
pub const PointCoordinate = c.GhosttyPointCoordinate;
pub const PointValue = c.GhosttyPointValue;
pub const GridRef = c.GhosttyGridRef;
pub const OUT_OF_SPACE = c.GHOSTTY_OUT_OF_SPACE;

// Point tag constants
pub const POINT_TAG_VIEWPORT: c_int = c.GHOSTTY_POINT_TAG_VIEWPORT;

// Scrollbar / total rows constants
pub const DATA_TOTAL_ROWS = c.GHOSTTY_TERMINAL_DATA_TOTAL_ROWS;
pub const DATA_SCROLLBACK_ROWS = c.GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS;
pub const DATA_SCROLLBAR = c.GHOSTTY_TERMINAL_DATA_SCROLLBAR;
pub const TerminalScrollbar = c.GhosttyTerminalScrollbar;

// Formatter types
pub const Formatter = c.GhosttyFormatter;
pub const FormatterTerminalOptions = c.GhosttyFormatterTerminalOptions;
pub const FormatterTerminalExtra = c.GhosttyFormatterTerminalExtra;
pub const FormatterScreenExtra = c.GhosttyFormatterScreenExtra;
pub const FORMATTER_PLAIN = c.GHOSTTY_FORMATTER_FORMAT_PLAIN;
pub const FORMATTER_FORMAT_HTML: c_int = c.GHOSTTY_FORMATTER_FORMAT_HTML;

pub const Error = error{ OutOfMemory, InvalidValue, NoValue, OutOfSpace, Unknown };

pub fn toError(c_error: c_int) Error!void {
switch (c_error) {
SUCCESS => return,
OUT_OF_MEMORY => return Error.OutOfMemory,
INVALID_VALUE => return Error.InvalidValue,
NO_VALUE => return Error.NoValue,
OUT_OF_SPACE => return Error.OutOfSpace,
else => return Error.Unknown,
}
}

pub const Multi = struct { c_uint, type };

fn Accessor(comptime Target: type, getter: anytype, setter: anytype, multi_getter: anytype) type {
return struct {
pub fn get(comptime T: type, target: Target, data: c_uint) !T {
comptime if (@TypeOf(getter) == void) @compileError("Not readable");
var value: T = undefined;
try toError(@call(.auto, getter, .{ target, data, @as(?*anyopaque, @ptrCast(&value)) }));
return value;
}

pub fn getOpt(comptime T: type, target: Target, data: c_uint) !?T {
comptime if (@TypeOf(getter) == void) @compileError("Not readable");
if (get(T, target, data)) |value| {
return value;
} else |err| return switch (err) {
Error.NoValue => null,
else => err,
};
}

fn MultiValues(comptime data: anytype) type {
var fields: [data.len]std.builtin.Type.StructField = undefined;
for (data, 0..) |d, i| {
fields[i] = std.builtin.Type.StructField{
.name = std.fmt.comptimePrint("{d}", .{i}),
.type = d[1],
.default_value_ptr = null,
.is_comptime = false,
.alignment = @alignOf(d[1]),
};
}

// zig fmt: off
return @Type(std.builtin.Type{.@"struct" = .{
.layout = .auto,
.fields = &fields,
.decls = &[_]std.builtin.Type.Declaration{},
.is_tuple = true
}});
// zig fmt: on
}

pub fn getMulti(target: Target, comptime keys_types: []const Multi) !MultiValues(keys_types) {
comptime if (@TypeOf(getter) == void) @compileError("Not multi gettable");
var keys: [keys_types.len]c_uint = undefined;
var values: MultiValues(keys_types) = undefined;
var ptrs: [keys_types.len]?*anyopaque = undefined;
inline for (keys_types, 0..) |key_type, i| {
keys[i] = key_type[0];
ptrs[i] = &values[i];
}

var num_written: usize = 0;
try toError(@call(.auto, multi_getter, .{ target, keys_types.len, &keys, &ptrs, &num_written }));
return if (num_written == keys_types.len) values else error.IncompleteRead;
}

pub fn read(target: Target, data: c_uint, out_ptr: anytype) !void {
comptime if (@TypeOf(getter) == void) @compileError("Not readable");
try toError(@call(.auto, getter, .{ target, data, @as(?*anyopaque, @ptrCast(out_ptr)) }));
}

pub fn set(target: Target, data: c_uint, value: anytype) !void {
comptime if (@TypeOf(setter) == void) @compileError("Not writable");
try toError(@call(.auto, setter, .{ target, data, @as(?*const anyopaque, @ptrCast(&value)) }));
}
};
}

pub const terminal_data = Accessor(c.GhosttyTerminal, c.ghostty_terminal_get, void, void);
pub const kitty_graphics_data = Accessor(c.GhosttyKittyGraphics, c.ghostty_kitty_graphics_get, void, void);
pub const kitty_placement_data = Accessor(c.GhosttyKittyGraphicsPlacementIterator, c.ghostty_kitty_graphics_placement_get, void, void);
pub const row = Accessor(c.GhosttyRow, c.ghostty_row_get, void, c.ghostty_row_get_multi);
pub const cell = Accessor(c.GhosttyCell, c.ghostty_cell_get, void, void);
pub const rs = Accessor(RenderState, c.ghostty_render_state_get, c.ghostty_render_state_set, c.ghostty_render_state_get_multi);
pub const rs_row = Accessor(RenderStateRowIterator, c.ghostty_render_state_row_get, c.ghostty_render_state_row_set, void);
pub const rs_row_cells = Accessor(RenderStateRowCells, c.ghostty_render_state_row_cells_get, void, void);

pub fn terminalModeGet(term: c.GhosttyTerminal, mode: c.GhosttyMode) !bool {
var enabled: bool = false;
try toError(c.ghostty_terminal_mode_get(term, mode, &enabled));
return enabled;
}

pub const rs_row_cells_next = c.ghostty_render_state_row_cells_next;
pub const rs_row_next = c.ghostty_render_state_row_iterator_next;

pub fn renderStateUpdate(state: RenderState, terminal: Terminal) !void {
try toError(c.ghostty_render_state_update(state, terminal));
}

pub const term_resize = c.ghostty_terminal_resize;
