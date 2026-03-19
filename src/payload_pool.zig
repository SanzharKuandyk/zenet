const std = @import("std");

pub fn PayloadPool(comptime cap: usize, comptime max_len: usize) type {
    comptime {
        if (cap == 0)
            @compileError("PayloadPool capacity must be greater than zero");
    }

    // Keep references and stored lengths no wider than this configuration needs.
    const SlotIndex = std.math.IntFittingRange(0, cap - 1);
    const Len = std.math.IntFittingRange(0, max_len);

    return struct {
        const Self = @This();

        pub const Ref = struct {
            slot: SlotIndex,
        };

        const Slot = struct {
            // Singly-linked free list embedded directly in the slot array.
            next_free: ?SlotIndex = null,
            used: bool = false,
            len: Len = 0,
            data: [max_len]u8 = undefined,
        };

        slots: [cap]Slot,
        // Head of the free list; null means the pool is exhausted.
        free_head: ?SlotIndex,

        pub fn init() Self {
            var self = Self{
                .slots = undefined,
                .free_head = 0,
            };

            // Link every slot into the initial free list once up front.
            for (&self.slots, 0..) |*slot, i| {
                slot.* = .{
                    .next_free = if (i + 1 < cap) @as(SlotIndex, @intCast(i + 1)) else null,
                };
            }

            return self;
        }

        pub fn allocCopy(self: *Self, src: []const u8) ?Ref {
            // Pop one slot from the free list in O(1).
            const slot_idx = self.free_head orelse return null;
            const slot = &self.slots[slot_idx];
            self.free_head = slot.next_free;

            // Copy once into a stable slot so queues can store a small ref.
            const len = @min(src.len, max_len);
            slot.used = true;
            slot.next_free = null;
            slot.len = @intCast(len);
            @memcpy(slot.data[0..len], src[0..len]);
            return .{ .slot = slot_idx };
        }

        pub fn release(self: *Self, ref: Ref) void {
            const slot = &self.slots[ref.slot];
            slot.used = false;
            slot.len = 0;
            // Push the released slot back to the front for O(1) reuse.
            slot.next_free = self.free_head;
            self.free_head = ref.slot;
        }

        pub fn slice(self: *const Self, ref: Ref) []const u8 {
            const slot = &self.slots[ref.slot];
            return slot.data[0..slot.len];
        }
    };
}
