const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ghostty_dep = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .@"emit-lib-vt" = true,
    });

    const ghostty_vt = ghostty_dep.artifact("ghostty-vt-static");

    const mod = b.createModule(.{
        .root_source_file = b.path("src/module.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Add Emacs module header include path
    mod.addSystemIncludePath(.{
        .cwd_relative = "/Applications/Emacs.app/Contents/Resources/include",
    });

    // Link libghostty-vt-static
    mod.linkLibrary(ghostty_vt);

    const lib = b.addLibrary(.{
        .name = "ghostel-module",
        .linkage = .dynamic,
        .root_module = mod,
    });

    b.installArtifact(lib);

    // Copy the shared library to project root for easy Emacs loading
    const copy_step = b.addInstallFile(
        lib.getEmittedBin(),
        "../ghostel-module.dylib",
    );
    b.getInstallStep().dependOn(&copy_step.step);
}
