//! Windows AFD terminal-error compensation for the Zig 0.16.0 threaded route
//! (born#126): upstream 0.16.0 collapses most non-SUCCESS AFD statuses to
//! error.Unexpected. Every AFD ioctl here runs through the Threaded vtable's
//! `operate` with `.device_io_control` (nonblocking), inheriting std's APC
//! submission, alertable wait, cancel and drain. A zero-length AFD SEND probe
//! recovers a socket's sticky terminal state for the read/write/send slots,
//! and the shim's own connect keeps the CONNECT NTSTATUS observable (std 0.16
//! closes the handle and discards the status before its error returns).
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

/// Submit one AFD ioctl through the Threaded `operate` slot and return the
/// terminal iosb status. `.device_io_control` with `nonblocking = true` submits
/// with an APC, waits alertably, and on a cancel request calls NtCancelIoFileEx
/// and drains the ioctl to completion before returning `error.Canceled`; any
/// other completion returns the raw iosb so the caller observes the terminal
/// NTSTATUS. The in/out buffers must outlive this call: std drains to completion
/// before returning, so the storage is never touched after it returns.
fn afdIoctl(io: Io, handle: HANDLE, code: windows.CTL_CODE, in: []const u8, out: []u8) Io.Cancelable!NTSTATUS {
    const result = try io.vtable.operate(io.userdata, .{ .device_io_control = .{
        .file = .{ .handle = handle, .flags = .{ .nonblocking = true } },
        .code = code,
        .in = in,
        .out = out,
    } });
    return result.device_io_control.u.Status;
}

/// Zero-length AFD SEND probe: reads the socket's CURRENT sticky terminal
/// state without transferring data. A healthy idle socket completes SUCCESS;
/// a reset/disconnected/timed-out socket completes with its terminal status.
/// Error path only; a successful read/write/send is never probed.
///
/// Completion-port safety: std's deviceIoControl submits the ioctl with an APC
/// and no event or completion-port association, so no IOCP completion packet is
/// queued even if the handle were associated with a completion port. The probe
/// only ever runs on Threaded-owned handles: on the Born route the provenance
/// gate services Born-owned (IOCP-associated) handles on Born's reactor and
/// forwards only registry-absent handles to fwd016, so a born-IOCP-owned handle
/// never reaches this probe.
fn probeTerminal(io: Io, handle: HANDLE) Io.Cancelable!NTSTATUS {
    var byte: [1]u8 = .{0};
    var bufs: [1]windows.AFD.WSABUF(.@"const") = .{.{ .len = 0, .buf = &byte }};
    var info: windows.AFD.SEND_INFO = .{
        .BufferArray = &bufs,
        .BufferCount = 1,
        .AfdFlags = .{ .NO_FAST_IO = true, .OVERLAPPED = true },
        .TdiFlags = .{},
    };
    return afdIoctl(io, handle, windows.IOCTL.AFD.SEND, std.mem.asBytes(&info), &.{});
}

