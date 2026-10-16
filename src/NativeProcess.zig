const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const gt = @import("ghostty-vt");

const backend_types = @import("backend_types.zig");
const emacs = @import("emacs");
const GhostelHandler = @import("handler.zig").GhostelHandler;
const GhostelTerm = @import("GhostelTerm.zig");
const RingQueue = @import("RingQueue.zig").RingQueue;

const Backend = switch (builtin.os.tag) {
    .windows => @import("ConPtyProcess.zig"),
    else => @import("PosixPtyProcess.zig"),
};
const EventWriter = Backend.EventWriter;

const Self = @This();

const log = std.log.scoped(.NativeProcessHandler);

pub const ChannelFd = EventWriter.Fd;
pub const ProcessParams = backend_types.ProcessParams;

const CommandQueueUsableCapacity = 16 * 1024;
const CommandQueueReservedStopSlots = 1;
const CommandQueueCapacity = CommandQueueUsableCapacity + CommandQueueReservedStopSlots + 1;

const WritePolicy = enum {
    wait,
    drop_if_blocked,

    fn cancellation(self: WritePolicy, context: *const anyopaque) ?backend_types.CancellationToken {
        return switch (self) {
            .wait => null,
            .drop_if_blocked => .{
                .context = context,
                .check_fn = rejectTerminalReplyWait,
                .poll_interval = .fromMilliseconds(0),
            },
        };
    }
};

const QueuedWrite = struct {
    data: []u8,
    policy: WritePolicy,
};

const Command = union(enum) {
    write: QueuedWrite,
    resize: backend_types.WinSize,
    stop,

    fn deinit(self: Command, alloc: Allocator) void {
        switch (self) {
            .write => |write| alloc.free(write.data),
            .resize, .stop => {},
        }
    }

    fn isStop(self: Command) bool {
        return switch (self) {
            .write, .resize => false,
            .stop => true,
        };
    }
};

alloc: Allocator,
io: std.Io,
backend: Backend,
/// Independent master descriptor for foreground queries; the backend remains reader-owned.
foreground_handle: ?Backend.ForegroundHandle = null,
/// Foreground queries try-lock so retirement never makes Emacs wait.
foreground_mutex: std.Io.Mutex = .init,
commands: RingQueue(Command, CommandQueueCapacity) = .{},
event_writer: EventWriter,
pid: i64,
replica_name: [:0]u8,
// Buffer event notifications so large terminal updates can be reported with
// few writes to Emacs.
event_buf: std.ArrayList(u8) = .empty,

owner: *GhostelTerm,
stream: gt.Stream(GhostelHandler(*Self)),
attached: bool = false,
term_mutex: std.Io.Mutex = .init,

quit: std.atomic.Value(bool) = .init(false),
detached: std.atomic.Value(bool) = .init(false),
refresh_enabled: std.atomic.Value(bool) = .init(true),
finish_drain_on_exit: bool = true,
thread: std.Thread,

const LockedStream = struct {
    process: *Self,
    drained: bool = false,

    pub fn nextSlice(self: *LockedStream, data: []const u8) !void {
        self.process.term_mutex.lockUncancelable(self.process.io);
        defer self.process.term_mutex.unlock(self.process.io);
        if (!self.process.attached) return;
        try self.process.owner.lock();
        defer self.process.owner.unlock();
        self.drained = true;
        self.process.stream.nextSlice(data);
    }
};

