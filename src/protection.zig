const std = @import("std");
const RingQueue = @import("ring_buffer.zig").RingQueue;

const USER_DATA_SIZE = @import("root.zig").USER_DATA_SIZE;

// Used when secure is true
// Sent with `ConnectionRequest.Secure`
// Should be created in your architecture by: Matchmaking/Lobby/etc
pub const ConnectToken = struct {
    client_id: u64,
    expires_at: u64,
    server_addrs: std.ArrayList(std.net.Address),
    user_data: [USER_DATA_SIZE]u8,
    mac: [16]u8,

    pub fn create() ConnectToken {}
    pub fn verify() bool {}
};

// Nonce check
pub fn RecentNonces(comptime Window: usize) type {
    return struct {
        const Self = @This();

        order: RingQueue(u64, Window),
        seen: std.AutoHashMap(u64, void),

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .order = .{},
                .seen = std.AutoHashMap(u64, void).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.seen.deinit();
        }

        pub fn contains(self: *const Self, nonce: u64) bool {
            return self.seen.contains(nonce);
        }

        pub fn insert(self: *Self, nonce: u64) !bool {
            if (self.seen.contains(nonce)) return false;

            if (self.order.isFull()) {
                const old = self.order.popFront().?;
                _ = self.seen.remove(old);
            }

            _ = self.order.pushBack(nonce);
            try self.seen.put(nonce, {});
            return true;
        }
    };
}
