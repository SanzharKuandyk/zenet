pub fn RingQueue(comptime T: type, comptime N: usize) type {
    comptime {
        if (N == 0 or (N & (N - 1)) != 0)
            @compileError("RingQueue capacity must be a power of two");
    }
    const mask = N - 1;

    return struct {
        const Self = @This();

        buf: [N]T = undefined,
        head: usize = 0,
        tail: usize = 0,
        len: usize = 0,

        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }

        pub fn isFull(self: *const Self) bool {
            return self.len == N;
        }

        pub fn pushBack(self: *Self, value: T) bool {
            if (self.len == N) return false;

            self.buf[self.tail] = value;
            self.tail = (self.tail + 1) & mask;
            self.len += 1;
            return true;
        }

        /// Reserve the next back slot for in-place writes.
        pub fn pushBackSlot(self: *Self) ?*T {
            if (self.len == N) return null;

            const slot = &self.buf[self.tail];
            self.tail = (self.tail + 1) & mask;
            self.len += 1;
            return slot;
        }

        pub fn popFront(self: *Self) ?T {
            if (self.len == 0) return null;

            const value = self.buf[self.head];
            self.head = (self.head + 1) & mask;
            self.len -= 1;
            return value;
        }

        pub fn peekFront(self: *const Self) ?*const T {
            if (self.len == 0) return null;
            return &self.buf[self.head];
        }

        pub fn peekFrontMut(self: *Self) ?*T {
            if (self.len == 0) return null;
            return &self.buf[self.head];
        }

        /// Discard the front element (void return = no copy, unlike popFront).
        pub fn advance(self: *Self) void {
            if (self.len == 0) return;
            self.head = (self.head + 1) & mask;
            self.len -= 1;
        }

        pub fn clear(self: *Self) void {
            self.head = 0;
            self.tail = 0;
            self.len = 0;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }
    };
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

const testing = @import("std").testing;

test "peekFront on empty returns null" {
    var q: RingQueue(u32, 4) = .{};
    try testing.expect(q.peekFront() == null);
    std.debug.print("\n  PASS: peekFront on empty returns null\n", .{});
}

test "peekFront does not advance" {
    var q: RingQueue(u32, 4) = .{};
    _ = q.pushBack(10);
    _ = q.pushBack(20);

    const p = q.peekFront().?;
    try testing.expectEqual(@as(u32, 10), p.*);
    try testing.expectEqual(@as(usize, 2), q.count());

    // second peek still returns same element
    const p2 = q.peekFront().?;
    try testing.expectEqual(@as(u32, 10), p2.*);
    try testing.expectEqual(@as(usize, 2), q.count());

    std.debug.print("\n  PASS: peekFront does not advance\n", .{});
}

test "advance discards front element" {
    var q: RingQueue(u32, 4) = .{};
    _ = q.pushBack(1);
    _ = q.pushBack(2);
    _ = q.pushBack(3);

    q.advance();
    try testing.expectEqual(@as(usize, 2), q.count());
    try testing.expectEqual(@as(u32, 2), q.peekFront().?.*);

    q.advance();
    try testing.expectEqual(@as(usize, 1), q.count());
    try testing.expectEqual(@as(u32, 3), q.peekFront().?.*);

    q.advance();
    try testing.expectEqual(@as(usize, 0), q.count());
    try testing.expect(q.peekFront() == null);

    // advance on empty is a no-op
    q.advance();
    try testing.expectEqual(@as(usize, 0), q.count());

    std.debug.print("\n  PASS: advance discards front element\n", .{});
}

const std = @import("std");
