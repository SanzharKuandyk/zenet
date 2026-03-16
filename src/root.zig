// Crypto constants — fixed by algorithm choice, not user-configurable
pub const SECRET_KEY_SIZE = 32;
pub const CHALLENGE_KEY_SIZE = 32;

/// Single comptime config shared by both Server and (future) Client.
/// Both sides must use identical options — the wire format depends on it.
pub const Options = struct {
    max_clients: usize = 1024,
    nonce_window: usize = 256,
    outgoing_queue_size: usize = 256,
    events_queue_size: usize = 256,
    user_data_size: usize = 256,
    max_payload_size: usize = 1024,
};

pub const ClientId = @import("connection.zig").ClientId;
pub const Server = @import("server.zig").Server;
pub const ServerConfig = @import("config.zig").ServerConfig;
pub const ServerError = @import("error.zig").ServerError;
pub const handshake = @import("handshake.zig");
