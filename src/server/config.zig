const std = @import("std");

const CHALLENGE_KEY_SIZE = @import("../root.zig").CHALLENGE_KEY_SIZE;
const SECRET_KEY_SIZE = @import("../root.zig").SECRET_KEY_SIZE;

pub const ServerConfig = struct {
    protocol_id: u32,
    handshake_alive_ns: u64,
    client_timeout_ns: u64,
    public_addresses: []const std.net.Address,
    secure: bool,
    challenge_key: [CHALLENGE_KEY_SIZE]u8,
    secret_key: ?[SECRET_KEY_SIZE]u8,

    pub fn init(
        protocol_id: u32,
        handshake_alive_ns: u64,
        client_timeout_ns: u64,
        public_addresses: []const std.net.Address,
        secure: bool,
        challenge_key: [CHALLENGE_KEY_SIZE]u8,
        secret_key: ?[SECRET_KEY_SIZE]u8,
    ) ServerConfig {
        return .{
            .protocol_id = protocol_id,
            .handshake_alive_ns = handshake_alive_ns,
            .client_timeout_ns = client_timeout_ns,
            .public_addresses = public_addresses,
            .secure = secure,
            .challenge_key = challenge_key,
            .secret_key = secret_key,
        };
    }
};