pub fn init(
    self: *Self,
    alloc: Allocator,
    io: std.Io,
    size: backend_types.WinSize,
    params: ProcessParams,
    owner: *GhostelTerm,
    event_fd: ChannelFd,
) !void {
    var backend = try Backend.init(alloc, io, size, params);
    errdefer _ = backend.deinitAndWait();

    const foreground_handle = backend.duplicateForegroundHandle();
    errdefer Backend.closeForegroundHandle(foreground_handle);

    var event_writer = try EventWriter.init(event_fd);
    errdefer event_writer.close();

    var stream: @TypeOf(self.stream) = .init(.{ .allocator = alloc, .handler = .init(alloc, owner, self) });
    errdefer stream.deinit();

    const replica_name = try alloc.dupeSentinel(u8, backend.replicaName(), 0);
    errdefer alloc.free(replica_name);

    self.* = .{
        .alloc = alloc,
        .io = io,
        .backend = backend,
        .foreground_handle = foreground_handle,
        .event_writer = event_writer,
        .pid = backend.pidValue(),
        .replica_name = replica_name,
        .owner = owner,
        .stream = stream,
        .attached = true,
        .refresh_enabled = .init(owner.refresh_enabled),
        .thread = undefined,
    };
    self.thread = try std.Thread.spawn(.{}, Self.run, .{self});
}

pub fn ptyWrite(self: *Self, _: emacs.Env, data: []const u8) !void {
    if (data.len == 0) return;

    const owned = try self.alloc.dupe(u8, data);
    errdefer self.alloc.free(owned);
    self.enqueue(.{ .write = .{ .data = owned, .policy = .wait } }) catch |err| switch (err) {
        error.ProcessExited => {
            self.alloc.free(owned);
            return;
        },
        else => return err,
    };
}

pub fn ptyWriteFromTerminal(self: *Self, data: []const u8) void {
    if (data.len == 0) return;

    const owned = self.alloc.dupe(u8, data) catch |err| {
        log.err("ghostel: Failed to allocate terminal reply: {any}", .{err});
        return;
    };
    self.enqueue(.{ .write = .{ .data = owned, .policy = .drop_if_blocked } }) catch |err| {
        self.alloc.free(owned);
        if (err != error.ProcessExited) {
            log.err("ghostel: Failed to queue terminal reply: {any}", .{err});
        }
    };
}

fn rejectTerminalReplyWait(_: *const anyopaque) !void {
    return error.TerminalReplyWouldBlock;
}

pub fn resizePty(self: *Self, size: backend_types.WinSize) !void {
    self.enqueue(.{ .resize = size }) catch |err| switch (err) {
        error.ProcessExited => return,
        else => return err,
    };
}

fn enqueue(self: *Self, command: Command) !void {
    switch (command) {
        .stop => {
            if (self.quit.load(.acquire)) return error.ProcessExited;
            if (!self.commands.push(command)) return error.CommandQueueFull;
            self.backend.requestStop(self.thread);
        },
        else => {
            if (self.detached.load(.acquire) or self.quit.load(.acquire)) {
                return error.ProcessExited;
            }
            if (!self.commands.pushReserved(command, CommandQueueReservedStopSlots)) {
                return error.CommandQueueFull;
            }
            self.backend.wakeCommands();
        },
    }
}

pub fn foregroundPgid(self: *Self) !?i32 {
    if (!self.foreground_mutex.tryLock()) return null;
    defer self.foreground_mutex.unlock(self.io);

    if (self.quit.load(.acquire) or self.detached.load(.acquire)) return null;
    return Backend.foregroundPgidForHandle(self.foreground_handle);
}

// Buffer semantic callbacks until the PTY drain completes. If allocation
// fails, `effect` rolls back only the incomplete callback.
pub fn effect(self: *Self, comptime func: []const u8, args: anytype) void {
    const event_len = self.event_buf.items.len;
    self.effectFallible(func, args) catch |err| {
        self.event_buf.shrinkRetainingCapacity(event_len);
        log.err("ghostel: Failed to write to event pipe: {s}", .{@errorName(err)});
    };
}

pub fn replicaName(self: *Self) [*:0]const u8 {
    return self.replica_name.ptr;
}

pub fn pidValue(self: *Self) i64 {
    return self.pid;
}

fn effectFallible(self: *Self, comptime func: []const u8, args: anytype) !void {
    try self.writeEvent("(");
    try self.writeEvent(func);
    inline for (@typeInfo(@TypeOf(args)).@"struct".field_names) |field_name| {
        try self.writeEvent(" ");
        try self.writeEventLispValue(@field(args, field_name));
    }
    try self.writeEvent(")");
}

