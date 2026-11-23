//! Windows AFD terminal-error compensation for the Zig 0.16.0 threaded route
//! (born#126). Upstream 0.16.0 collapses most non-SUCCESS AFD statuses to
//! error.Unexpected; 0.17.1 corrected the connect/read/write switches. This
//! module recovers a socket's sticky terminal state with a zero-length AFD
//! SEND probe and maps it into the 0.16 error sets, and performs the shim's
//! own connect so the CONNECT NTSTATUS stays observable (std 0.16 closes the
//! handle and discards the status before its error returns).
//!
//! Comptime-dead outside Windows + 0.16: every export is referenced only from
//! the shim's `is_windows and !is_017` branches, so the Windows-specific bodies
//! are never analyzed on other targets or on 0.17.x.

const std = @import("std");
const Io = std.Io;
const windows = std.os.windows;
const ws2 = windows.ws2_32;
const ntdll = windows.ntdll;
const T = Io.Threaded;

const HANDLE = windows.HANDLE;
const NTSTATUS = windows.NTSTATUS;
const Handle = Io.net.Socket.Handle;

extern "kernel32" fn CreateEventW(?*anyopaque, windows.BOOL, windows.BOOL, ?[*:0]const u16) callconv(.winapi) ?HANDLE;

/// Probe wait bound: terminal states complete immediately; one second is a
/// safety net for a non-terminal socket that would otherwise pend.
const probe_timeout_100ns: i64 = -10_000_000;
/// Connect wait bound: a TCP connect resolves well inside this; on expiry the
/// pending CONNECT is cancelled and drained and the slot reports Timeout.
const connect_timeout_100ns: i64 = -300_000_000;
/// Setup ioctl (SOCKOPT/BIND) wait bound.
const setup_timeout_100ns: i64 = -10_000_000;

/// Event-based AFD ioctl with a bounded wait. Returns the final iosb status,
/// or null if the wait expired (the ioctl is cancelled and its completion
/// drained before returning). The iosb/event storage stays live until the
/// completion is drained; the caller's in/out buffers must outlive this call.
fn afdIoctlEvent(
    handle: HANDLE,
    code: windows.CTL_CODE,
    in: ?*const anyopaque,
    in_len: u32,
    out: ?*anyopaque,
    out_len: u32,
    timeout_100ns: i64,
) ?NTSTATUS {
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    const event = CreateEventW(null, .TRUE, .FALSE, null) orelse return null;
    defer windows.CloseHandle(event);
    const rc = ntdll.NtDeviceIoControlFile(handle, event, null, null, &iosb, code, in, in_len, out, out_len);
    if (rc == .PENDING) {
        var timeout: windows.LARGE_INTEGER = timeout_100ns;
        const w = ntdll.NtWaitForSingleObject(event, .FALSE, &timeout);
        if (w != .SUCCESS) {
            var cancel_iosb: windows.IO_STATUS_BLOCK = undefined;
            _ = ntdll.NtCancelIoFileEx(handle, &iosb, &cancel_iosb);
            _ = ntdll.NtWaitForSingleObject(event, .FALSE, null);
            return null;
        }
    } else if (rc != .SUCCESS) {
        return rc;
    }
    return iosb.u.Status;
}

/// Zero-length AFD SEND probe: reads the socket's CURRENT sticky terminal
/// state without transferring data. A healthy idle socket completes SUCCESS;
/// a reset/disconnected/timed-out socket completes with its terminal status.
/// Error path only; a successful read/write/send is never probed.
fn probeTerminal(handle: HANDLE) ?NTSTATUS {
    var byte: [1]u8 = .{0};
    var bufs: [1]windows.AFD.WSABUF(.@"const") = .{.{ .len = 0, .buf = &byte }};
    var info: windows.AFD.SEND_INFO = .{
        .BufferArray = &bufs,
        .BufferCount = 1,
        .AfdFlags = .{ .NO_FAST_IO = true, .OVERLAPPED = true },
        .TdiFlags = .{},
    };
    return afdIoctlEvent(handle, windows.IOCTL.AFD.SEND, &info, @sizeOf(windows.AFD.SEND_INFO), null, 0, probe_timeout_100ns);
}

