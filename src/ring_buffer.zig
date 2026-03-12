pub fn RingQueue(comptime T: type, comptime N: usize) type {
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
            self.tail = (self.tail + 1) % N;
            self.len += 1;
            return true;
        }

        pub fn popFront(self: *Self) ?T {
            if (self.len == 0) return null;

            const value = self.buf[self.head];
            self.head = (self.head + 1) % N;
            self.len -= 1;
            return value;
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
