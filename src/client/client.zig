const std = @import("std");
const root = @import("../root.zig");
const packet_mod = @import("../packet.zig");
const handshake = @import("../handshake.zig");
const Options = root.Options;
const RingQueue = @import("../ring_buffer.zig").RingQueue;
const ClientError = @import("error.zig").ClientError;
const ClientConfig = @import("config.zig").ClientConfig;

pub fn Client(comptime opts: Options) type {
    const Pkt = packet_mod.Packet(opts);
    const pkt_size = @sizeOf(Pkt);

    const ConnectTokenType = if (opts.ConnectToken == void)
        handshake.DefaultConnectToken(opts.user_data_size)
    else
        opts.ConnectToken;

    return struct {
        const Self = @This();

        pub const State = enum { Disconnected, Connecting, Connected };

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
        connect_sent_at: u64,
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
                .connect_sent_at = 0,
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

        /// Advance the client clock and expire stale states.
        pub fn update(self: *Self, now: std.time.Instant) void {
            self.current_time = now;
            const t = self.getCurrentTime();
            switch (self.state) {
                .Connecting => {
                    if (t -| self.connect_sent_at > self.config.connect_timeout_ms) {
                        self.state = .Disconnected;
                        _ = self.events.pushBack(.Disconnected);
                    }
                },
                .Connected => {
                    if (t -| self.last_recv > self.config.timeout_ms) {
                        self.state = .Disconnected;
                        _ = self.events.pushBack(.Disconnected);
                    }
                },
                .Disconnected => {},
            }
        }

        /// Send a plain (unauthenticated) connection request.
        pub fn connect(self: *Self) ClientError!void {
            if (self.state != .Disconnected) return ClientError.InvalidState;
            self.client_nonce = std.crypto.random.int(u64);
            self.connect_sent_at = self.getCurrentTime();
            self.state = .Connecting;
            if (!self.outgoing.pushBack(.{
                .addr = self.config.server_addr,
                .packet = .{ .ConnectionRequest = .{ .Plain = .{
                    .protocol_id = @truncate(self.config.protocol_id),
                    .client_nonce = self.client_nonce,
                } } },
            })) return ClientError.IoError;
        }

        /// Send a secure connection request using a connect token.
        pub fn connectSecure(self: *Self, token: ConnectTokenType) ClientError!void {
            if (self.state != .Disconnected) return ClientError.InvalidState;
            self.client_nonce = std.crypto.random.int(u64);
            self.connect_sent_at = self.getCurrentTime();
            self.state = .Connecting;
            if (!self.outgoing.pushBack(.{
                .addr = self.config.server_addr,
                .packet = .{ .ConnectionRequest = .{ .Secure = .{
                    .protocol_id = @truncate(self.config.protocol_id),
                    .client_nonce = self.client_nonce,
                    .token = token,
                } } },
            })) return ClientError.IoError;
        }

        /// Process a raw packet received from the server.
        pub fn handlePacket(self: *Self, buffer: []const u8) ClientError!void {
            if (buffer.len < pkt_size) return ClientError.InvalidPacket;
            const pkt = packet_mod.deserialize(opts, buffer[0..pkt_size].*);

            switch (pkt) {
                .Challenge => |challenge| {
                    if (self.state != .Connecting) return ClientError.InvalidPacket;
                    // Echo the challenge back immediately.
                    if (!self.outgoing.pushBack(.{
                        .addr = self.config.server_addr,
                        .packet = .{ .ConnectionResponse = .{
                            .sequence = challenge.sequence,
                            .token = challenge.token,
                        } },
                    })) return ClientError.IoError;
                    self.last_recv = self.getCurrentTime();
                    self.state = .Connected;
                    _ = self.events.pushBack(.Connected);
                },
                .Payload => |payload| {
                    if (self.state != .Connected) return ClientError.InvalidPacket;
                    self.last_recv = self.getCurrentTime();
                    _ = self.events.pushBack(.{ .PayloadReceived = payload });
                },
                .Disconnect => {
                    if (self.state != .Connected) return ClientError.InvalidPacket;
                    self.state = .Disconnected;
                    _ = self.events.pushBack(.Disconnected);
                },
                // Server-to-server or wrong-direction packets.
                .ConnectionRequest, .ConnectionResponse => return ClientError.InvalidPacket,
            }
        }

        /// Queue a payload to send to the server.
        pub fn sendPayload(self: *Self, body: [opts.max_payload_size]u8) ClientError!void {
            if (self.state != .Connected) return ClientError.InvalidState;
            if (!self.outgoing.pushBack(.{
                .addr = self.config.server_addr,
                .packet = .{ .Payload = .{ .body = body } },
            })) return ClientError.IoError;
        }

        /// Gracefully disconnect. Queues a Disconnect packet and transitions immediately.
        pub fn disconnect(self: *Self) void {
            if (self.state != .Connected) return;
            self.state = .Disconnected;
            _ = self.outgoing.pushBack(.{
                .addr = self.config.server_addr,
                .packet = .Disconnect,
            });
        }

        pub fn pollEvent(self: *Self) ?Event {
            return self.events.popFront();
        }

        pub fn pollOutgoing(self: *Self) ?Outgoing {
            return self.outgoing.popFront();
        }
    };
}
