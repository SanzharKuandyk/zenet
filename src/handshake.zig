const std = @import("std");
const AddressKey = @import("addr.zig").AddressKey;
const SECRET_KEY_SIZE = @import("root.zig").SECRET_KEY_SIZE;
const CHALLENGE_KEY_SIZE = @import("root.zig").CHALLENGE_KEY_SIZE;

/// Compile-time validation that T implements the ConnectToken interface:
///
///   pub const wire_size: usize
///   pub fn encode(*const T, *[wire_size]u8) void
///   pub fn decode(*const [wire_size]u8) ?T
///   pub fn verify(*const T, u64, *const [32]u8) bool
///   pub fn authorizeAddress(*const T, std.net.Address) bool
///   user_data: [user_data_size]u8
pub fn validateConnectTokenInterface(comptime T: type, comptime user_data_size: usize) void {
    if (!@hasDecl(T, "wire_size"))
        @compileError("ConnectToken must have: pub const wire_size: usize");

    if (!@hasDecl(T, "encode"))
        @compileError("ConnectToken must have: pub fn encode(*const @This(), *[wire_size]u8) void");
    switch (@typeInfo(@TypeOf(T.encode))) {
        .@"fn" => |fi| {
            if (fi.params.len != 2)
                @compileError("ConnectToken.encode must take exactly 2 parameters");
            const p0 = fi.params[0].type orelse @compileError("ConnectToken.encode param[0] must be *const @This()");
            if (p0 != *const T)
                @compileError("ConnectToken.encode param[0] must be *const @This(), got " ++ @typeName(p0));
            const p1 = fi.params[1].type orelse @compileError("ConnectToken.encode param[1] must be *[wire_size]u8");
            if (p1 != *[T.wire_size]u8)
                @compileError("ConnectToken.encode param[1] must be *[wire_size]u8, got " ++ @typeName(p1));
            const ret = fi.return_type orelse @compileError("ConnectToken.encode must return void");
            if (ret != void)
                @compileError("ConnectToken.encode must return void, got " ++ @typeName(ret));
        },
        else => @compileError("ConnectToken.encode must be a function"),
    }

    if (!@hasDecl(T, "decode"))
        @compileError("ConnectToken must have: pub fn decode(*const [wire_size]u8) ?@This()");
    switch (@typeInfo(@TypeOf(T.decode))) {
        .@"fn" => |fi| {
            if (fi.params.len != 1)
                @compileError("ConnectToken.decode must take exactly 1 parameter");
            const p0 = fi.params[0].type orelse @compileError("ConnectToken.decode param[0] must be *const [wire_size]u8");
            if (p0 != *const [T.wire_size]u8)
                @compileError("ConnectToken.decode param[0] must be *const [wire_size]u8, got " ++ @typeName(p0));
            const ret = fi.return_type orelse @compileError("ConnectToken.decode must return ?@This()");
            switch (@typeInfo(ret)) {
                .optional => |opt| {
                    if (opt.child != T)
                        @compileError("ConnectToken.decode must return ?@This(), got ?" ++ @typeName(opt.child));
                },
                else => @compileError("ConnectToken.decode must return ?@This()"),
            }
        },
        else => @compileError("ConnectToken.decode must be a function"),
    }

    if (!@hasDecl(T, "verify"))
        @compileError("ConnectToken must have: pub fn verify(*const @This(), u64, *const [32]u8) bool");
    switch (@typeInfo(@TypeOf(T.verify))) {
        .@"fn" => |fi| {
            if (fi.params.len != 3)
                @compileError("ConnectToken.verify must take exactly 3 parameters");
            const p0 = fi.params[0].type orelse @compileError("ConnectToken.verify param[0] must be *const @This()");
            if (p0 != *const T)
                @compileError("ConnectToken.verify param[0] must be *const @This(), got " ++ @typeName(p0));
            const p1 = fi.params[1].type orelse @compileError("ConnectToken.verify param[1] must be u64");
            if (p1 != u64)
                @compileError("ConnectToken.verify param[1] must be u64, got " ++ @typeName(p1));
            const p2 = fi.params[2].type orelse @compileError("ConnectToken.verify param[2] must be *const [32]u8");
            if (p2 != *const [SECRET_KEY_SIZE]u8)
                @compileError("ConnectToken.verify param[2] must be *const [32]u8, got " ++ @typeName(p2));
            const ret = fi.return_type orelse @compileError("ConnectToken.verify must return bool");
            if (ret != bool)
                @compileError("ConnectToken.verify must return bool, got " ++ @typeName(ret));
        },
        else => @compileError("ConnectToken.verify must be a function"),
    }

    if (!@hasDecl(T, "authorizeAddress"))
        @compileError("ConnectToken must have: pub fn authorizeAddress(*const @This(), std.net.Address) bool");
    switch (@typeInfo(@TypeOf(T.authorizeAddress))) {
        .@"fn" => |fi| {
            if (fi.params.len != 2)
                @compileError("ConnectToken.authorizeAddress must take exactly 2 parameters");
            const p0 = fi.params[0].type orelse @compileError("ConnectToken.authorizeAddress param[0] must be *const @This()");
            if (p0 != *const T)
                @compileError("ConnectToken.authorizeAddress param[0] must be *const @This(), got " ++ @typeName(p0));
            const p1 = fi.params[1].type orelse @compileError("ConnectToken.authorizeAddress param[1] must be std.net.Address");
            if (p1 != std.net.Address)
                @compileError("ConnectToken.authorizeAddress param[1] must be std.net.Address, got " ++ @typeName(p1));
            const ret = fi.return_type orelse @compileError("ConnectToken.authorizeAddress must return bool");
            if (ret != bool)
                @compileError("ConnectToken.authorizeAddress must return bool, got " ++ @typeName(ret));
        },
        else => @compileError("ConnectToken.authorizeAddress must be a function"),
    }

    if (!@hasField(T, "user_data"))
        @compileError("ConnectToken must have field: user_data: [opts.user_data_size]u8");
    if (@FieldType(T, "user_data") != [user_data_size]u8)
        @compileError("ConnectToken.user_data must be [opts.user_data_size]u8");
}

