const builtin = @import("builtin");
const std = @import("std");
const emacs = @import("emacs.zig");

const is_windows = builtin.os.tag == .windows;

const c = if (is_windows)
    @cImport({
        @cInclude("windows.h");
        @cInclude("io.h");
    })
else
    struct {};

const HPCON = if (is_windows) ?*anyopaque else ?*anyopaque;
const CreatePseudoConsoleFn = if (is_windows)
    *const fn (c.COORD, c.HANDLE, c.HANDLE, u32, *HPCON) callconv(.winapi) c.HRESULT
else
    *const fn () callconv(.c) c_int;
const ResizePseudoConsoleFn = if (is_windows)
    *const fn (HPCON, c.COORD) callconv(.winapi) c.HRESULT
else
    *const fn () callconv(.c) c_int;
const ClosePseudoConsoleFn = if (is_windows)
    *const fn (HPCON) callconv(.winapi) void
else
    *const fn () callconv(.c) void;

const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
const OUTPUT_BUFFER_SIZE = 64 * 1024;
const PENDING_BUFFER_SIZE = 4 * 1024 * 1024;

pub const State = if (is_windows) struct {
    hpc: HPCON = null,
    pty_input: c.HANDLE = c.INVALID_HANDLE_VALUE,
    pty_output: c.HANDLE = c.INVALID_HANDLE_VALUE,
    shell_process: c.HANDLE = c.INVALID_HANDLE_VALUE,
    reader_thread: c.HANDLE = c.INVALID_HANDLE_VALUE,
    notify_fd: c_int = -1,
    pending_lock: c.CRITICAL_SECTION = undefined,
    output_buf: [2][OUTPUT_BUFFER_SIZE]u8 = undefined,
    pending_buf: [PENDING_BUFFER_SIZE]u8 = undefined,
    pending_len: usize = 0,
    running: std.atomic.Value(u8) = std.atomic.Value(u8).init(1),
} else struct {};

var create_pseudo_console: ?CreatePseudoConsoleFn = null;
var resize_pseudo_console: ?ResizePseudoConsoleFn = null;
var close_pseudo_console: ?ClosePseudoConsoleFn = null;

pub fn init(
    env: emacs.Env,
    process: emacs.Value,
    shell_command: []const u8,
    rows: u16,
    cols: u16,
    working_directory: []const u8,
    process_environment: emacs.Value,
    allocator: std.mem.Allocator,
) !*State {
    if (!is_windows) return error.UnsupportedPlatform;
    if (!(try initApi())) return error.MissingConpty;

    const state = try std.heap.c_allocator.create(State);
    errdefer std.heap.c_allocator.destroy(state);
    state.* = .{};
    c.InitializeCriticalSection(&state.pending_lock);
    errdefer c.DeleteCriticalSection(&state.pending_lock);

    state.notify_fd = env.openChannel(process);
    if (state.notify_fd < 0) return error.OpenChannelFailed;

    try createConpty(state, rows, cols);
    errdefer deinit(state);

    try spawnShell(state, env, shell_command, working_directory, process_environment, allocator);

    state.reader_thread = c.CreateThread(
        null,
        0,
        readerThread,
        state,
        0,
        null,
    ) orelse return error.CreateThreadFailed;

    return state;
}

pub fn deinit(state_opt: ?*State) void {
    if (!is_windows) return;
    const state = state_opt orelse return;

    requestShutdown(state);

    if (state.reader_thread != c.INVALID_HANDLE_VALUE) {
        const cleanup_thread = c.CreateThread(
            null,
            0,
            cleanupThread,
            state,
            0,
            null,
        );
        if (cleanup_thread != null) {
            _ = c.CloseHandle(cleanup_thread);
            return;
        }
    }

    waitForReaderThread(state, c.INFINITE);
    finalizeState(state);
}