fn writeEventLispValue(self: *Self, val: anytype) !void {
    const T = @TypeOf(val);
    const ty = @typeInfo(T);
    switch (ty) {
        .pointer => try self.writeEventLispString(val),
        .optional => if (val) |v| try self.writeEventLispValue(v) else try self.writeEvent("nil"),
        .int => try self.writeEventLispNumber(val),
        else => @compileError(std.fmt.comptimePrint("Non-supported type: {}", .{T})),
    }
}

fn writeEventLispNumber(self: *Self, val: anytype) !void {
    var buf: [1024]u8 = undefined;
    const str = try std.mem.printSentinel(&buf, "{}", .{val}, 0);
    try self.writeEvent(str);
}

fn writeEventLispString(self: *Self, str: []const u8) !void {
    try self.writeEvent("\"");
    for (str) |ch| {
        switch (ch) {
            '\\' => try self.writeEvent("\\\\"),
            '\n' => try self.writeEvent("\\n"),
            '"' => try self.writeEvent("\\\""),
            else => try self.writeEvent(&[_]u8{ch}),
        }
    }
    try self.writeEvent("\"");
}

fn run(self: *Self) void {
    self.event_writer.onThreadEnter();
    defer EventWriter.onThreadExit();

    self.loop() catch |err| {
        log.warn("ghostel: error in read loop: {any}", .{err});
    };
    self.quit.store(true, .release);
    self.discardCommands();
    // Drop the duplicate before the reaper closes its master; otherwise it
    // would suppress the PTY hangup that can let the child exit.
    self.retireForegroundHandle();

    if (self.finish_drain_on_exit) {
        var final_stream = LockedStream{ .process = self };
        self.backend.finishDrain(&final_stream) catch |err| {
            log.warn("ghostel: error finishing read loop: {any}", .{err});
        };
        if (self.event_buf.items.len > 0) {
            self.flushEvents() catch |err| {
                log.warn("ghostel: error flushing final terminal callbacks: {any}", .{err});
            };
        }
    }

    const backend = self.backend.takeForReaper();

    // Let detached cleanup join the reader without waiting for child exit;
    // the detached reaper owns the child wait and final framed exit event.
    const reaper_thread = std.Thread.spawn(
        .{ .stack_size = 1024 * 1024 },
        reapChild,
        .{ backend, self.event_writer },
    ) catch |err| {
        log.err(
            "ghostel: failed to spawn reaper thread; reaping inline: {any}",
            .{err},
        );
        reapChild(backend, self.event_writer);
        return;
    };
    reaper_thread.detach();
}

fn loop(self: *Self) !void {
    while (try self.loopOnce()) {}
}

fn loopOnce(self: *Self) !bool {
    if (self.quit.load(.acquire)) {
        self.discardCommands();
        return false;
    }
    if (!try self.processCommands(&self.backend)) return false;
    if (self.quit.load(.acquire)) {
        self.discardCommands();
        return false;
    }

    var stream = LockedStream{ .process = self };
    const result = try self.backend.drain(&stream);
    if (stream.drained) try self.notifyVtUpdate();

    return switch (result) {
        .output, .command => true,
        .finished => blk: {
            self.quit.store(true, .release);
            self.discardCommands();
            break :blk false;
        },
        .stopped => blk: {
            self.finish_drain_on_exit = false;
            self.quit.store(true, .release);
            self.discardCommands();
            break :blk false;
        },
    };
}

