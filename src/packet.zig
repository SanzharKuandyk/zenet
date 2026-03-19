// Handshake flow:
// 1. (client) ConnectionRequest
// 2. (server) Challenge
// 3. (client) ConnectionResponse
// 4. (server) ConnectionAccepted

const std = @import("std");
const handshake = @import("handshake.zig");
const root = @import("root.zig");
const validation = @import("validation/root.zig");
const Options = root.Options;

pub const ChallengeToken = handshake.ChallengeToken;
pub const PROTOCOL_VERSION: u8 = 1;

// Wire format:
//   byte 0   = protocol version
//   byte 1   = packet kind
//   bytes 2+ = kind-specific payload, all integer fields big-endian
//
// Packet layouts:
//   ConnectionRequestPlain  = [ver:u8][kind:u8][protocol_id:u32][client_nonce:u64]
//   ConnectionRequestSecure = [ver:u8][kind:u8][protocol_id:u32][client_nonce:u64][token]
//   Challenge               = [ver:u8][kind:u8][sequence:u64][expires_at:u64][token:16]
//   ConnectionResponse      = [ver:u8][kind:u8][sequence:u64][token:16]
//   ConnectionAccepted      = [ver:u8][kind:u8]
//   Payload                 = [ver:u8][kind:u8][len:u16][body:len]
//   Disconnect              = [ver:u8][kind:u8]
const PacketKind = enum(u8) {
    ConnectionRequestPlain = 1,
    ConnectionRequestSecure = 2,
    Challenge = 3,
    ConnectionResponse = 4,
    ConnectionAccepted = 5,
    Payload = 6,
    Disconnect = 7,
};

fn TokenType(comptime opts: Options) type {
    return if (opts.ConnectToken == void)
        handshake.DefaultConnectToken(opts.user_data_size, opts.max_token_addresses)
    else
        opts.ConnectToken;
}

pub fn Packet(comptime opts: Options) type {
    comptime validation.options.validate(opts);

    return union(enum) {
        ConnectionRequest: ConnectionRequest(opts),
        Challenge: Challenge,
        ConnectionResponse: ConnectionResponse,
        ConnectionAccepted,
        Payload: Payload(opts),
        Disconnect,
    };
}

pub fn maxPacketSize(comptime opts: Options) usize {
    comptime validation.options.validate(opts);

    const token_wire_size = TokenType(opts).wire_size;
    // Worst-case packet is the secure connection request because the token size
    // is user-configurable, but payload packets cap out at max_payload_size.
    return @max(
        14 + token_wire_size,
        @max(34, @max(26, 4 + opts.max_payload_size)),
    );
}

pub fn serialize(comptime opts: Options, p: Packet(opts), out: []u8) error{ BufferTooSmall, PayloadTooLarge }!usize {
    comptime validation.options.validate(opts);

    if (out.len < maxPacketSize(opts)) return error.BufferTooSmall;

    out[0] = PROTOCOL_VERSION;
    switch (p) {
        .ConnectionRequest => |req| switch (req) {
            .Plain => |plain| {
                out[1] = @intFromEnum(PacketKind.ConnectionRequestPlain);
                std.mem.writeInt(u32, out[2..6], plain.protocol_id, .big);
                std.mem.writeInt(u64, out[6..14], plain.client_nonce, .big);
                return 14;
            },
            .Secure => |secure| {
                const Token = TokenType(opts);
                out[1] = @intFromEnum(PacketKind.ConnectionRequestSecure);
                std.mem.writeInt(u32, out[2..6], secure.protocol_id, .big);
                std.mem.writeInt(u64, out[6..14], secure.client_nonce, .big);
                const token_out: *[Token.wire_size]u8 = @ptrCast(out[14 .. 14 + Token.wire_size]);
                secure.token.encode(token_out);
                return 14 + Token.wire_size;
            },
        },
        .Challenge => |challenge| {
            out[1] = @intFromEnum(PacketKind.Challenge);
            std.mem.writeInt(u64, out[2..10], challenge.sequence, .big);
            std.mem.writeInt(u64, out[10..18], challenge.expires_at, .big);
            @memcpy(out[18..34], challenge.token[0..]);
            return 34;
        },
        .ConnectionResponse => |resp| {
            out[1] = @intFromEnum(PacketKind.ConnectionResponse);
            std.mem.writeInt(u64, out[2..10], resp.sequence, .big);
            @memcpy(out[10..26], resp.token[0..]);
            return 26;
        },
        .ConnectionAccepted => {
            out[1] = @intFromEnum(PacketKind.ConnectionAccepted);
            return 2;
        },
        .Payload => |payload| {
            if (payload.len > opts.max_payload_size) return error.PayloadTooLarge;
            out[1] = @intFromEnum(PacketKind.Payload);
            std.mem.writeInt(u16, out[2..4], payload.len, .big);
            @memcpy(out[4 .. 4 + payload.len], payload.body[0..payload.len]);
            return 4 + payload.len;
        },
        .Disconnect => {
            out[1] = @intFromEnum(PacketKind.Disconnect);
            return 2;
        },
    }
}

