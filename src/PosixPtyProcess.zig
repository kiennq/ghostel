const std = @import("std");
const Allocator = std.mem.Allocator;
const sys = std.posix.system;

const backend_types = @import("backend_types.zig");
const c = @import("posix_c");

const Self = @This();
const WRITE_CHUNK_SIZE = 4096;

const log = std.log.scoped(.NativeProcessHandler);

const Pty = struct {
    primary_fd: c_int = -1,
    replica_fd: c_int = -1,
    replica_name: [1024:0]u8 = undefined,

    pub fn init() !Pty {
        var self: @This() = .{};
        self.primary_fd = c.posix_openpt(c.O_RDWR | c.O_NOCTTY | c.O_CLOEXEC);
        if (sys.errno(self.primary_fd) != .SUCCESS) {
            return error.OpenPtFailed;
        }
        errdefer _ = sys.close(self.primary_fd);

        if (sys.errno(c.grantpt(self.primary_fd)) != .SUCCESS) {
            return error.GrantPtFailed;
        }

        if (sys.errno(c.unlockpt(self.primary_fd)) != .SUCCESS) {
            return error.UnlockPtFailed;
        }

        const ptsname_err = sys.errno(c.ptsname_r(
            self.primary_fd,
            &self.replica_name,
            self.replica_name.len,
        ));
        if (ptsname_err != .SUCCESS) {
            return error.PtsNameFailed;
        }

        self.replica_fd = sys.open(&self.replica_name, .{ .ACCMODE = .RDWR, .NOCTTY = true });
        if (sys.errno(self.replica_fd) != .SUCCESS) return error.OpenReplicaFailed;
        errdefer _ = sys.close(self.replica_fd);

        // Configure the line discipline on the replica. On macOS/BSD the
        // master (ptm) fd rejects termios ioctls with ENOTTY; only the
        // replica carries the terminal attributes, so this must run on
        // `replica_fd', not `primary_fd'.
        var attrs: c.termios = undefined;
        if (c.tcgetattr(self.replica_fd, &attrs) != 0) return error.TcgetattrFailed;

        // Enable UTF-8 mode so backspace erases multi-byte characters.
        attrs.c_iflag |= c.IUTF8;
        // Disable XON/XOFF flow control so C-q (DC1) and C-s (DC3) pass
        // through to the application instead of being swallowed by the
        // line discipline. Ghostel's send-next-key escape hatch and the
        // direct C-q binding rely on these bytes reaching the child.
        attrs.c_iflag &= ~@as(@TypeOf(attrs.c_iflag), c.IXON);
        if (c.tcsetattr(self.replica_fd, c.TCSANOW, &attrs) != 0) return error.TcsetattrFailed;

        return self;
    }

    pub fn resize(self: *@This(), cols: u16, rows: u16) !void {
        const size = c.winsize{ .ws_col = cols, .ws_row = rows, .ws_xpixel = 0, .ws_ypixel = 0 };
        switch (sys.errno(c.ioctl(self.primary_fd, c.TIOCSWINSZ, &size))) {
            .SUCCESS, .IO, .NXIO => {},
            else => return error.PtyResizeFailed,
        }
    }

    pub fn closePrimary(self: *@This()) void {
        if (self.primary_fd != -1) {
            _ = sys.close(self.primary_fd);
            self.primary_fd = -1;
        }
    }

    pub fn closeReplica(self: *@This()) void {
        if (self.replica_fd != -1) {
            _ = sys.close(self.replica_fd);
            self.replica_fd = -1;
        }
    }

    pub fn replicaName(self: *@This()) []const u8 {
        return std.mem.span(@as([*:0]const u8, @ptrCast(&self.replica_name)));
    }

    pub fn setupReplica(self: *@This()) !void {
        if (sys.errno(sys.setsid()) != .SUCCESS) return error.SetSidFailed;
        if (sys.errno(c.ioctl(self.replica_fd, c.TIOCSCTTY)) != .SUCCESS) return error.CttyFailed;

        if (sys.errno(sys.dup2(self.replica_fd, sys.STDIN_FILENO)) != .SUCCESS) {
            return error.ReplicaFdSetupFailed;
        }
        if (sys.errno(sys.dup2(self.replica_fd, sys.STDOUT_FILENO)) != .SUCCESS) {
            return error.ReplicaFdSetupFailed;
        }
        if (sys.errno(sys.dup2(self.replica_fd, sys.STDERR_FILENO)) != .SUCCESS) {
            return error.ReplicaFdSetupFailed;
        }
    }

    pub fn deinit(self: *@This()) void {
        self.closePrimary();
        self.closeReplica();
    }
};

