const std = @import("std");
const root = @import("../root.zig");
const connection_mod = @import("connection.zig");
const packet_mod = @import("../packet.zig");
const handshake = @import("../handshake.zig");
const Options = root.Options;
const AddressKey = @import("../addr.zig").AddressKey;
const ServerError = @import("error.zig").ServerError;
const ServerConfig = @import("config.zig").ServerConfig;
const RingQueue = @import("../ring_buffer.zig").RingQueue;
const RecentNonces = @import("../nonce.zig").RecentNonces;

const CHALLENGE_KEY_SIZE = root.CHALLENGE_KEY_SIZE;
const SECRET_KEY_SIZE = root.SECRET_KEY_SIZE;

pub fn Server(comptime opts: Options) type {
    comptime {
        if (opts.ConnectToken != void) {
            if (!@hasDecl(opts.ConnectToken, "verify"))
                @compileError("ConnectToken must have: pub fn verify(*const @This(), u64, *const [32]u8) bool");
            if (!@hasField(opts.ConnectToken, "user_data"))
                @compileError("ConnectToken must have: user_data: [opts.user_data_size]u8");
        }
    }

    const Conn = connection_mod.Connection(opts);
    const PendingConn = connection_mod.PendingConnection(opts);
    const Pkt = packet_mod.Packet(opts);
    const pkt_size = @sizeOf(Pkt);

    return struct {
        const Self = @This();

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
            PayloadReceived: struct {
                cid: u64,
                addr: std.net.Address,
                payload: packet_mod.Payload(opts),
            },
        };

        pub const Outgoing = struct {
            addr: std.net.Address,
            packet: Pkt,
        };

        allocator: std.mem.Allocator,

        protocol_id: u64,
        secure: bool,
        secret_key: ?[SECRET_KEY_SIZE]u8,
        public_addresses: []const std.net.Address,

        recent_nonces: RecentNonces(opts.nonce_window),

        challenge_key: [CHALLENGE_KEY_SIZE]u8,
        challenge_seq: u64,

        config: ServerConfig,

        start_time: std.time.Instant,
        current_time: std.time.Instant,

        clients: [opts.max_clients]?Conn,
        recycled_slots: std.ArrayList(u64), // disconnected slots available for reuse
        slot_cursor: u64, // high-water mark: next never-used index in clients[]
        pending: std.AutoArrayHashMap(AddressKey, PendingConn),

        outgoing: RingQueue(Outgoing, opts.outgoing_queue_size),
        events: RingQueue(Event, opts.events_queue_size),

        pub fn init(allocator: std.mem.Allocator, config: ServerConfig) !Self {
            return .{
                .allocator = allocator,
                .protocol_id = config.protocol_id,
                .secure = config.secure,
                .secret_key = config.secret_key,
                .public_addresses = config.public_addresses,
                .recent_nonces = RecentNonces(opts.nonce_window).init(allocator),
                .challenge_key = config.challenge_key,
                .challenge_seq = 0,
                .config = config,
                .start_time = try std.time.Instant.now(),
                .current_time = try std.time.Instant.now(),
                .clients = [_]?Conn{null} ** opts.max_clients,
                .recycled_slots = .empty,
                .slot_cursor = 0,
                .pending = std.AutoArrayHashMap(AddressKey, PendingConn).init(allocator),
                .outgoing = .{},
                .events = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.pending.deinit();
            self.recycled_slots.deinit(self.allocator);
            self.recent_nonces.deinit();
        }

        pub fn getCurrentTime(self: *const Self) u64 {
            return self.current_time.since(self.start_time);
        }

        pub fn update(self: *Self, now: std.time.Instant) !void {
            self.current_time = now;

            var to_remove: std.ArrayList(AddressKey) = .empty;
            defer to_remove.deinit(self.allocator);

            var it = self.pending.iterator();
            while (it.next()) |entry| {
                if (self.getCurrentTime() > entry.value_ptr.expires_at) {
                    try to_remove.append(self.allocator, entry.key_ptr.*);
                }
            }
            for (to_remove.items) |key| {
                _ = self.pending.swapRemove(key);
            }
        }

        pub fn pollEvent(self: *Self) ?Event {
            return self.events.popFront();
        }

        pub fn pollOutgoing(self: *Self) ?Outgoing {
            return self.outgoing.popFront();
        }

        pub fn handlePacket(self: *Self, addr: std.net.Address, buffer: []const u8) (ServerError || error{OutOfMemory})!void {
            if (buffer.len < pkt_size) return ServerError.InvalidPacket;
            const pkt = packet_mod.deserialize(opts, buffer[0..pkt_size].*);

            switch (pkt) {
                .ConnectionRequest => |req| {
                    const Fields = struct {
                        protocol_id: u32,
                        client_nonce: u64,
                        user_data: ?[opts.user_data_size]u8,
                    };
                    const fields: Fields = switch (req) {
                        .Plain => |r| blk: {
                            if (self.secure) return ServerError.InvalidPacket;
                            break :blk .{ .protocol_id = r.protocol_id, .client_nonce = r.client_nonce, .user_data = null };
                        },
                        .Secure => |r| blk: {
                            if (!self.secure) return ServerError.InvalidPacket;
                            if (!r.token.verify(self.getCurrentTime(), &self.secret_key.?)) return ServerError.InvalidPacket;
                            break :blk .{ .protocol_id = r.protocol_id, .client_nonce = r.client_nonce, .user_data = r.token.user_data };
                        },
                    };

                    if (self.protocol_id != fields.protocol_id) return ServerError.InvalidProtocolId;
                    if (self.recent_nonces.contains(fields.client_nonce)) return ServerError.InvalidPacket;
                    _ = try self.recent_nonces.insert(fields.client_nonce);

                    const cid: u64 = if (self.recycled_slots.pop()) |slot| slot else blk: {
                        if (self.slot_cursor >= opts.max_clients) return ServerError.ServerFull;
                        const s = self.slot_cursor;
                        self.slot_cursor += 1;
                        break :blk s;
                    };

                    self.challenge_seq += 1;
                    const expires_at = self.getCurrentTime() + self.config.handshake_alive_ms;
                    const token = handshake.generateChallengeToken(
                        &self.challenge_key,
                        cid,
                        fields.client_nonce,
                        self.challenge_seq,
                        expires_at,
                    );

                    const gop = try self.pending.getOrPut(AddressKey.fromAddress(addr));
                    if (gop.found_existing) return ServerError.InvalidPacket;
                    gop.value_ptr.* = PendingConn{
                        .cid = cid,
                        .client_nonce = fields.client_nonce,
                        .sequence = self.challenge_seq,
                        .expires_at = expires_at,
                        .user_data = fields.user_data,
                    };

                    if (!self.outgoing.pushBack(.{
                        .addr = addr,
                        .packet = .{ .Challenge = .{ .sequence = self.challenge_seq, .expires_at = expires_at, .token = token } },
                    })) return ServerError.IoError;
                },
                .ConnectionResponse => |resp| {
                    const pending = self.pending.get(AddressKey.fromAddress(addr)) orelse return ServerError.UnknownClient;

                    const valid = handshake.verifyChallengeToken(
                        resp.token,
                        &self.challenge_key,
                        pending.cid,
                        pending.client_nonce,
                        resp.sequence,
                        pending.expires_at,
                    );
                    if (!valid) return ServerError.InvalidPacket;

                    _ = self.pending.swapRemove(AddressKey.fromAddress(addr));

                    self.clients[@intCast(pending.cid)] = Conn{
                        .cid = pending.cid,
                        .addr = addr,
                        .last_recv = self.getCurrentTime(),
                        .last_send = 0,
                        .user_data = pending.user_data,
                    };

                    if (!self.events.pushBack(.{
                        .ClientConnected = .{ .cid = pending.cid, .addr = addr, .user_data = pending.user_data },
                    })) return ServerError.IoError;
                },
                .Payload => |payload| {
                    const i = self.findClientByAddr(addr) orelse return ServerError.UnknownClient;
                    const conn = self.clients[i].?;
                    if (!self.events.pushBack(.{
                        .PayloadReceived = .{ .cid = conn.cid, .addr = conn.addr, .payload = payload },
                    })) return ServerError.IoError;
                },
                .Disconnect => {
                    const i = self.findClientByAddr(addr) orelse return ServerError.UnknownClient;
                    const conn = self.clients[i].?;
                    self.clients[i] = null;
                    try self.recycled_slots.append(self.allocator, i);
                    if (!self.events.pushBack(.{
                        .ClientDisconnected = .{ .cid = conn.cid, .addr = addr },
                    })) return ServerError.IoError;
                },

                .Challenge => return ServerError.InvalidPacket,
            }
        }

        fn findClientByAddr(self: *const Self, addr: std.net.Address) ?usize {
            const key = AddressKey.fromAddress(addr);
            for (self.clients, 0..) |maybe_conn, i| {
                const conn = maybe_conn orelse continue;
                if (AddressKey.eql(AddressKey.fromAddress(conn.addr), key)) return i;
            }
            return null;
        }
    };
}
