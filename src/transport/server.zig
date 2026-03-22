const std = @import("std");
const root = @import("../root.zig");
const validation = @import("../validation/root.zig");
const packet_mod = @import("../packet.zig");
const server_mod = @import("../server/server.zig");
const channel_mod = @import("../channel.zig");
const socket_mod = @import("socket.zig");
const RingQueue = @import("../ring_buffer.zig").RingQueue;
const UdpSocket = @import("udp.zig").UdpSocket;

pub fn TransportServer(comptime opts: root.Options, comptime SocketType: type) type {
    const Socket = if (SocketType == void) UdpSocket else SocketType;

    comptime {
        validation.options.validate(opts);
        if (SocketType != void) validation.socket.validate(Socket);
    }

    const Srv = server_mod.Server(opts);
    const max_packet_size = packet_mod.maxPacketSize(opts);
    const max_user_data = opts.max_payload_size - channel_mod.HEADER_SIZE;
    const PoolRef = Srv.PayloadPool.Ref;

    const Layout = channel_mod.ChannelLayout(opts.channels);
    const channel_count = Layout.channel_count;

    const RelState = channel_mod.ReliableState(opts.reliable_buffer, max_user_data);
    const OrderedRecvState = channel_mod.ReliableOrderedRecvState(
        opts.reliable_ordered_recv_window,
        opts.max_payload_size,
    );
    const UnorderedRecvState = channel_mod.ReliableUnorderedRecvState(opts.reliable_buffer);

    const OrderedCount = Layout.ordered_count;
    const UnorderedCount = Layout.unordered_count;
    const UlCount = Layout.latest_count;

    const OrderedChannelState = struct {
        send: ?*RelState = null,
        recv: OrderedRecvState = .{},
    };

    const UnorderedChannelState = struct {
        send: ?*RelState = null,
        recv: UnorderedRecvState = .{},
    };

    const UlChannelState = struct {
        send_seq: u16 = 0,
        recv: channel_mod.UnreliableLatestState = .{},
    };

    return struct {
        const Self = @This();

        pub const max_message_size = max_user_data;

        pub const Event = union(enum) {
            ClientConnected: struct {
                cid: u64,
                addr: std.net.Address,
                user_data: ?[opts.user_data_size]u8,
            },
            ClientDisconnected: struct {
                cid: u64,
                addr: std.net.Address,
            },
        };

        pub const Message = struct {
            cid: u64,
            channel_id: u8,
            data: [max_user_data]u8,
            len: usize,
        };

        pub const MessageView = struct {
            cid: u64,
            channel_id: u8,
            payload: PoolRef,
        };

        srv: Srv,
        socket: Socket,
        // The channel schema is global, but runtime state is per client.
        // Store each kind separately so channels do not carry unused fields.
        ordered_state: *[opts.max_clients][OrderedCount]OrderedChannelState,
        unordered_state: *[opts.max_clients][UnorderedCount]UnorderedChannelState,
        ul_state: *[opts.max_clients][UlCount]UlChannelState,
        rtt_state: *[opts.max_clients]channel_mod.RttState,
        allocator: std.mem.Allocator,
        events: RingQueue(Event, opts.events_queue_size),
        messages: RingQueue(MessageView, opts.messages_queue_size),

        pub fn init(allocator: std.mem.Allocator, config: root.ServerConfig, bind_addr: std.net.Address) !Self {
            const socket = try Socket.open(bind_addr);
            errdefer {
                var s = socket;
                s.close();
            }
            return initWithSocket(allocator, config, socket);
        }

        pub fn initWithSocket(allocator: std.mem.Allocator, config: root.ServerConfig, socket: Socket) !Self {
            const ordered_state = try allocator.create([opts.max_clients][OrderedCount]OrderedChannelState);
            errdefer allocator.destroy(ordered_state);
            for (ordered_state) |*row| row.* = [_]OrderedChannelState{.{}} ** OrderedCount;

            const unordered_state = try allocator.create([opts.max_clients][UnorderedCount]UnorderedChannelState);
            errdefer allocator.destroy(unordered_state);
            for (unordered_state) |*row| row.* = [_]UnorderedChannelState{.{}} ** UnorderedCount;

            const ul_state = try allocator.create([opts.max_clients][UlCount]UlChannelState);
            errdefer allocator.destroy(ul_state);
            for (ul_state) |*row| row.* = [_]UlChannelState{.{}} ** UlCount;

            const rtt_state = try allocator.create([opts.max_clients]channel_mod.RttState);
            errdefer allocator.destroy(rtt_state);
            rtt_state.* = [_]channel_mod.RttState{.{}} ** opts.max_clients;

            const srv = try Srv.init(allocator, config);
            return .{
                .srv = srv,
                .socket = socket,
                .ordered_state = ordered_state,
                .unordered_state = unordered_state,
                .ul_state = ul_state,
                .rtt_state = rtt_state,
                .allocator = allocator,
                .events = .{},
                .messages = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.clearMessages();
            for (0..opts.max_clients) |slot| self.resetClientChannelState(slot);
            self.srv.deinit();
            self.socket.close();
            self.allocator.destroy(self.ordered_state);
            self.allocator.destroy(self.unordered_state);
            self.allocator.destroy(self.ul_state);
            self.allocator.destroy(self.rtt_state);
        }

        pub fn tick(self: *Self) void {
            const now = std.time.Instant.now() catch return;
            self.srv.update(now);
            const now_ns = self.srv.getCurrentTime();

            var buf: [max_packet_size]u8 = undefined;
            while (self.socket.recvfrom(&buf)) |result| {
                self.srv.handlePacket(result.addr, buf[0..result.len]) catch {};
            }

            while (self.srv.peekEvent()) |ev| {
                switch (ev.*) {
                    .ClientConnected => |e| {
                        self.resetClientChannelState(@intCast(e.cid));
                        _ = self.events.pushBack(.{ .ClientConnected = .{
                            .cid = e.cid,
                            .addr = e.addr,
                            .user_data = e.user_data,
                        } });
                    },
                    .ClientDisconnected => |e| {
                        self.resetClientChannelState(@intCast(e.cid));
                        _ = self.events.pushBack(.{ .ClientDisconnected = .{
                            .cid = e.cid,
                            .addr = e.addr,
                        } });
                    },
                }
                self.srv.consumeEvent();
            }

            // Drain SM message queue (payloads from wire -> pool).
            while (self.srv.peekMessage()) |raw| {
                const ref = raw.payload;
                const cid = raw.cid;
                self.srv.consumeMessage();
                self.handleIncoming(cid, ref);
            }

            self.retransmitReliable(now_ns);
            self.flushOutgoing();
        }

        fn flushOutgoing(self: *Self) void {
            var buf: [max_packet_size]u8 = undefined;
            while (self.srv.peekOutgoing()) |out| {
                const len = packet_mod.serialize(opts, out.packet, buf[0..]) catch {
                    self.srv.consumeOutgoing();
                    continue;
                };
                self.socket.sendto(out.addr, buf[0..len]);
                self.srv.consumeOutgoing();
            }
        }

        fn handleIncoming(self: *Self, cid: u64, ref: PoolRef) void {
            const body = self.srv.payloadData(ref);
            const slot: usize = @intCast(cid);
            const hdr = channel_mod.Header.decode(body) orelse {
                self.srv.releasePayload(ref);
                return;
            };
            if (hdr.channel_id >= channel_count) {
                self.srv.releasePayload(ref);
                return;
            }
            const ch_idx = hdr.channel_id;
            const kind = Layout.kind(ch_idx);

            if (hdr.is_ack) {
                self.handleAck(slot, ch_idx, kind, hdr.seq);
                self.srv.releasePayload(ref);
                return;
            }

            switch (kind) {
                .Unreliable => {},
                .UnreliableLatest => if (!self.acceptLatest(slot, ch_idx, hdr.seq)) {
                    self.srv.releasePayload(ref);
                    return;
                },
                .ReliableOrdered => {
                    self.handleReliableOrdered(cid, slot, ch_idx, hdr.seq, ref);
                    return;
                },
                .ReliableUnordered => if (!self.acceptReliableUnordered(slot, cid, ch_idx, hdr.seq)) {
                    self.srv.releasePayload(ref);
                    return;
                },
            }

            self.enqueueMessage(cid, @intCast(ch_idx), ref);
        }

        fn retransmitReliable(self: *Self, now_ns: u64) void {
            // Iterate only connected clients via addr_to_slot.
            for (self.srv.addr_to_slot.values()) |slot| {
                const rto = self.rtt_state[slot].rto(opts.reliable_resend_ns);
                for (0..channel_count) |ch_idx| {
                    switch (Layout.kind(@intCast(ch_idx))) {
                        .ReliableOrdered => {
                            const send_ptr = self.orderedSendPtr(slot, @intCast(ch_idx)) orelse continue;
                            const rel = send_ptr.* orelse continue;
                            self.retransmitState(rel, @intCast(slot), @intCast(ch_idx), now_ns, rto);
                        },
                        .ReliableUnordered => {
                            const send_ptr = self.unorderedSendPtr(slot, @intCast(ch_idx)) orelse continue;
                            const rel = send_ptr.* orelse continue;
                            self.retransmitState(rel, @intCast(slot), @intCast(ch_idx), now_ns, rto);
                        },
                        else => {},
                    }
                }
            }
        }

        fn retransmitState(self: *Self, rel: *RelState, cid: u64, channel_id: u8, now_ns: u64, rto: u64) void {
            for (&rel.entries) |*e| {
                if (!e.active) continue;
                if (now_ns -| e.sent_at < rto) continue;

                var body: [opts.max_payload_size]u8 = undefined;
                const body_len = channel_mod.HEADER_SIZE + e.len;
                channel_mod.encodeHeader(body[0..channel_mod.HEADER_SIZE], channel_id, e.seq);
                @memcpy(body[channel_mod.HEADER_SIZE..body_len], e.data[0..e.len]);
                self.srv.sendPayload(cid, body[0..body_len]) catch continue;
                e.sent_at = now_ns;
            }
        }

        pub fn sendOnChannel(self: *Self, cid: u64, channel_id: u8, data: []const u8) !void {
            if (channel_id >= channel_count) return error.InvalidChannel;
            const slot: usize = @intCast(cid);
            const now_ns = self.srv.getCurrentTime();
            const data_len = @min(data.len, max_user_data);
            const body_len = channel_mod.HEADER_SIZE + data_len;

            // For reliable channels, push to retransmit buffer first (may fail with BufferFull).
            var seq: u16 = 0;
            switch (Layout.kind(channel_id)) {
                .Unreliable => {},
                .UnreliableLatest => {
                    const idx = Layout.latestIndex(channel_id) orelse return error.InvalidChannel;
                    const st = &self.ul_state[slot][idx];
                    st.send_seq +%= 1;
                    seq = st.send_seq;
                },
                .ReliableOrdered => {
                    const send_ptr = self.orderedSendPtr(slot, channel_id) orelse return error.InvalidChannel;
                    const rel = try self.getOrCreateReliableState(send_ptr);
                    seq = rel.push(data[0..data_len], now_ns) orelse return error.ReliableBufferFull;
                },
                .ReliableUnordered => {
                    const send_ptr = self.unorderedSendPtr(slot, channel_id) orelse return error.InvalidChannel;
                    const rel = try self.getOrCreateReliableState(send_ptr);
                    seq = rel.push(data[0..data_len], now_ns) orelse return error.ReliableBufferFull;
                },
            }

            // Write header + user data directly into the outgoing slot (no intermediate buffer).
            const out = try self.srv.reservePayloadSlot(cid);
            const body = &out.packet.Payload.body;
            channel_mod.encodeHeader(body[0..channel_mod.HEADER_SIZE], channel_id, seq);
            @memcpy(body[channel_mod.HEADER_SIZE..body_len], data[0..data_len]);
            out.packet.Payload.len = @intCast(body_len);
        }

        pub fn pollEvent(self: *Self) ?Event {
            // Copy-out convenience API.
            return self.events.popFront();
        }

        pub fn pollMessage(self: *Self) ?Message {
            // Copy-out convenience API built on top of the zero-copy message view.
            const msg = self.peekMessage() orelse return null;
            const data = self.messageData(msg);
            var owned: Message = .{
                .cid = msg.cid,
                .channel_id = msg.channel_id,
                .data = undefined,
                .len = data.len,
            };
            @memcpy(owned.data[0..owned.len], data);
            self.consumeMessage();
            return owned;
        }

        pub fn peekMessage(self: *const Self) ?*const MessageView {
            // Zero-copy view into the front message. Read bytes with messageData(msg).
            return self.messages.peekFront();
        }

        pub fn messageData(self: *const Self, msg: *const MessageView) []const u8 {
            return self.srv.payloadData(msg.payload)[channel_mod.HEADER_SIZE..];
        }

        pub fn consumeMessage(self: *Self) void {
            const msg = self.messages.peekFront() orelse return;
            self.srv.releasePayload(msg.payload);
            self.messages.advance();
        }

        pub fn getStateMachine(self: *Self) *Srv {
            return &self.srv;
        }

        fn sendAck(self: *Self, cid: u64, channel_id: u8, seq: u16) void {
            var ack_body: [channel_mod.HEADER_SIZE]u8 = undefined;
            channel_mod.encodeAck(&ack_body, channel_id, seq);
            self.srv.sendPayload(cid, &ack_body) catch {};
        }

        fn handleAck(self: *Self, slot: usize, channel_id: u8, kind: channel_mod.ChannelKind, seq: u16) void {
            const now_ns = self.srv.getCurrentTime();
            const sent_at: ?u64 = switch (kind) {
                .ReliableOrdered => blk: {
                    const send_ptr = self.orderedSendPtr(slot, channel_id) orelse break :blk null;
                    break :blk if (send_ptr.*) |rel| rel.ack(seq) else null;
                },
                .ReliableUnordered => blk: {
                    const send_ptr = self.unorderedSendPtr(slot, channel_id) orelse break :blk null;
                    break :blk if (send_ptr.*) |rel| rel.ack(seq) else null;
                },
                else => null,
            };

            if (sent_at) |t| {
                self.rtt_state[slot].update(now_ns -| t);
            }
        }

        fn acceptLatest(self: *Self, slot: usize, channel_id: u8, seq: u16) bool {
            const recv = self.ulRecvState(slot, channel_id) orelse return false;
            return recv.accept(seq);
        }

        fn handleReliableOrdered(
            self: *Self,
            cid: u64,
            slot: usize,
            channel_id: u8,
            seq: u16,
            ref: PoolRef,
        ) void {
            const body = self.srv.payloadData(ref);
            const recv = self.orderedRecvState(slot, channel_id) orelse {
                self.srv.releasePayload(ref);
                return;
            };
            const action = recv.receive(self.allocator, seq, body) catch {
                self.srv.releasePayload(ref);
                return;
            };
            switch (action) {
                .drop => {
                    self.srv.releasePayload(ref);
                    return;
                },
                .ack_only => {
                    self.sendAck(cid, channel_id, seq);
                    self.srv.releasePayload(ref);
                    return;
                },
                .deliver => {
                    self.sendAck(cid, channel_id, seq);
                    self.enqueueMessage(cid, channel_id, ref);

                    // Buffered followers: allocate new pool refs from SM pool.
                    while (recv.peekReady()) |ready_body| {
                        const future_ref = self.srv.payload_pool.allocCopy(ready_body) orelse break;
                        self.enqueueMessage(cid, channel_id, future_ref);
                        recv.consumeReady();
                    }
                },
            }
        }

        fn acceptReliableUnordered(self: *Self, slot: usize, cid: u64, channel_id: u8, seq: u16) bool {
            const recv = self.unorderedRecvStatePtr(slot, channel_id) orelse return false;
            const action = recv.classify(seq);
            if (action != .stale) self.sendAck(cid, channel_id, seq);
            return action == .deliver;
        }

        fn enqueueMessage(self: *Self, cid: u64, channel_id: u8, ref: PoolRef) void {
            if (!self.messages.pushBack(.{
                .cid = cid,
                .channel_id = channel_id,
                .payload = ref,
            })) {
                self.srv.releasePayload(ref);
            }
        }

        fn orderedSendPtr(self: *Self, slot: usize, channel_id: u8) ?*?*RelState {
            const idx = Layout.orderedIndex(channel_id) orelse return null;
            if (OrderedCount == 0) return null;
            return &self.ordered_state[slot][idx].send;
        }

        fn unorderedSendPtr(self: *Self, slot: usize, channel_id: u8) ?*?*RelState {
            const idx = Layout.unorderedIndex(channel_id) orelse return null;
            if (UnorderedCount == 0) return null;
            return &self.unordered_state[slot][idx].send;
        }

        fn orderedRecvState(self: *Self, slot: usize, channel_id: u8) ?*OrderedRecvState {
            const idx = Layout.orderedIndex(channel_id) orelse return null;
            if (OrderedCount == 0) return null;
            return &self.ordered_state[slot][idx].recv;
        }

        fn unorderedRecvStatePtr(self: *Self, slot: usize, channel_id: u8) ?*UnorderedRecvState {
            const idx = Layout.unorderedIndex(channel_id) orelse return null;
            if (UnorderedCount == 0) return null;
            return &self.unordered_state[slot][idx].recv;
        }

        fn ulRecvState(self: *Self, slot: usize, channel_id: u8) ?*channel_mod.UnreliableLatestState {
            const idx = Layout.latestIndex(channel_id) orelse return null;
            if (UlCount == 0) return null;
            return &self.ul_state[slot][idx].recv;
        }

        fn getOrCreateReliableState(self: *Self, send_ptr: *?*RelState) !*RelState {
            if (send_ptr.*) |rel| return rel;

            // Unused reliable channels stay cheap until first use.
            const rel = try self.allocator.create(RelState);
            rel.* = .{};
            send_ptr.* = rel;
            return rel;
        }

        fn resetClientChannelState(self: *Self, slot: usize) void {
            for (0..OrderedCount) |idx| {
                if (self.ordered_state[slot][idx].send) |rel| self.allocator.destroy(rel);
                self.ordered_state[slot][idx].recv.deinit(self.allocator);
            }
            for (0..UnorderedCount) |idx| {
                if (self.unordered_state[slot][idx].send) |rel| self.allocator.destroy(rel);
            }

            self.ordered_state[slot] = [_]OrderedChannelState{.{}} ** OrderedCount;
            self.unordered_state[slot] = [_]UnorderedChannelState{.{}} ** UnorderedCount;
            self.ul_state[slot] = [_]UlChannelState{.{}} ** UlCount;
            self.rtt_state[slot] = .{};
        }

        fn clearMessages(self: *Self) void {
            while (self.messages.peekFront()) |msg| {
                self.srv.releasePayload(msg.payload);
                self.messages.advance();
            }
        }
    };
}
