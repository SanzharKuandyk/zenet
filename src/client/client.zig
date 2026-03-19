const std = @import("std");
const root = @import("../root.zig");
const packet_mod = @import("../packet.zig");
const handshake = @import("../handshake.zig");
const Options = root.Options;
const ClientError = @import("error.zig").ClientError;
const ClientConfig = @import("config.zig").ClientConfig;
const RingQueue = @import("../ring_buffer.zig").RingQueue;

pub fn Client(comptime opts: Options) type {
    const Pkt = packet_mod.Packet(opts);
    const ConnectTokenType = if (opts.ConnectToken == void)
        handshake.DefaultConnectToken(opts.user_data_size, opts.max_token_addresses)
    else
        opts.ConnectToken;

    return struct {
        const Self = @This();

        pub const State = enum { Disconnected, SendingRequest, SendingResponse, Connected };

        pub const Event = union(enum) {
            Connected,
            Disconnected,
            PayloadReceived: packet_mod.Payload(opts),
        };

        pub const Outgoing = struct {
            addr: std.net.Address,
            packet: Pkt,
        };

        state: State,
        config: ClientConfig,

        client_nonce: u64,
        secure_token: ?ConnectTokenType,
        pending_response: ?packet_mod.ConnectionResponse,
        connect_started_at: u64,
        last_handshake_send: u64,
        has_handshake_send: bool,
        last_recv: u64,

        start_time: std.time.Instant,
        current_time: std.time.Instant,

        outgoing: RingQueue(Outgoing, opts.outgoing_queue_size),
        events: RingQueue(Event, opts.events_queue_size),

        pub fn init(config: ClientConfig) !Self {
            const now = try std.time.Instant.now();
            return .{
                .state = .Disconnected,
                .config = config,
                .client_nonce = 0,
                .secure_token = null,
                .pending_response = null,
                .connect_started_at = 0,
                .last_handshake_send = 0,
                .has_handshake_send = false,
                .last_recv = 0,
                .start_time = now,
                .current_time = now,
                .outgoing = .{},
                .events = .{},
            };
        }

        pub fn getCurrentTime(self: *const Self) u64 {
            return self.current_time.since(self.start_time);
        }

        pub fn update(self: *Self, now: std.time.Instant) void {
            self.current_time = now;
            const t = self.getCurrentTime();
            switch (self.state) {
                .SendingRequest, .SendingResponse => self.updateHandshake(t),
                .Connected => {
                    if (t -| self.last_recv > self.config.timeout_ns) {
                        self.state = .Disconnected;
                        self.clearHandshakeState();
                        _ = self.events.pushBack(.Disconnected);
                    }
                },
                .Disconnected => {},
            }
        }

        pub fn connect(self: *Self) ClientError!void {
            if (self.state != .Disconnected) return error.InvalidState;
            self.client_nonce = std.crypto.random.int(u64);
            self.secure_token = null;
            self.pending_response = null;
            self.connect_started_at = self.getCurrentTime();
            self.last_handshake_send = 0;
            self.state = .SendingRequest;
            self.queueConnectionRequest() catch |err| {
                self.state = .Disconnected;
                self.clearHandshakeState();
                return err;
            };
        }

        pub fn connectSecure(self: *Self, token: ConnectTokenType) ClientError!void {
            if (self.state != .Disconnected) return error.InvalidState;
            self.client_nonce = std.crypto.random.int(u64);
            self.secure_token = token;
            self.pending_response = null;
            self.connect_started_at = self.getCurrentTime();
            self.last_handshake_send = 0;
            self.state = .SendingRequest;
            self.queueConnectionRequest() catch |err| {
                self.state = .Disconnected;
                self.clearHandshakeState();
                return err;
            };
        }

        pub fn handlePacket(self: *Self, buffer: []const u8) ClientError!void {
            const pkt = packet_mod.deserialize(opts, buffer) catch return error.InvalidPacket;

            switch (pkt) {
                .Challenge => |challenge| {
                    switch (self.state) {
                        .SendingRequest, .SendingResponse => {},
                        else => return error.InvalidPacket,
                    }
                    self.pending_response = .{
                        .sequence = challenge.sequence,
                        .token = challenge.token,
                    };
                    self.state = .SendingResponse;
                    try self.queueConnectionResponse();
                    self.last_recv = self.getCurrentTime();
                },
                .ConnectionAccepted => {
                    if (self.state != .SendingResponse) return error.InvalidPacket;
                    self.state = .Connected;
                    self.clearHandshakeState();
                    self.last_recv = self.getCurrentTime();
                    _ = self.events.pushBack(.Connected);
                },
                .Payload => |payload| {
                    if (self.state != .Connected) return error.InvalidPacket;
                    self.last_recv = self.getCurrentTime();
                    _ = self.events.pushBack(.{ .PayloadReceived = payload });
                },
                .Disconnect => {
                    if (self.state != .Connected) return error.InvalidPacket;
                    self.state = .Disconnected;
                    self.clearHandshakeState();
                    _ = self.events.pushBack(.Disconnected);
                },
                .ConnectionRequest, .ConnectionResponse => return error.InvalidPacket,
            }
        }

        pub fn sendPayload(self: *Self, body: []const u8) ClientError!void {
            if (self.state != .Connected) return error.InvalidState;
            if (body.len > opts.max_payload_size) return error.PayloadTooLarge;

            var payload: packet_mod.Payload(opts) = .{
                .len = @intCast(body.len),
                .body = undefined,
            };
            @memcpy(payload.body[0..body.len], body);

            if (!self.outgoing.pushBack(.{
                .addr = self.config.server_addr,
                .packet = .{ .Payload = payload },
            })) return error.IoError;
        }

        pub fn disconnect(self: *Self) void {
            if (self.state != .Connected) return;
            self.state = .Disconnected;
            self.clearHandshakeState();
            _ = self.outgoing.pushBack(.{
                .addr = self.config.server_addr,
                .packet = .Disconnect,
            });
        }

        pub fn pollEvent(self: *Self) ?Event {
            // Copy-out convenience API.
            return self.events.popFront();
        }

        pub fn peekEvent(self: *const Self) ?*const Event {
            // Zero-copy view into the front event.
            return self.events.peekFront();
        }

        pub fn consumeEvent(self: *Self) void {
            // Drop the event returned by peekEvent().
            self.events.advance();
        }

        pub fn pollOutgoing(self: *Self) ?Outgoing {
            // Copy-out convenience API.
            return self.outgoing.popFront();
        }

        pub fn peekOutgoing(self: *const Self) ?*const Outgoing {
            // Zero-copy view into the front outgoing packet.
            return self.outgoing.peekFront();
        }

        pub fn consumeOutgoing(self: *Self) void {
            // Drop the packet returned by peekOutgoing().
            self.outgoing.advance();
        }

        fn updateHandshake(self: *Self, now: u64) void {
            if (now -| self.connect_started_at > self.config.connect_timeout_ns) {
                self.state = .Disconnected;
                self.clearHandshakeState();
                _ = self.events.pushBack(.Disconnected);
                return;
            }
            if (self.has_handshake_send and now -| self.last_handshake_send < self.config.connect_retry_ns)
                return;

            switch (self.state) {
                .SendingRequest => self.queueConnectionRequest() catch {},
                .SendingResponse => self.queueConnectionResponse() catch {},
                else => {},
            }
        }

        fn queueConnectionRequest(self: *Self) ClientError!void {
            const req: packet_mod.ConnectionRequest(opts) = if (self.secure_token) |token|
                .{ .Secure = .{
                    .protocol_id = self.config.protocol_id,
                    .client_nonce = self.client_nonce,
                    .token = token,
                } }
            else
                .{ .Plain = .{
                    .protocol_id = self.config.protocol_id,
                    .client_nonce = self.client_nonce,
                } };

            if (!self.outgoing.pushBack(.{
                .addr = self.config.server_addr,
                .packet = .{ .ConnectionRequest = req },
            })) return error.IoError;

            self.last_handshake_send = self.getCurrentTime();
            self.has_handshake_send = true;
        }

        fn queueConnectionResponse(self: *Self) ClientError!void {
            const response = self.pending_response orelse return error.InvalidState;
            if (!self.outgoing.pushBack(.{
                .addr = self.config.server_addr,
                .packet = .{ .ConnectionResponse = response },
            })) return error.IoError;

            self.last_handshake_send = self.getCurrentTime();
            self.has_handshake_send = true;
        }

        fn clearHandshakeState(self: *Self) void {
            self.secure_token = null;
            self.pending_response = null;
            self.connect_started_at = 0;
            self.last_handshake_send = 0;
            self.has_handshake_send = false;
        }
    };
}
