const std = @import("std");
const root = @import("../root.zig");
const validation = @import("../validation/root.zig");
const packet_mod = @import("../packet.zig");
const client_mod = @import("../client/client.zig");
const channel_mod = @import("../channel.zig");
const socket_mod = @import("socket.zig");
const RingQueue = @import("../ring_buffer.zig").RingQueue;
const AddressKey = @import("../addr.zig").AddressKey;
const UdpSocket = @import("udp.zig").UdpSocket;

pub fn TransportClient(comptime opts: root.Options, comptime SocketType: type) type {
    const Socket = if (SocketType == void) UdpSocket else SocketType;

    comptime {
        validation.options.validate(opts);
        if (SocketType != void) validation.socket.validate(Socket);
    }

    const Cli = client_mod.Client(opts);
    const max_packet_size = packet_mod.maxPacketSize(opts);
    const max_user_data = opts.max_payload_size - channel_mod.HEADER_SIZE;
    const PoolRef = Cli.PayloadPool.Ref;

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

    const ConnectTokenType = if (opts.ConnectToken == void)
        @import("../handshake.zig").DefaultConnectToken(opts.user_data_size, opts.max_token_addresses)
    else
        opts.ConnectToken;

    const OrderedChannelState = struct {
        send: RelState = .{},
        recv: OrderedRecvState = .{},
    };

    const UnorderedChannelState = struct {
        send: RelState = .{},
        recv: UnorderedRecvState = .{},
    };

    const UlChannelState = struct {
        send_seq: u16 = 0,
        recv: channel_mod.UnreliableLatestState = .{},
    };

    return struct {
        const Self = @This();

        pub const max_message_size = max_user_data;
        pub const Event = enum { Connected, Disconnected };

        pub const Message = struct {
            channel_id: u8,
            data: [max_user_data]u8,
            len: usize,
        };

        pub const MessageView = struct {
            channel_id: u8,
            payload: PoolRef,
        };

        cli: Cli,
        socket: Socket,
        allocator: std.mem.Allocator,
        // State is split by channel kind so each channel only keeps what it uses.
        ordered_state: [OrderedCount]OrderedChannelState,
        unordered_state: [UnorderedCount]UnorderedChannelState,
        ul_state: [UlCount]UlChannelState,
        rtt_state: channel_mod.RttState,
        events: RingQueue(Event, opts.events_queue_size),
        messages: RingQueue(MessageView, opts.messages_queue_size),

        pub fn init(config: root.ClientConfig, bind_addr: std.net.Address) !Self {
            const socket = try Socket.open(bind_addr);
            errdefer {
                var s = socket;
                s.close();
            }
            return initWithSocket(config, socket);
        }

        pub fn initWithSocket(config: root.ClientConfig, socket: Socket) !Self {
            const cli = try Cli.init(config);
            return .{
                .cli = cli,
                .socket = socket,
                .allocator = std.heap.page_allocator,
                .ordered_state = [_]OrderedChannelState{.{}} ** OrderedCount,
                .unordered_state = [_]UnorderedChannelState{.{}} ** UnorderedCount,
                .ul_state = [_]UlChannelState{.{}} ** UlCount,
                .rtt_state = .{},
                .events = .{},
                .messages = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.clearMessages();
            self.resetChannelState();
            self.socket.close();
        }

        pub fn tick(self: *Self) void {
            const now = std.time.Instant.now() catch return;
            self.cli.update(now);
            const now_ns = self.cli.getCurrentTime();

            self.flushOutgoing();

            var buf: [max_packet_size]u8 = undefined;
            while (self.socket.recvfrom(&buf)) |result| {
                if (!AddressKey.eql(
                    AddressKey.fromAddress(result.addr),
                    AddressKey.fromAddress(self.cli.config.server_addr),
                )) continue;

                self.cli.handlePacket(buf[0..result.len]) catch {};
            }

            while (self.cli.peekEvent()) |ev| {
                switch (ev.*) {
                    .Connected => {
                        self.resetChannelState();
                        _ = self.events.pushBack(.Connected);
                    },
                    .Disconnected => {
                        self.resetChannelState();
                        _ = self.events.pushBack(.Disconnected);
                    },
                }
                self.cli.consumeEvent();
            }

            // Drain SM message queue (payloads from wire -> pool).
            while (self.cli.peekMessage()) |raw| {
                const ref = raw.payload;
                self.cli.consumeMessage();
                self.handleIncoming(ref);
            }

            self.flushOutgoing();
            self.retransmitReliable(now_ns);
            self.flushOutgoing();
        }

        fn flushOutgoing(self: *Self) void {
            var buf: [max_packet_size]u8 = undefined;
            while (self.cli.peekOutgoing()) |out| {
                const len = packet_mod.serialize(opts, out.packet, buf[0..]) catch {
                    self.cli.consumeOutgoing();
                    continue;
                };
                self.socket.sendto(out.addr, buf[0..len]);
                self.cli.consumeOutgoing();
            }
        }

        fn handleIncoming(self: *Self, ref: PoolRef) void {
            const body = self.cli.payloadData(ref);
            const hdr = channel_mod.Header.decode(body) orelse {
                self.cli.releasePayload(ref);
                return;
            };
            if (hdr.channel_id >= channel_count) {
                self.cli.releasePayload(ref);
                return;
            }
            const ch_idx = hdr.channel_id;
            const kind = Layout.kind(ch_idx);

            if (hdr.is_ack) {
                self.handleAck(ch_idx, kind, hdr.seq);
                self.cli.releasePayload(ref);
                return;
            }

            switch (kind) {
                .Unreliable => {},
                .UnreliableLatest => if (!self.acceptLatest(ch_idx, hdr.seq)) {
                    self.cli.releasePayload(ref);
                    return;
                },
                .ReliableOrdered => {
                    self.handleReliableOrdered(ch_idx, hdr.seq, ref);
                    return;
                },
                .ReliableUnordered => if (!self.acceptReliableUnordered(ch_idx, hdr.seq)) {
                    self.cli.releasePayload(ref);
                    return;
                },
            }

            self.enqueueMessage(@intCast(ch_idx), ref);
        }

        fn retransmitReliable(self: *Self, now_ns: u64) void {
            const rto = self.rtt_state.rto(opts.reliable_resend_ns);
            for (0..channel_count) |ch_idx| {
                switch (Layout.kind(@intCast(ch_idx))) {
                    .ReliableOrdered => {
                        const send = self.orderedSendState(@intCast(ch_idx)) orelse continue;
                        self.retransmitState(send, @intCast(ch_idx), now_ns, rto);
                    },
                    .ReliableUnordered => {
                        const send = self.unorderedSendState(@intCast(ch_idx)) orelse continue;
                        self.retransmitState(send, @intCast(ch_idx), now_ns, rto);
                    },
                    else => {},
                }
            }
        }

        fn retransmitState(self: *Self, rel: *RelState, channel_id: u8, now_ns: u64, rto: u64) void {
            for (&rel.entries) |*e| {
                if (!e.active) continue;
                if (now_ns -| e.sent_at < rto) continue;

                var body: [opts.max_payload_size]u8 = undefined;
                const body_len = channel_mod.HEADER_SIZE + e.len;
                channel_mod.encodeHeader(body[0..channel_mod.HEADER_SIZE], channel_id, e.seq);
                @memcpy(body[channel_mod.HEADER_SIZE..body_len], e.data[0..e.len]);
                self.cli.sendPayload(body[0..body_len]) catch continue;
                e.sent_at = now_ns;
            }
        }

        pub fn sendOnChannel(self: *Self, channel_id: u8, data: []const u8) !void {
            if (channel_id >= channel_count) return error.InvalidChannel;
            const now_ns = self.cli.getCurrentTime();
            const data_len = @min(data.len, max_user_data);
            const body_len = channel_mod.HEADER_SIZE + data_len;

            // For reliable channels, push to retransmit buffer first (may fail with BufferFull).
            var seq: u16 = 0;
            switch (Layout.kind(channel_id)) {
                .Unreliable => {},
                .UnreliableLatest => {
                    const idx = Layout.latestIndex(channel_id) orelse return error.InvalidChannel;
                    const st = &self.ul_state[idx];
                    st.send_seq +%= 1;
                    seq = st.send_seq;
                },
                .ReliableOrdered => {
                    const send = self.orderedSendState(channel_id) orelse return error.InvalidChannel;
                    seq = send.push(data[0..data_len], now_ns) orelse
                        return error.ReliableBufferFull;
                },
                .ReliableUnordered => {
                    const send = self.unorderedSendState(channel_id) orelse return error.InvalidChannel;
                    seq = send.push(data[0..data_len], now_ns) orelse
                        return error.ReliableBufferFull;
                },
            }

            // Write header + user data directly into the outgoing slot (no intermediate buffer).
            const out = try self.cli.reservePayloadSlot();
            const body = &out.packet.Payload.body;
            channel_mod.encodeHeader(body[0..channel_mod.HEADER_SIZE], channel_id, seq);
            @memcpy(body[channel_mod.HEADER_SIZE..body_len], data[0..data_len]);
            out.packet.Payload.len = @intCast(body_len);
        }

        pub fn connect(self: *Self) !void {
            try self.cli.connect();
        }

        pub fn connectSecure(self: *Self, token: ConnectTokenType) !void {
            try self.cli.connectSecure(token);
        }

        pub fn disconnect(self: *Self) void {
            self.cli.disconnect();
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
            return self.cli.payloadData(msg.payload)[channel_mod.HEADER_SIZE..];
        }

        pub fn consumeMessage(self: *Self) void {
            const msg = self.messages.peekFront() orelse return;
            self.cli.releasePayload(msg.payload);
            self.messages.advance();
        }

        pub fn getStateMachine(self: *Self) *Cli {
            return &self.cli;
        }

        fn sendAck(self: *Self, channel_id: u8, seq: u16) void {
            var ack_body: [channel_mod.HEADER_SIZE]u8 = undefined;
            channel_mod.encodeAck(&ack_body, channel_id, seq);
            self.cli.sendPayload(&ack_body) catch {};
            self.flushOutgoing();
        }

        fn handleAck(self: *Self, channel_id: u8, kind: channel_mod.ChannelKind, seq: u16) void {
            const now_ns = self.cli.getCurrentTime();
            const sent_at: ?u64 = switch (kind) {
                .ReliableOrdered => blk: {
                    const send = self.orderedSendState(channel_id) orelse break :blk null;
                    break :blk send.ack(seq);
                },
                .ReliableUnordered => blk: {
                    const send = self.unorderedSendState(channel_id) orelse break :blk null;
                    break :blk send.ack(seq);
                },
                else => null,
            };
            if (sent_at) |t| {
                self.rtt_state.update(now_ns -| t);
            }
        }

        fn acceptLatest(self: *Self, channel_id: u8, seq: u16) bool {
            const recv = self.ulRecvState(channel_id) orelse return false;
            return recv.accept(seq);
        }

        fn handleReliableOrdered(self: *Self, channel_id: u8, seq: u16, ref: PoolRef) void {
            const body = self.cli.payloadData(ref);
            const recv = self.orderedRecvState(channel_id) orelse {
                self.cli.releasePayload(ref);
                return;
            };
            const action = recv.receive(self.allocator, seq, body) catch {
                self.cli.releasePayload(ref);
                return;
            };
            switch (action) {
                .drop => {
                    self.cli.releasePayload(ref);
                    return;
                },
                .ack_only => {
                    self.sendAck(channel_id, seq);
                    self.cli.releasePayload(ref);
                    return;
                },
                .deliver => {
                    self.sendAck(channel_id, seq);
                    self.enqueueMessage(channel_id, ref);

                    // Buffered followers: allocate new pool refs from SM pool.
                    while (recv.peekReady()) |ready_body| {
                        const future_ref = self.cli.payload_pool.allocCopy(ready_body) orelse break;
                        self.enqueueMessage(channel_id, future_ref);
                        recv.consumeReady();
                    }
                },
            }
        }

        fn acceptReliableUnordered(self: *Self, channel_id: u8, seq: u16) bool {
            const recv = self.unorderedRecvStatePtr(channel_id) orelse return false;
            const action = recv.classify(seq);
            if (action != .stale) self.sendAck(channel_id, seq);
            return action == .deliver;
        }

        fn enqueueMessage(self: *Self, channel_id: u8, ref: PoolRef) void {
            if (!self.messages.pushBack(.{
                .channel_id = channel_id,
                .payload = ref,
            })) {
                self.cli.releasePayload(ref);
            }
        }

        fn orderedSendState(self: *Self, channel_id: u8) ?*RelState {
            const idx = Layout.orderedIndex(channel_id) orelse return null;
            if (OrderedCount == 0) return null;
            return &self.ordered_state[idx].send;
        }

        fn unorderedSendState(self: *Self, channel_id: u8) ?*RelState {
            const idx = Layout.unorderedIndex(channel_id) orelse return null;
            if (UnorderedCount == 0) return null;
            return &self.unordered_state[idx].send;
        }

        fn orderedRecvState(self: *Self, channel_id: u8) ?*OrderedRecvState {
            const idx = Layout.orderedIndex(channel_id) orelse return null;
            if (OrderedCount == 0) return null;
            return &self.ordered_state[idx].recv;
        }

        fn unorderedRecvStatePtr(self: *Self, channel_id: u8) ?*UnorderedRecvState {
            const idx = Layout.unorderedIndex(channel_id) orelse return null;
            if (UnorderedCount == 0) return null;
            return &self.unordered_state[idx].recv;
        }

        fn ulRecvState(self: *Self, channel_id: u8) ?*channel_mod.UnreliableLatestState {
            const idx = Layout.latestIndex(channel_id) orelse return null;
            if (UlCount == 0) return null;
            return &self.ul_state[idx].recv;
        }

        fn resetChannelState(self: *Self) void {
            for (0..OrderedCount) |idx| {
                self.ordered_state[idx].recv.deinit(self.allocator);
            }
            self.ordered_state = [_]OrderedChannelState{.{}} ** OrderedCount;
            self.unordered_state = [_]UnorderedChannelState{.{}} ** UnorderedCount;
            self.ul_state = [_]UlChannelState{.{}} ** UlCount;
            self.rtt_state = .{};
        }

        fn clearMessages(self: *Self) void {
            while (self.messages.peekFront()) |msg| {
                self.cli.releasePayload(msg.payload);
                self.messages.advance();
            }
        }
    };
}
