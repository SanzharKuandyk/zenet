// 1. (client) ConnectionRequest
// 2. (server) Challenge
// 3. (client) ConnectionResponse

const std = @import("std");
const ServerError = @import("error.zig");
const ConnectToken = @import("protection.zig").ConnectToken;
const CHALLENGE_KEY_SIZE = @import("root.zig").CHALLENGE_KEY_SIZE;
const SECRET_KEY_SIZE = @import("root.zig").SECRET_KEY_SIZE;
const MAX_PAYLOAD_SIZE = @import("root.zig").MAX_PAYLOAD_SIZE;

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
        secret_key: *const [SECRET_KEY_SIZE]u8,
        cid: u64,
        client_nonce: u64,
        challenge_seq: u64,
        expires_at: u64,
    ) Challenge {
        const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

        var msg: [8 + 8 + 8 + 8]u8 = undefined;
        var i: usize = 0;

        std.mem.writeInt(u64, msg[i..][0..8], cid, .big);
        i += 8;

        std.mem.writeInt(u64, msg[i..][0..8], client_nonce, .big);
        i += 8;

        std.mem.writeInt(u64, msg[i..][0..8], challenge_seq, .big);
        i += 8;

        std.mem.writeInt(u64, msg[i..][0..8], expires_at, .big);
        i += 8;

        var full_mac: [HmacSha256.mac_length]u8 = undefined;
        HmacSha256.create(full_mac[0..], msg[0..i], secret_key[0..]);

        var token: ChallengeToken = undefined;
        @memcpy(token[0..], full_mac[0..token.len]); // truncate to 16 bytes

        return .{
            .sequence = challenge_seq,
            .expires_at = expires_at,
            .token = token,
        };
    }
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
    // Optional ConnectToken 
    // depends on secure config
    token: ?ConnectToken,
};

pub const Challenge = struct {
    sequence: u64,
    expires_at: u64,
    token: ChallengeToken,
};

pub const ConnectionResponse = struct {
    sequence: u64,
    token: ChallengeToken,
};

pub const Payload = struct {
    body: [MAX_PAYLOAD_SIZE]u8,
};
