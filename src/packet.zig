// 1. (client) ConnectionRequest
// 2. (server) Challenge
// 3. (client) ConnectionResponse

const ServerError = @import("error.zig");
const USER_DATA_SIZE = @import("zenet").USER_DATA_SIZE;
const CHALLENGE_KEY_SIZE = @import("zenet").CHALLENGE_KEY_SIZE;

pub const ChallengeToken = [16]u8;

// (unused) PacketKind to determine packet type
pub const PacketKind = enum(u8) {
    ConnectionRequest = 0,
    Challenge = 1,
    ConnectionResponse = 2,
    Payload = 3,
    Disconnect = 4,
};

// Packet type
pub const Packet = union(enum) {
    ConnectionRequest: ConnectionRequest,
    Challenge: Challenge,
    ConnectionResponse: ConnectionResponse,
    Payload: Payload,
    Disconnect,

    pub fn generateChallenge(
        cid: u64,
        user_data: *[USER_DATA_SIZE]u8,
        challenge_seq: u64,
        challenge_key: *[CHALLENGE_KEY_SIZE]u8,
    ) ServerError!Challenge {}
};

pub const PacketBytes = [@sizeOf(Packet)]u8;

pub fn serialize(p: Packet) PacketBytes {
    return @bitCast(p);
}

pub fn deserialize(bytes: PacketBytes) Packet {
    return @bitCast(bytes);
}

pub const ConnectionRequest = struct {
    client_nonce: u64,
    protocol_id: u32,
    expires_at: u64,
    user_data: [USER_DATA_SIZE]u8,
};

pub const Challenge = struct {
    sequence: u64,
    token: ChallengeToken,
};

pub const ConnectionResponse = struct {
    sequence: u64,
    token: ChallengeToken,
};

pub const Payload = struct {
    body: [1024]u8,
};
