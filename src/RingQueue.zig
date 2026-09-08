const std = @import("std");

/// Fixed-capacity multi-producer/single-consumer ring buffer.
///
/// Producers reserve slots by advancing `next` with compare-exchange, write the
/// item, then publish readiness for that slot. The single consumer advances
/// `head` in order and only reads a slot after observing it ready. It is not safe
/// for multiple consumers or arbitrary list-style mutation.
///
/// The ring leaves one physical slot empty to distinguish full from empty; it
/// does not reserve any slot for a particular command kind.
pub fn RingQueue(comptime T: type, comptime capacity: usize) type {
    comptime std.debug.assert(capacity > 1);

    return struct {
        const Self = @This();
        const Slot = struct {
            item: T = undefined,
            ready: std.atomic.Value(bool) = .init(false),
        };

        slots: [capacity]Slot = [_]Slot{.{}} ** capacity,
        head: std.atomic.Value(usize) = .init(0),
        next: std.atomic.Value(usize) = .init(0),

        pub fn push(self: *Self, item: T) bool {
            return self.pushReserved(item, 0);
        }

        pub fn pushReserved(self: *Self, item: T, reserved_slots: usize) bool {
            std.debug.assert(reserved_slots < capacity);

            const slot_index = while (true) {
                const next = self.next.load(.monotonic);
                const new_next = advance(next);
                const head = self.head.load(.acquire);
                if (!hasCapacityAfterPush(new_next, head, reserved_slots)) return false;

                if (self.next.cmpxchgWeak(next, new_next, .acq_rel, .monotonic) == null) {
                    break next;
                }
            };

            self.slots[slot_index].item = item;
            self.slots[slot_index].ready.store(true, .release);
            return true;
        }

        pub fn pop(self: *Self) ?T {
            const head = self.head.load(.monotonic);
            if (!self.slots[head].ready.load(.acquire)) return null;

            const item = self.slots[head].item;
            self.slots[head].ready.store(false, .release);
            self.head.store(advance(head), .release);
            return item;
        }

        pub fn isEmpty(self: *Self) bool {
            const head = self.head.load(.monotonic);
            return !self.slots[head].ready.load(.acquire);
        }

        fn advance(index: usize) usize {
            return (index + 1) % capacity;
        }

        fn hasCapacityAfterPush(new_next: usize, head: usize, reserved_slots: usize) bool {
            var probe = new_next;
            var empty_slots: usize = 0;
            while (empty_slots <= reserved_slots) : (empty_slots += 1) {
                if (probe == head) return false;
                probe = advance(probe);
            }
            return true;
        }
    };
}

test "RingQueue preserves FIFO order" {
    var queue: RingQueue(u8, 3) = .{};

    try std.testing.expect(queue.push(1));
    try std.testing.expect(queue.push(2));
    try std.testing.expectEqual(@as(?u8, 1), queue.pop());
    try std.testing.expect(queue.push(3));
    try std.testing.expectEqual(@as(?u8, 2), queue.pop());
    try std.testing.expectEqual(@as(?u8, 3), queue.pop());
    try std.testing.expectEqual(@as(?u8, null), queue.pop());
}

test "RingQueue reports full without command-reserved slots" {
    var queue: RingQueue(u8, 3) = .{};

    try std.testing.expect(queue.push(1));
    try std.testing.expect(queue.push(2));
    try std.testing.expect(!queue.push(3));

    try std.testing.expectEqual(@as(?u8, 1), queue.pop());
    try std.testing.expectEqual(@as(?u8, 2), queue.pop());
    try std.testing.expectEqual(@as(?u8, null), queue.pop());
}

test "RingQueue can preserve a reserved slot" {
    var queue: RingQueue(u8, 4) = .{};

    try std.testing.expect(queue.pushReserved(1, 1));
    try std.testing.expect(queue.pushReserved(2, 1));
    try std.testing.expect(!queue.pushReserved(3, 1));
    try std.testing.expect(queue.push(3));
    try std.testing.expect(!queue.push(4));

    try std.testing.expectEqual(@as(?u8, 1), queue.pop());
    try std.testing.expectEqual(@as(?u8, 2), queue.pop());
    try std.testing.expectEqual(@as(?u8, 3), queue.pop());
    try std.testing.expectEqual(@as(?u8, null), queue.pop());
}

test "RingQueue reports whether queued work remains" {
    var queue: RingQueue(u8, 3) = .{};

    try std.testing.expect(queue.isEmpty());
    try std.testing.expect(queue.push(1));
    try std.testing.expect(!queue.isEmpty());
    try std.testing.expectEqual(@as(?u8, 1), queue.pop());
    try std.testing.expect(queue.isEmpty());
}

test "RingQueue supports multiple producers" {
    var queue: RingQueue(u32, 64) = .{};
    const Producer = struct {
        fn run(q: *RingQueue(u32, 64), base: u32) void {
            var i: u32 = 0;
            while (i < 16) : (i += 1) {
                while (!q.push(base + i)) std.Thread.yield() catch {};
            }
        }
    };

    const t1 = try std.Thread.spawn(.{}, Producer.run, .{ &queue, 0 });
    const t2 = try std.Thread.spawn(.{}, Producer.run, .{ &queue, 100 });
    t1.join();
    t2.join();

    var seen = [_]bool{false} ** 32;
    var count: usize = 0;
    while (queue.pop()) |value| {
        const index: usize = if (value < 16) value else value - 84;
        try std.testing.expect(index < seen.len);
        try std.testing.expect(!seen[index]);
        seen[index] = true;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 32), count);
    for (seen) |item_seen| try std.testing.expect(item_seen);
}
