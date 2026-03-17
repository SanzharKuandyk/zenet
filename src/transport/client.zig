const std = @import("std");
const root = @import("../root.zig");
const packet_mod = @import("../packet.zig");
const client_mod = @import("../client/client.zig");
const channel_mod = @import("../channel.zig");
const RingQueue = @import("../ring_buffer.zig").RingQueue;
const UdpSocket = @import("udp.zig").UdpSocket;

/// Wraps a Client state machine and a socket, driving the full I/O loop.
/// SocketType = void uses the built-in UdpSocket; pass any type satisfying
/// the socket interface (open/close/recvfrom/sendto) for a custom transport.
pub fn TransportClient(comptime opts: root.Options, comptime SocketType: type) type {
    const Socket = if (SocketType == void) UdpSocket else SocketType;

    // Validate the custom socket interface at compile time.
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

    const Cli = client_mod.Client(opts);
    const Pkt = packet_mod.Packet(opts);
    const pkt_size = @sizeOf(Pkt); // exact byte size expected for every incoming datagram
    const channel_count = opts.channels.len;
    // Payload body minus the 3-byte channel header = maximum user data per message.
    const max_user_data = opts.max_payload_size - channel_mod.HEADER_SIZE;
    const RelState = channel_mod.ReliableState(opts.reliable_buffer, max_user_data);

    // Resolve the connect token type from Options (void → built-in default).
    const ConnectTokenType = if (opts.ConnectToken == void)
        @import("../handshake.zig").DefaultConnectToken(opts.user_data_size)
    else
        opts.ConnectToken;

    // Runtime state kept per logical channel.
    const PerChannelState = struct {
        send_seq: u16 = 0, // outgoing sequence counter (UnreliableLatest / Reliable)
        ul: channel_mod.UnreliableLatestState = .{}, // recv filter for UnreliableLatest
        rel: RelState = .{}, // unACKed send buffer for Reliable
    };

    return struct {
        const Self = @This();

        /// Maximum bytes of user data that fit in a single message.
        pub const max_message_size = max_user_data;

        /// Connection lifecycle events only — no data payloads.
        pub const Event = enum { Connected, Disconnected };

        /// Incoming data received from the server.
        pub const Message = struct {
            channel_id: u8,
            data: [max_user_data]u8,
            len: usize, // valid bytes in data[0..len]
        };

        cli: Cli, // underlying state machine (handshake, sequence tracking)
        socket: Socket, // non-blocking socket used for I/O
        channel_state: [channel_count]PerChannelState, // one entry per configured channel
        events: RingQueue(Event, opts.events_queue_size), // Connected / Disconnected
        messages: RingQueue(Message, opts.messages_queue_size), // incoming data from server

        /// Open the socket bound to `bind_addr` and initialise the state machine.
        pub fn init(config: root.ClientConfig, bind_addr: std.net.Address) !Self {
            const socket = try Socket.open(bind_addr);
            errdefer {
                var s = socket;
                s.close();
            }
            const cli = try Cli.init(config);
            return .{
                .cli = cli,
                .socket = socket,
                .channel_state = [_]PerChannelState{.{}} ** channel_count,
                .events = .{},
                .messages = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.socket.close();
        }

        /// Drive one iteration of the client loop:
        ///   1. Advance the state machine clock (triggers timeout detection).
        ///   2. Flush any already-queued outgoing packets (e.g. a connect request
        ///      that was enqueued before tick was called).
        ///   3. Receive all pending datagrams and feed them to the state machine.
        ///   4. Translate inner state-machine events into our Event / Message queues.
        ///   5. Flush outgoing again — handlePacket may have queued a response
        ///      (e.g. ConnectionResponse echoing back the server's Challenge).
        ///   6. Retransmit any reliable messages that have not been ACKed in time.
        pub fn tick(self: *Self) void {
            const now = std.time.Instant.now() catch return;
            const now_ms = self.cli.getCurrentTime(); // ms since client started, for timers
            self.cli.update(now); // advance clock; may emit Disconnected on timeout

            // Step 2: send anything already sitting in the outgoing queue.
            self.flushOutgoing();

            // Step 3: drain the socket — receive until there are no more datagrams.
            var buf: [pkt_size]u8 = undefined;
            while (self.socket.recvfrom(&buf)) |result| {
                // Silently drop datagrams that are too short to be a valid packet.
                if (result.len >= pkt_size) {
                    self.cli.handlePacket(&buf) catch {};
                }
            }

            // Step 4: translate inner events.
            while (self.cli.pollEvent()) |ev| {
                switch (ev) {
                    .Connected => {
                        // Fresh connection: reset all per-channel state so stale
                        // sequence numbers from a previous session don't interfere.
                        self.channel_state = [_]PerChannelState{.{}} ** channel_count;
                        _ = self.events.pushBack(.Connected);
                    },
                    .Disconnected => _ = self.events.pushBack(.Disconnected),
                    // Raw payload from the server — decode the channel header and
                    // apply channel-specific logic before exposing to the caller.
                    .PayloadReceived => |p| self.handleIncoming(p.body[0..]),
                }
            }

            // Step 5: flush responses produced by handlePacket (e.g. ConnectionResponse).
            self.flushOutgoing();

            // Step 6: resend reliable messages that haven't been ACKed yet.
            self.retransmitReliable(now_ms);
        }

        /// Serialize and send every packet currently in the state machine's outgoing queue.
        fn flushOutgoing(self: *Self) void {
            while (self.cli.pollOutgoing()) |out| {
                const bytes = packet_mod.serialize(opts, out.packet);
                self.socket.sendto(out.addr, &bytes);
            }
        }

        /// Decode a raw payload body, apply channel logic, and push a Message if
        /// the packet should be delivered to the caller.
        fn handleIncoming(self: *Self, body: []const u8) void {
            // Parse the 3-byte channel header at the start of the payload body.
            const hdr = channel_mod.Header.decode(body) orelse return;
            if (hdr.channel_id >= channel_count) return; // unknown channel → drop
            const ch_idx = hdr.channel_id;

            if (hdr.is_ack) {
                // This is an ACK from the server for a reliable message we sent.
                // Free the corresponding slot in our send buffer.
                self.channel_state[ch_idx].rel.ack(hdr.seq);
                return;
            }

            const kind = opts.channels[ch_idx];

            // Reliable channel: immediately send an ACK back so the server knows
            // this message was received and can free its send-buffer slot.
            if (kind == .Reliable) {
                var ack_body: [opts.max_payload_size]u8 = [_]u8{0} ** opts.max_payload_size;
                channel_mod.encodeAck(ack_body[0..channel_mod.HEADER_SIZE], @intCast(ch_idx), hdr.seq);
                self.cli.sendPayload(ack_body) catch {};
                self.flushOutgoing(); // send the ACK immediately, don't wait for next tick
            }

            // Decide whether this packet should be delivered to the caller.
            const should_deliver = switch (kind) {
                .Unreliable => true, // always deliver
                // Deliver only if this sequence number is newer than the last seen;
                // drops reordered or duplicate packets.
                .UnreliableLatest => self.channel_state[ch_idx].ul.accept(hdr.seq),
                .Reliable => true, // ordering/dedup handled by the ACK + resend loop
            };
            if (!should_deliver) return;

            // Slice past the channel header to get the user data.
            const data_start = channel_mod.HEADER_SIZE;
            if (body.len < data_start) return;
            const data_len = @min(body.len - data_start, max_user_data);

            var msg: Message = .{
                .channel_id = @intCast(ch_idx),
                .data = [_]u8{0} ** max_user_data,
                .len = data_len,
            };
            @memcpy(msg.data[0..data_len], body[data_start .. data_start + data_len]);
            _ = self.messages.pushBack(msg);
        }

        /// Walk every reliable channel's send buffer and resend any entry whose
        /// ACK has not arrived within `opts.reliable_resend_ms` milliseconds.
        ///
        /// Called once per tick, after all incoming packets have been processed,
        /// so any ACKs that arrived this tick have already been applied and won't
        /// cause a spurious resend.
        fn retransmitReliable(self: *Self, now_ms: u64) void {
            // Iterate over every configured channel.
            for (0..channel_count) |ch_idx| {
                // Only reliable channels maintain a send buffer; skip the rest.
                if (opts.channels[ch_idx] != .Reliable) continue;

                const rel = &self.channel_state[ch_idx].rel;

                // Inspect every slot in the fixed-size send buffer.
                for (&rel.entries) |*e| {
                    // Slot is empty (already ACKed or never used) — nothing to do.
                    if (!e.active) continue;

                    // Not enough time has passed since the last send attempt.
                    // `-|` is saturating subtraction: protects against now_ms < e.sent_at
                    // which could happen if the clock is read before update() in edge cases.
                    if (now_ms -| e.sent_at < opts.reliable_resend_ms) continue;

                    // Rebuild the full payload body: channel header followed by the
                    // original user data that was stored when the message was first sent.
                    var body: [opts.max_payload_size]u8 = [_]u8{0} ** opts.max_payload_size;
                    channel_mod.encodeHeader(body[0..channel_mod.HEADER_SIZE], @intCast(ch_idx), e.seq);
                    @memcpy(body[channel_mod.HEADER_SIZE .. channel_mod.HEADER_SIZE + e.len], e.data[0..e.len]);

                    // Wrap the body in a Payload packet and serialize it to bytes.
                    // We reuse e.seq as the packet-level sequence number so the
                    // server-side dedup (last_recv_seq) doesn't filter it out on resend —
                    // a higher packet seq would be required for that, but we're retransmitting
                    // the same logical message, so we keep the same seq intentionally.
                    const bytes = packet_mod.serialize(opts, .{ .Payload = .{
                        .sequence = e.seq,
                        .body = body,
                    } });

                    // Fire the datagram directly through the socket, bypassing the
                    // state machine's outgoing queue (this is a transport-level concern).
                    self.socket.sendto(self.cli.config.server_addr, &bytes);

                    // Reset the resend timer so we don't immediately send again next tick.
                    e.sent_at = now_ms;
                }
            }
        }

        /// Send a message on the given channel to the server.
        /// For Reliable channels the message is buffered until ACKed; for others it is
        /// fire-and-forget. Returns error.ReliableBufferFull if the send buffer is exhausted.
        pub fn sendOnChannel(self: *Self, channel_id: u8, data: []const u8) !void {
            if (channel_id >= channel_count) return error.InvalidChannel;
            const kind = opts.channels[channel_id];
            const now_ms = self.cli.getCurrentTime();

            var body: [opts.max_payload_size]u8 = [_]u8{0} ** opts.max_payload_size;
            const data_len = @min(data.len, max_user_data);

            switch (kind) {
                .Unreliable => {
                    // Seq = 0: Unreliable channels don't use sequence numbers.
                    channel_mod.encodeHeader(body[0..channel_mod.HEADER_SIZE], channel_id, 0);
                    @memcpy(body[channel_mod.HEADER_SIZE .. channel_mod.HEADER_SIZE + data_len], data[0..data_len]);
                },
                .UnreliableLatest => {
                    // Increment the outgoing seq so the receiver can drop older packets.
                    self.channel_state[channel_id].send_seq +%= 1;
                    const seq = self.channel_state[channel_id].send_seq;
                    channel_mod.encodeHeader(body[0..channel_mod.HEADER_SIZE], channel_id, seq);
                    @memcpy(body[channel_mod.HEADER_SIZE .. channel_mod.HEADER_SIZE + data_len], data[0..data_len]);
                },
                .Reliable => {
                    // push() stores the data and assigns a seq; returns null if the
                    // buffer is full (too many unACKed messages in flight).
                    const rel = &self.channel_state[channel_id].rel;
                    const seq = rel.push(data[0..data_len], now_ms) orelse return error.ReliableBufferFull;
                    channel_mod.encodeHeader(body[0..channel_mod.HEADER_SIZE], channel_id, seq);
                    @memcpy(body[channel_mod.HEADER_SIZE .. channel_mod.HEADER_SIZE + data_len], data[0..data_len]);
                },
            }

            // Hand the framed payload to the state machine; it will enqueue an
            // outgoing Payload packet which flushOutgoing() will send on the next tick.
            try self.cli.sendPayload(body);
        }

        /// Initiate a plain (unauthenticated) connection to the server.
        pub fn connect(self: *Self) !void {
            try self.cli.connect();
        }

        /// Initiate a secure connection using a signed connect token.
        pub fn connectSecure(self: *Self, token: ConnectTokenType) !void {
            try self.cli.connectSecure(token);
        }

        /// Gracefully disconnect: sends a Disconnect packet and transitions immediately.
        pub fn disconnect(self: *Self) void {
            self.cli.disconnect();
        }

        /// Poll the next connection lifecycle event (Connected / Disconnected).
        /// Returns null when the queue is empty.
        pub fn pollEvent(self: *Self) ?Event {
            return self.events.popFront();
        }

        /// Poll the next incoming message from the server.
        /// Returns null when the queue is empty.
        pub fn pollMessage(self: *Self) ?Message {
            return self.messages.popFront();
        }

        /// Direct access to the underlying state machine for advanced usage.
        pub fn getStateMachine(self: *Self) *Cli {
            return &self.cli;
        }
    };
}
