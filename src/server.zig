const std = @import("std");
const root = @import("root.zig");
const areion = @import("areion");
const Conn = @import("connection.zig").Connection;
const PendingConn = @import("connection.zig").PendingConnection;
const Packet = @import("packet.zig").Packet;
const Challenge = @import("packet.zig").Challenge;
const ConnectionResponse = @import("packet.zig").ConnectionResponse;
const ServerError = @import("error.zig").ServerError;
const ServerConfig = @import("config.zig").ServerConfig;
const RecentNonces = @import("protection.zig").RecentNonces;

const MAX_CLIENTS = root.MAX_CLIENTS;
const NONCE_WINDOW = root.NONCE_WINDOW;
const CHALLENGE_KEY_SIZE = root.CHALLENGE_KEY_SIZE;
const SECRET_KEY_SIZE = root.SECRET_KEY_SIZE;
const USER_DATA_SIZE = root.USER_DATA_SIZE;

const deserialize = @import("packet.zig").deserialize;

pub const ServerEvent = union(enum) {
    ClientConnected,
    ClientDisconnected,
};

pub const Server = struct {
    protocol_id: u64,
    secure: bool,
    secret_key: ?[SECRET_KEY_SIZE]u8,
    public_addresses: std.ArrayList(std.net.Address),
    start_time: std.time.Instant,
    current_time: std.time.Instant,
    clients: [MAX_CLIENTS]?Conn,
    // What type should be here?
    free_slots: std.ArrayList(u32),
    // free slot in clients array
    next_free_slot: u32,
    // pending handshakes (addr, cid)
    pending: std.AutoArrayHashMap(AddressKey, PendingConn),
    // recent nonces
    recent_nonces: RecentNonces(NONCE_WINDOW),
    challenge_seq: u64,
    config: ServerConfig,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: ServerConfig) !Server {
        return .{
            .allocator = allocator,
            .protocol_id = config.protocol_id,
            .secure = config.secure,
            .secret_key = config.secret_key,
            .public_addresses = config.public_addresses,
            .start_time = try std.time.Instant.now(),
            .current_time = try std.time.Instant.now(),
            .clients = undefined,
            .free_slots = .empty,
            .next_free_slot = 0,
            .pending = std.AutoArrayHashMap(AddressKey, PendingConn).init(allocator),
            .recent_nonces = RecentNonces(NONCE_WINDOW).init(allocator),
            .challenge_seq = 0,
            .config = config,
        };
    }

    pub fn getCurrentTime(self: *const Server) u64 {
        return self.current_time.since(self.start_time);
    }

    pub fn update(self: *Server) !void {
        self.current_time = try std.time.Instant.now();

        var to_remove: std.ArrayList(AddressKey) = .empty;
        defer to_remove.deinit(self.allocator);

        var it = self.pending.iterator();
        while (it.next()) |entry| {
            if (self.getCurrentTime() > entry.value_ptr.expires_at) {
                try to_remove.append(self.allocator, entry.key_ptr.*);
            }
        }

        for (to_remove.items) |addr| {
            _ = self.pending.swapRemove(addr);
        }

        std.debug.print("Updated", .{});
    }

    pub fn handlePacket(self: *Server, addr: std.net.Address, buffer: []u8) ServerError!Packet {
        const pkt = deserialize(buffer);

        switch (pkt) {
            .ConnectionRequest => |req| {
                if (self.protocol_id != req.protocol_id) {
                    return ServerError.InvalidProtocolId;
                }

                if (self.get_current_time() > req.expires_at) {
                    return ServerError.Expired;
                }

                if (self.recent_nonces.contains(req.client_nonce)) {
                    return ServerError.InvalidPacket;
                }
                self.recent_nonces.insert(req.client_nonce);

                var cid = undefined;
                const free_slot = self.free_slots.pop();
                if (free_slot) |slot| {
                    cid = slot;
                } else {
                    cid = self.next_free_slot;
                    self.next_free_slot += 1;

                    if (self.next_free_slot > MAX_CLIENTS) {
                        return ServerError.ServerFull;
                    }
                }

                self.challenge_seq += 1;
                const expires_at = self.getCurrentTime() + self.config.handshake_alive_ms;
                const challenge = Packet.generateChallenge(
                    &self.secret_key,
                    cid,
                    req.client_nonce,
                    self.challenge_seq,
                    expires_at,
                );

                const gop = try self.pending.getOrPut(AddressKey.fromAddress(addr));
                if (!gop.found_existing) {
                    gop.value_ptr.* = PendingConn{
                        .cid = cid,
                        .client_nonce = req.client_nonce,
                        .sequence = self.challenge_seq,
                        .expires_at = expires_at,
                    };
                } else {
                    std.debug.print("pending already had value: {s}\n", .{gop.value_ptr.*});
                    return ServerError.InvalidPacket;
                }

                return challenge;
            },
            .ConnectionResponse => |resp| {
                if (self.pending.get(addr)) |pending| {
                    verifyConnectResponse(
                        self.secret_key,
                        pending.cid,
                        pending.client_nonce,
                        resp,
                    );
                } else {
                    return ServerError.UnknownClient;
                }
            },
            .Payload => |payload| {
                payload;
            },
            .Disconnect => {},

            else => {
                // something
            },
        }
    }

    pub fn deinit(self: *Server) void {
        self.pending.deinit();
        self.free_slots.deinit(self.allocator);
        self.recent_nonces.deinit(self.allocator);
    }
};

fn verifyConnectResponse(
    secret_key: *const [SECRET_KEY_SIZE]u8,
    cid: u64,
    client_nonce: u64,
    resp: ConnectionResponse,
) bool {
    const expected = Packet.generateChallenge(
        secret_key,
        cid,
        client_nonce,
        resp.sequence,
    );

    return std.crypto.timing_safe.eql(
        u8,
        expected.token[0..],
        resp.token[0..],
    );
}

const AddressKey = struct {
    ip: [16]u8, // IPv4 mapped into IPv6 or raw IPv6
    port: u16,

    pub fn fromAddress(addr: std.net.Address) AddressKey {
        var out: AddressKey = .{
            .ip = [_]u8{0} ** 16,
            .port = 0,
        };

        switch (addr.any.family) {
            std.os.AF.INET => {
                // 0000:0000:0000:0000:0000:ffff:XXXX:XXXX
                const a = addr.in;
                out.ip[10] = 0xff;
                out.ip[11] = 0xff;
                @memcpy(out.ip[12..16], std.mem.asBytes(&a.sa.addr));
                out.port = std.mem.bigToNative(u16, a.sa.port);
            },
            std.os.AF.INET6 => {
                const a = addr.in6;
                @memcpy(out.ip[0..16], &a.sa.addr);
                out.port = std.mem.bigToNative(u16, a.sa.port);
            },
            else => unreachable,
        }

        return out;
    }

    pub fn hash(self: AddressKey) u64 {
        return std.hash.Wyhash.hash(0, std.mem.asBytes(&self));
    }

    pub fn eql(a: AddressKey, b: AddressKey) bool {
        return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
    }
};
