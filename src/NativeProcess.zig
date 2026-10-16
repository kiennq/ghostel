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
pub const ChildProcess = Backend.ChildProcess;

const Self = @This();

const log = std.log.scoped(.NativeProcessHandler);

pub const ChannelFd = EventWriter.Fd;
pub const ProcessParams = backend_types.ProcessParams;

const CommandQueueUsableCapacity = 16 * 1024;
const CommandQueueReservedStopSlots = 1;
const CommandQueueCapacity = CommandQueueUsableCapacity + CommandQueueReservedStopSlots + 1;
const HandoffJournalLimit = 4 * 1024 * 1024;

const EventMutex = struct {
    locked: std.atomic.Value(bool) = .init(false),

    fn lock(self: *@This()) void {
        while (self.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    fn tryLock(self: *@This()) bool {
        return !self.locked.swap(true, .acquire);
    }

    fn unlock(self: *@This()) void {
        self.locked.store(false, .release);
    }
};

const HandoffPhase = enum(u8) {
    dormant,
    staging,
    raw,
    cancel_pending,
    failed,
    discarded,
};

pub const HandoffCommitResult = enum {
    committed,
    retry,
    unavailable,
};

const HandoffJournal = struct {
    bytes: std.ArrayList(u8) = .empty,

    fn append(self: *@This(), alloc: Allocator, data: []const u8, limit: usize) !void {
        if (self.bytes.items.len > limit or data.len > limit - self.bytes.items.len) {
            return error.HandoffOverflow;
        }
        if (data.len == 0) return;

        const required = self.bytes.items.len + data.len;
        if (self.bytes.capacity < required) {
            const doubled = std.math.mul(usize, self.bytes.capacity, 2) catch limit;
            const capacity = @min(limit, @max(required, doubled));
            try self.bytes.ensureTotalCapacityPrecise(alloc, capacity);
        }
        self.bytes.appendSliceAssumeCapacity(data);
    }

    fn replay(self: *@This(), stream: anytype, current: []const u8) void {
        if (self.bytes.items.len > 0) replayHandoffSlice(stream, self.bytes.items);
        if (current.len > 0) replayHandoffSlice(stream, current);
        self.bytes.clearRetainingCapacity();
    }

    fn rawFrame(self: *const @This(), alloc: Allocator, pid: i64) !?[]u8 {
        if (self.bytes.items.len == 0) return null;
        return try makeRawOutputFrame(alloc, pid, self.bytes.items);
    }

    fn deinit(self: *@This(), alloc: Allocator) void {
        self.bytes.deinit(alloc);
        self.bytes = .empty;
    }
};

fn replayHandoffSlice(stream: anytype, bytes: []const u8) void {
    stream.nextSlice(bytes);
    stream.handler.flushControlMode();
}

fn captureOrReplay(
    journal: *HandoffJournal,
    alloc: Allocator,
    data: []const u8,
    limit: usize,
    stream: anytype,
) !bool {
    journal.append(alloc, data, limit) catch |err| switch (err) {
        error.HandoffOverflow => {
            log.warn("native PTY handoff journal overflow; replaying output to the old parser", .{});
            journal.replay(stream, data);
            return false;
        },
        error.OutOfMemory => {
            log.warn("failed to grow native PTY handoff journal; replaying output to the old parser", .{});
            journal.replay(stream, data);
            return false;
        },
    };
    return true;
}

fn makeRawOutputFrame(alloc: Allocator, pid: i64, data: []const u8) ![]u8 {
    var header_buf: [96]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &header_buf,
        "(ghostel--native-transport-output {d} \"",
        .{pid},
    );
    const encoded_len = std.base64.standard.Encoder.calcSize(data.len);
    const content_len = std.math.add(usize, header.len, encoded_len) catch {
        return error.RawFrameTooLarge;
    };
    const frame_len = std.math.add(usize, content_len, 2) catch {
        return error.RawFrameTooLarge;
    };
    const frame = try alloc.alloc(u8, frame_len);

    @memcpy(frame[0..header.len], header);
    _ = std.base64.standard.Encoder.encode(
        frame[header.len..content_len],
        data,
    );
    @memcpy(frame[content_len..], "\")");
    return frame;
}

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
replica_name: [:0]u8,
child_pid: i64,
// Buffer event notifications so large terminal updates can be reported with
// few writes to Emacs.
event_buf: std.ArrayList(u8) = .empty,
event_mutex: EventMutex = .{},
event_flushing: bool = false,

owner: *GhostelTerm,
stream: gt.Stream(GhostelHandler(*Self)),
attached: std.atomic.Value(bool) = .init(false),
handoff_phase: std.atomic.Value(HandoffPhase) = .init(.dormant),
handoff_journal: HandoffJournal = .{},
commit_frame: ?[]u8 = null,
commit_frame_pending: std.atomic.Value(bool) = .init(false),

quit: std.atomic.Value(bool) = .init(false),
detached: std.atomic.Value(bool) = .init(false),
refresh_enabled: std.atomic.Value(bool) = .init(true),
finish_drain_on_exit: bool = true,
thread: std.Thread,

const LockedStream = struct {
    process: *Self,
    drained: bool = false,

    pub fn nextSlice(self: *LockedStream, data: []const u8) !void {
        if (!self.process.attached.load(.acquire)) return;
        try self.process.owner.lock();
        defer self.process.owner.unlock();
        if (!self.process.attached.load(.acquire)) return;
        try self.process.consumeOutputLocked(data, &self.drained);
    }
};

/// Return the child with a reference owned by the caller.
pub fn init(
    self: *Self,
    alloc: Allocator,
    io: std.Io,
    size: backend_types.WinSize,
    params: ProcessParams,
    owner: *GhostelTerm,
    event_fd: ChannelFd,
) !*ChildProcess {
    var event_writer = try EventWriter.init(event_fd);
    errdefer event_writer.close();

    var backend = try Backend.init(alloc, io, size, params);
    const child = backend.childHandle();
    errdefer {
        // Failed setup must not leave an unreachable child running.
        child.terminate() catch |err| log.err("Failed to terminate uninitialized native child: {any}", .{err});
        _ = backend.deinitAndWait();
    }
    child.refcount.retain();
    errdefer child.refcount.release();

    const foreground_handle = backend.duplicateForegroundHandle();
    errdefer Backend.closeForegroundHandle(foreground_handle);

    var stream: @TypeOf(self.stream) = .init(.{ .allocator = alloc, .handler = .init(alloc, owner, self) });
    errdefer stream.deinit();

    const replica_name = try alloc.dupeSentinel(u8, backend.replicaName(), 0);
    errdefer alloc.free(replica_name);
    const child_pid = child.pidValue();

    self.* = .{
        .alloc = alloc,
        .io = io,
        .backend = backend,
        .foreground_handle = foreground_handle,
        .event_writer = event_writer,
        .replica_name = replica_name,
        .child_pid = child_pid,
        .owner = owner,
        .stream = stream,
        .attached = .init(true),
        .refresh_enabled = .init(owner.refresh_enabled),
        .thread = undefined,
    };
    owner.refcount.retain();
    errdefer owner.refcount.release();
    if (builtin.mode == .debug) emacs.nativeReaderStarted();
    errdefer if (builtin.mode == .debug) emacs.nativeReaderStopped();
    self.thread = try std.Thread.spawn(.{}, Self.run, .{self});
    return child;
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

pub fn beginHandoff(self: *Self) !void {
    if (!self.owner.mutex.tryLock()) return error.TerminalBusy;
    defer self.owner.unlock();

    if (!self.attached.load(.acquire) or !self.isRunning()) return error.ProcessExited;
    switch (self.handoff_phase.load(.acquire)) {
        .dormant, .failed => {},
        else => return error.HandoffUnavailable,
    }

    self.handoff_journal.deinit(self.alloc);
    self.handoff_phase.store(.staging, .release);
}

pub fn commitHandoff(self: *Self) HandoffCommitResult {
    if (!self.owner.mutex.tryLock()) return .retry;

    if (!self.attached.load(.acquire) or !self.isRunning() or
        self.handoff_phase.load(.acquire) != .staging)
    {
        self.owner.unlock();
        return .unavailable;
    }

    const frame = self.handoff_journal.rawFrame(self.alloc, self.child_pid) catch |err| {
        log.warn("failed to prepare native PTY handoff frame; rolling back: {s}", .{@errorName(err)});
        self.handoff_phase.store(.cancel_pending, .release);
        self.owner.unlock();
        self.backend.wakeCommands();
        return .retry;
    };

    if (frame) |bytes| {
        if (!self.event_mutex.tryLock()) {
            self.alloc.free(bytes);
            self.owner.unlock();
            return .retry;
        }
        if (self.event_flushing) {
            self.event_mutex.unlock();
            self.alloc.free(bytes);
            self.owner.unlock();
            return .retry;
        }
        const with_frame = std.math.add(usize, self.event_buf.items.len, bytes.len) catch {
            log.warn("native PTY handoff event buffer size overflow; rolling back", .{});
            self.event_mutex.unlock();
            self.alloc.free(bytes);
            self.handoff_phase.store(.cancel_pending, .release);
            self.owner.unlock();
            self.backend.wakeCommands();
            return .retry;
        };
        const required = std.math.add(usize, with_frame, 2) catch {
            log.warn("native PTY handoff event buffer size overflow; rolling back", .{});
            self.event_mutex.unlock();
            self.alloc.free(bytes);
            self.handoff_phase.store(.cancel_pending, .release);
            self.owner.unlock();
            self.backend.wakeCommands();
            return .retry;
        };
        self.event_buf.ensureTotalCapacityPrecise(self.alloc, required) catch |err| {
            log.warn("failed to reserve native PTY handoff event buffer; rolling back: {s}", .{@errorName(err)});
            self.event_mutex.unlock();
            self.alloc.free(bytes);
            self.handoff_phase.store(.cancel_pending, .release);
            self.owner.unlock();
            self.backend.wakeCommands();
            return .retry;
        };
        self.event_mutex.unlock();
    }

    self.commit_frame = frame;
    self.commit_frame_pending.store(frame != null, .release);
    if (self.handoff_phase.cmpxchgStrong(
        .staging,
        .raw,
        .acq_rel,
        .acquire,
    ) != null) {
        self.commit_frame_pending.store(false, .release);
        self.commit_frame = null;
        if (frame) |bytes| self.alloc.free(bytes);
        self.owner.unlock();
        return .unavailable;
    }

    self.handoff_journal.deinit(self.alloc);
    self.owner.unlock();
    self.backend.wakeCommands();
    return .committed;
}

pub fn cancelHandoff(self: *Self) bool {
    if (!self.attached.load(.acquire) or !self.isRunning()) return false;

    const previous = self.handoff_phase.cmpxchgStrong(
        .staging,
        .cancel_pending,
        .acq_rel,
        .acquire,
    );
    if (previous == null) {
        self.backend.wakeCommands();
        return true;
    }
    return previous.? == .cancel_pending;
}

fn consumeOutputLocked(self: *Self, data: []const u8, drained: *bool) !void {
    if (data.len == 0) return;

    self.serviceHandoffLocked(drained, false);
    var phase = self.handoff_phase.load(.acquire);
    if (phase == .cancel_pending) {
        self.serviceHandoffLocked(drained, false);
        phase = self.handoff_phase.load(.acquire);
    }

    switch (phase) {
        .staging => {
            const captured = try captureOrReplay(
                &self.handoff_journal,
                self.alloc,
                data,
                HandoffJournalLimit,
                &self.stream,
            );
            if (captured) return;

            self.handoff_journal.deinit(self.alloc);
            self.handoff_phase.store(.failed, .release);
            drained.* = true;
        },
        .raw => {
            self.flushCommitFrameLocked(drained);
            try self.appendRawOutputFrameLocked(data);
            drained.* = true;
        },
        .dormant, .failed => self.parseDirectLocked(data, drained),
        .cancel_pending, .discarded => {},
    }
}

fn parseDirectLocked(self: *Self, data: []const u8, drained: *bool) void {
    self.stream.nextSlice(data);
    self.stream.handler.flushControlMode();
    drained.* = true;
}

fn serviceHandoffLocked(self: *Self, drained: *bool, process_exit: bool) void {
    switch (self.handoff_phase.load(.acquire)) {
        .cancel_pending => {
            const had_staged_bytes = self.handoff_journal.bytes.items.len > 0;
            self.handoff_journal.replay(&self.stream, "");
            self.handoff_journal.deinit(self.alloc);
            self.handoff_phase.store(if (process_exit) .failed else .dormant, .release);
            if (had_staged_bytes) drained.* = true;
        },
        .staging => if (process_exit) {
            const had_staged_bytes = self.handoff_journal.bytes.items.len > 0;
            self.handoff_journal.replay(&self.stream, "");
            self.handoff_journal.deinit(self.alloc);
            self.handoff_phase.store(.failed, .release);
            if (had_staged_bytes) drained.* = true;
        },
        .raw => self.flushCommitFrameLocked(drained),
        .dormant, .failed, .discarded => {},
    }
}

fn flushCommitFrameLocked(self: *Self, drained: *bool) void {
    if (!self.commit_frame_pending.swap(false, .acq_rel)) return;
    const frame = self.commit_frame orelse unreachable;

    self.event_mutex.lock();
    self.event_buf.appendSliceAssumeCapacity(frame);
    self.event_mutex.unlock();

    self.alloc.free(frame);
    self.commit_frame = null;
    drained.* = true;
}

fn appendRawOutputFrameLocked(self: *Self, data: []const u8) !void {
    const frame = try makeRawOutputFrame(self.alloc, self.child_pid, data);
    defer self.alloc.free(frame);

    self.event_mutex.lock();
    defer self.event_mutex.unlock();
    try self.event_buf.appendSlice(self.alloc, frame);
}

fn serviceHandoffAtLoopStart(self: *Self) !bool {
    if (self.handoff_phase.load(.acquire) != .cancel_pending and
        !self.commit_frame_pending.load(.acquire))
    {
        return false;
    }

    try self.owner.lock();
    defer self.owner.unlock();
    if (!self.attached.load(.acquire)) return false;

    var drained = false;
    self.serviceHandoffLocked(&drained, false);
    return drained;
}

fn finishHandoffOnExit(self: *Self) bool {
    self.owner.mutex.lockUncancelable(self.io);

    var drained = false;
    self.serviceHandoffLocked(&drained, true);
    if (self.handoff_phase.load(.acquire) == .raw) {
        self.flushCommitFrameLocked(&drained);
    }
    const has_pending_events = self.hasPendingEventsLocked();
    self.owner.unlock();
    return drained or has_pending_events;
}

// Buffer semantic callbacks until the PTY drain completes. If allocation
// fails, `effect` rolls back only the incomplete callback.
pub fn effect(self: *Self, comptime func: []const u8, args: anytype) void {
    self.event_mutex.lock();
    defer self.event_mutex.unlock();

    const event_len = self.event_buf.items.len;
    self.effectFallibleLocked(func, args) catch |err| {
        self.event_buf.shrinkRetainingCapacity(event_len);
        log.err("ghostel: Failed to write to event pipe: {s}", .{@errorName(err)});
    };
}

pub fn replicaName(self: *Self) [*:0]const u8 {
    return self.replica_name.ptr;
}

fn effectFallibleLocked(self: *Self, comptime func: []const u8, args: anytype) !void {
    try self.writeEventLocked("(");
    try self.writeEventLocked(func);
    inline for (@typeInfo(@TypeOf(args)).@"struct".field_names) |field_name| {
        try self.writeEventLocked(" ");
        try self.writeEventLispValueLocked(@field(args, field_name));
    }
    try self.writeEventLocked(")");
}

fn writeEventLispValueLocked(self: *Self, val: anytype) !void {
    const T = @TypeOf(val);
    const ty = @typeInfo(T);
    switch (ty) {
        .pointer => try self.writeEventLispStringLocked(val),
        .optional => if (val) |v| try self.writeEventLispValueLocked(v) else try self.writeEventLocked("nil"),
        .int => try self.writeEventLispNumberLocked(val),
        else => @compileError(std.fmt.comptimePrint("Non-supported type: {}", .{T})),
    }
}

fn writeEventLispNumberLocked(self: *Self, val: anytype) !void {
    var buf: [1024]u8 = undefined;
    const str = try std.mem.printSentinel(&buf, "{}", .{val}, 0);
    try self.writeEventLocked(str);
}

fn writeEventLispStringLocked(self: *Self, str: []const u8) !void {
    try self.writeEventLocked("\"");
    for (str) |ch| {
        switch (ch) {
            '\\' => try self.writeEventLocked("\\\\"),
            '\n' => try self.writeEventLocked("\\n"),
            '"' => try self.writeEventLocked("\\\""),
            else => try self.writeEventLocked(&[_]u8{ch}),
        }
    }
    try self.writeEventLocked("\"");
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
        const handoff_drained = if (self.attached.load(.acquire))
            self.finishHandoffOnExit()
        else
            false;
        if (self.attached.load(.acquire) and
            (final_stream.drained or handoff_drained or self.hasPendingEvents()))
        {
            self.notifyVtUpdate() catch |err| {
                log.warn("ghostel: error notifying final terminal update: {any}", .{err});
            };
        }
    }

    // The parser stream is reader-owned. Destroy it only after the final
    // callback, then release the terminal before child reaping can block.
    self.owner.mutex.lockUncancelable(self.io);
    self.handoff_journal.deinit(self.alloc);
    if (self.commit_frame) |frame| self.alloc.free(frame);
    self.commit_frame = null;
    self.commit_frame_pending.store(false, .release);
    self.stream.deinit();
    self.owner.unlock();
    self.owner.refcount.release();
    if (builtin.mode == .debug) emacs.nativeReaderStopped();

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
    if (try self.serviceHandoffAtLoopStart()) try self.notifyVtUpdate();
    if (!try self.processCommands(&self.backend)) return false;
    if (self.quit.load(.acquire)) {
        self.discardCommands();
        return false;
    }

    var stream = LockedStream{ .process = self };
    const result = try self.backend.drain(&stream);
    if (stream.drained or self.hasPendingEvents()) try self.notifyVtUpdate();

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
    self.event_mutex.lock();
    if (self.event_buf.items.len == 0) {
        if (!self.refresh_enabled.load(.acquire)) {
            self.event_mutex.unlock();
            return;
        }
        self.event_buf.appendSlice(self.alloc, "()") catch |err| {
            self.event_mutex.unlock();
            return err;
        };
    }
    self.event_mutex.unlock();
    try self.flushEventsWithWriter(writer);
}

fn writeEvent(self: *Self, data: []const u8) !void {
    self.event_mutex.lock();
    defer self.event_mutex.unlock();
    try self.writeEventLocked(data);
}

fn writeEventLocked(self: *Self, data: []const u8) !void {
    try self.event_buf.appendSlice(self.alloc, data);
}

fn flushEvents(self: *Self) !void {
    try self.flushEventsWithWriter(&self.event_writer);
}

fn flushEventsWithWriter(self: *Self, writer: anytype) !void {
    self.event_mutex.lock();
    const len = self.event_buf.items.len;
    if (len == 0) {
        self.event_mutex.unlock();
        return;
    }
    self.event_flushing = true;
    const batch = self.event_buf.items;
    self.event_mutex.unlock();

    const write_result = writer.write(batch);

    self.event_mutex.lock();
    self.event_flushing = false;
    if (write_result) |_| {
        if (self.event_buf.items.len < len) {
            self.event_mutex.unlock();
            return error.EventBufferChanged;
        }

        const remaining = self.event_buf.items.len - len;
        std.mem.copyForwards(
            u8,
            self.event_buf.items[0..remaining],
            self.event_buf.items[len..],
        );
        self.event_buf.shrinkRetainingCapacity(remaining);
        self.event_mutex.unlock();
    } else |err| {
        self.event_mutex.unlock();
        return err;
    }
}

fn hasPendingEventsLocked(self: *Self) bool {
    self.event_mutex.lock();
    defer self.event_mutex.unlock();
    return self.event_buf.items.len > 0;
}

fn hasPendingEvents(self: *Self) bool {
    return self.hasPendingEventsLocked();
}

fn reapChild(backend: Backend.Reaper, event_writer: EventWriter) void {
    var be = backend;
    const pid = be.pid;
    const exit_code = be.deinitAndWait();

    var writer = event_writer;
    var buf: [64]u8 = undefined;
    const marker = std.fmt.bufPrint(&buf, "\x1e{} {}\n", .{ pid, exit_code }) catch unreachable;
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
    self.attached.store(false, .release);
    self.handoff_phase.store(.discarded, .release);
}

fn cleanupDetached(self: *Self) void {
    // Retire before join so a copied PTY descriptor cannot suppress hangup.
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

fn makeTestProcess(io: std.Io) Self {
    return .{
        .alloc = std.testing.allocator,
        .io = io,
        .backend = undefined,
        .event_writer = .{ .fd = -1 },
        .replica_name = undefined,
        .child_pid = 4242,
        .owner = undefined,
        .stream = undefined,
        .thread = undefined,
    };
}

test "event serialization does not write while buffering" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var process: Self = undefined;
    process.alloc = std.testing.allocator;
    process.io = threaded.io();
    process.event_buf = .empty;
    process.event_mutex = .{};
    defer process.event_buf.deinit(process.alloc);
    process.event_writer = .{ .fd = -1 };

    const payload = try std.testing.allocator.alloc(u8, 20 * 1024);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');

    try process.writeEvent(payload);
    try std.testing.expectEqualSlices(u8, payload, process.event_buf.items);
}

test "paused empty VT update does not write a refresh" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var process = makeTestProcess(threaded.io());
    defer process.event_buf.deinit(process.alloc);
    process.setRefreshEnabled(false);

    var writer = RecordingEventWriter{ .alloc = std.testing.allocator };
    defer writer.deinit();

    try process.notifyVtUpdateWithWriter(&writer);
    try std.testing.expectEqualSlices(u8, "", writer.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), process.event_buf.items.len);
}

