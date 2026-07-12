const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const gt = @import("ghostty-vt");

const backend_types = @import("backend_types.zig");
const emacs = @import("emacs");
const GhostelHandler = @import("handler.zig").GhostelHandler;
const RecursiveMutex = @import("RecursiveMutex.zig");
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

const Size = struct {
    cols: u16,
    rows: u16,
};

const Command = union(enum) {
    write: []u8,
    resize: Size,
    stop,

    fn deinit(self: Command, alloc: Allocator) void {
        switch (self) {
            .write => |data| alloc.free(data),
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
commands: RingQueue(Command, CommandQueueCapacity) = .{},
event_writer: EventWriter,
pid: i64,
replica_name: [:0]u8,
// Buffer event notifications so large terminal updates can be reported with
// few writes to Emacs.
event_buf: std.ArrayList(u8) = .empty,

term_mutex: RecursiveMutex = .{},
term: *gt.Terminal,
stream: gt.Stream(GhostelHandler(*Self)),
attached: bool = false,

quit: std.atomic.Value(bool) = .init(false),
detached: std.atomic.Value(bool) = .init(false),
finish_drain_on_exit: bool = true,
thread: std.Thread,

const LockedStream = struct {
    process: *Self,
    drained: bool = false,

    pub fn nextSlice(self: *LockedStream, data: []const u8) !void {
        try self.process.term_mutex.lock(self.process.io);
        defer self.process.term_mutex.unlock(self.process.io);
        if (!self.process.attached) return;
        self.drained = true;
        self.process.stream.nextSlice(data);
    }
};

pub fn init(
    self: *Self,
    alloc: Allocator,
    io: std.Io,
    initial_cols: u16,
    initial_rows: u16,
    params: ProcessParams,
    term: *gt.Terminal,
    event_fd: ChannelFd,
) !void {
    var backend = try Backend.init(alloc, io, initial_cols, initial_rows, params);
    errdefer _ = backend.deinitAndWait();

    var event_writer = try EventWriter.init(event_fd);
    errdefer event_writer.close();

    var stream: @TypeOf(self.stream) = .initAlloc(alloc, .init(self, term));
    errdefer stream.deinit();

    const replica_name = try alloc.dupeZ(u8, backend.replicaName());
    errdefer alloc.free(replica_name);

    self.* = .{
        .alloc = alloc,
        .io = io,
        .backend = backend,
        .event_writer = event_writer,
        .pid = backend.pidValue(),
        .replica_name = replica_name,
        .term = term,
        .stream = stream,
        .attached = true,
        .thread = undefined,
    };
    self.thread = try std.Thread.spawn(.{}, Self.run, .{self});
}

pub fn lockTerm(self: *Self) !void {
    try self.term_mutex.lock(self.io);
}

pub fn tryLockTerm(self: *Self) bool {
    return self.term_mutex.tryLock();
}

pub fn unlockTerm(self: *Self) void {
    self.term_mutex.unlock(self.io);
}

pub fn ptyWrite(self: *Self, _: emacs.Env, data: []const u8) !void {
    if (data.len == 0) return;

    const owned = try self.alloc.dupe(u8, data);
    errdefer self.alloc.free(owned);
    self.enqueue(.{ .write = owned }) catch |err| switch (err) {
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
    self.enqueue(.{ .write = owned }) catch |err| {
        self.alloc.free(owned);
        if (err != error.ProcessExited) {
            log.err("ghostel: Failed to queue terminal reply: {any}", .{err});
        }
    };
}

pub fn resizePty(self: *Self, cols: u16, rows: u16) !void {
    self.enqueue(.{ .resize = .{ .cols = cols, .rows = rows } }) catch |err| switch (err) {
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
    inline for (std.meta.fields(@TypeOf(args))) |field| {
        try self.writeEvent(" ");
        try self.writeEventLispValue(@field(args, field.name));
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
    const str = try std.fmt.bufPrintZ(&buf, "{}", .{val});
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

    // The reader thread must not waitpid here: it may be joined from Emacs
    // during buffer teardown, and blocking that path would freeze Emacs.  Hand
    // the child and event writer to a detached reaper instead. The channel stays
    // open until the reaper observes child exit, mirroring Emacs process
    // lifetime semantics for the Lisp-side pipe process.
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
            .write => |data| {
                defer self.alloc.free(data);

                var offset: usize = 0;
                while (offset < data.len) {
                    const write_result = backend.write(data[offset..], null) catch |err| {
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
                backend.resize(size.cols, size.rows) catch |err| {
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
    if (self.event_buf.items.len == 0) try self.writeEvent("()");
    try self.flushEvents();
}

fn writeEvent(self: *Self, data: []const u8) !void {
    try self.event_buf.appendSlice(self.alloc, data);
}

fn flushEvents(self: *Self) !void {
    try self.event_writer.write(self.event_buf.items);
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
        log.err("ghostel: failed to spawn native cleanup thread: {any}", .{err});
        return;
    };
    cleanup_thread.detach();
}

pub fn isRunning(self: *Self) bool {
    return !self.quit.load(.acquire) and !self.detached.load(.acquire);
}

fn detachOutput(self: *Self) void {
    self.term_mutex.lockUncancelable(self.io);
    defer self.term_mutex.unlock(self.io);

    if (!self.attached) return;
    self.attached = false;
    self.stream.deinit();
}

fn cleanupDetached(self: *Self) void {
    self.thread.join();
    self.backend.closeWakeEndpoints();
    self.discardCommands();
    self.event_buf.deinit(self.alloc);
    self.alloc.free(self.replica_name);
    self.alloc.destroy(self);
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

test "tryLockTerm declines another thread's lock" {
    var process: Self = undefined;
    var io: std.Io.Threaded = .init_single_threaded;
    process.io = io.io();
    process.term_mutex = .{};

    var acquired: std.Io.Semaphore = .{};
    var release: std.Io.Semaphore = .{};
    const Holder = struct {
        fn run(
            native_process: *Self,
            lock_acquired: *std.Io.Semaphore,
            lock_release: *std.Io.Semaphore,
        ) void {
            native_process.lockTerm() catch unreachable;
            lock_acquired.post(native_process.io);
            lock_release.waitUncancelable(native_process.io);
            native_process.unlockTerm();
        }
    };

    const holder = try std.Thread.spawn(.{}, Holder.run, .{ &process, &acquired, &release });
    acquired.waitUncancelable(process.io);
    const contended = process.tryLockTerm();
    release.post(process.io);
    holder.join();

    try std.testing.expect(!contended);
    try std.testing.expect(process.tryLockTerm());
    process.unlockTerm();
}