fn processCommands(self: *Self, backend: *Backend) !bool {
    while (self.commands.pop()) |command| {
        switch (command) {
            .write => |write| {
                defer self.alloc.free(write.data);

                var offset: usize = 0;
                while (offset < write.data.len) {
                    const write_result = backend.write(
                        write.data[offset..],
                        write.policy.cancellation(self),
                    ) catch |err| {
                        if (err == error.TerminalReplyWouldBlock) break;
                        if (err == error.ProcessExited) {
                            self.quit.store(true, .release);
                            self.discardCommands();
                            return false;
                        }
                        log.warn("ghostel: dropping queued native input after write failed: {any}", .{err});
                        break;
                    };
                    switch (write_result) {
                        .written => |n| offset += n,
                        .interrupted => {
                            if (!self.processPendingStop()) return false;
                        },
                    }
                }
            },
            .resize => |size| {
                backend.resize(size) catch |err| {
                    log.warn("ghostel: dropping queued resize after resize failed: {any}", .{err});
                };
            },
            .stop => {
                self.finish_drain_on_exit = false;
                self.quit.store(true, .release);
                self.discardCommands();
                return false;
            },
        }
    }

    return true;
}

fn processPendingStop(self: *Self) bool {
    while (self.commands.pop()) |command| {
        if (command.isStop()) {
            self.finish_drain_on_exit = false;
            self.quit.store(true, .release);
            self.discardCommands();
            return false;
        }
        command.deinit(self.alloc);
    }
    return true;
}

fn discardCommands(self: *Self) void {
    while (self.commands.pop()) |command| command.deinit(self.alloc);
}

fn notifyVtUpdate(self: *Self) !void {
    try self.notifyVtUpdateWithWriter(&self.event_writer);
}

fn notifyVtUpdateWithWriter(self: *Self, writer: anytype) !void {
    if (self.event_buf.items.len == 0) {
        if (!self.refresh_enabled.load(.acquire)) return;
        try self.writeEvent("()");
    }
    try self.flushEventsWithWriter(writer);
}

fn writeEvent(self: *Self, data: []const u8) !void {
    try self.event_buf.appendSlice(self.alloc, data);
}

fn flushEvents(self: *Self) !void {
    try self.flushEventsWithWriter(&self.event_writer);
}

fn flushEventsWithWriter(self: *Self, writer: anytype) !void {
    try writer.write(self.event_buf.items);
    self.event_buf.shrinkRetainingCapacity(0);
}

fn reapChild(backend: Backend.Reaper, event_writer: EventWriter) void {
    var be = backend;
    const exit_code = be.deinitAndWait();

    var writer = event_writer;
    var buf: [64]u8 = undefined;
    const marker = std.fmt.bufPrint(&buf, "\x1e{} {}\n", .{ be.pid, exit_code }) catch unreachable;
    writer.write(marker) catch |err| log.warn("ghostel: failed to write native exit event: {any}", .{err});
    writer.close();
}

pub fn deinit(self: *Self) void {
    if (self.detached.swap(true, .acq_rel)) return;

    self.detachOutput();
    self.enqueue(.stop) catch |err| switch (err) {
        error.ProcessExited => {},
        else => log.warn("ghostel: failed to queue native stop command: {any}", .{err}),
    };

    const cleanup_thread = std.Thread.spawn(
        .{ .stack_size = 1024 * 1024 },
        cleanupDetached,
        .{self},
    ) catch |err| {
        // The reader still retires this descriptor before backend reaping.
        log.err("ghostel: failed to spawn native cleanup thread: {any}", .{err});
        return;
    };
    cleanup_thread.detach();
}

fn retireForegroundHandle(self: *Self) void {
    self.foreground_mutex.lockUncancelable(self.io);
    defer self.foreground_mutex.unlock(self.io);

    Backend.closeForegroundHandle(self.foreground_handle);
    self.foreground_handle = null;
}

pub fn isRunning(self: *Self) bool {
    return !self.quit.load(.acquire) and !self.detached.load(.acquire);
}

pub fn setRefreshEnabled(self: *Self, enabled: bool) void {
    self.refresh_enabled.store(enabled, .release);
}

fn detachOutput(self: *Self) void {
    self.term_mutex.lockUncancelable(self.io);
    defer self.term_mutex.unlock(self.io);

    self.owner.mutex.lockUncancelable(self.io);
    defer self.owner.mutex.unlock(self.io);

    if (!self.attached) return;
    self.attached = false;
    self.stream.deinit();
}