test "semantic callbacks flush while refresh notifications are paused" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var process = makeTestProcess(threaded.io());
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
    var threaded: std.Io.Threaded = .init_single_threaded;
    var process = makeTestProcess(threaded.io());
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
    process.attached = .init(false);

    var stream = LockedStream{ .process = &process };
    try stream.nextSlice("detached");
}

test "terminal replies reject PTY capacity waits" {
    const context: u8 = 0;
    const cancellation = WritePolicy.drop_if_blocked.cancellation(&context).?;

    try std.testing.expectEqual(@as(i64, 0), cancellation.poll_interval.toMilliseconds());
    try std.testing.expectError(error.TerminalReplyWouldBlock, cancellation.check());
}

test "handoff commit keeps staged and live raw frames ordered and PID-tagged" {
    var journal = HandoffJournal{};
    defer journal.deinit(std.testing.allocator);

    try journal.append(std.testing.allocator, "old", 64);
    try journal.append(std.testing.allocator, "new", 64);

    const staged_frame = (try journal.rawFrame(std.testing.allocator, 4242)).?;
    defer std.testing.allocator.free(staged_frame);
    const later_frame = try makeRawOutputFrame(std.testing.allocator, 4242, "tail");
    defer std.testing.allocator.free(later_frame);

    var frames: std.ArrayList(u8) = .empty;
    defer frames.deinit(std.testing.allocator);
    try frames.appendSlice(std.testing.allocator, staged_frame);
    try frames.appendSlice(std.testing.allocator, later_frame);

    try std.testing.expectEqualStrings(
        "(ghostel--native-transport-output 4242 \"b2xkbmV3\")" ++
            "(ghostel--native-transport-output 4242 \"dGFpbA==\")",
        frames.items,
    );
}

