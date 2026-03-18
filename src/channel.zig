const std = @import("std");
const testing = std.testing;

pub const ChannelKind = enum {
    Unreliable,
    UnreliableLatest,
    ReliableOrdered,
    ReliableUnordered,
};

/// Bytes consumed from payload body by the channel framing layer.
pub const HEADER_SIZE: usize = 3; // channel_id(1) + seq(2)

/// High bit of channel_id byte signals an ACK-only packet.
pub const ACK_FLAG: u8 = 0x80;

pub fn countChannels(comptime channels: []const ChannelKind, comptime wanted: ChannelKind) usize {
    var count: usize = 0;
    for (channels) |kind| {
        if (kind == wanted) count += 1;
    }
    return count;
}

pub fn makeChannelIndexMap(comptime channels: []const ChannelKind, comptime wanted: ChannelKind) [channels.len]?u8 {
    var map = [_]?u8{null} ** channels.len;
    var idx: u8 = 0;

    for (channels, 0..) |kind, ch_idx| {
        if (kind == wanted) {
            map[ch_idx] = idx;
            idx += 1;
        }
    }

    return map;
}

pub fn encodeHeader(buf: *[HEADER_SIZE]u8, channel_id: u8, seq: u16) void {
    buf[0] = channel_id & ~ACK_FLAG;
    std.mem.writeInt(u16, buf[1..3], seq, .big);
}

pub fn encodeAck(buf: *[HEADER_SIZE]u8, channel_id: u8, acked_seq: u16) void {
    buf[0] = (channel_id & ~ACK_FLAG) | ACK_FLAG;
    std.mem.writeInt(u16, buf[1..3], acked_seq, .big);
}

pub const Header = struct {
    channel_id: u8,
    seq: u16,
    is_ack: bool,

    pub fn decode(buf: []const u8) ?Header {
        if (buf.len < HEADER_SIZE) return null;
        return .{
            .channel_id = buf[0] & ~ACK_FLAG,
            .seq = std.mem.readInt(u16, buf[1..3], .big),
            .is_ack = (buf[0] & ACK_FLAG) != 0,
        };
    }
};

/// Per-channel receive state for UnreliableLatest: drop packets older than last received.
pub const UnreliableLatestState = struct {
    last_seq: u16 = 0,
    initialized: bool = false,

    pub fn accept(self: *UnreliableLatestState, seq: u16) bool {
        if (!self.initialized) {
            self.initialized = true;
            self.last_seq = seq;
            return true;
        }
        if (seqGreater(seq, self.last_seq)) {
            self.last_seq = seq;
            return true;
        }
        return false;
    }
};

/// Per-channel state for Reliable: buffer unACKed outgoing messages and retransmit.
pub fn ReliableState(comptime buf_size: usize, comptime data_cap: usize) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            seq: u16 = 0,
            data: [data_cap]u8 = undefined,
            len: usize = 0,
            sent_at: u64 = 0,
            active: bool = false,
        };

        send_seq: u16 = 0,
        entries: [buf_size]Entry = [_]Entry{.{}} ** buf_size,

        /// Enqueue a message for reliable delivery. Returns the assigned sequence number,
        /// or null if the send buffer is full.
        pub fn push(self: *Self, data: []const u8, now: u64) ?u16 {
            for (&self.entries) |*e| {
                if (!e.active) {
                    self.send_seq +%= 1;
                    const copy_len = @min(data.len, data_cap);
                    e.* = .{
                        .seq = self.send_seq,
                        .len = copy_len,
                        .sent_at = now,
                        .active = true,
                    };
                    @memcpy(e.data[0..copy_len], data[0..copy_len]);
                    return self.send_seq;
                }
            }
            return null;
        }

        /// Mark a sequence number as acknowledged; frees the slot.
        pub fn ack(self: *Self, seq: u16) void {
            for (&self.entries) |*e| {
                if (e.active and e.seq == seq) {
                    e.active = false;
                    return;
                }
            }
        }

        /// Mark an entry as re-sent (update sent_at) so the resend timer resets.
        pub fn markResent(self: *Self, seq: u16, now: u64) void {
            for (&self.entries) |*e| {
                if (e.active and e.seq == seq) {
                    e.sent_at = now;
                    return;
                }
            }
        }
    };
}