fn cleanupDetached(self: *Self) void {
    // The reader may be on its inline waitpid fallback, so retire before join.
    self.retireForegroundHandle();
    self.thread.join();
    self.backend.closeWakeEndpoints();
    self.discardCommands();
    self.event_buf.deinit(self.alloc);
    self.alloc.free(self.replica_name);
    self.alloc.destroy(self);
}

const RecordingEventWriter = struct {
    alloc: Allocator,
    bytes: std.ArrayList(u8) = .empty,

    fn write(self: *@This(), data: []const u8) !void {
        try self.bytes.appendSlice(self.alloc, data);
    }

    fn deinit(self: *@This()) void {
        self.bytes.deinit(self.alloc);
    }
};

fn makeTestProcess() Self {
    return .{
        .alloc = std.testing.allocator,
        .io = undefined,
        .backend = undefined,
        .event_writer = .{ .fd = -1 },
        .pid = 0,
        .replica_name = undefined,
        .owner = undefined,
        .stream = undefined,
        .thread = undefined,
    };
}

test "event serialization does not write while buffering" {
    var process: Self = undefined;
    process.alloc = std.testing.allocator;
    process.event_buf = .empty;
    defer process.event_buf.deinit(process.alloc);
    process.event_writer = .{ .fd = -1 };

    const payload = try std.testing.allocator.alloc(u8, 20 * 1024);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');

    try process.writeEvent(payload);
    try std.testing.expectEqualSlices(u8, payload, process.event_buf.items);
}

test "paused empty VT update does not write a refresh" {
    var process = makeTestProcess();
    defer process.event_buf.deinit(process.alloc);
    process.setRefreshEnabled(false);

    var writer = RecordingEventWriter{ .alloc = std.testing.allocator };
    defer writer.deinit();

    try process.notifyVtUpdateWithWriter(&writer);
    try std.testing.expectEqualSlices(u8, "", writer.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), process.event_buf.items.len);
}

test "semantic callbacks flush while refresh notifications are paused" {
    var process = makeTestProcess();
    defer process.event_buf.deinit(process.alloc);
    process.setRefreshEnabled(false);

    var writer = RecordingEventWriter{ .alloc = std.testing.allocator };
    defer writer.deinit();

    process.effect("ghostel--bell", .{});
    try process.notifyVtUpdateWithWriter(&writer);

    try std.testing.expectEqualSlices(u8, "(ghostel--bell)", writer.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), process.event_buf.items.len);
}

test "refresh notifications are active by default and resume when enabled" {
    var process = makeTestProcess();
    defer process.event_buf.deinit(process.alloc);

    var writer = RecordingEventWriter{ .alloc = std.testing.allocator };
    defer writer.deinit();

    try process.notifyVtUpdateWithWriter(&writer);
    try std.testing.expectEqualSlices(u8, "()", writer.bytes.items);

    process.setRefreshEnabled(false);
    try process.notifyVtUpdateWithWriter(&writer);
    try std.testing.expectEqualSlices(u8, "()", writer.bytes.items);

    process.setRefreshEnabled(true);
    try process.notifyVtUpdateWithWriter(&writer);
    try std.testing.expectEqualSlices(u8, "()()", writer.bytes.items);
}

test "detached output does not touch owner" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var process: Self = undefined;
    process.io = threaded.io();
    process.owner = @ptrFromInt(0x1000);
    process.attached = false;
    process.term_mutex = .init;

    var stream = LockedStream{ .process = &process };
    try stream.nextSlice("detached");
}

test "terminal replies reject PTY capacity waits" {
    const context: u8 = 0;
    const cancellation = WritePolicy.drop_if_blocked.cancellation(&context).?;

    try std.testing.expectEqual(@as(i64, 0), cancellation.poll_interval.toMilliseconds());
    try std.testing.expectError(error.TerminalReplyWouldBlock, cancellation.check());
}