fn requestShutdown(state: *State) void {
    state.running.store(0, .release);

    if (state.shell_process != c.INVALID_HANDLE_VALUE) {
        var exit_code: c.DWORD = 0;
        if (c.GetExitCodeProcess(state.shell_process, &exit_code) != 0 and exit_code == c.STILL_ACTIVE) {
            _ = c.TerminateProcess(state.shell_process, 1);
        }
        _ = c.CloseHandle(state.shell_process);
        state.shell_process = c.INVALID_HANDLE_VALUE;
    }

    if (state.pty_input != c.INVALID_HANDLE_VALUE) {
        _ = c.CloseHandle(state.pty_input);
        state.pty_input = c.INVALID_HANDLE_VALUE;
    }

    if (state.hpc != null) {
        close_pseudo_console.?(state.hpc);
        state.hpc = null;
    }

    if (state.reader_thread != c.INVALID_HANDLE_VALUE) {
        _ = c.CancelSynchronousIo(state.reader_thread);
    }

    if (state.pty_output != c.INVALID_HANDLE_VALUE) {
        _ = c.CloseHandle(state.pty_output);
        state.pty_output = c.INVALID_HANDLE_VALUE;
    }
}

fn waitForReaderThread(state: *State, timeout_ms: c.DWORD) void {
    if (state.reader_thread == c.INVALID_HANDLE_VALUE) return;
    _ = c.WaitForSingleObject(state.reader_thread, timeout_ms);
    _ = c.CloseHandle(state.reader_thread);
    state.reader_thread = c.INVALID_HANDLE_VALUE;
}

fn finalizeState(state: *State) void {
    if (state.notify_fd >= 0) {
        _ = c._close(state.notify_fd);
        state.notify_fd = -1;
    }

    c.DeleteCriticalSection(&state.pending_lock);
    std.heap.c_allocator.destroy(state);
}

fn cleanupThread(param: ?*anyopaque) callconv(.winapi) c.DWORD {
    const state: *State = @ptrCast(@alignCast(param.?));
    waitForReaderThread(state, c.INFINITE);
    finalizeState(state);
    return 0;
}

pub fn readPending(env: emacs.Env, state: *State) emacs.Value {
    if (!is_windows) return env.nil();

    c.EnterCriticalSection(&state.pending_lock);
    defer c.LeaveCriticalSection(&state.pending_lock);

    if (state.pending_len == 0) return env.nil();

    const str = env.makeString(state.pending_buf[0..state.pending_len]);
    state.pending_len = 0;
    return str;
}

pub fn write(state: *State, data: []const u8) !void {
    if (!is_windows) return error.UnsupportedPlatform;
    if (data.len == 0) return;

    var offset: usize = 0;
    while (offset < data.len) {
        var wrote: c.DWORD = 0;
        const chunk_len: c.DWORD = @intCast(@min(data.len - offset, std.math.maxInt(c.DWORD)));
        if (c.WriteFile(state.pty_input, data[offset..].ptr, chunk_len, &wrote, null) == 0) {
            return error.WriteFailed;
        }
        offset += wrote;
        if (wrote == 0) return error.WriteFailed;
    }
}

pub fn resize(state: *State, rows: u16, cols: u16) bool {
    if (!is_windows) return false;
    const size = c.COORD{
        .X = @intCast(cols),
        .Y = @intCast(rows),
    };
    return resize_pseudo_console.?(state.hpc, size) >= 0;
}

pub fn isAlive(state: *State) bool {
    if (!is_windows) return false;
    if (state.shell_process == c.INVALID_HANDLE_VALUE) return false;
    var exit_code: c.DWORD = 0;
    return c.GetExitCodeProcess(state.shell_process, &exit_code) != 0 and exit_code == c.STILL_ACTIVE;
}

pub fn kill(state: *State) bool {
    if (!is_windows) return false;
    if (state.shell_process == c.INVALID_HANDLE_VALUE) return false;
    return c.TerminateProcess(state.shell_process, 1) != 0;
}

fn initApi() !bool {
    if (!is_windows) return false;
    if (create_pseudo_console != null) return true;

    const kernel32 = c.GetModuleHandleA("kernel32.dll") orelse return false;
    create_pseudo_console = @ptrCast(c.GetProcAddress(kernel32, "CreatePseudoConsole") orelse return false);
    resize_pseudo_console = @ptrCast(c.GetProcAddress(kernel32, "ResizePseudoConsole") orelse return false);
    close_pseudo_console = @ptrCast(c.GetProcAddress(kernel32, "ClosePseudoConsole") orelse return false);
    return true;
}