pty: Pty,
pid: sys.pid_t = -1,
wake_pipe: [2]sys.fd_t = .{ -1, -1 },
command_pipe: [2]sys.fd_t = .{ -1, -1 },

pub const EventWriter = struct {
    pub const Fd = sys.fd_t;

    fd: Fd,

    pub fn init(fd: Fd) !EventWriter {
        return .{ .fd = fd };
    }

    pub fn write(self: *EventWriter, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            const n = writeWithRetry(self.fd, data[written..data.len]);
            if (n <= 0) return error.EventWriteFailed;
            written += @intCast(n);
        }
    }

    pub fn close(self: *EventWriter) void {
        if (self.fd == -1) return;
        _ = sys.close(self.fd);
        self.fd = -1;
    }

    pub fn onThreadEnter(self: *EventWriter) void {
        if (@hasDecl(sys.F, "SETNOSIGPIPE")) {
            _ = fcntl(self.fd, sys.F.SETNOSIGPIPE, 1) catch |err| {
                log.warn("Unable to set SETNOSIGPIPE: {any}", .{err});
            };
        }

        var set: c.sigset_t = undefined;
        _ = c.sigemptyset(&set);
        _ = c.sigaddset(&set, c.SIGPIPE);
        _ = sys.errno(c.pthread_sigmask(c.SIG_BLOCK, &set, null));
    }

    pub fn onThreadExit() void {
        var pending: c.sigset_t = undefined;
        _ = c.sigpending(&pending);
        if (c.sigismember(&pending, c.SIGPIPE) != 0) {
            var wait_sigs: c.sigset_t = undefined;
            _ = c.sigemptyset(&wait_sigs);
            _ = c.sigaddset(&wait_sigs, c.SIGPIPE);
            var sig: c_int = undefined;
            _ = c.sigwait(&wait_sigs, &sig);
        }
    }
};

fn fcntl(fd: sys.fd_t, cmd: c_int, arg: c_int) !c_int {
    const result = sys.fcntl(fd, cmd, arg);
    return if (sys.errno(result) == .SUCCESS) result else error.FcntlFailed;
}

fn writeWithRetry(fd: sys.fd_t, data: []const u8) isize {
    while (true) {
        const written = sys.write(fd, data.ptr, data.len);
        if (sys.errno(written) != .INTR) return written;
    }
}

fn pollWithRetry(pollfds: []sys.pollfd, timeout: c_int) c_int {
    while (true) {
        const result = sys.poll(pollfds.ptr, @intCast(pollfds.len), timeout);
        if (sys.errno(result) != .INTR) return result;
    }
}

fn failChild(msg: []const u8, err: []const u8) noreturn {
    _ = sys.write(sys.STDERR_FILENO, msg.ptr, msg.len);
    _ = sys.write(sys.STDERR_FILENO, ": ", 2);
    _ = sys.write(sys.STDERR_FILENO, err.ptr, err.len);
    std.c._exit(1);
}

pub const Reaper = struct {
    pty: Pty,
    pid: sys.pid_t,

    pub fn deinitAndWait(self: *@This()) u32 {
        std.debug.assert(self.pid > 0);
        self.pty.deinit();

        while (true) {
            var status: c_int = undefined;
            switch (sys.errno(sys.waitpid(self.pid, &status, 0))) {
                .SUCCESS => {
                    if (c.WIFEXITED(status)) return @intCast(c.WEXITSTATUS(status));
                    if (c.WIFSIGNALED(status)) return @intCast(128 + c.WTERMSIG(status));
                    return 255;
                },
                .INTR => continue,
                else => return 255,
            }
        }
    }
};

fn createNonblockingPipe(pipe: *[2]sys.fd_t) !void {
    if (sys.errno(sys.pipe(pipe)) != .SUCCESS) return error.PipeCreationFailed;
    errdefer closePipe(pipe);

    // pipe2 is unavailable on macOS, so set both properties after creation.
    for (pipe.*) |fd| {
        _ = try fcntl(fd, sys.F.SETFD, sys.FD_CLOEXEC);
        const flags = try fcntl(fd, sys.F.GETFL, 0);
        _ = try fcntl(
            fd,
            sys.F.SETFL,
            flags | @as(u32, @bitCast(sys.O{ .NONBLOCK = true })),
        );
    }
}

