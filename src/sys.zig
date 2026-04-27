/// System interface for libghostty — PNG decoder and logging.
const std = @import("std");
const gt = @import("ghostty.zig");
const png = @import("png.zig");

/// PNG decode callback for libghostty's kitty graphics support.
/// Wraps `png.decode` to copy decoded pixels into a libghostty-owned
/// buffer.
fn decodePng(
    _: ?*anyopaque,
    allocator: ?*const gt.c.GhosttyAllocator,
    data: [*c]const u8,
    data_len: usize,
    out: ?*gt.c.GhosttySysImage,
) callconv(.c) bool {
    const out_ptr = out orelse return false;
    if (data_len == 0) return false;

    // Decode into a Zig-owned buffer first, then memcpy into a buffer
    // owned by libghostty's allocator.  The extra copy lets the
    // decoder live in a libghostty-free module that's straightforward
    // to unit-test (`src/png.zig`).
    const result = png.decode(std.heap.c_allocator, data[0..data_len]) catch return false;
    defer std.heap.c_allocator.free(result.data);

    const buf = gt.c.ghostty_alloc(allocator, result.data.len) orelse return false;
    @memcpy(buf[0..result.data.len], result.data);

    out_ptr.width = result.width;
    out_ptr.height = result.height;
    out_ptr.data = buf;
    out_ptr.data_len = result.data.len;
    return true;
}

/// Install system callbacks.  Call once at module init before any
/// terminal is created.
///
/// `GHOSTTY_SYS_OPT_LOG` is intentionally NOT installed here — that
/// global slot is owned by `ghostel--enable-vt-log` /
/// `ghostel--disable-vt-log` (see `module.zig:fnEnableVtLog`), which
/// route libghostty's log output to the `*ghostel-debug*` buffer.
/// Installing a debug-build stderr logger here would race with the
/// VT-log path: enabling vt-log would silently displace it, and
/// disabling vt-log would clear ours.  If you need always-on stderr
/// logging during development, set `OPT_LOG` directly from a temporary
/// patch instead of from this function.
pub fn init() void {
    _ = gt.c.ghostty_sys_set(
        gt.c.GHOSTTY_SYS_OPT_DECODE_PNG,
        @as(?*const anyopaque, @ptrCast(&decodePng)),
    );
}
