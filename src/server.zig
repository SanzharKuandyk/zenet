const std = @import("std");
const areion = @import("areion");
const zenet = @import("zenet");
const Conn = @import("connection.zig").Connection;
const Packet = @import("packet.zig").Packet;
const Challenge = @import("packet.zig").Challenge;
const ServerError = @import("error.zig").ServerError;
const RecentNonces = @import("protection.zig").RecentNonces;

const deserialize = @import("packet.zig").deserialize;

pub const ServerConfig = struct {
    protocol_id: u64,
    handshake_alive_ms: u64,
};

pub const ServerEvent = union(enum) {
    ClientConnected,
    ClientDisconnected,
};

pub const Server = struct {
    protocol_id: u64,
    start_time: std.time.Instant,
    current_time: std.time.Instant,
    clients: [zenet.MAX_CLIENTS]?Conn,
    // What type should be here?
    free_slots: std.ArrayList(u32),
    // free slot in clients array
    next_free_slot: ?u32,
    // pending handshakes (addr, cid)
    pending: std.AutoArrayHashMap(std.net.Address, u64),
    // recent nonces
    recent_nonces: RecentNonces(zenet.NONCE_WINDOW),
    challenge_seq: u64,
    challenge_key: [zenet.CHALLENGE_KEY_SIZE]u8,

    pub fn init(allocator: std.mem.Allocator, config: ServerConfig) !Server {
        var ckey: [zenet.CHALLENGE_KEY_SIZE]u8 = undefined;
        std.crypto.random.bytes(&ckey);

        return .{
            .protocol_id = config.protocol_id,
            .start_time = try std.time.Instant.now(),
            .current_time = try std.time.Instant.now(),
            .clients = undefined,
            .free_slots = std.ArrayList(u32).init(allocator),
            .next_free_slot = 0,
            .pending = std.AutoArrayHashMap(std.net.Address, u64).init(allocator),
            .recent_nonces = RecentNonces(zenet.NONCE_WINDOW).init(allocator),
            .challenge_seq = 0,
            .challenge_key = ckey,
        };
    }

    pub fn getCurrentTime(self: *const Server) u64 {
        return self.current_time.since(self.start_time);
    }

    pub fn update(self: *Server) !void {
        self.current_time = try std.time.Instant.now();
    }

    pub fn handlePacket(self: *Server, addr: std.net.Address, buffer: []u8) ServerError!void {
        const p = deserialize(buffer);

        switch (p) {
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

                self.challenge_seq += 1;
                const challenge = try Packet.generateChallenge(cid, user_data, challenge_seq, challenge_key);
            },
            .Payload => |payload| {
                payload;
            },
            .Disconnect => {},
        }
    }

    pub fn deinit(self: *Server) void {
        self.pending.deinit();
        self.free_slots.deinit();
        self.recent_nonces.deinit();
    }
};