/// 0.16 Reader.Error mapping: CONNECTION_RESET and REMOTE_DISCONNECT map to
/// ConnectionResetByPeer, IO_TIMEOUT to Timeout (Reader.Error carries Timeout,
/// not ConnectionTimedOut). LOCAL_DISCONNECT is excluded: it reports a local
/// shutdown(send), not a peer reset, so it must not turn a read into
/// ConnectionResetByPeer. Non-sticky/unknown statuses (including SUCCESS)
/// return null: stay Unexpected.
fn mapRead(status: NTSTATUS) ?Io.net.Stream.Reader.Error {
    return switch (status) {
        .CONNECTION_RESET, .REMOTE_DISCONNECT => error.ConnectionResetByPeer,
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
/// null when the socket holds no sticky terminal state (stay Unexpected). A
/// canceled probe surfaces error.Canceled (Reader.Error carries it on 0.16).
pub fn readError(io: Io, handle: Handle) ?Io.net.Stream.Reader.Error {
    const status = probeTerminal(io, handle) catch return error.Canceled;
    return mapRead(status);
}

/// Recover the terminal error behind a threaded netWrite error.Unexpected.
pub fn writeError(io: Io, handle: Handle) ?Io.net.Stream.Writer.Error {
    const status = probeTerminal(io, handle) catch return error.Canceled;
    return mapWrite(status);
}

/// Recover the terminal error behind a threaded netSend error.Unexpected.
pub fn sendError(io: Io, handle: Handle) ?Io.net.Socket.SendError {
    const status = probeTerminal(io, handle) catch return error.Canceled;
    return mapSend(status);
}

/// Open a raw AFD endpoint identical to std's openSocketAfd (NtCreateFile on
/// \Device\Afd\Endpoint with FULL_EA_INFORMATION), so std's read/write/close
/// accept the resulting handle. NtCreateFile on the AFD endpoint completes
/// synchronously; the status mapping mirrors std's openSocketAfd.
fn openSocketAfd(family: ws2.ADDRESS_FAMILY, mode: Io.net.Socket.Mode, protocol: ?Io.net.Protocol) error{
    AddressFamilyUnsupported,
    ProtocolUnsupportedByAddressFamily,
    Unexpected,
}!HANDLE {
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
    return switch (rc) {
        .SUCCESS => handle,
        .PROTOCOL_NOT_SUPPORTED => error.AddressFamilyUnsupported,
        .NO_SUCH_FILE => error.ProtocolUnsupportedByAddressFamily,
        else => error.Unexpected,
    };
}

/// Mirror std's connect setup: SO_REUSE_UNICASTPORT on the raw endpoint. The
/// status mapping mirrors std's socketOptionAfd.
fn setReuseUnicastport(io: Io, handle: HANDLE) error{ SystemResources, Unexpected, Canceled }!void {
    var val: bool = true;
    const info = windows.AFD.SOCKOPT_INFO{
        .mode = .set,
        .level = ws2.SOL.SOCKET,
        .optname = ws2.SO.REUSE_UNICASTPORT,
        .optval = &val,
        .optlen = @sizeOf(bool),
    };
    const st = try afdIoctl(io, handle, windows.IOCTL.AFD.SOCKOPT, std.mem.asBytes(&info), &.{});
    switch (st) {
        .SUCCESS => {},
        .CANCELLED => unreachable, // deviceIoControl drains and returns error.Canceled
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        else => return error.Unexpected,
    }
}

/// Mirror std's connect setup: bind the wildcard address in .Active mode and
/// return the bound local address. The status mapping mirrors std's
/// bindSocketIpAfd; the caller maps AddressInUse to Unexpected as std does.
fn bindActiveWildcard(io: Io, handle: HANDLE, address: *const Io.net.IpAddress) error{
    SystemResources,
    AddressInUse,
    Unexpected,
    Canceled,
}!Io.net.IpAddress {
    const Storage = extern struct { Info: windows.AFD.BIND_INFO, Address: T.PosixAddress };
    var storage: Storage = .{ .Info = .{ .Mode = .Active }, .Address = undefined };
    const addr_len = T.addressToPosix(address, &storage.Address);
    const st = try afdIoctl(
        io,
        handle,
        windows.IOCTL.AFD.BIND,
        @as([]const u8, @ptrCast(&storage))[0 .. @offsetOf(Storage, "Address") + addr_len],
        @as([]u8, @ptrCast(&storage.Address))[0..addr_len],
    );
    switch (st) {
        .SUCCESS => {},
        .CANCELLED => unreachable, // deviceIoControl drains and returns error.Canceled
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        .SHARING_VIOLATION => return error.AddressInUse,
        else => return error.Unexpected,
    }
    return T.addressFromPosix(&storage.Address);
}

/// The shim's own connect (Windows + 0.16): create the AFD endpoint, set
/// REUSE_UNICASTPORT, bind wildcard .Active, issue CONNECT and read its NTSTATUS
/// directly. No second network probe: the connect itself yields the terminal
/// status. The returned handle is a raw AFD endpoint std read/write/close
/// accept. There is no connect timeout: CONNECT completes when TCP gives up and
/// the caller cancels (error.Canceled), matching std 0.16. Setup-path errors
/// propagate with std's mapping rather than collapsing to Unexpected.
pub fn connect(io: Io, address: *const Io.net.IpAddress, options: Io.net.IpAddress.ConnectOptions) Io.net.IpAddress.ConnectError!Io.net.Socket {
    // std 0.16 panics on a connect timeout; reject it explicitly instead.
    if (options.timeout != .none) return error.OptionUnsupported;
    const family = T.posixAddressFamily(address);
    const handle = try openSocketAfd(family, options.mode, options.protocol);
    errdefer windows.CloseHandle(handle);
    try setReuseUnicastport(io, handle);
    const wildcard: Io.net.IpAddress = switch (address.*) {
        .ip4 => .{ .ip4 = .unspecified(0) },
        .ip6 => .{ .ip6 = .unspecified(0) },
    };
    const bound = bindActiveWildcard(io, handle, &wildcard) catch |err| switch (err) {
        error.AddressInUse => return error.Unexpected, // std netConnectIpWindows maps bind AddressInUse to Unexpected
        else => |e| return e,
    };
    const Storage = extern struct { Reserved0: [3]usize = @splat(0), Address: T.PosixAddress };
    var storage: Storage = .{ .Address = undefined };
    const addr_len = T.addressToPosix(address, &storage.Address);
    const st = try afdIoctl(
        io,
        handle,
        windows.IOCTL.AFD.CONNECT,
        @as([]const u8, @ptrCast(&storage))[0 .. @offsetOf(Storage, "Address") + addr_len],
        &.{},
    );
    switch (st) {
        .SUCCESS => {},
        .CANCELLED => unreachable, // deviceIoControl drains and returns error.Canceled
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        else => {
            if (mapConnect(st)) |mapped| return mapped;
            return error.Unexpected;
        },
    }
    return .{ .handle = handle, .address = bound };
}
