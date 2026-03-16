const std = @import("std");
const AddressKey = @import("addr.zig").AddressKey;
const SECRET_KEY_SIZE = @import("root.zig").SECRET_KEY_SIZE;
const CHALLENGE_KEY_SIZE = @import("root.zig").CHALLENGE_KEY_SIZE;

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
    return std.crypto.timing_safe.eql(u8, expected[0..], token[0..]);
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
            return std.crypto.timing_safe.eql(u8, expected[0..], self.mac[0..]);
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
