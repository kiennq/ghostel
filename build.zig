const builtin = @import("builtin");
const std = @import("std");
const emacs_util_mods = @import("vendor/emacs-util-mods/build.zig");

const vendored_emacs_include_dir = emacs_util_mods.vendored_emacs_include_dir;
const EmacsIncludeSource = emacs_util_mods.EmacsIncludeSource;

pub fn build(b: *std.Build) void {
    const default_target: std.Target.Query = if (builtin.os.tag == .windows)
        .{
            .cpu_arch = builtin.cpu.arch,
            .os_tag = .windows,
            .abi = .gnu,
        }
    else
        .{};
    const target = b.standardTargetOptions(.{
        .default_target = default_target,
    });
    const optimize = b.standardOptimizeOption(.{});
    const strip_binaries = optimize != .Debug;
    const target_os = target.result.os.tag;
    const emacs_include = resolveEmacsIncludePath(b);
    const ghostty_dep = b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .@"emit-lib-vt" = true,
        .strip = strip_binaries,
    }) orelse std.debug.panic(
        "ghostty dependency unavailable; initialize the vendor/ghostty submodule",
        .{},
    );

    const mod = b.createModule(.{
        .root_source_file = b.path("src/module.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip_binaries,
        .link_libc = true,
    });
    addModuleIncludes(b, mod, emacs_include);
    mod.linkLibrary(ghostty_dep.artifact("ghostty-vt-static"));

    const lib = b.addLibrary(.{
        .name = "ghostel-module",
        .linkage = .dynamic,
        .root_module = mod,
    });
    if (target_os == .windows) {
        addWindowsRuntimeLibraries(b, lib, target.result);
    }

    b.installArtifact(lib);

    const copy_step = b.addInstallFile(
        lib.getEmittedBin(),
        moduleOutputName(target_os),
    );
    b.getInstallStep().dependOn(&copy_step.step);

    const check_mod = b.createModule(.{
        .root_source_file = b.path("src/module.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addModuleIncludes(b, check_mod, emacs_include);

    const check_obj = b.addObject(.{
        .name = "ghostel-module-check",
        .root_module = check_mod,
    });

    const check = b.step("check", "Check that the module compiles (no linking)");
    check.dependOn(&check_obj.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/module.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addModuleIncludes(b, test_mod, emacs_include);
    test_mod.linkLibrary(ghostty_dep.artifact("ghostty-vt-static"));

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    if (target_os == .windows) {
        addWindowsRuntimeLibraries(b, unit_tests, target.result);
    }

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run Zig unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

fn addModuleIncludes(
    b: *std.Build,
    mod: *std.Build.Module,
    emacs_include: std.Build.LazyPath,
) void {
    mod.addSystemIncludePath(emacs_include);
    mod.addIncludePath(b.path("vendor/ghostty/include"));
}

fn resolveEmacsIncludePath(b: *std.Build) std.Build.LazyPath {
    return emacs_util_mods.resolveEmacsIncludePath(b);
}

fn resolveEmacsIncludeSource(
    emacs_include_dir: ?[]const u8,
    emacs_source_dir: ?[]const u8,
) EmacsIncludeSource {
    return emacs_util_mods.resolveEmacsIncludeSource(emacs_include_dir, emacs_source_dir);
}

fn vendoredEmacsIncludeDir() []const u8 {
    return vendored_emacs_include_dir;
}

fn addWindowsRuntimeLibraries(
    b: *std.Build,
    lib: *std.Build.Step.Compile,
    resolved_target: std.Target,
) void {
    lib.linkSystemLibrary("kernel32");
    if (resolved_target.abi != .msvc) return;

    lib.linkSystemLibrary("libvcruntime");

    const arch = resolved_target.cpu.arch;
    const sdk = std.zig.WindowsSdk.find(b.allocator, arch) catch null;
    if (sdk) |s| {
        if (s.windows10sdk) |w10| {
            const arch_str: []const u8 = switch (arch) {
                .x86_64 => "x64",
                .x86 => "x86",
                .aarch64 => "arm64",
                else => "x64",
            };
            const ucrt_lib_path = std.fmt.allocPrint(
                b.allocator,
                "{s}\\Lib\\{s}\\ucrt\\{s}",
                .{ w10.path, w10.version, arch_str },
            ) catch null;

            if (ucrt_lib_path) |path| {
                lib.addLibraryPath(.{ .cwd_relative = path });
            }
        }
    }

    lib.linkSystemLibrary("libucrt");
}

test "emacs include resolution prefers include dir override" {
    const source = resolveEmacsIncludeSource("C:/headers", "Q:/repos/emacs-build/git/master");
    try std.testing.expect(source == .include_dir);
    try std.testing.expectEqualStrings("C:/headers", source.include_dir);
}

test "emacs include resolution prefers source dir over vendored header" {
    const source = resolveEmacsIncludeSource(null, "Q:/repos/emacs-build/git/master");
    try std.testing.expect(source == .source_dir);
    try std.testing.expectEqualStrings("Q:/repos/emacs-build/git/master", source.source_dir);
}

test "emacs include resolution falls back to vendored header" {
    const source = resolveEmacsIncludeSource(null, null);
    try std.testing.expect(source == .vendored);
}

fn moduleOutputName(target_os: std.Target.Os.Tag) []const u8 {
    return switch (target_os) {
        .macos => "bin/ghostel-module.dylib",
        .windows => "bin/ghostel-module.dll",
        else => "bin/ghostel-module.so",
    };
}
