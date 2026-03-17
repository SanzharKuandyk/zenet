// Handshake flow:
// 1. (client) ConnectionRequest
// 2. (server) Challenge
// 3. (client) ConnectionResponse

const std = @import("std");
const handshake = @import("handshake.zig");
const Options = @import("root.zig").Options;

pub const ChallengeToken = handshake.ChallengeToken;

pub fn Packet(comptime opts: Options) type {
    return union(enum) {
        ConnectionRequest: ConnectionRequest(opts),
        Challenge: Challenge,
        ConnectionResponse: ConnectionResponse,
        Payload: Payload(opts),
        Disconnect,
    };
}

pub fn serialize(comptime opts: Options, p: Packet(opts)) [@sizeOf(Packet(opts))]u8 {
    return std.mem.toBytes(p);
}

pub fn deserialize(comptime opts: Options, bytes: [@sizeOf(Packet(opts))]u8) Packet(opts) {
    return std.mem.bytesToValue(Packet(opts), &bytes);
}

pub fn ConnectionRequest(comptime opts: Options) type {
    return union(enum) {
        Plain: PlainConnectionRequest,
        Secure: SecureConnectionRequest(opts),
    };
}

pub const PlainConnectionRequest = struct {
    protocol_id: u32,
    client_nonce: u64,
};

pub fn SecureConnectionRequest(comptime opts: Options) type {
    const TokenType = if (opts.ConnectToken == void)
        handshake.DefaultConnectToken(opts.user_data_size)
    else
        opts.ConnectToken;
    return struct {
        protocol_id: u32,
        client_nonce: u64,
        token: TokenType,
    };
}

pub const Challenge = struct {
    sequence: u64,
    expires_at: u64,
    token: ChallengeToken,
};

pub const ConnectionResponse = struct {
    sequence: u64,
    token: ChallengeToken,
};

pub fn Payload(comptime opts: Options) type {
    return struct {
        sequence: u64,
        body: [opts.max_payload_size]u8,
    };
}
