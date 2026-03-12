// PacketKind to determine packet type
pub const PacketKind = enum(u8) {
    ConnectionRequest = 0,
    Payload = 1,
    Disconnect = 2,
};

// Packet type
pub const Packet = union(enum) {
    ConnectionRequest: ConnectionRequest,
    Payload: Payload,
    Disconnect,
};

pub const ConnectionRequest = struct {
    client_nonce: u64,
    protocol_id: u32,
    expires_at: u64,
};

pub const Payload = struct {
    body: [1024]u8,
};
