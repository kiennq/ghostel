const std = @import("std");
const emacs = @import("emacs");

pub const LoaderAbiVersion: u32 = 1;
pub const DispatchFn = *const fn (u32, ?*emacs.c.emacs_env, isize, [*c]emacs.c.emacs_value, ?*anyopaque) callconv(.c) emacs.c.emacs_value;
pub const VariableGetFn = *const fn (u32, ?*emacs.c.emacs_env, ?*anyopaque) callconv(.c) emacs.c.emacs_value;
pub const VariableSetFn = *const fn (u32, ?*emacs.c.emacs_env, emacs.c.emacs_value, ?*anyopaque) callconv(.c) emacs.c.emacs_value;
pub const CleanupFn = *const fn (?*emacs.c.emacs_env) callconv(.c) void;
pub const CleanupSymbolName: [:0]const u8 = "loader_module_cleanup";

pub const ExportKind = enum(u32) {
    function = 1,
    variable = 2,
};

pub const ExportFlag = struct {
    pub const writable: u32 = 1;
};

pub const ExportDescriptor = extern struct {
    export_id: u32,
    kind: u32,
    lisp_name: [*:0]const u8,
    min_arity: i32,
    max_arity: i32,
    docstring: [*:0]const u8,
    flags: u32,
};

pub const GenericManifest = extern struct {
    loader_abi: u32,
    module_id: [*:0]const u8,
    module_version: [*:0]const u8,
    exports_len: u32,
    exports: [*]const ExportDescriptor,
    invoke: DispatchFn,
    get_variable: VariableGetFn,
    set_variable: VariableSetFn,
};

pub const GenericLoaderModuleInitFn = *const fn (*GenericManifest) callconv(.c) void;

test "manifest can describe generic function and variable exports" {
    const exports = [_]ExportDescriptor{
        .{
            .export_id = 1,
            .kind = @intFromEnum(ExportKind.function),
            .lisp_name = "sample--ping",
            .min_arity = 0,
            .max_arity = 0,
            .docstring = "Ping sample module.",
            .flags = 0,
        },
        .{
            .export_id = 2,
            .kind = @intFromEnum(ExportKind.variable),
            .lisp_name = "sample-mode",
            .min_arity = 0,
            .max_arity = 0,
            .docstring = "Sample variable.",
            .flags = ExportFlag.writable,
        },
    };
    const manifest = GenericManifest{
        .loader_abi = LoaderAbiVersion,
        .module_id = "sample-module",
        .module_version = "1.0",
        .exports_len = exports.len,
        .exports = &exports,
        .invoke = undefined,
        .get_variable = undefined,
        .set_variable = undefined,
    };

    try std.testing.expectEqual(@as(u32, 2), manifest.exports_len);
    try std.testing.expectEqual(@intFromEnum(ExportKind.function), manifest.exports[0].kind);
    try std.testing.expectEqualStrings("sample-mode", std.mem.span(manifest.exports[1].lisp_name));
    try std.testing.expectEqual(ExportFlag.writable, manifest.exports[1].flags);
}
