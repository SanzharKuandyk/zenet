const std = @import("std");
const AddressKey = @import("addr.zig").AddressKey;
const SECRET_KEY_SIZE = @import("root.zig").SECRET_KEY_SIZE;
const CHALLENGE_KEY_SIZE = @import("root.zig").CHALLENGE_KEY_SIZE;

/// Compile-time validation that T implements the ConnectToken interface:
///
///   pub fn verify(*const T, u64, *const [32]u8) bool
///   user_data: [user_data_size]u8
///
/// Call inside a `comptime { }` block.
pub fn validateConnectTokenInterface(comptime T: type, comptime user_data_size: usize) void {
    // verify(*const T, u64, *const [SECRET_KEY_SIZE]u8) bool
    if (!@hasDecl(T, "verify"))
        @compileError("ConnectToken must have: pub fn verify(*const @This(), u64, *const [32]u8) bool");
    switch (@typeInfo(@TypeOf(T.verify))) {
        .@"fn" => |fi| {
            if (fi.params.len != 3)
                @compileError("ConnectToken.verify must take exactly 3 parameters: (*const @This(), u64, *const [32]u8)");
            const p0 = fi.params[0].type orelse
                @compileError("ConnectToken.verify param[0] must be a concrete type (*const @This())");
            if (p0 != *const T)
                @compileError("ConnectToken.verify param[0] must be *const @This(), got " ++ @typeName(p0));
            const p1 = fi.params[1].type orelse
                @compileError("ConnectToken.verify param[1] must be u64");
            if (p1 != u64)
                @compileError("ConnectToken.verify param[1] must be u64, got " ++ @typeName(p1));
            const p2 = fi.params[2].type orelse
                @compileError("ConnectToken.verify param[2] must be *const [32]u8");
            if (p2 != *const [SECRET_KEY_SIZE]u8)
                @compileError("ConnectToken.verify param[2] must be *const [32]u8, got " ++ @typeName(p2));
            const ret = fi.return_type orelse
                @compileError("ConnectToken.verify return type must be bool");
            if (ret != bool)
                @compileError("ConnectToken.verify must return bool, got " ++ @typeName(ret));
        },
        else => @compileError("ConnectToken.verify must be a function"),
    }

    // user_data: [user_data_size]u8
    if (!@hasField(T, "user_data"))
        @compileError("ConnectToken must have field: user_data: [opts.user_data_size]u8");
    if (@FieldType(T, "user_data") != [user_data_size]u8)
        @compileError("ConnectToken.user_data must be [opts.user_data_size]u8");
}

pub const ChallengeToken = [16]u8;

/// Generates the HMAC token for the challenge handshake.
/// Binds: cid, client_nonce, sequence, expires_at.
pub fn generateChallengeToken(
    challenge_key: *const [CHALLENGE_KEY_SIZE]u8,
    cid: u64,
    client_nonce: u64,
    challenge_seq: u64,
    expires_at: u64,
) ChallengeToken {
    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

    var msg: [8 * 4]u8 = undefined;
    std.mem.writeInt(u64, msg[0..8], @as(u64, cid), .big);
    std.mem.writeInt(u64, msg[8..16], client_nonce, .big);
    std.mem.writeInt(u64, msg[16..24], challenge_seq, .big);
    std.mem.writeInt(u64, msg[24..32], expires_at, .big);

    var full_mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(full_mac[0..], msg[0..], challenge_key[0..]);

    var token: ChallengeToken = undefined;
    @memcpy(token[0..], full_mac[0..16]);
    return token;
}

/// Verifies a challenge token received in a ConnectionResponse.
pub fn verifyChallengeToken(
    token: ChallengeToken,
    challenge_key: *const [CHALLENGE_KEY_SIZE]u8,
    cid: u64,
    client_nonce: u64,
    sequence: u64,
    expires_at: u64,
) bool {
    const expected = generateChallengeToken(challenge_key, cid, client_nonce, sequence, expires_at);
    return std.crypto.timing_safe.eql([16]u8, expected, token);
}

/// Secure connection token issued by a matchmaking/lobby server.
/// Sent by the client inside a SecureConnectionRequest.
pub fn DefaultConnectToken(comptime user_data_size: usize) type {
    return struct {
        const Self = @This();

        client_id: u64,
        expires_at: u64,
        public_addresses: []const std.net.Address,
        user_data: [user_data_size]u8,
        mac: [16]u8,

        pub fn create(
            client_id: u64,
            expires_at: u64,
            public_addresses: []const std.net.Address,
            user_data: [user_data_size]u8,
            secret_key: *const [SECRET_KEY_SIZE]u8,
        ) Self {
            var token = Self{
                .client_id = client_id,
                .expires_at = expires_at,
                .public_addresses = public_addresses,
                .user_data = user_data,
                .mac = undefined,
            };
            token.mac = token.computeMac(secret_key);
            return token;
        }

        pub fn verify(
            self: *const Self,
            now: u64,
            secret_key: *const [SECRET_KEY_SIZE]u8,
        ) bool {
            if (now > self.expires_at) return false;
            const expected = self.computeMac(secret_key);
            return std.crypto.timing_safe.eql([16]u8, expected, self.mac);
        }

        fn computeMac(self: *const Self, secret_key: *const [SECRET_KEY_SIZE]u8) [16]u8 {
            const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
            var h = HmacSha256.init(secret_key[0..]);
            var buf: [8]u8 = undefined;

            std.mem.writeInt(u64, buf[0..], @as(u64, self.client_id), .big);
            h.update(buf[0..]);
            std.mem.writeInt(u64, buf[0..], self.expires_at, .big);
            h.update(buf[0..]);

            for (self.public_addresses) |addr| {
                const key = AddressKey.fromAddress(addr);
                h.update(key.ip[0..]);
                var port_buf: [2]u8 = undefined;
                std.mem.writeInt(u16, port_buf[0..], key.port, .big);
                h.update(port_buf[0..]);
            }

            h.update(self.user_data[0..]);

            var full_mac: [HmacSha256.mac_length]u8 = undefined;
            h.final(full_mac[0..]);
            var out: [16]u8 = undefined;
            @memcpy(out[0..], full_mac[0..16]);
            return out;
        }
    };
}
