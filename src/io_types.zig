/// Non-blocking read outcome.
pub const NbRead = union(enum) {
    data: usize, // > 0 bytes unless the caller supplied an empty buffer
    want_read, // drained or receive pending; wait for the next read event/completion
    want_write, // TLS-only (post-handshake control messages); never for plain
    eof, // clean close
};

/// Non-blocking write outcome.
pub const NbWrite = union(enum) {
    done: usize, // bytes accepted (may be a partial write)
    want_read, // TLS-only; never for plain
    want_write, // send buffer full or send pending; wait for the write event/completion
};

pub const IoError = error{
    ConnectFailed,
    SocketError,
    OutOfMemory,
};

// Which overlapped op a completion belongs to.
pub const CompletionKind = enum { recv, send, connect, unknown };
