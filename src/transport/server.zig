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

    const PerChannelState = struct {
        send_seq: u16 = 0,
        ul: channel_mod.UnreliableLatestState = .{},
        rel: RelState = .{},
        rel_recv: channel_mod.ReliableRecvState = .{},
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
        channel_state: *[opts.max_clients][channel_count]PerChannelState,
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
            const channel_state = try allocator.create([opts.max_clients][channel_count]PerChannelState);
            errdefer allocator.destroy(channel_state);
            for (channel_state) |*row| row.* = [_]PerChannelState{.{}} ** channel_count;
            const srv = try Srv.init(allocator, config);
            return .{
                .srv = srv,
                .socket = socket,
                .channel_state = channel_state,
                .allocator = allocator,
                .events = .{},
                .messages = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.srv.deinit();
            self.socket.close();
            self.allocator.destroy(self.channel_state);
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
                        self.channel_state[slot] = [_]PerChannelState{.{}} ** channel_count;
                        _ = self.events.pushBack(.{ .ClientConnected = .{
                            .cid = e.cid,
                            .addr = e.addr,
                            .user_data = e.user_data,
                        } });
                    },
                    .ClientDisconnected => |e| _ = self.events.pushBack(.{ .ClientDisconnected = .{
                        .cid = e.cid,
                        .addr = e.addr,
                    } }),
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

            if (hdr.is_ack) {
                self.channel_state[slot][ch_idx].rel.ack(hdr.seq);
                return;
            }

            const kind = opts.channels[ch_idx];
            if (kind == .Reliable) {
                const action = self.channel_state[slot][ch_idx].rel_recv.classify(hdr.seq);
                if (action == .future) return;

                var ack_body: [channel_mod.HEADER_SIZE]u8 = undefined;
                channel_mod.encodeAck(&ack_body, @intCast(ch_idx), hdr.seq);
                self.srv.sendPayload(cid, &ack_body) catch {};

                if (action == .duplicate) return;
            }

            const should_deliver = switch (kind) {
                .Unreliable => true,
                .UnreliableLatest => self.channel_state[slot][ch_idx].ul.accept(hdr.seq),
                .Reliable => true,
            };
            if (!should_deliver) return;

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
                    if (opts.channels[ch_idx] != .Reliable) continue;
                    const rel = &self.channel_state[slot][ch_idx].rel;
                    for (&rel.entries) |*e| {
                        if (!e.active) continue;
                        if (now_ns -| e.sent_at < opts.reliable_resend_ns) continue;

                        var body: [opts.max_payload_size]u8 = [_]u8{0} ** opts.max_payload_size;
                        const body_len = channel_mod.HEADER_SIZE + e.len;
                        channel_mod.encodeHeader(body[0..channel_mod.HEADER_SIZE], @intCast(ch_idx), e.seq);
                        @memcpy(body[channel_mod.HEADER_SIZE .. body_len], e.data[0..e.len]);
                        self.srv.sendPayload(@intCast(slot), body[0..body_len]) catch continue;
                        e.sent_at = now_ns;
                    }
                }
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
                    self.channel_state[slot][channel_id].send_seq +%= 1;
                    channel_mod.encodeHeader(
                        body[0..channel_mod.HEADER_SIZE],
                        channel_id,
                        self.channel_state[slot][channel_id].send_seq,
                    );
                },
                .Reliable => {
                    const rel = &self.channel_state[slot][channel_id].rel;
                    const seq = rel.push(data[0..data_len], now_ns) orelse return error.ReliableBufferFull;
                    channel_mod.encodeHeader(body[0..channel_mod.HEADER_SIZE], channel_id, seq);
                },
            }

            @memcpy(body[channel_mod.HEADER_SIZE .. body_len], data[0..data_len]);
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
    };
}