fn createConpty(state: *State, rows: u16, cols: u16) !void {
    var in_read: c.HANDLE = c.INVALID_HANDLE_VALUE;
    var in_write: c.HANDLE = c.INVALID_HANDLE_VALUE;
    var out_read: c.HANDLE = c.INVALID_HANDLE_VALUE;
    var out_write: c.HANDLE = c.INVALID_HANDLE_VALUE;
    errdefer {
        if (in_read != c.INVALID_HANDLE_VALUE) _ = c.CloseHandle(in_read);
        if (in_write != c.INVALID_HANDLE_VALUE) _ = c.CloseHandle(in_write);
        if (out_read != c.INVALID_HANDLE_VALUE) _ = c.CloseHandle(out_read);
        if (out_write != c.INVALID_HANDLE_VALUE) _ = c.CloseHandle(out_write);
    }

    var sa = std.mem.zeroes(c.SECURITY_ATTRIBUTES);
    sa.nLength = @sizeOf(c.SECURITY_ATTRIBUTES);
    sa.bInheritHandle = c.TRUE;

    if (c.CreatePipe(&in_read, &in_write, &sa, 0) == 0) return error.CreatePipeFailed;
    if (c.CreatePipe(&out_read, &out_write, &sa, 0) == 0) return error.CreatePipeFailed;

    const size = c.COORD{
        .X = @intCast(cols),
        .Y = @intCast(rows),
    };
    if (create_pseudo_console.?(size, in_read, out_write, 0, &state.hpc) < 0) {
        return error.CreatePseudoConsoleFailed;
    }

    state.pty_input = in_write;
    state.pty_output = out_read;

    _ = c.CloseHandle(in_read);
    _ = c.CloseHandle(out_write);
}

fn spawnShell(
    state: *State,
    env: emacs.Env,
    shell_command: []const u8,
    working_directory: []const u8,
    process_environment: emacs.Value,
    allocator: std.mem.Allocator,
) !void {
    const command_line = try std.unicode.utf8ToUtf16LeAllocZ(allocator, shell_command);
    defer allocator.free(command_line);

    const cwd = try std.unicode.utf8ToUtf16LeAllocZ(allocator, working_directory);
    defer allocator.free(cwd);

    const env_block = try buildEnvironmentBlock(allocator, env, process_environment);
    defer if (env_block) |blk| allocator.free(blk);

    var attr_list_size: usize = 0;
    _ = c.InitializeProcThreadAttributeList(null, 1, 0, &attr_list_size);
    const attr_list_buf = try std.heap.c_allocator.alloc(u8, attr_list_size);
    defer std.heap.c_allocator.free(attr_list_buf);

    var si = std.mem.zeroes(c.STARTUPINFOEXW);
    si.StartupInfo.cb = @sizeOf(c.STARTUPINFOEXW);
    si.lpAttributeList = @ptrCast(@alignCast(attr_list_buf.ptr));
    if (c.InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &attr_list_size) == 0) {
        return error.InitializeProcThreadAttributeListFailed;
    }
    defer c.DeleteProcThreadAttributeList(si.lpAttributeList);

    if (c.UpdateProcThreadAttribute(
        si.lpAttributeList,
        0,
        PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
        state.hpc,
        @sizeOf(HPCON),
        null,
        null,
    ) == 0) {
        return error.UpdateProcThreadAttributeFailed;
    }

    var pi = std.mem.zeroes(c.PROCESS_INFORMATION);
    const flags = c.EXTENDED_STARTUPINFO_PRESENT | c.CREATE_UNICODE_ENVIRONMENT;
    const env_ptr = if (env_block) |blk| @as(?*anyopaque, @ptrCast(blk.ptr)) else null;
    if (c.CreateProcessW(
        null,
        command_line.ptr,
        null,
        null,
        c.FALSE,
        flags,
        env_ptr,
        cwd.ptr,
        &si.StartupInfo,
        &pi,
    ) == 0) {
        return error.CreateProcessFailed;
    }

    state.shell_process = pi.hProcess;
    _ = c.CloseHandle(pi.hThread);
}