pub const ChallengeToken = [16]u8;

pub fn generateChallengeToken(
    challenge_key: *const [CHALLENGE_KEY_SIZE]u8,
    cid: u64,
    client_nonce: u64,
    challenge_seq: u64,
    expires_at: u64,
) ChallengeToken {
    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

    var msg: [8 * 4]u8 = undefined;
    std.mem.writeInt(u64, msg[0..8], cid, .big);
    std.mem.writeInt(u64, msg[8..16], client_nonce, .big);
    std.mem.writeInt(u64, msg[16..24], challenge_seq, .big);
    std.mem.writeInt(u64, msg[24..32], expires_at, .big);

    var full_mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(full_mac[0..], msg[0..], challenge_key[0..]);

    var token: ChallengeToken = undefined;
    @memcpy(token[0..], full_mac[0..16]);
    return token;
}

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

pub fn DefaultConnectToken(comptime user_data_size: usize, comptime max_addresses: usize) type {
    comptime {
        if (max_addresses == 0)
            @compileError("DefaultConnectToken requires max_addresses >= 1");
        if (max_addresses > std.math.maxInt(u8))
            @compileError("DefaultConnectToken max_addresses must fit in u8");
    }

    return struct {
        const Self = @This();

        pub const wire_size = 8 + 8 + 1 + (max_addresses * AddressKey.WIRE_SIZE) + user_data_size + 16;

        client_id: u64,
        expires_at: u64,
        address_count: u8,
        public_addresses: [max_addresses]AddressKey,
        user_data: [user_data_size]u8,
        mac: [16]u8,

        pub fn create(
            client_id: u64,
            expires_at: u64,
            public_addresses: []const std.net.Address,
            user_data: [user_data_size]u8,
            secret_key: *const [SECRET_KEY_SIZE]u8,
        ) !Self {
            if (public_addresses.len > max_addresses) return error.TooManyAddresses;

            var normalized = [_]AddressKey{.{
                .ip = [_]u8{0} ** 16,
                .port = 0,
            }} ** max_addresses;
            for (public_addresses, 0..) |addr, i| {
                normalized[i] = AddressKey.fromAddress(addr);
            }

            var token = Self{
                .client_id = client_id,
                .expires_at = expires_at,
                .address_count = @intCast(public_addresses.len),
                .public_addresses = normalized,
                .user_data = user_data,
                .mac = undefined,
            };
            token.mac = token.computeMac(secret_key);
            return token;
        }

        pub fn verify(self: *const Self, now: u64, secret_key: *const [SECRET_KEY_SIZE]u8) bool {
            if (self.address_count > max_addresses) return false;
            if (now > self.expires_at) return false;
            const expected = self.computeMac(secret_key);
            return std.crypto.timing_safe.eql([16]u8, expected, self.mac);
        }

        pub fn authorizeAddress(self: *const Self, addr: std.net.Address) bool {
            const key = AddressKey.fromAddress(addr);
            for (0..self.address_count) |i| {
                if (AddressKey.eql(self.public_addresses[i], key)) return true;
            }
            return false;
        }

        pub fn encode(self: *const Self, out: *[wire_size]u8) void {
            std.mem.writeInt(u64, out[0..8], self.client_id, .big);
            std.mem.writeInt(u64, out[8..16], self.expires_at, .big);
            out[16] = self.address_count;

            var offset: usize = 17;
            for (self.public_addresses) |addr| {
                var addr_buf: [AddressKey.WIRE_SIZE]u8 = undefined;
                addr.encode(&addr_buf);
                @memcpy(out[offset .. offset + AddressKey.WIRE_SIZE], addr_buf[0..]);
                offset += AddressKey.WIRE_SIZE;
            }

            @memcpy(out[offset .. offset + user_data_size], self.user_data[0..]);
            offset += user_data_size;
            @memcpy(out[offset .. offset + 16], self.mac[0..]);
        }

        pub fn decode(bytes: *const [wire_size]u8) ?Self {
            const address_count = bytes[16];
            if (address_count > max_addresses) return null;

            var public_addresses = [_]AddressKey{.{
                .ip = [_]u8{0} ** 16,
                .port = 0,
            }} ** max_addresses;

            var offset: usize = 17;
            for (0..max_addresses) |i| {
                const addr_bytes: *const [AddressKey.WIRE_SIZE]u8 = @ptrCast(bytes[offset .. offset + AddressKey.WIRE_SIZE]);
                public_addresses[i] = AddressKey.decode(addr_bytes);
                offset += AddressKey.WIRE_SIZE;
            }

            var user_data: [user_data_size]u8 = undefined;
            @memcpy(user_data[0..], bytes[offset .. offset + user_data_size]);
            offset += user_data_size;

            var mac: [16]u8 = undefined;
            @memcpy(mac[0..], bytes[offset .. offset + 16]);

            return .{
                .client_id = std.mem.readInt(u64, bytes[0..8], .big),
                .expires_at = std.mem.readInt(u64, bytes[8..16], .big),
                .address_count = address_count,
                .public_addresses = public_addresses,
                .user_data = user_data,
                .mac = mac,
            };
        }

        fn computeMac(self: *const Self, secret_key: *const [SECRET_KEY_SIZE]u8) [16]u8 {
            const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
            var h = HmacSha256.init(secret_key[0..]);
            var buf: [8]u8 = undefined;

            std.mem.writeInt(u64, buf[0..], self.client_id, .big);
            h.update(buf[0..]);
            std.mem.writeInt(u64, buf[0..], self.expires_at, .big);
            h.update(buf[0..]);
            h.update(&.{self.address_count});

            for (0..self.address_count) |i| {
                const key = self.public_addresses[i];
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
