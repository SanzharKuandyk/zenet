pub const ServerError = error{
    Expired,
    IoError,
    ServerFull,
    InvalidPacket,
    UnknownClient,
    InvalidProtocolId,
};