pub fn init(alloc: Allocator, _: std.Io, initial_cols: u16, initial_rows: u16, params: backend_types.ProcessParams) !Self {
    var self = Self{ .pty = try .init() };
    errdefer self.pty.deinit();
    try self.pty.resize(initial_cols, initial_rows);

    var arena_allocator = std.heap.ArenaAllocator.init(alloc);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    const env = try params.env.createPosixBlock(arena, .{});
    const args = try arena.allocSentinel(?[*:0]const u8, params.args.len, null);
    for (params.args, 0..) |arg, i| args[i] = arg;

    try createNonblockingPipe(&self.wake_pipe);
    errdefer closePipe(&self.wake_pipe);

    try createNonblockingPipe(&self.command_pipe);
    errdefer closePipe(&self.command_pipe);

    const flags = try fcntl(self.pty.primary_fd, sys.F.GETFL, 0);
    _ = try fcntl(
        self.pty.primary_fd,
        sys.F.SETFL,
        flags | @as(u32, @bitCast(sys.O{ .NONBLOCK = true })),
    );

    const pid = sys.fork();
    if (sys.errno(pid) != .SUCCESS) return error.ForkFailed;
    if (pid != 0) {
        // This is the parent, child started successfully.
        self.pty.closeReplica();
        self.pid = pid;
        return self;
    }

    // This is the child.
    self.pty.setupReplica() catch |err| {
        failChild("Failed to set up PTY replica", @errorName(err));
    };

    if (params.cwd) |cwd| {
        const result = sys.errno(sys.chdir(cwd));
        if (result != .SUCCESS) {
            failChild("Failed to change working directory", @tagName(result));
        }
    }

    const err = sys.execve(params.file, args, env.slice);

    // The above never returns on success, if we're here it means we failed.
    failChild("Failed to start subprocess", @tagName(sys.errno(err)));
}

pub fn pidValue(self: *const Self) i64 {
    return @intCast(self.pid);
}

pub fn resize(self: *Self, cols: u16, rows: u16) !void {
    try self.pty.resize(cols, rows);
}

pub fn write(
    self: *Self,
    data: []const u8,
    cancellation: ?backend_types.CancellationToken,
) !backend_types.WriteResult {
    if (data.len == 0) return .{ .written = 0 };

    const chunk = data[0..@min(data.len, WRITE_CHUNK_SIZE)];
    while (true) {
        const written = writeWithRetry(self.pty.primary_fd, chunk);
        if (written == 0) return error.IoFailed;
        switch (sys.errno(written)) {
            .SUCCESS => return .{ .written = @intCast(written) },

            .PIPE, .IO, .SRCH, .NXIO => return error.ProcessExited,

            .AGAIN => {
                var pollfds = [_]sys.pollfd{
                    .{
                        .fd = self.pty.primary_fd,
                        .events = sys.POLL.OUT,
                        .revents = undefined,
                    },
                    .{
                        .fd = self.wake_pipe[0],
                        .events = sys.POLL.IN,
                        .revents = undefined,
                    },
                };
                const timeout: i32 = if (cancellation) |token|
                    @intCast(@min(
                        token.poll_interval.toMilliseconds(),
                        @as(u32, @intCast(std.math.maxInt(i32))),
                    ))
                else
                    -1;
                const ready = pollWithRetry(&pollfds, timeout);
                if (sys.errno(ready) != .SUCCESS) return error.IoFailed;
                if (ready == 0) {
                    try cancellation.?.check();
                    continue;
                }
                if (pollfds[1].revents != 0) return .interrupted;
                continue;
            },

            else => return error.IoFailed,
        }
    }
}

pub fn drain(self: *Self, stream: anytype) !backend_types.DrainResult {
    var buf: [4096]u8 = undefined;

    var pollfds = [_]sys.pollfd{
        .{
            .fd = self.pty.primary_fd,
            .events = sys.POLL.IN,
            .revents = undefined,
        },
        .{
            .fd = self.wake_pipe[0],
            .events = sys.POLL.IN,
            .revents = undefined,
        },
        .{
            .fd = self.command_pipe[0],
            .events = sys.POLL.IN,
            .revents = undefined,
        },
    };
    if (sys.errno(pollWithRetry(&pollfds, -1)) != .SUCCESS) {
        return error.PollFailed;
    }
    if (pollfds[1].revents != 0) return .stopped;
    if (pollfds[2].revents != 0) {
        self.clearCommandWake();
        return .command;
    }

    const eof = pollfds[0].revents & sys.POLL.HUP != 0;
    var drained = false;
    while (true) {
        const len = sys.read(self.pty.primary_fd, &buf, buf.len);
        if (len == 0) return if (eof) .finished else if (drained) .output else .finished;
        switch (sys.errno(len)) {
            .SUCCESS => {
                drained = true;
                try stream.nextSlice(buf[0..@intCast(len)]);
            },
            .INTR => continue,
            .AGAIN => return if (eof) .finished else .output,
            .BADF, .IO => return .finished,
            else => return error.ReadFailed,
        }
    }
}

