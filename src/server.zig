const std = @import("std");
const Conn = @import("connection.zig").Connection;
const Packet = @import("packet.zig").Packet;
const ServerError = @import("error.zig").ServerError;
const RecentNonces = @import("protection.zig").RecentNonces;

pub const MAX_CLIENTS = 1024;
pub const NONCE_WINDOW = 256;

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
    clients: [MAX_CLIENTS]?Conn,
    // What type should be here?
    free_slots: std.ArrayList(u32),
    // free slot in clients array
    next_free_slot: ?u32,
    // pending handshakes (addr, cid)
    pending: std.AutoArrayHashMap(std.net.Address, u64),
    // recent nonces
    recent_nonces: RecentNonces(NONCE_WINDOW),

    pub fn init(allocator: std.mem.Allocator, config: ServerConfig) !Server {
        return .{
            .protocol_id = config.protocol_id,
            .start_time = try std.time.Instant.now(),
            .current_time = try std.time.Instant.now(),
            .clients = undefined,
            .free_slots = std.ArrayList(u32).init(allocator),
            .next_free_slot = 0,
            .pending = std.AutoArrayHashMap(std.net.Address, u64).init(allocator),
            .recent_nonces = RecentNonces(NONCE_WINDOW).init(allocator),
        };
    }

    pub fn get_current_time(self: *const Server) u64 {
        return self.current_time.since(self.start_time);
    }

    pub fn update(self: *Server) !void {
        self.current_time = try std.time.Instant.now();
    }

    pub fn handle_packet(self: *Server, p: Packet) ServerError!void {
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