/// 0.16 Reader.Error mapping: the reset trio maps to ConnectionResetByPeer and
/// IO_TIMEOUT to Timeout (Reader.Error carries Timeout, not ConnectionTimedOut).
/// Non-sticky/unknown statuses (including SUCCESS) return null: stay Unexpected.
fn mapRead(status: NTSTATUS) ?Io.net.Stream.Reader.Error {
    return switch (status) {
        .CONNECTION_RESET, .REMOTE_DISCONNECT, .LOCAL_DISCONNECT => error.ConnectionResetByPeer,
        .IO_TIMEOUT => error.Timeout,
        else => null,
    };
}

/// 0.16 Writer.Error mapping: reset trio to ConnectionResetByPeer, refusal to
/// ConnectionRefused. Writer.Error has no Timeout, so IO_TIMEOUT stays null.
fn mapWrite(status: NTSTATUS) ?Io.net.Stream.Writer.Error {
    return switch (status) {
        .CONNECTION_RESET, .REMOTE_DISCONNECT, .LOCAL_DISCONNECT => error.ConnectionResetByPeer,
        .CONNECTION_REFUSED => error.ConnectionRefused,
        else => null,
    };
}

/// 0.16 SendError mapping: identical shape to Writer.Error (no Timeout member).
fn mapSend(status: NTSTATUS) ?Io.net.Socket.SendError {
    return switch (status) {
        .CONNECTION_RESET, .REMOTE_DISCONNECT, .LOCAL_DISCONNECT => error.ConnectionResetByPeer,
        .CONNECTION_REFUSED => error.ConnectionRefused,
        else => null,
    };
}

/// 0.16 ConnectError mapping for the CONNECT status: refusal to
/// ConnectionRefused, reset trio to ConnectionResetByPeer, IO_TIMEOUT to
/// Timeout, resource exhaustion to SystemResources.
fn mapConnect(status: NTSTATUS) ?Io.net.IpAddress.ConnectError {
    return switch (status) {
        .CONNECTION_REFUSED => error.ConnectionRefused,
        .CONNECTION_RESET, .REMOTE_DISCONNECT, .LOCAL_DISCONNECT => error.ConnectionResetByPeer,
        .IO_TIMEOUT => error.Timeout,
        .INSUFFICIENT_RESOURCES => error.SystemResources,
        else => null,
    };
}

/// Recover the terminal error behind a threaded netRead error.Unexpected, or
/// null when the socket holds no sticky terminal state (stay Unexpected).
pub fn readError(handle: Handle) ?Io.net.Stream.Reader.Error {
    const status = probeTerminal(handle) orelse return null;
    return mapRead(status);
}

/// Recover the terminal error behind a threaded netWrite error.Unexpected.
pub fn writeError(handle: Handle) ?Io.net.Stream.Writer.Error {
    const status = probeTerminal(handle) orelse return null;
    return mapWrite(status);
}

/// Recover the terminal error behind a threaded netSend error.Unexpected.
pub fn sendError(handle: Handle) ?Io.net.Socket.SendError {
    const status = probeTerminal(handle) orelse return null;
    return mapSend(status);
}

/// Open a raw AFD endpoint identical to std's openSocketAfd (NtCreateFile on
/// \Device\Afd\Endpoint with FULL_EA_INFORMATION), so std's read/write/close
/// accept the resulting handle.
fn openSocketAfd(family: ws2.ADDRESS_FAMILY, mode: Io.net.Socket.Mode, protocol: ?Io.net.Protocol) !HANDLE {
    const mp = try T.posixSocketModeProtocol(family, mode, protocol);
    var handle: HANDLE = undefined;
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    const ea = windows.AFD.OPEN_PACKET.FULL_EA_INFORMATION{ .Value = .{
        .EndpointType = .{
            .CONNECTIONLESS = switch (mode) {
                .stream, .seqpacket, .rdm => false,
                .dgram, .raw => true,
            },
            .MESSAGEMODE = mode != .stream,
            .RAW = mode == .raw,
        },
        .GroupID = 0,
        .AddressFamily = family,
        .SocketType = @bitCast(mp[0]),
        .Protocol = @bitCast(mp[1]),
        .TransportDeviceNameLength = 0,
        .TransportDeviceName = undefined,
    } };
    const rc = ntdll.NtCreateFile(
        &handle,
        .{ .STANDARD = .{ .RIGHTS = .{ .WRITE_DAC = true }, .SYNCHRONIZE = true }, .GENERIC = .{ .WRITE = true, .READ = true } },
        &.{ .ObjectName = @constCast(&windows.UNICODE_STRING.init(windows.AFD.DEVICE_NAME ++ .{ '\\', 'E', 'n', 'd', 'p', 'o', 'i', 'n', 't' })) },
        &iosb,
        null,
        .{},
        .{ .READ = true, .WRITE = true },
        .OPEN_IF,
        .{ .IO = .ASYNCHRONOUS },
        &ea,
        @sizeOf(@TypeOf(ea)),
    );
    if (rc != .SUCCESS) return error.Unexpected;
    return handle;
}

