const builtin = @import("builtin");
const std = @import("std");

const posix = if (builtin.os.tag == .windows) struct {} else @cImport({
    @cInclude("dlfcn.h");
});
const win = if (builtin.os.tag == .windows) @cImport({
    @cInclude("windows.h");
}) else struct {};

pub const Library = struct {
    handle: ?*anyopaque,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Library {
        if (builtin.os.tag == .windows) {
            const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
            defer allocator.free(wide);

            const handle = win.LoadLibraryW(wide.ptr) orelse return error.OpenLibraryFailed;
            return .{ .handle = @ptrCast(handle) };
        }

        const handle = posix.dlopen(path.ptr, posix.RTLD_NOW | posix.RTLD_LOCAL) orelse
            return error.OpenLibraryFailed;
        return .{ .handle = handle };
    }

    pub fn close(self: *Library) void {
        const handle = self.handle orelse return;

        if (builtin.os.tag == .windows) {
            _ = win.FreeLibrary(@ptrCast(@alignCast(handle)));
        } else {
            _ = posix.dlclose(handle);
        }
        self.handle = null;
    }

    pub fn lookup(self: Library, comptime T: type, symbol: [:0]const u8) !T {
        const handle = self.handle orelse return error.LibraryClosed;
        const ptr = if (builtin.os.tag == .windows)
            win.GetProcAddress(@ptrCast(@alignCast(handle)), symbol.ptr)
        else
            posix.dlsym(handle, symbol.ptr);

        if (ptr == null) return error.SymbolNotFound;
        return @ptrCast(@alignCast(ptr));
    }
};