fn buildEnvironmentBlock(allocator: std.mem.Allocator, env: emacs.Env, list: emacs.Value) !?[]u16 {
    if (!is_windows) return null;

    var items = std.ArrayList([]const u8).empty;
    defer {
        for (items.items) |item| allocator.free(item);
        items.deinit(allocator);
    }

    var iter = list;
    const car = env.intern("car");
    const cdr = env.intern("cdr");
    while (env.isNotNil(iter)) {
        const item = env.call1(car, iter);
        const item_utf8 = env.extractStringAlloc(item, allocator) orelse
            return error.InvalidEnvironmentEntry;
        try items.append(allocator, item_utf8);
        iter = env.call1(cdr, iter);
    }
    return try buildEnvironmentBlockUtf8(allocator, items.items);
}

fn buildEnvironmentBlockUtf8(allocator: std.mem.Allocator, items: []const []const u8) !?[]u16 {
    if (items.len == 0) return null;

    var builder = std.ArrayList(u16).empty;
    errdefer builder.deinit(allocator);

    for (items) |item| {
        const item_utf16 = try std.unicode.utf8ToUtf16LeAllocZ(allocator, item);
        defer allocator.free(item_utf16);
        try builder.appendSlice(allocator, item_utf16);
        try builder.append(allocator, 0);
    }
    try builder.append(allocator, 0);
    return try builder.toOwnedSlice(allocator);
}

fn readerThread(param: ?*anyopaque) callconv(.winapi) c.DWORD {
    const state: *State = @ptrCast(@alignCast(param.?));
    var slot: usize = 0;

    while (state.running.load(.acquire) != 0) {
        var bytes_read: c.DWORD = 0;
        if (c.ReadFile(
            state.pty_output,
            state.output_buf[slot][0..].ptr,
            OUTPUT_BUFFER_SIZE,
            &bytes_read,
            null,
        ) == 0 or bytes_read == 0) {
            break;
        }

        c.EnterCriticalSection(&state.pending_lock);
        const available = state.pending_buf.len - state.pending_len;
        const copy_len = @min(available, @as(usize, @intCast(bytes_read)));
        if (copy_len > 0) {
            @memcpy(
                state.pending_buf[state.pending_len .. state.pending_len + copy_len],
                state.output_buf[slot][0..copy_len],
            );
            state.pending_len += copy_len;
        }
        c.LeaveCriticalSection(&state.pending_lock);

        notify(state.notify_fd);
        slot = (slot + 1) % state.output_buf.len;
    }

    state.running.store(0, .release);
    notify(state.notify_fd);
    return 0;
}

fn notify(fd: c_int) void {
    if (fd < 0) return;
    const signal = [_]u8{'1'};
    _ = c._write(fd, &signal, signal.len);
}

test "buildEnvironmentBlockUtf8 appends a double-null terminator" {
    const items = [_][]const u8{ "TERM=xterm-256color", "FOO=bar" };
    const block = (try buildEnvironmentBlockUtf8(std.testing.allocator, &items)).?;
    defer std.testing.allocator.free(block);

    const expected = [_]u16{
        'T', 'E', 'R', 'M', '=', 'x', 't', 'e', 'r', 'm', '-', '2', '5', '6', 'c', 'o', 'l', 'o', 'r', 0,
        'F', 'O', 'O', '=', 'b', 'a', 'r', 0,
        0,
    };
    try std.testing.expectEqualSlices(u16, &expected, block);
}

test "buildEnvironmentBlockUtf8 returns null for an empty environment list" {
    const items = [_][]const u8{};
    try std.testing.expectEqual(@as(?[]u16, null), try buildEnvironmentBlockUtf8(std.testing.allocator, &items));
}

fn testSleepThread(_: ?*anyopaque) callconv(.winapi) c.DWORD {
    c.Sleep(200);
    return 0;
}

test "deinit returns without waiting for the reader thread" {
    if (!is_windows) return;

    const reader_thread = c.CreateThread(
        null,
        0,
        testSleepThread,
        null,
        0,
        null,
    ) orelse return error.CreateThreadFailed;

    const state = try std.heap.c_allocator.create(State);
    state.* = .{};
    c.InitializeCriticalSection(&state.pending_lock);
    state.reader_thread = reader_thread;

    const start = std.time.nanoTimestamp();
    deinit(state);
    const elapsed_ms = @as(u64, @intCast(@divTrunc(std.time.nanoTimestamp() - start, std.time.ns_per_ms)));
    try std.testing.expect(elapsed_ms < 100);

    c.Sleep(300);
}