test "handoff abort replays staged bytes before the current input" {
    const TestStream = struct {
        alloc: Allocator,
        bytes: std.ArrayList(u8) = .empty,
        handler: struct {
            flushes: *usize,

            fn flushControlMode(self: *@This()) void {
                self.flushes.* += 1;
            }
        },

        fn nextSlice(self: *@This(), bytes: []const u8) void {
            self.bytes.appendSlice(self.alloc, bytes) catch unreachable;
        }
    };

    var flushes: usize = 0;
    var stream = TestStream{
        .alloc = std.testing.allocator,
        .handler = .{ .flushes = &flushes },
    };
    defer stream.bytes.deinit(std.testing.allocator);

    var journal = HandoffJournal{};
    defer journal.deinit(std.testing.allocator);
    try journal.append(std.testing.allocator, "staged", 64);

    journal.replay(&stream, "current");

    try std.testing.expectEqualStrings("stagedcurrent", stream.bytes.items);
    try std.testing.expectEqual(@as(usize, 2), flushes);
}

test "handoff overflow replays the staged prefix and overflowing slice" {
    const TestStream = struct {
        alloc: Allocator,
        bytes: std.ArrayList(u8) = .empty,
        handler: struct {
            flushes: *usize,

            fn flushControlMode(self: *@This()) void {
                self.flushes.* += 1;
            }
        },

        fn nextSlice(self: *@This(), bytes: []const u8) void {
            self.bytes.appendSlice(self.alloc, bytes) catch unreachable;
        }
    };

    var flushes: usize = 0;
    var stream = TestStream{
        .alloc = std.testing.allocator,
        .handler = .{ .flushes = &flushes },
    };
    defer stream.bytes.deinit(std.testing.allocator);

    var journal = HandoffJournal{};
    defer journal.deinit(std.testing.allocator);

    try std.testing.expect(try captureOrReplay(
        &journal,
        std.testing.allocator,
        "abc",
        3,
        &stream,
    ));
    try std.testing.expect(!try captureOrReplay(
        &journal,
        std.testing.allocator,
        "d",
        3,
        &stream,
    ));

    try std.testing.expectEqualStrings("abcd", stream.bytes.items);
    try std.testing.expectEqual(@as(usize, 2), flushes);
}
