const std = @import("std");
const root = @import("../root.zig");
const packet_mod = @import("../packet.zig");
const server_mod = @import("../server/server.zig");
const channel_mod = @import("../channel.zig");
const RingQueue = @import("../ring_buffer.zig").RingQueue;
const UdpSocket = @import("udp.zig").UdpSocket;

pub fn TransportServer(comptime opts: root.Options, comptime SocketType: type) type {
    const Socket = if (SocketType == void) UdpSocket else SocketType;

    comptime {
        if (SocketType != void) {
            if (!@hasDecl(SocketType, "open"))
                @compileError("Socket must have: pub fn open(std.net.Address) !@This()");
            if (!@hasDecl(SocketType, "close"))
                @compileError("Socket must have: pub fn close(*@This()) void");
            if (!@hasDecl(SocketType, "recvfrom"))
                @compileError("Socket must have: pub fn recvfrom(*@This(), []u8) ?Recv");
            if (!@hasDecl(SocketType, "sendto"))
                @compileError("Socket must have: pub fn sendto(*@This(), std.net.Address, []const u8) void");
        }
        if (opts.channels.len == 0)
            @compileError("Options.channels must have at least one entry");
    }

    const Srv = server_mod.Server(opts);
    const Pkt = packet_mod.Packet(opts);
    const pkt_size = @sizeOf(Pkt);
    const channel_count = opts.channels.len;
    const max_user_data = opts.max_payload_size - channel_mod.HEADER_SIZE;
    const RelState = channel_mod.ReliableState(opts.reliable_buffer, max_user_data);

    const PerChannelState = struct {
        send_seq: u16 = 0,
        ul: channel_mod.UnreliableLatestState = .{},
        rel: RelState = .{},
    };

    return struct {
        const Self = @This();

        pub const max_message_size = max_user_data;

        /// Connection lifecycle events only.
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

        /// Incoming data from a connected client.
        pub const Message = struct {
            cid: u64,
            channel_id: u8,
            data: [max_user_data]u8,
            len: usize,
        };

        srv: Srv,
        socket: Socket,
        channel_state: [opts.max_clients][channel_count]PerChannelState,
        events: RingQueue(Event, opts.events_queue_size),
        messages: RingQueue(Message, opts.messages_queue_size),

        pub fn init(allocator: std.mem.Allocator, config: root.ServerConfig, bind_addr: std.net.Address) !Self {
            const socket = try Socket.open(bind_addr);
            errdefer {
                var s = socket;
                s.close();
            }
            const srv = try Srv.init(allocator, config);
            return .{
                .srv = srv,
                .socket = socket,
                .channel_state = [_][channel_count]PerChannelState{
                    [_]PerChannelState{.{}} ** channel_count,
                } ** opts.max_clients,
                .events = .{},
                .messages = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.srv.deinit();
            self.socket.close();
        }

        pub fn tick(self: *Self) void {
            const now = std.time.Instant.now() catch return;
            const now_ms = self.srv.getCurrentTime();
            self.srv.update(now);

            // Drain recv → state machine
            var buf: [pkt_size]u8 = undefined;
            while (self.socket.recvfrom(&buf)) |result| {
                if (result.len >= pkt_size) {
                    self.srv.handlePacket(result.addr, &buf) catch {};
                }
            }

            // Drain inner server events → our queues
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
                    .ClientDisconnected => |e| {
                        _ = self.events.pushBack(.{ .ClientDisconnected = .{
                            .cid = e.cid,
                            .addr = e.addr,
                        } });
                    },
                    .PayloadReceived => |e| self.handleIncoming(e.cid, e.payload.body[0..]),
                }
            }

            // Retransmit pending reliable messages
            self.retransmitReliable(now_ms);

            // Drain state machine → send
            while (self.srv.pollOutgoing()) |out| {
                const bytes = packet_mod.serialize(opts, out.packet);
                self.socket.sendto(out.addr, &bytes);
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
                const conn = self.srv.clients[slot] orelse return;
                var ack_body: [opts.max_payload_size]u8 = [_]u8{0} ** opts.max_payload_size;
                channel_mod.encodeAck(ack_body[0..channel_mod.HEADER_SIZE], @intCast(ch_idx), hdr.seq);
                self.srv.sendPayload(cid, ack_body) catch {};
                while (self.srv.pollOutgoing()) |out| {
                    const bytes = packet_mod.serialize(opts, out.packet);
                    self.socket.sendto(out.addr, &bytes);
                }
                _ = conn;
            }

            const should_deliver = switch (kind) {
                .Unreliable => true,
                .UnreliableLatest => self.channel_state[slot][ch_idx].ul.accept(hdr.seq),
                .Reliable => true,
            };
            if (!should_deliver) return;

            const data_start = channel_mod.HEADER_SIZE;
            if (body.len < data_start) return;
            const data_len = @min(body.len - data_start, max_user_data);

            var msg: Message = .{
                .cid = cid,
                .channel_id = @intCast(ch_idx),
                .data = [_]u8{0} ** max_user_data,
                .len = data_len,
            };
            @memcpy(msg.data[0..data_len], body[data_start .. data_start + data_len]);
            _ = self.messages.pushBack(msg);
        }

        fn retransmitReliable(self: *Self, now_ms: u64) void {
            for (0..opts.max_clients) |slot| {
                const conn = self.srv.clients[slot] orelse continue;
                for (0..channel_count) |ch_idx| {
                    if (opts.channels[ch_idx] != .Reliable) continue;
                    const rel = &self.channel_state[slot][ch_idx].rel;
                    for (&rel.entries) |*e| {
                        if (!e.active) continue;
                        if (now_ms -| e.sent_at < opts.reliable_resend_ms) continue;
                        var body: [opts.max_payload_size]u8 = [_]u8{0} ** opts.max_payload_size;
                        channel_mod.encodeHeader(body[0..channel_mod.HEADER_SIZE], @intCast(ch_idx), e.seq);
                        @memcpy(body[channel_mod.HEADER_SIZE .. channel_mod.HEADER_SIZE + e.len], e.data[0..e.len]);
                        const bytes = packet_mod.serialize(opts, .{ .Payload = .{
                            .sequence = e.seq,
                            .body = body,
                        } });
                        self.socket.sendto(conn.addr, &bytes);
                        e.sent_at = now_ms;
                    }
                }
            }
        }

        /// Send a message on the given channel to a connected client.
        pub fn sendOnChannel(self: *Self, cid: u64, channel_id: u8, data: []const u8) !void {
            if (channel_id >= channel_count) return error.InvalidChannel;
            const slot: usize = @intCast(cid);
            const kind = opts.channels[channel_id];
            const now_ms = self.srv.getCurrentTime();

            var body: [opts.max_payload_size]u8 = [_]u8{0} ** opts.max_payload_size;
            const data_len = @min(data.len, max_user_data);

            switch (kind) {
                .Unreliable => {
                    channel_mod.encodeHeader(body[0..channel_mod.HEADER_SIZE], channel_id, 0);
                    @memcpy(body[channel_mod.HEADER_SIZE .. channel_mod.HEADER_SIZE + data_len], data[0..data_len]);
                },
                .UnreliableLatest => {
                    self.channel_state[slot][channel_id].send_seq +%= 1;
                    const seq = self.channel_state[slot][channel_id].send_seq;
                    channel_mod.encodeHeader(body[0..channel_mod.HEADER_SIZE], channel_id, seq);
                    @memcpy(body[channel_mod.HEADER_SIZE .. channel_mod.HEADER_SIZE + data_len], data[0..data_len]);
                },
                .Reliable => {
                    const rel = &self.channel_state[slot][channel_id].rel;
                    const seq = rel.push(data[0..data_len], now_ms) orelse return error.ReliableBufferFull;
                    channel_mod.encodeHeader(body[0..channel_mod.HEADER_SIZE], channel_id, seq);
                    @memcpy(body[channel_mod.HEADER_SIZE .. channel_mod.HEADER_SIZE + data_len], data[0..data_len]);
                },
            }

            try self.srv.sendPayload(cid, body);
        }

        /// Poll the next connection lifecycle event (ClientConnected / ClientDisconnected).
        pub fn pollEvent(self: *Self) ?Event {
            return self.events.popFront();
        }

        /// Poll the next incoming message from any client.
        pub fn pollMessage(self: *Self) ?Message {
            return self.messages.popFront();
        }

        pub fn getStateMachine(self: *Self) *Srv {
            return &self.srv;
        }
    };
}