pub fn finishDrain(_: *Self, _: anytype) !void {}

pub fn wakeCommands(self: *Self) void {
    if (self.command_pipe[1] == -1) return;
    _ = writeWithRetry(self.command_pipe[1], "W");
}

pub fn clearCommandWake(self: *Self) void {
    clearPipe(self.command_pipe[0]);
}

pub fn requestStop(self: *Self, _: std.Thread) void {
    if (self.wake_pipe[1] == -1) return;
    _ = writeWithRetry(self.wake_pipe[1], "S");
}

pub fn takeForReaper(self: *Self) Reaper {
    const reaper = Reaper{
        .pty = self.pty,
        .pid = self.pid,
    };
    self.pty.primary_fd = -1;
    self.pty.replica_fd = -1;
    self.pid = -1;
    return reaper;
}

pub fn replicaName(self: *Self) []const u8 {
    return self.pty.replicaName();
}

pub fn closeWakeEndpoints(self: *Self) void {
    closePipe(&self.wake_pipe);
    closePipe(&self.command_pipe);
}

pub fn deinitAndWait(self: *Self) u32 {
    self.closeWakeEndpoints();
    var reaper = self.takeForReaper();
    return reaper.deinitAndWait();
}

fn clearPipe(fd: sys.fd_t) void {
    if (fd == -1) return;

    var buf: [64]u8 = undefined;
    while (true) {
        const n = sys.read(fd, &buf, buf.len);
        switch (sys.errno(n)) {
            .SUCCESS => {},
            .INTR => continue,
            .AGAIN => return,
            else => return,
        }
        if (n == 0 or n < buf.len) return;
    }
}

fn closePipe(pipe: *[2]sys.fd_t) void {
    if (pipe[0] != -1) {
        _ = sys.close(pipe[0]);
        pipe[0] = -1;
    }
    if (pipe[1] != -1) {
        _ = sys.close(pipe[1]);
        pipe[1] = -1;
    }
}

test "wakeCommands signals command pipe after reaper handoff" {
    var command_pipe: [2]sys.fd_t = .{ -1, -1 };
    try createNonblockingPipe(&command_pipe);
    defer closePipe(&command_pipe);

    var process = Self{
        .pty = .{},
        .pid = 42,
        .command_pipe = command_pipe,
    };

    _ = process.takeForReaper();
    process.wakeCommands();

    var pollfds = [_]sys.pollfd{.{
        .fd = command_pipe[0],
        .events = sys.POLL.IN,
        .revents = undefined,
    }};
    const ready = pollWithRetry(&pollfds, 0);
    try std.testing.expectEqual(sys.E.SUCCESS, sys.errno(ready));
    try std.testing.expectEqual(@as(c_int, 1), ready);
    try std.testing.expect(pollfds[0].revents & sys.POLL.IN != 0);

    var buf: [1]u8 = undefined;
    const n = sys.read(command_pipe[0], &buf, buf.len);
    try std.testing.expectEqual(sys.E.SUCCESS, sys.errno(n));
    try std.testing.expectEqual(@as(isize, 1), n);
    try std.testing.expectEqualStrings("W", &buf);
}

test "requestStop signals wake pipe after reaper handoff" {
    var wake_pipe: [2]sys.fd_t = .{ -1, -1 };
    try createNonblockingPipe(&wake_pipe);
    defer closePipe(&wake_pipe);

    var process = Self{
        .pty = .{},
        .pid = 42,
        .wake_pipe = wake_pipe,
    };

    _ = process.takeForReaper();
    process.requestStop(undefined);

    var pollfds = [_]sys.pollfd{.{
        .fd = wake_pipe[0],
        .events = sys.POLL.IN,
        .revents = undefined,
    }};
    const ready = pollWithRetry(&pollfds, 0);
    try std.testing.expectEqual(sys.E.SUCCESS, sys.errno(ready));
    try std.testing.expectEqual(@as(c_int, 1), ready);
    try std.testing.expect(pollfds[0].revents & sys.POLL.IN != 0);

    var buf: [1]u8 = undefined;
    const n = sys.read(wake_pipe[0], &buf, buf.len);
    try std.testing.expectEqual(sys.E.SUCCESS, sys.errno(n));
    try std.testing.expectEqual(@as(isize, 1), n);
    try std.testing.expectEqualStrings("S", &buf);
}
