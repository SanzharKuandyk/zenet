const std = @import("std");
const root = @import("../root.zig");
const packet_mod = @import("../packet.zig");
const client_mod = @import("../client/client.zig");
const channel_mod = @import("../channel.zig");
const socket_mod = @import("socket.zig");
const RingQueue = @import("../ring_buffer.zig").RingQueue;
const UdpSocket = @import("udp.zig").UdpSocket;
const AddressKey = @import("../addr.zig").AddressKey;

pub fn TransportClient(comptime opts: root.Options, comptime SocketType: type) type {
    const Socket = if (SocketType == void) UdpSocket else SocketType;

    comptime {
        if (SocketType != void) socket_mod.validateSocketInterface(Socket);
        if (opts.channels.len == 0)
            @compileError("Options.channels must have at least one entry");
    }

    const Cli = client_mod.Client(opts);
    const max_packet_size = packet_mod.maxPacketSize(opts);
    const channel_count = opts.channels.len;
    const max_user_data = opts.max_payload_size - channel_mod.HEADER_SIZE;
    const RelState = channel_mod.ReliableState(opts.reliable_buffer, max_user_data);
    const OrderedCount = channel_mod.countChannels(opts.channels, .ReliableOrdered);
    const UnorderedCount = channel_mod.countChannels(opts.channels, .ReliableUnordered);
    const UlCount = channel_mod.countChannels(opts.channels, .UnreliableLatest);
    const OrderedMap = comptime channel_mod.makeChannelIndexMap(opts.channels, .ReliableOrdered);
    const UnorderedMap = comptime channel_mod.makeChannelIndexMap(opts.channels, .ReliableUnordered);
    const UlMap = comptime channel_mod.makeChannelIndexMap(opts.channels, .UnreliableLatest);
    const UnorderedRecvState = channel_mod.ReliableUnorderedRecvState(opts.reliable_buffer);

    const ConnectTokenType = if (opts.ConnectToken == void)
        @import("../handshake.zig").DefaultConnectToken(opts.user_data_size, opts.max_token_addresses)
    else
        opts.ConnectToken;

    const OrderedChannelState = struct {
        send: RelState = .{},
        recv: channel_mod.ReliableOrderedRecvState = .{},
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

        cli: Cli,
        socket: Socket,
        ordered_state: [OrderedCount]OrderedChannelState,
        unordered_state: [UnorderedCount]UnorderedChannelState,
        ul_state: [UlCount]UlChannelState,
        events: RingQueue(Event, opts.events_queue_size),
        messages: RingQueue(Message, opts.messages_queue_size),

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
                .ordered_state = [_]OrderedChannelState{.{}} ** OrderedCount,
                .unordered_state = [_]UnorderedChannelState{.{}} ** UnorderedCount,
                .ul_state = [_]UlChannelState{.{}} ** UlCount,
                .events = .{},
                .messages = .{},
            };
        }

        pub fn deinit(self: *Self) void {
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

            while (self.cli.pollEvent()) |ev| {
                switch (ev) {
                    .Connected => {
                        self.resetChannelState();
                        _ = self.events.pushBack(.Connected);
                    },
                    .Disconnected => {
                        self.resetChannelState();
                        _ = self.events.pushBack(.Disconnected);
                    },
                    .PayloadReceived => |payload| self.handleIncoming(payload.body[0..payload.len]),
                }
            }

            self.flushOutgoing();
            self.retransmitReliable(now_ns);
            self.flushOutgoing();
        }

        fn flushOutgoing(self: *Self) void {
            var buf: [max_packet_size]u8 = undefined;
            while (self.cli.pollOutgoing()) |out| {
                const len = packet_mod.serialize(opts, out.packet, buf[0..]) catch continue;
                self.socket.sendto(out.addr, buf[0..len]);
            }
        }

        fn handleIncoming(self: *Self, body: []const u8) void {
            const hdr = channel_mod.Header.decode(body) orelse return;
            if (hdr.channel_id >= channel_count) return;
            const ch_idx = hdr.channel_id;
            const kind = opts.channels[ch_idx];

            if (hdr.is_ack) {
                switch (kind) {
                    .ReliableOrdered => {
                        if (OrderedCount == 0) return;
                        const idx = OrderedMap[ch_idx] orelse return;
                        self.ordered_state[idx].send.ack(hdr.seq);
                    },
                    .ReliableUnordered => {
                        if (UnorderedCount == 0) return;
                        const idx = UnorderedMap[ch_idx] orelse return;
                        self.unordered_state[idx].send.ack(hdr.seq);
                    },
                    else => {},
                }
                return;
            }

            switch (kind) {
                .Unreliable => {},
                .UnreliableLatest => {
                    if (UlCount == 0) return;
                    const idx = UlMap[ch_idx] orelse return;
                    if (!self.ul_state[idx].recv.accept(hdr.seq)) return;
                },
                .ReliableOrdered => {
                    if (OrderedCount == 0) return;
                    const idx = OrderedMap[ch_idx] orelse return;
                    const action = self.ordered_state[idx].recv.classify(hdr.seq);
                    if (action == .future) return;

                    self.sendAck(@intCast(ch_idx), hdr.seq);
                    if (action == .duplicate) return;
                },
                .ReliableUnordered => {
                    if (UnorderedCount == 0) return;
                    const idx = UnorderedMap[ch_idx] orelse return;
                    const action = self.unordered_state[idx].recv.classify(hdr.seq);
                    if (action != .stale) self.sendAck(@intCast(ch_idx), hdr.seq);
                    if (action != .deliver) return;
                },
            }

            const data_len = body.len -| channel_mod.HEADER_SIZE;
            var msg: Message = .{
                .channel_id = @intCast(ch_idx),
                .data = [_]u8{0} ** max_user_data,
                .len = @min(data_len, max_user_data),
            };
            @memcpy(msg.data[0..msg.len], body[channel_mod.HEADER_SIZE .. channel_mod.HEADER_SIZE + msg.len]);
            _ = self.messages.pushBack(msg);
        }

        fn retransmitReliable(self: *Self, now_ns: u64) void {
            for (0..channel_count) |ch_idx| {
                switch (opts.channels[ch_idx]) {
                    .ReliableOrdered => {
                        if (OrderedCount == 0) continue;
                        const idx = OrderedMap[ch_idx] orelse continue;
                        self.retransmitState(&self.ordered_state[idx].send, @intCast(ch_idx), now_ns);
                    },
                    .ReliableUnordered => {
                        if (UnorderedCount == 0) continue;
                        const idx = UnorderedMap[ch_idx] orelse continue;
                        self.retransmitState(&self.unordered_state[idx].send, @intCast(ch_idx), now_ns);
                    },
                    else => {},
                }
            }
        }

        fn retransmitState(self: *Self, rel: *RelState, channel_id: u8, now_ns: u64) void {
            for (&rel.entries) |*e| {
                if (!e.active) continue;
                if (now_ns -| e.sent_at < opts.reliable_resend_ns) continue;

                var body: [opts.max_payload_size]u8 = [_]u8{0} ** opts.max_payload_size;
                const body_len = channel_mod.HEADER_SIZE + e.len;
                channel_mod.encodeHeader(body[0..channel_mod.HEADER_SIZE], channel_id, e.seq);
                @memcpy(body[channel_mod.HEADER_SIZE..body_len], e.data[0..e.len]);
                self.cli.sendPayload(body[0..body_len]) catch continue;
                e.sent_at = now_ns;
            }
        }

        pub fn sendOnChannel(self: *Self, channel_id: u8, data: []const u8) !void {
            if (channel_id >= channel_count) return error.InvalidChannel;
            const kind = opts.channels[channel_id];
            const now_ns = self.cli.getCurrentTime();

            var body: [opts.max_payload_size]u8 = [_]u8{0} ** opts.max_payload_size;
            const data_len = @min(data.len, max_user_data);
            const body_len = channel_mod.HEADER_SIZE + data_len;

            switch (kind) {
                .Unreliable => {
                    channel_mod.encodeHeader(body[0..channel_mod.HEADER_SIZE], channel_id, 0);
                },
                .UnreliableLatest => {
                    if (UlCount == 0) return error.InvalidChannel;
                    const idx = UlMap[channel_id] orelse return error.InvalidChannel;
                    self.ul_state[idx].send_seq +%= 1;
                    channel_mod.encodeHeader(
                        body[0..channel_mod.HEADER_SIZE],
                        channel_id,
                        self.ul_state[idx].send_seq,
                    );
                },
                .ReliableOrdered => {
                    if (OrderedCount == 0) return error.InvalidChannel;
                    const idx = OrderedMap[channel_id] orelse return error.InvalidChannel;
                    const seq = self.ordered_state[idx].send.push(data[0..data_len], now_ns) orelse
                        return error.ReliableBufferFull;
                    channel_mod.encodeHeader(body[0..channel_mod.HEADER_SIZE], channel_id, seq);
                },
                .ReliableUnordered => {
                    if (UnorderedCount == 0) return error.InvalidChannel;
                    const idx = UnorderedMap[channel_id] orelse return error.InvalidChannel;
                    const seq = self.unordered_state[idx].send.push(data[0..data_len], now_ns) orelse
                        return error.ReliableBufferFull;
                    channel_mod.encodeHeader(body[0..channel_mod.HEADER_SIZE], channel_id, seq);
                },
            }

            @memcpy(body[channel_mod.HEADER_SIZE..body_len], data[0..data_len]);
            try self.cli.sendPayload(body[0..body_len]);
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
            return self.events.popFront();
        }

        pub fn pollMessage(self: *Self) ?Message {
            return self.messages.popFront();
        }

        pub fn peekMessage(self: *const Self) ?*const Message {
            return self.messages.peekFront();
        }

        pub fn consumeMessage(self: *Self) void {
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

        fn resetChannelState(self: *Self) void {
            self.ordered_state = [_]OrderedChannelState{.{}} ** OrderedCount;
            self.unordered_state = [_]UnorderedChannelState{.{}} ** UnorderedCount;
            self.ul_state = [_]UlChannelState{.{}} ** UlCount;
        }
    };
}
