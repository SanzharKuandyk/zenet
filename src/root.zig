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
    /// User-provided ConnectToken type. `void` = use zenet's built-in default.
    ConnectToken: type = void,
};

pub const Client = @import("client/client.zig").Client;
pub const ClientConfig = @import("client/client.zig").ClientConfig;
pub const ClientError = @import("client/client.zig").ClientError;
pub const Server = @import("server/server.zig").Server;
pub const ServerConfig = @import("server/config.zig").ServerConfig;
pub const ServerError = @import("server/error.zig").ServerError;
pub const handshake = @import("handshake.zig");
