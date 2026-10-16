const builtin = @import("builtin");

test {
    _ = @import("emacs");
    _ = @import("png.zig");
    _ = @import("ppm.zig");
    _ = @import("image_composition.zig");
    _ = @import("KittyRenderer.zig");
    _ = @import("GlyphMetricsCache.zig");
    _ = @import("fixed_array_list.zig");
    _ = @import("RefCount.zig");
    _ = @import("input.zig");
    _ = @import("RingQueue.zig");
    _ = @import("version.zig");
    if (builtin.os.tag == .windows) {
        _ = @import("ConPtyProcess.zig");
    } else {
        _ = @import("PosixPtyProcess.zig");
        _ = @import("pty_utils.zig");
    }
}
