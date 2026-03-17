const std = @import("std");

pub const AddressKey = struct {
    ip: [16]u8, // IPv4 mapped into IPv6 or raw IPv6
    port: u16,

    pub fn fromAddress(addr: std.net.Address) AddressKey {
        var out: AddressKey = .{
            .ip = [_]u8{0} ** 16,
            .port = 0,
        };

        switch (addr.any.family) {
            std.posix.AF.INET => {
                // 0000:0000:0000:0000:0000:ffff:XXXX:XXXX
                const a = addr.in;
                out.ip[10] = 0xff;
                out.ip[11] = 0xff;
                @memcpy(out.ip[12..16], std.mem.asBytes(&a.sa.addr));
                out.port = std.mem.bigToNative(u16, a.sa.port);
            },
            std.posix.AF.INET6 => {
                const a = addr.in6;
                @memcpy(out.ip[0..16], &a.sa.addr);
                out.port = std.mem.bigToNative(u16, a.sa.port);
            },
            else => unreachable,
        }

        return out;
    }

    pub fn hash(self: AddressKey) u64 {
        return std.hash.Wyhash.hash(0, std.mem.asBytes(&self));
    }

    pub fn eql(a: AddressKey, b: AddressKey) bool {
        return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
    }
};
