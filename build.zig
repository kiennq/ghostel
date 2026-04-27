const std = @import("std");

const vendored_emacs_module_dir = "vendor";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_release = optimize != .Debug;
    const target_os = target.result.os.tag;
    const emacs_module_dir = resolveEmacsModuleDir(b);
    const ghostty_dep = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .@"emit-lib-vt" = true,
    });

    const ghostty_lib = ghostty_dep.artifact("ghostty-vt-static");

    const mod = b.createModule(.{
        .root_source_file = b.path("src/module.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = if (is_release) true else null,
        .omit_frame_pointer = if (is_release) true else null,
    });
    addModuleIncludes(mod, emacs_module_dir, ghostty_lib);
    mod.linkLibrary(ghostty_lib);

    // stb_image for PNG decoding (kitty graphics)
    mod.addIncludePath(b.path("vendor/stb"));
    mod.addCSourceFile(.{ .file = b.path("src/stb_image.c") });

    const lib = b.addLibrary(.{
        .name = "ghostel-module",
        .linkage = .dynamic,
        .root_module = mod,
    });
    if (is_release) {
        lib.link_gc_sections = true;
        lib.link_function_sections = true;
        lib.link_data_sections = true;
        lib.dead_strip_dylibs = true;

        if (target_os == .linux) {
            lib.setVersionScript(b.path("symbols.map"));
        }
    }

    b.installArtifact(lib);

    const copy_step = b.addInstallFile(
        lib.getEmittedBin(),
        moduleOutputName(target_os),
    );
    b.getInstallStep().dependOn(&copy_step.step);

    // ----------------------------------------------------------------
    // `zig build test` — pure-Zig unit tests for the decoder helpers.
    //
    // Only modules that don't depend on libghostty or emacs-module are
    // covered here (ppm.zig, png.zig).  End-to-end tests through the
    // C API run via `make test-native`.
    // ----------------------------------------------------------------
    const test_step = b.step("test", "Run Zig unit tests");

    const ppm_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ppm.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(ppm_tests).step);

    const png_test_mod = b.createModule(.{
        .root_source_file = b.path("src/png.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    png_test_mod.addIncludePath(b.path("vendor/stb"));
    png_test_mod.addCSourceFile(.{ .file = b.path("src/stb_image.c") });
    const png_tests = b.addTest(.{ .root_module = png_test_mod });
    test_step.dependOn(&b.addRunArtifact(png_tests).step);
}

fn addModuleIncludes(
    mod: *std.Build.Module,
    emacs_module_dir: std.Build.LazyPath,
    ghostty_lib: *std.Build.Step.Compile,
) void {
    mod.addSystemIncludePath(emacs_module_dir);
    mod.addIncludePath(ghostty_lib.getEmittedIncludeTree());
}

fn resolveEmacsModuleDir(b: *std.Build) std.Build.LazyPath {
    if (b.graph.env_map.get("EMACS_INCLUDE_DIR")) |dir| {
        ensureEmacsModuleHeaderExists(b.allocator, "EMACS_INCLUDE_DIR", dir);
        return .{ .cwd_relative = dir };
    }

    if (b.graph.env_map.get("EMACS_BIN_DIR")) |bin_dir| {
        const include_dir = resolveEmacsIncludeDirFromBin(b.allocator, bin_dir) orelse
            std.debug.panic(
                "EMACS_BIN_DIR={s} does not resolve to a directory containing emacs-module.h",
                .{bin_dir},
            );
        return .{ .cwd_relative = include_dir };
    }

    return .{ .cwd_relative = vendored_emacs_module_dir };
}

fn resolveEmacsIncludeDirFromBin(
    allocator: std.mem.Allocator,
    bin_dir: []const u8,
) ?[]const u8 {
    const include_dir = std.fs.path.join(allocator, &.{ bin_dir, "..", "include" }) catch
        @panic("out of memory while resolving EMACS_BIN_DIR");
    if (dirHasEmacsModuleHeader(allocator, include_dir)) {
        return include_dir;
    }
    allocator.free(include_dir);

    const share_include_dir = std.fs.path.join(
        allocator,
        &.{ bin_dir, "..", "share", "emacs", "include" },
    ) catch @panic("out of memory while resolving EMACS_BIN_DIR");
    if (dirHasEmacsModuleHeader(allocator, share_include_dir)) {
        return share_include_dir;
    }
    allocator.free(share_include_dir);

    return null;
}

fn ensureEmacsModuleHeaderExists(
    allocator: std.mem.Allocator,
    env_name: []const u8,
    dir: []const u8,
) void {
    if (!dirHasEmacsModuleHeader(allocator, dir)) {
        std.debug.panic("{s}={s} does not contain emacs-module.h", .{ env_name, dir });
    }
}

fn dirHasEmacsModuleHeader(allocator: std.mem.Allocator, dir: []const u8) bool {
    const header_path = std.fs.path.join(allocator, &.{ dir, "emacs-module.h" }) catch
        @panic("out of memory while resolving emacs-module.h");
    defer allocator.free(header_path);

    std.fs.cwd().access(header_path, .{}) catch return false;
    return true;
}

fn moduleOutputName(target_os: std.Target.Os.Tag) []const u8 {
    return switch (target_os) {
        .macos => "../ghostel-module.dylib",
        else => "../ghostel-module.so",
    };
}