pub const ReliableOrderedRecvAction = enum {
    deliver,
    duplicate,
    future,
};

pub const ReliableOrderedRecvState = struct {
    next_seq: u16 = 1,

    pub fn classify(self: *ReliableOrderedRecvState, seq: u16) ReliableOrderedRecvAction {
        if (seq == self.next_seq) {
            self.next_seq +%= 1;
            return .deliver;
        }
        if (seqGreater(seq, self.next_seq)) return .future;
        return .duplicate;
    }
};

pub const ReliableUnorderedRecvAction = enum {
    deliver,
    duplicate,
    stale,
};

pub fn ReliableUnorderedRecvState(comptime window_size: usize) type {
    comptime {
        if (window_size == 0)
            @compileError("ReliableUnorderedRecvState window_size must be greater than zero");
    }

    return struct {
        const Self = @This();

        initialized: bool = false,
        newest_seq: u16 = 0,
        seen: [window_size]?u16 = [_]?u16{null} ** window_size,

        pub fn classify(self: *Self, seq: u16) ReliableUnorderedRecvAction {
            if (!self.initialized) {
                self.initialized = true;
                self.newest_seq = seq;
                self.seen[indexFor(seq)] = seq;
                return .deliver;
            }

            if (!seqGreater(seq, self.newest_seq)) {
                const behind = self.newest_seq -% seq;
                if (behind >= window_size) return .stale;
            }

            const idx = indexFor(seq);
            if (self.seen[idx]) |seen_seq| {
                if (seen_seq == seq) return .duplicate;
            }

            self.seen[idx] = seq;
            if (seqGreater(seq, self.newest_seq)) self.newest_seq = seq;
            return .deliver;
        }

        fn indexFor(seq: u16) usize {
            return @as(usize, seq) % window_size;
        }
    };
}

/// Sequence comparison with 16-bit wrapping (half-space rule).
/// Returns true if `a` is strictly after `b` in sequence space.
pub fn seqGreater(a: u16, b: u16) bool {
    return a != b and (a -% b) < 0x8000;
}

// --- Tests ---

test "seqGreater basic" {
    try testing.expect(seqGreater(1, 0));
    try testing.expect(seqGreater(100, 50));
    try testing.expect(!seqGreater(0, 1));
    try testing.expect(!seqGreater(1, 1));
    try testing.expect(!seqGreater(50, 100));
    std.debug.print("\n  PASS: seqGreater basic\n", .{});
}

test "seqGreater wrapping" {
    // 0 is one ahead of 65535 in wrapping arithmetic
    try testing.expect(seqGreater(0, 65535));
    // 1 is two ahead of 65535
    try testing.expect(seqGreater(1, 65535));
    // 65535 is one ahead of 65534
    try testing.expect(seqGreater(65535, 65534));
    // Exactly half-space away: ambiguous, treated as not greater
    try testing.expect(!seqGreater(32768, 0));
    std.debug.print("\n  PASS: seqGreater wrapping\n", .{});
}

test "UnreliableLatestState" {
    var state: UnreliableLatestState = .{};
    // First packet always accepted
    try testing.expect(state.accept(5));
    // Newer accepted
    try testing.expect(state.accept(6));
    try testing.expect(state.accept(10));
    // Older or equal rejected
    try testing.expect(!state.accept(10));
    try testing.expect(!state.accept(9));
    try testing.expect(!state.accept(1));
    // Newer again accepted
    try testing.expect(state.accept(11));
    std.debug.print("\n  PASS: UnreliableLatestState\n", .{});
}

