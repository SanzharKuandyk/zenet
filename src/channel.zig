pub const ChannelKind = enum { ReliableOrdered, Unreliable };

pub const Channel = struct {
    kind: ChannelKind,
};
