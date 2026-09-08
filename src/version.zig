const std = @import("std");

/// Module version — single source of truth for src/module.zig and build.zig.
/// Keep in sync with `version` in build.zig.zon and `Version:` in lisp/ghostel.el.
pub const version = "0.56.0";

pub fn selectBuildVersion(override: ?[]const u8) []const u8 {
    const value = override orelse return version;
    return if (value.len == 0) version else value;
}

test "select build version uses non-empty override or source fallback" {
    const Case = struct {
        override: ?[]const u8,
        expected: []const u8,
    };
    const cases = [_]Case{
        .{ .override = null, .expected = "0.56.0" },
        .{ .override = "", .expected = "0.56.0" },
        .{ .override = "0.56.0.162.ec928f", .expected = "0.56.0.162.ec928f" },
    };

    for (cases) |case| {
        try std.testing.expectEqualStrings(
            case.expected,
            selectBuildVersion(case.override),
        );
    }
}
