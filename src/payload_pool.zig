const std = @import("std");

pub fn PayloadPool(comptime cap: usize, comptime max_len: usize) type {
    comptime {
        if (cap == 0)
            @compileError("PayloadPool capacity must be greater than zero");
    }

    return struct {
        const Self = @This();

        pub const Ref = struct {
            slot: u32,
        };

        const Slot = struct {
            used: bool = false,
            len: u16 = 0,
            data: [max_len]u8 = undefined,
        };

        slots: [cap]Slot = [_]Slot{.{}} ** cap,

        pub fn allocCopy(self: *Self, src: []const u8) ?Ref {
            for (&self.slots, 0..) |*slot, i| {
                if (slot.used) continue;

                // Copy once into a stable slot so queues can store a small ref.
                const len = @min(src.len, max_len);
                slot.used = true;
                slot.len = @intCast(len);
                @memcpy(slot.data[0..len], src[0..len]);
                return .{ .slot = @intCast(i) };
            }
            return null;
        }

        pub fn release(self: *Self, ref: Ref) void {
            self.slots[ref.slot] = .{};
        }

        pub fn slice(self: *const Self, ref: Ref) []const u8 {
            const slot = &self.slots[ref.slot];
            return slot.data[0..slot.len];
        }
    };
}