pub fn deserialize(comptime opts: Options, bytes: []const u8) error{ InvalidPacket, UnsupportedVersion }!Packet(opts) {
    comptime validation.options.validate(opts);

    if (bytes.len < 2) return error.InvalidPacket;
    if (bytes[0] != PROTOCOL_VERSION) return error.UnsupportedVersion;

    const kind: PacketKind = std.meta.intToEnum(PacketKind, bytes[1]) catch return error.InvalidPacket;
    switch (kind) {
        .ConnectionRequestPlain => {
            if (bytes.len != 14) return error.InvalidPacket;
            return .{ .ConnectionRequest = .{ .Plain = .{
                .protocol_id = std.mem.readInt(u32, bytes[2..6], .big),
                .client_nonce = std.mem.readInt(u64, bytes[6..14], .big),
            } } };
        },
        .ConnectionRequestSecure => {
            const Token = TokenType(opts);
            if (bytes.len != 14 + Token.wire_size) return error.InvalidPacket;
            const token_bytes: *const [Token.wire_size]u8 = @ptrCast(bytes[14 .. 14 + Token.wire_size]);
            const token = Token.decode(token_bytes) orelse return error.InvalidPacket;
            return .{ .ConnectionRequest = .{ .Secure = .{
                .protocol_id = std.mem.readInt(u32, bytes[2..6], .big),
                .client_nonce = std.mem.readInt(u64, bytes[6..14], .big),
                .token = token,
            } } };
        },
        .Challenge => {
            if (bytes.len != 34) return error.InvalidPacket;
            var token: ChallengeToken = undefined;
            @memcpy(token[0..], bytes[18..34]);
            return .{ .Challenge = .{
                .sequence = std.mem.readInt(u64, bytes[2..10], .big),
                .expires_at = std.mem.readInt(u64, bytes[10..18], .big),
                .token = token,
            } };
        },
        .ConnectionResponse => {
            if (bytes.len != 26) return error.InvalidPacket;
            var token: ChallengeToken = undefined;
            @memcpy(token[0..], bytes[10..26]);
            return .{ .ConnectionResponse = .{
                .sequence = std.mem.readInt(u64, bytes[2..10], .big),
                .token = token,
            } };
        },
        .ConnectionAccepted => {
            if (bytes.len != 2) return error.InvalidPacket;
            return .ConnectionAccepted;
        },
        .Payload => {
            if (bytes.len < 4) return error.InvalidPacket;
            const len = std.mem.readInt(u16, bytes[2..4], .big);
            if (len > opts.max_payload_size) return error.InvalidPacket;
            if (bytes.len != 4 + len) return error.InvalidPacket;

            var body: [opts.max_payload_size]u8 = undefined;
            @memcpy(body[0..len], bytes[4 .. 4 + len]);
            return .{ .Payload = .{
                .len = len,
                .body = body,
            } };
        },
        .Disconnect => {
            if (bytes.len != 2) return error.InvalidPacket;
            return .Disconnect;
        },
    }
}

pub fn ConnectionRequest(comptime opts: Options) type {
    comptime validation.options.validate(opts);

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
    comptime validation.options.validate(opts);

    return struct {
        protocol_id: u32,
        client_nonce: u64,
        token: TokenType(opts),
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
    comptime validation.options.validate(opts);

    return struct {
        len: u16,
        body: [opts.max_payload_size]u8,
    };
}
