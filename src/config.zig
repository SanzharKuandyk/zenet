const SECRET_KEY_SIZE = @import("root.zig").SECRET_KEY_SIZE;

pub const ServerConfig = struct {
    protocol_id: u64,
    handshake_alive_ms: u64,
    client_timeout_ms: u64,
    server_auth: ServerAuth,

    pub fn init(
        protocol_id: u64,
        handshake_alive_ms: u64,
        client_timeout_ms: u64,
        server_auth: ?ServerAuth,
    ) ServerConfig {
        const auth = server_auth orelse ServerAuth.AuthNotSecure;

        return .{
            .protocol_id = protocol_id,
            .handshake_alive_ms = handshake_alive_ms,
            .client_timeout_ms = client_timeout_ms,
            .server_auth = auth,
        };
    }
};

pub const ServerAuth = union(enum) {
    AuthSecure: AuthSecure,
    AuthNotSecure,
};

pub const AuthSecure = struct {
    secret_key: [SECRET_KEY_SIZE]u8,
};
