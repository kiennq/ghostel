const std = @import("std");
const Self = @This();

mutex: std.Io.Mutex = .init,
thread_id: std.Thread.Id = unlocked,
lock_count: usize = 0,

const unlocked = std.math.maxInt(std.Thread.Id);

pub fn lock(self: *Self, io: std.Io) !void {
    const current = std.Thread.getCurrentId();
    if (@atomicLoad(std.Thread.Id, &self.thread_id, .unordered) != current) {
        try self.mutex.lock(io);
        @atomicStore(std.Thread.Id, &self.thread_id, current, .unordered);
    }
    self.lock_count += 1;
}

pub fn lockUncancelable(self: *Self, io: std.Io) void {
    const current = std.Thread.getCurrentId();
    if (@atomicLoad(std.Thread.Id, &self.thread_id, .unordered) != current) {
        self.mutex.lockUncancelable(io);
        @atomicStore(std.Thread.Id, &self.thread_id, current, .unordered);
    }
    self.lock_count += 1;
}

pub fn tryLock(self: *Self) bool {
    const current = std.Thread.getCurrentId();
    if (@atomicLoad(std.Thread.Id, &self.thread_id, .unordered) == current) {
        self.lock_count += 1;
        return true;
    }
    if (!self.mutex.tryLock()) return false;
    @atomicStore(std.Thread.Id, &self.thread_id, current, .unordered);
    self.lock_count = 1;
    return true;
}

pub fn unlock(self: *Self, io: std.Io) void {
    self.lock_count -= 1;
    if (self.lock_count == 0) {
        @atomicStore(std.Thread.Id, &self.thread_id, unlocked, .unordered);
        self.mutex.unlock(io);
    }
}

test "tryLock rejects a foreign holder and succeeds after release" {
    const Context = struct {
        mutex: *Self,
        io: std.Io,
        result: *std.atomic.Value(bool),

        fn run(self: *@This()) void {
            const acquired = self.mutex.tryLock();
            self.result.store(acquired, .release);
            if (acquired) self.mutex.unlock(self.io);
        }
    };

    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var mutex: Self = .{};
    var result = std.atomic.Value(bool).init(false);
    var context = Context{
        .mutex = &mutex,
        .io = io,
        .result = &result,
    };

    try mutex.lock(io);
    var thread = try std.Thread.spawn(.{}, Context.run, .{&context});
    thread.join();
    try std.testing.expect(!result.load(.acquire));

    mutex.unlock(io);
    result.store(false, .release);
    thread = try std.Thread.spawn(.{}, Context.run, .{&context});
    thread.join();
    try std.testing.expect(result.load(.acquire));
}
