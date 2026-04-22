const builtin = @import("builtin");

pub const UdpSocket = if (builtin.os.tag == .windows)
    @import("../adapters/windows_udp.zig").UdpSocket
else
    @import("../adapters/std_udp.zig").UdpSocket;