test "UnreliableLatestState wrapping" {
    var state: UnreliableLatestState = .{};
    _ = state.accept(65534);
    _ = state.accept(65535);
    // 0 wraps past 65535
    try testing.expect(state.accept(0));
    try testing.expect(state.accept(1));
    try testing.expect(!state.accept(65535));
    std.debug.print("\n  PASS: UnreliableLatestState wrapping\n", .{});
}

test "Header encode/decode data" {
    var buf: [HEADER_SIZE]u8 = undefined;
    encodeHeader(&buf, 3, 1000);
    const h = Header.decode(&buf).?;
    try testing.expect(!h.is_ack);
    try testing.expectEqual(@as(u8, 3), h.channel_id);
    try testing.expectEqual(@as(u16, 1000), h.seq);
    std.debug.print("\n  PASS: Header encode/decode data\n", .{});
}

test "Header encode/decode ack" {
    var buf: [HEADER_SIZE]u8 = undefined;
    encodeAck(&buf, 3, 1000);
    const h = Header.decode(&buf).?;
    try testing.expect(h.is_ack);
    try testing.expectEqual(@as(u8, 3), h.channel_id);
    try testing.expectEqual(@as(u16, 1000), h.seq);
    std.debug.print("\n  PASS: Header encode/decode ack\n", .{});
}

test "Header decode too short" {
    const buf = [_]u8{0};
    try testing.expect(Header.decode(&buf) == null);
    std.debug.print("\n  PASS: Header decode too short\n", .{});
}

test "ReliableState push and ack" {
    const S = ReliableState(4, 32);
    var state: S = .{};

    const data = [_]u8{ 1, 2, 3 };
    const seq1 = state.push(&data, 0).?;
    try testing.expectEqual(@as(u16, 1), seq1);

    const seq2 = state.push(&data, 0).?;
    try testing.expectEqual(@as(u16, 2), seq2);

    state.ack(seq1);

    // Slot freed, can push again
    const seq3 = state.push(&data, 0).?;
    try testing.expectEqual(@as(u16, 3), seq3);
    std.debug.print("\n  PASS: ReliableState push and ack\n", .{});
}

test "ReliableState buffer full" {
    const S = ReliableState(2, 8);
    var state: S = .{};
    const data = [_]u8{0};
    _ = state.push(&data, 0).?;
    _ = state.push(&data, 0).?;
    try testing.expect(state.push(&data, 0) == null);
    std.debug.print("\n  PASS: ReliableState buffer full\n", .{});
}

test "ReliableUnorderedRecvState deduplicates within window" {
    const S = ReliableUnorderedRecvState(8);
    var state: S = .{};

    try testing.expectEqual(ReliableUnorderedRecvAction.deliver, state.classify(10));
    try testing.expectEqual(ReliableUnorderedRecvAction.deliver, state.classify(12));
    try testing.expectEqual(ReliableUnorderedRecvAction.deliver, state.classify(11));
    try testing.expectEqual(ReliableUnorderedRecvAction.duplicate, state.classify(12));

    std.debug.print("\n  PASS: ReliableUnorderedRecvState deduplicates within window\n", .{});
}

test "ReliableUnorderedRecvState drops stale packets outside window" {
    const S = ReliableUnorderedRecvState(4);
    var state: S = .{};

    try testing.expectEqual(ReliableUnorderedRecvAction.deliver, state.classify(10));
    try testing.expectEqual(ReliableUnorderedRecvAction.deliver, state.classify(11));
    try testing.expectEqual(ReliableUnorderedRecvAction.deliver, state.classify(12));
    try testing.expectEqual(ReliableUnorderedRecvAction.deliver, state.classify(13));
    try testing.expectEqual(ReliableUnorderedRecvAction.deliver, state.classify(14));
    try testing.expectEqual(ReliableUnorderedRecvAction.stale, state.classify(10));

    std.debug.print("\n  PASS: ReliableUnorderedRecvState drops stale packets outside window\n", .{});
}
