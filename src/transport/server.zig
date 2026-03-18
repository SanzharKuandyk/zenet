const std = @import("std");
const root = @import("../root.zig");
const packet_mod = @import("../packet.zig");
const server_mod = @import("../server/server.zig");
const channel_mod = @import("../channel.zig");
const socket_mod = @import("socket.zig");
const RingQueue = @import("../ring_buffer.zig").RingQueue;
const UdpSocket = @import("udp.zig").UdpSocket;

pub fn TransportServer(comptime opts: root.Options, comptime SocketType: type) type {
    const Socket = if (SocketType == void) UdpSocket else SocketType;

    comptime {
        if (SocketType != void) socket_mod.validateSocketInterface(Socket);
        if (opts.channels.len == 0)
            @compileError("Options.channels must have at least one entry");
    }

    const Srv = server_mod.Server(opts);
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

    const OrderedChannelState = struct {
        send: ?*RelState = null,
        recv: channel_mod.ReliableOrderedRecvState = .{},
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

        srv: Srv,
        socket: Socket,
        ordered_state: *[opts.max_clients][OrderedCount]OrderedChannelState,
        unordered_state: *[opts.max_clients][UnorderedCount]UnorderedChannelState,
        ul_state: *[opts.max_clients][UlCount]UlChannelState,
        allocator: std.mem.Allocator,
        events: RingQueue(Event, opts.events_queue_size),
        messages: RingQueue(Message, opts.messages_queue_size),

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

            const srv = try Srv.init(allocator, config);
            return .{
                .srv = srv,
                .socket = socket,
                .ordered_state = ordered_state,
                .unordered_state = unordered_state,
                .ul_state = ul_state,
                .allocator = allocator,
                .events = .{},
                .messages = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            for (0..opts.max_clients) |slot| self.resetClientChannelState(slot);
            self.srv.deinit();
            self.socket.close();
            self.allocator.destroy(self.ordered_state);
            self.allocator.destroy(self.unordered_state);
            self.allocator.destroy(self.ul_state);
        }

        pub fn tick(self: *Self) void {
            const now = std.time.Instant.now() catch return;
            self.srv.update(now);
            const now_ns = self.srv.getCurrentTime();

            var buf: [max_packet_size]u8 = undefined;
            while (self.socket.recvfrom(&buf)) |result| {
                self.srv.handlePacket(result.addr, buf[0..result.len]) catch {};
            }

            while (self.srv.pollEvent()) |ev| {
                switch (ev) {
                    .ClientConnected => |e| {
                        const slot: usize = @intCast(e.cid);
                        self.resetClientChannelState(slot);
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
                    .PayloadReceived => |e| self.handleIncoming(e.cid, e.payload.body[0..e.payload.len]),
                }
            }

            self.retransmitReliable(now_ns);
            self.flushOutgoing();
        }

        fn flushOutgoing(self: *Self) void {
            var buf: [max_packet_size]u8 = undefined;
            while (self.srv.pollOutgoing()) |out| {
                const len = packet_mod.serialize(opts, out.packet, buf[0..]) catch continue;
                self.socket.sendto(out.addr, buf[0..len]);
            }
        }

        fn handleIncoming(self: *Self, cid: u64, body: []const u8) void {
            const slot: usize = @intCast(cid);
            const hdr = channel_mod.Header.decode(body) orelse return;
            if (hdr.channel_id >= channel_count) return;
            const ch_idx = hdr.channel_id;
            const kind = opts.channels[ch_idx];

            if (hdr.is_ack) {
                switch (kind) {
                    .ReliableOrdered => {
                        if (OrderedCount == 0) return;
                        const idx = OrderedMap[ch_idx] orelse return;
                        if (self.ordered_state[slot][idx].send) |rel| rel.ack(hdr.seq);
                    },
                    .ReliableUnordered => {
                        if (UnorderedCount == 0) return;
                        const idx = UnorderedMap[ch_idx] orelse return;
                        if (self.unordered_state[slot][idx].send) |rel| rel.ack(hdr.seq);
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
                    if (!self.ul_state[slot][idx].recv.accept(hdr.seq)) return;
                },
                .ReliableOrdered => {
                    if (OrderedCount == 0) return;
                    const idx = OrderedMap[ch_idx] orelse return;
                    const st = &self.ordered_state[slot][idx];
                    const action = st.recv.classify(hdr.seq);
                    if (action == .future) return;

                    self.sendAck(cid, @intCast(ch_idx), hdr.seq);
                    if (action == .duplicate) return;
                },
                .ReliableUnordered => {
                    if (UnorderedCount == 0) return;
                    const idx = UnorderedMap[ch_idx] orelse return;
                    const st = &self.unordered_state[slot][idx];
                    const action = st.recv.classify(hdr.seq);
                    if (action != .stale) self.sendAck(cid, @intCast(ch_idx), hdr.seq);
                    if (action != .deliver) return;
                },
            }

            const data_len = body.len -| channel_mod.HEADER_SIZE;
            var msg: Message = .{
                .cid = cid,
                .channel_id = @intCast(ch_idx),
                .data = [_]u8{0} ** max_user_data,
                .len = @min(data_len, max_user_data),
            };
            @memcpy(msg.data[0..msg.len], body[channel_mod.HEADER_SIZE .. channel_mod.HEADER_SIZE + msg.len]);
            _ = self.messages.pushBack(msg);
        }

        fn retransmitReliable(self: *Self, now_ns: u64) void {
            for (0..opts.max_clients) |slot| {
                _ = self.srv.clients[slot] orelse continue;

                for (0..channel_count) |ch_idx| {
                    switch (opts.channels[ch_idx]) {
                        .ReliableOrdered => {
                            if (OrderedCount == 0) continue;
                            const idx = OrderedMap[ch_idx] orelse continue;
                            const rel = self.ordered_state[slot][idx].send orelse continue;
                            self.retransmitState(rel, @intCast(slot), @intCast(ch_idx), now_ns);
                        },
                        .ReliableUnordered => {
                            if (UnorderedCount == 0) continue;
                            const idx = UnorderedMap[ch_idx] orelse continue;
                            const rel = self.unordered_state[slot][idx].send orelse continue;
                            self.retransmitState(rel, @intCast(slot), @intCast(ch_idx), now_ns);
                        },
                        else => {},
                    }
                }
            }
        }

        fn retransmitState(self: *Self, rel: *RelState, cid: u64, channel_id: u8, now_ns: u64) void {
            for (&rel.entries) |*e| {
                if (!e.active) continue;
                if (now_ns -| e.sent_at < opts.reliable_resend_ns) continue;

                var body: [opts.max_payload_size]u8 = [_]u8{0} ** opts.max_payload_size;
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
            const kind = opts.channels[channel_id];
            const now_ns = self.srv.getCurrentTime();

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
                    self.ul_state[slot][idx].send_seq +%= 1;
                    channel_mod.encodeHeader(
                        body[0..channel_mod.HEADER_SIZE],
                        channel_id,
                        self.ul_state[slot][idx].send_seq,
                    );
                },
                .ReliableOrdered => {
                    if (OrderedCount == 0) return error.InvalidChannel;
                    const idx = OrderedMap[channel_id] orelse return error.InvalidChannel;
                    const rel = try self.getOrCreateReliableState(&self.ordered_state[slot][idx].send);
                    const seq = rel.push(data[0..data_len], now_ns) orelse return error.ReliableBufferFull;
                    channel_mod.encodeHeader(body[0..channel_mod.HEADER_SIZE], channel_id, seq);
                },
                .ReliableUnordered => {
                    if (UnorderedCount == 0) return error.InvalidChannel;
                    const idx = UnorderedMap[channel_id] orelse return error.InvalidChannel;
                    const rel = try self.getOrCreateReliableState(&self.unordered_state[slot][idx].send);
                    const seq = rel.push(data[0..data_len], now_ns) orelse return error.ReliableBufferFull;
                    channel_mod.encodeHeader(body[0..channel_mod.HEADER_SIZE], channel_id, seq);
                },
            }

            @memcpy(body[channel_mod.HEADER_SIZE..body_len], data[0..data_len]);
            try self.srv.sendPayload(cid, body[0..body_len]);
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

        pub fn getStateMachine(self: *Self) *Srv {
            return &self.srv;
        }

        fn sendAck(self: *Self, cid: u64, channel_id: u8, seq: u16) void {
            var ack_body: [channel_mod.HEADER_SIZE]u8 = undefined;
            channel_mod.encodeAck(&ack_body, channel_id, seq);
            self.srv.sendPayload(cid, &ack_body) catch {};
        }

        fn getOrCreateReliableState(self: *Self, send_ptr: *?*RelState) !*RelState {
            if (send_ptr.*) |rel| return rel;

            const rel = try self.allocator.create(RelState);
            rel.* = .{};
            send_ptr.* = rel;
            return rel;
        }

        fn resetClientChannelState(self: *Self, slot: usize) void {
            for (0..OrderedCount) |idx| {
                if (self.ordered_state[slot][idx].send) |rel| self.allocator.destroy(rel);
            }
            for (0..UnorderedCount) |idx| {
                if (self.unordered_state[slot][idx].send) |rel| self.allocator.destroy(rel);
            }

            self.ordered_state[slot] = [_]OrderedChannelState{.{}} ** OrderedCount;
            self.unordered_state[slot] = [_]UnorderedChannelState{.{}} ** UnorderedCount;
            self.ul_state[slot] = [_]UlChannelState{.{}} ** UlCount;
        }
    };
}
