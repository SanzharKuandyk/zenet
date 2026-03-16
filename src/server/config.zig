const std = @import("std");

const CHALLENGE_KEY_SIZE = @import("../root.zig").CHALLENGE_KEY_SIZE;
const SECRET_KEY_SIZE = @import("../root.zig").SECRET_KEY_SIZE;

pub const ServerConfig = struct {
    protocol_id: u64,
    handshake_alive_ms: u64,
    client_timeout_ms: u64,
    public_addresses: []const std.net.Address,
    secure: bool,
    challenge_key: [CHALLENGE_KEY_SIZE]u8,
    secret_key: ?[SECRET_KEY_SIZE]u8,

    pub fn init(
        protocol_id: u64,
        handshake_alive_ms: u64,
        client_timeout_ms: u64,
        public_addresses: []const std.net.Address,
        secure: bool,
        challenge_key: [CHALLENGE_KEY_SIZE]u8,
        secret_key: ?[SECRET_KEY_SIZE]u8,
    ) ServerConfig {
        return .{
            .protocol_id = protocol_id,
            .handshake_alive_ms = handshake_alive_ms,
            .client_timeout_ms = client_timeout_ms,
            .public_addresses = public_addresses,
            .secure = secure,
            .challenge_key = challenge_key,
            .secret_key = secret_key,
        };
    }
};
