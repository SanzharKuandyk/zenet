const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;
const RecvResult = @import("socket.zig").RecvResult;

pub const UdpSocket = struct {
    fd: std.posix.socket_t,

    pub fn open(addr: std.net.Address) !UdpSocket {
        const flags: u32 = std.posix.SOCK.DGRAM | std.posix.SOCK.NONBLOCK;
        const fd = try std.posix.socket(addr.any.family, flags, std.posix.IPPROTO.UDP);
        errdefer {
            if (native_os == .windows) {
                std.os.windows.closesocket(fd) catch {};
            } else {
                std.posix.close(fd);
            }
        }
        try std.posix.bind(fd, &addr.any, addr.getOsSockLen());
        return .{ .fd = fd };
    }

    pub fn close(self: *UdpSocket) void {
        if (native_os == .windows) {
            std.os.windows.closesocket(self.fd) catch {};
        } else {
            std.posix.close(self.fd);
        }
    }

    pub fn recvfrom(self: *UdpSocket, buf: []u8) ?RecvResult {
        if (native_os == .windows) {
            return recvfromWindows(self, buf);
        } else {
            return recvfromPosix(self, buf);
        }
    }

    pub fn sendto(self: *UdpSocket, addr: std.net.Address, data: []const u8) void {
        if (native_os == .windows) {
            sendtoWindows(self, addr, data);
        } else {
            sendtoPosix(self, addr, data);
        }
    }

    fn recvfromPosix(self: *UdpSocket, buf: []u8) ?RecvResult {
        var src_addr: std.posix.sockaddr = undefined;
        var addrlen: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
        const n = std.posix.recvfrom(self.fd, buf, 0, &src_addr, &addrlen) catch return null;
        return .{
            .addr = std.net.Address{ .any = src_addr },
            .len = n,
        };
    }

    fn sendtoPosix(self: *UdpSocket, addr: std.net.Address, data: []const u8) void {
        _ = std.posix.sendto(self.fd, data, 0, &addr.any, addr.getOsSockLen()) catch {};
    }

    fn recvfromWindows(self: *UdpSocket, buf: []u8) ?RecvResult {
        const ws2_32 = std.os.windows.ws2_32;
        var src_addr: std.posix.sockaddr = undefined;
        var addrlen: i32 = @sizeOf(std.posix.sockaddr);
        const len: i32 = @intCast(@min(buf.len, std.math.maxInt(i32)));
        const rc = ws2_32.recvfrom(self.fd, buf.ptr, len, 0, &src_addr, &addrlen);
        if (rc == ws2_32.SOCKET_ERROR) return null;
        return .{
            .addr = std.net.Address{ .any = src_addr },
            .len = @intCast(rc),
        };
    }

    fn sendtoWindows(self: *UdpSocket, addr: std.net.Address, data: []const u8) void {
        const ws2_32 = std.os.windows.ws2_32;
        const len: i32 = @intCast(@min(data.len, std.math.maxInt(i32)));
        const addrlen: i32 = @intCast(addr.getOsSockLen());
        _ = ws2_32.sendto(self.fd, data.ptr, len, 0, &addr.any, addrlen);
    }
};