/// Mirror std's connect setup: SO_REUSE_UNICASTPORT on the raw endpoint.
fn setReuseUnicastport(handle: HANDLE) !void {
    var val: bool = true;
    const info = windows.AFD.SOCKOPT_INFO{
        .mode = .set,
        .level = ws2.SOL.SOCKET,
        .optname = ws2.SO.REUSE_UNICASTPORT,
        .optval = &val,
        .optlen = @sizeOf(bool),
    };
    const st = afdIoctlEvent(handle, windows.IOCTL.AFD.SOCKOPT, &info, @sizeOf(@TypeOf(info)), null, 0, setup_timeout_100ns) orelse return error.Unexpected;
    if (st != .SUCCESS) return error.Unexpected;
}

/// Mirror std's connect setup: bind the wildcard address in .Active mode and
/// return the bound local address.
fn bindActiveWildcard(handle: HANDLE, address: *const Io.net.IpAddress) !Io.net.IpAddress {
    const Storage = extern struct { Info: windows.AFD.BIND_INFO, Address: T.PosixAddress };
    var storage: Storage = .{ .Info = .{ .Mode = .Active }, .Address = undefined };
    const addr_len = T.addressToPosix(address, &storage.Address);
    const st = afdIoctlEvent(handle, windows.IOCTL.AFD.BIND, &storage, @offsetOf(Storage, "Address") + addr_len, &storage.Address, addr_len, setup_timeout_100ns) orelse return error.Unexpected;
    if (st != .SUCCESS) return error.Unexpected;
    return T.addressFromPosix(&storage.Address);
}

/// The shim's own connect (Windows + 0.16): create the AFD endpoint, set
/// REUSE_UNICASTPORT, bind wildcard .Active, issue CONNECT and read its NTSTATUS
/// directly. No second network probe: the connect itself yields the terminal
/// status. The returned handle is a raw AFD endpoint std read/write/close accept.
pub fn connect(address: *const Io.net.IpAddress, options: Io.net.IpAddress.ConnectOptions) Io.net.IpAddress.ConnectError!Io.net.Socket {
    // std 0.16 panics on a connect timeout; reject it explicitly instead.
    if (options.timeout != .none) return error.OptionUnsupported;
    const family = T.posixAddressFamily(address);
    const handle = openSocketAfd(family, options.mode, options.protocol) catch return error.Unexpected;
    errdefer windows.CloseHandle(handle);
    setReuseUnicastport(handle) catch return error.Unexpected;
    const wildcard: Io.net.IpAddress = switch (address.*) {
        .ip4 => .{ .ip4 = .unspecified(0) },
        .ip6 => .{ .ip6 = .unspecified(0) },
    };
    const bound = bindActiveWildcard(handle, &wildcard) catch return error.Unexpected;
    const Storage = extern struct { Reserved0: [3]usize = @splat(0), Address: T.PosixAddress };
    var storage: Storage = .{ .Address = undefined };
    const addr_len = T.addressToPosix(address, &storage.Address);
    const st = afdIoctlEvent(handle, windows.IOCTL.AFD.CONNECT, &storage, @offsetOf(Storage, "Address") + addr_len, null, 0, connect_timeout_100ns) orelse return error.Timeout;
    switch (st) {
        .SUCCESS => {},
        else => {
            if (mapConnect(st)) |mapped| return mapped;
            return error.Unexpected;
        },
    }
    return .{ .handle = handle, .address = bound };
}
