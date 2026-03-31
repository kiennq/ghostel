const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/module.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Emacs module header — check EMACS_INCLUDE_DIR env, then platform defaults
    if (b.graph.env_map.get("EMACS_INCLUDE_DIR")) |inc_dir| {
        mod.addSystemIncludePath(.{ .cwd_relative = inc_dir });
    } else {
        const resolved = target.result;
        if (resolved.os.tag == .macos) {
            mod.addSystemIncludePath(.{
                .cwd_relative = "/Applications/Emacs.app/Contents/Resources/include",
            });
        } else {
            mod.addSystemIncludePath(.{
                .cwd_relative = "/usr/include",
            });
        }
    }

    // libghostty-vt headers — try both source tree and build output
    mod.addIncludePath(b.path("vendor/ghostty/include"));
    mod.addIncludePath(b.path("vendor/ghostty/zig-out/include"));

    // Full build: link against pre-built static libraries
    const lib = b.addLibrary(.{
        .name = "ghostel-module",
        .linkage = .dynamic,
        .root_module = mod,
    });

    lib.addObjectFile(b.path("vendor/ghostty/zig-out/lib/libghostty-vt.a"));
    lib.addObjectFile(b.path("vendor/ghostty/zig-out/lib/libsimdutf.a"));
    lib.addObjectFile(b.path("vendor/ghostty/zig-out/lib/libhighway.a"));
    lib.linkSystemLibrary("c++");

    b.installArtifact(lib);

    // Copy the shared library to project root for easy Emacs loading.
    const target_os = target.result.os.tag;
    const lib_name = if (target_os == .macos)
        "../ghostel-module.dylib"
    else
        "../ghostel-module.so";
    const copy_step = b.addInstallFile(
        lib.getEmittedBin(),
        lib_name,
    );
    b.getInstallStep().dependOn(&copy_step.step);

    // "zig build check" — compile-only step for CI.
    // Verifies all Zig source compiles against headers without needing
    // the pre-built static libraries (no linking).
    const check_mod = b.createModule(.{
        .root_source_file = b.path("src/module.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    if (b.graph.env_map.get("EMACS_INCLUDE_DIR")) |inc_dir| {
        check_mod.addSystemIncludePath(.{ .cwd_relative = inc_dir });
    } else {
        const check_resolved = target.result;
        if (check_resolved.os.tag == .macos) {
            check_mod.addSystemIncludePath(.{
                .cwd_relative = "/Applications/Emacs.app/Contents/Resources/include",
            });
        } else {
            check_mod.addSystemIncludePath(.{
                .cwd_relative = "/usr/include",
            });
        }
    }

    check_mod.addIncludePath(b.path("vendor/ghostty/include"));
    check_mod.addIncludePath(b.path("vendor/ghostty/zig-out/include"));

    const check_obj = b.addObject(.{
        .name = "ghostel-module-check",
        .root_module = check_mod,
    });

    const check = b.step("check", "Check that the module compiles (no linking)");
    check.dependOn(&check_obj.step);
}
