//! Native compatibility surface for Born's supported Zig toolchains.
//!
//! The module owns only ABI declarations and behavior that the standard
//! library no longer provides consistently. Public sockets, descriptors,
//! sockaddr layouts, errors, and synchronization primitives remain native.
//! POSIX calls that used to retry on EINTR still do; close never retries.

const std = @import("std");
const builtin = @import("builtin");

const this = @This();
const native_os = builtin.os.tag;
const is_windows = native_os == .windows;
const is_darwin = native_os.isDarwin();
const is_linux = native_os == .linux;
const has_new_signal_type = builtin.zig_version.minor >= 16;

/// Returns an empty `std.EnumSet(E)` on every supported toolchain.
pub fn emptyEnumSet(comptime Enum: type) std.EnumSet(Enum) {
    if (@hasDecl(std.EnumSet(Enum), "empty")) return .empty;
    return .initEmpty();
}

/// Returns the first index of `needle` in `haystack`, or null.
pub fn find(comptime T: type, haystack: []const T, needle: []const T) ?usize {
    if (@hasDecl(std.mem, "find")) return std.mem.find(T, haystack, needle);
    return std.mem.indexOf(T, haystack, needle);
}

/// Returns the first index of `value` in `slice`, or null.
pub fn findScalar(comptime T: type, slice: []const T, value: T) ?usize {
    if (@hasDecl(std.mem, "findScalar")) return std.mem.findScalar(T, slice, value);
    return std.mem.indexOfScalar(T, slice, value);
}

/// Toolchain-independent enum field with a name and numeric value.
pub const EnumField = struct {
    name: [:0]const u8,
    value: i64,
};

/// Returns enum fields in declaration order across both reflection layouts.
pub fn enumFields(comptime Enum: type) []const EnumField {
    const fields = comptime blk: {
        const info = @typeInfo(Enum).@"enum";
        if (builtin.zig_version.minor >= 17) {
            var result: [info.field_names.len]EnumField = undefined;
            for (info.field_names, info.field_values, 0..) |name, value, index| {
                result[index] = .{ .name = name, .value = @intCast(value) };
            }
            break :blk result;
        }
        var result: [info.fields.len]EnumField = undefined;
        for (info.fields, 0..) |field, index| {
            result[index] = .{ .name = field.name, .value = @intCast(field.value) };
        }
        break :blk result;
    };
    return &fields;
}

/// Returns error names in declaration order across both reflection layouts.
pub fn errorSetNames(comptime ErrorSet: type) []const [:0]const u8 {
    if (comptime builtin.zig_version.minor >= 17) {
        return @typeInfo(ErrorSet).error_set.error_names orelse &.{};
    }
    const names = comptime blk: {
        const fields = @typeInfo(ErrorSet).error_set.?;
        var result: [fields.len][:0]const u8 = undefined;
        for (fields, 0..) |field, index| result[index] = field.name;
        break :blk result;
    };
    return &names;
}

/// Converts a native signal constant to Born's public `u8` representation.
pub fn signalNumber(signal: anytype) u8 {
    return switch (@typeInfo(@TypeOf(signal))) {
        .@"enum" => @intCast(@intFromEnum(signal)),
        else => @intCast(signal),
    };
}

/// Native signal value type: an enum on newer toolchains, `u8` on 0.15.
pub const NativeSignal = if (has_new_signal_type) std.posix.SIG else u8;

/// Converts Born's public `u8` signal to the native signal type.
pub fn nativeSignal(signal: u8) NativeSignal {
    if (comptime has_new_signal_type) return @enumFromInt(signal);
    return signal;
}

/// Calls Linux `waitid`, passing a null rusage pointer where the ABI requires it.
pub fn waitid(
    id_type: std.os.linux.P,
    id: i32,
    info: *std.os.linux.siginfo_t,
    flags: u32,
) usize {
    if (comptime !is_linux) @compileError("waitid is Linux-only");
    if (comptime builtin.zig_version.minor >= 16) {
        return std.os.linux.waitid(id_type, id, info, flags, null);
    }
    return std.os.linux.waitid(id_type, id, info, flags);
}

/// Born-owned Win32 and Winsock declarations. No emulated handles or layouts.
pub const windows = struct {
    /// Native Win32 `BOOL`.
    pub const BOOL = c_int;
    /// Native Win32 `DWORD`.
    pub const DWORD = u32;
    /// Native Win32 `WORD`.
    pub const WORD = u16;
    /// Native Win32 `ULONG`.
    pub const ULONG = u32;
    /// Native pointer-sized unsigned integer.
    pub const ULONG_PTR = usize;
    /// Native Win32 handle.
    pub const HANDLE = *anyopaque;
    /// The invalid Win32 handle sentinel.
    pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
    /// Native Win32 true value.
    pub const TRUE: BOOL = 1;
    /// Native Win32 false value.
    pub const FALSE: BOOL = 0;
    /// Infinite Win32 wait timeout.
    pub const INFINITE: DWORD = 0xffffffff;
    /// Native NTSTATUS, reused because its representation is stable.
    pub const NTSTATUS = std.os.windows.NTSTATUS;
    /// Console Ctrl+C event.
    pub const CTRL_C_EVENT: DWORD = 0;
    /// Console Ctrl+Break event.
    pub const CTRL_BREAK_EVENT: DWORD = 1;
    /// Console close event.
    pub const CTRL_CLOSE_EVENT: DWORD = 2;
    /// Console logoff event.
    pub const CTRL_LOGOFF_EVENT: DWORD = 5;
    /// Console shutdown event.
    pub const CTRL_SHUTDOWN_EVENT: DWORD = 6;

    /// Native Win32 `FILETIME` layout.
    pub const FILETIME = extern struct {
        dwLowDateTime: DWORD,
        dwHighDateTime: DWORD,
    };

    /// Native Win32 `GUID` layout.
    pub const GUID = extern struct {
        Data1: u32,
        Data2: u16,
        Data3: u16,
        Data4: [8]u8,
    };

    /// Native Win32 `OVERLAPPED` layout. Storage must outlive completion drain.
    pub const OVERLAPPED = extern struct {
        Internal: ULONG_PTR,
        InternalHigh: ULONG_PTR,
        DUMMYUNIONNAME: extern union {
            DUMMYSTRUCTNAME: extern struct {
                Offset: DWORD,
                OffsetHigh: DWORD,
            },
            Pointer: ?*anyopaque,
        },
        hEvent: ?HANDLE,
    };

    /// Native `OVERLAPPED_ENTRY`; posted completions permit a null overlapped pointer.
    pub const OVERLAPPED_ENTRY = extern struct {
        lpCompletionKey: ULONG_PTR,
        lpOverlapped: ?*OVERLAPPED,
        Internal: ULONG_PTR,
        dwNumberOfBytesTransferred: DWORD,
    };

    /// Native slim reader/writer lock layout.
    pub const SRWLOCK = extern struct {
        Ptr: ?*anyopaque = null,
    };

    /// Native condition variable layout.
    pub const CONDITION_VARIABLE = extern struct {
        Ptr: ?*anyopaque = null,
    };

    /// Console control callback type.
    pub const HANDLER_ROUTINE = *const fn (DWORD) callconv(.winapi) BOOL;

    /// Win32 errors inspected by Born.
    pub const Win32Error = enum(u32) {
        WAIT_TIMEOUT = 258,
        TIMEOUT = 1460,
        _,
    };

    /// Raw kernel32 functions used by Born and its compatibility primitives.
    pub const kernel32 = struct {
        /// Returns the last Win32 error for the calling thread.
        pub extern "kernel32" fn GetLastError() callconv(.winapi) Win32Error;
        /// Closes a native handle. The caller handles pending completions first.
        pub extern "kernel32" fn CloseHandle(HANDLE) callconv(.winapi) BOOL;
        /// Returns a pseudo-handle for the current process.
        pub extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
        /// Returns the current process handle count.
        pub extern "kernel32" fn GetProcessHandleCount(HANDLE, *DWORD) callconv(.winapi) BOOL;
        /// Suspends the calling thread for at least the requested milliseconds.
        pub extern "kernel32" fn Sleep(DWORD) callconv(.winapi) void;
        /// Reads the high-resolution performance counter.
        pub extern "kernel32" fn QueryPerformanceCounter(*i64) callconv(.winapi) BOOL;
        /// Reads the high-resolution performance counter frequency.
        pub extern "kernel32" fn QueryPerformanceFrequency(*i64) callconv(.winapi) BOOL;
        /// Creates or associates an I/O completion port.
        pub extern "kernel32" fn CreateIoCompletionPort(
            FileHandle: HANDLE,
            ExistingCompletionPort: ?HANDLE,
            CompletionKey: ULONG_PTR,
            NumberOfConcurrentThreads: DWORD,
        ) callconv(.winapi) ?HANDLE;
        /// Harvests a batch of completion-port entries in one call.
        pub extern "kernel32" fn GetQueuedCompletionStatusEx(
            CompletionPort: HANDLE,
            lpCompletionPortEntries: [*]OVERLAPPED_ENTRY,
            ulCount: ULONG,
            ulNumEntriesRemoved: *ULONG,
            dwMilliseconds: DWORD,
            fAlertable: BOOL,
        ) callconv(.winapi) BOOL;
        /// Posts one completion-port entry, optionally with a null overlapped pointer.
        pub extern "kernel32" fn PostQueuedCompletionStatus(
            CompletionPort: HANDLE,
            dwNumberOfBytesTransferred: DWORD,
            dwCompletionKey: ULONG_PTR,
            lpOverlapped: ?*OVERLAPPED,
        ) callconv(.winapi) BOOL;
        /// Requests cancellation of overlapped operations on a handle.
        pub extern "kernel32" fn CancelIoEx(HANDLE, ?*OVERLAPPED) callconv(.winapi) BOOL;
        /// Installs or removes a console control handler, or changes Ctrl+C ignoring.
        pub extern "kernel32" fn SetConsoleCtrlHandler(
            ?HANDLER_ROUTINE,
            BOOL,
        ) callconv(.winapi) BOOL;
        /// Lists processes attached to the current console.
        pub extern "kernel32" fn GetConsoleProcessList([*]DWORD, DWORD) callconv(.winapi) DWORD;
        /// Initializes an SRW lock.
        pub extern "kernel32" fn InitializeSRWLock(*SRWLOCK) callconv(.winapi) void;
        /// Acquires an SRW lock exclusively.
        pub extern "kernel32" fn AcquireSRWLockExclusive(*SRWLOCK) callconv(.winapi) void;
        /// Releases an exclusively held SRW lock.
        pub extern "kernel32" fn ReleaseSRWLockExclusive(*SRWLOCK) callconv(.winapi) void;
        /// Initializes a condition variable.
        pub extern "kernel32" fn InitializeConditionVariable(
            *CONDITION_VARIABLE,
        ) callconv(.winapi) void;
        /// Releases an SRW lock and waits on a condition variable.
        pub extern "kernel32" fn SleepConditionVariableSRW(
            *CONDITION_VARIABLE,
            *SRWLOCK,
            DWORD,
            ULONG,
        ) callconv(.winapi) BOOL;
        /// Wakes one condition-variable waiter.
        pub extern "kernel32" fn WakeConditionVariable(*CONDITION_VARIABLE) callconv(.winapi) void;
        /// Wakes every condition-variable waiter.
        pub extern "kernel32" fn WakeAllConditionVariable(
            *CONDITION_VARIABLE,
        ) callconv(.winapi) void;

        /// Opaque thread-pool timer object.
        pub const TpTimer = opaque {};
        /// Opaque thread-pool callback instance.
        pub const TpCallbackInstance = opaque {};
        /// Native thread-pool timer callback type.
        pub const TimerCallback = *const fn (
            ?*TpCallbackInstance,
            ?*anyopaque,
            *TpTimer,
        ) callconv(.winapi) void;

        /// Creates a thread-pool timer in the process default pool when `pcbe` is null.
        pub extern "kernel32" fn CreateThreadpoolTimer(
            pfnti: TimerCallback,
            pv: ?*anyopaque,
            pcbe: ?*anyopaque,
        ) callconv(.winapi) ?*TpTimer;
        /// Arms or disarms a thread-pool timer using the native relative `FILETIME` convention.
        pub extern "kernel32" fn SetThreadpoolTimer(
            pti: *TpTimer,
            pftDueTime: ?*const FILETIME,
            msPeriod: DWORD,
            msWindowLength: DWORD,
        ) callconv(.winapi) void;
        /// Waits for timer callbacks and optionally cancels queued callbacks.
        pub extern "kernel32" fn WaitForThreadpoolTimerCallbacks(
            pti: *TpTimer,
            fCancelPendingCallbacks: BOOL,
        ) callconv(.winapi) void;
        /// Closes a thread-pool timer after callbacks have drained.
        pub extern "kernel32" fn CloseThreadpoolTimer(pti: *TpTimer) callconv(.winapi) void;
        /// Reports whether a thread-pool timer is currently set.
        pub extern "kernel32" fn IsThreadpoolTimerSet(pti: *TpTimer) callconv(.winapi) BOOL;
    };

    /// Raw Winsock ABI used by Born's IOCP socket and listener backends.
    pub const ws2_32 = struct {
        /// Native Winsock socket handle.
        pub const SOCKET = *opaque {};
        /// Invalid Winsock socket sentinel.
        pub const INVALID_SOCKET: SOCKET = @ptrFromInt(std.math.maxInt(usize));
        /// Winsock operation failure return value.
        pub const SOCKET_ERROR: i32 = -1;
        /// Native Winsock address family type.
        pub const ADDRESS_FAMILY = u16;
        /// Compatibility length type used by address containers.
        pub const socklen_t = u32;
        /// Create an overlapped socket.
        pub const WSA_FLAG_OVERLAPPED: u32 = 0x01;
        /// Disable handle inheritance for a new socket.
        pub const WSA_FLAG_NO_HANDLE_INHERIT: u32 = 0x80;
        /// Extension-function ioctl input flag.
        pub const IOC_IN: u32 = 0x80000000;
        /// Extension-function ioctl output flag.
        pub const IOC_OUT: u32 = 0x40000000;
        /// Winsock ioctl namespace.
        pub const IOC_WS2: u32 = 0x08000000;
        /// Ioctl used to resolve AcceptEx and ConnectEx.
        pub const SIO_GET_EXTENSION_FUNCTION_POINTER: u32 = IOC_IN | IOC_OUT | IOC_WS2 | 6;
        /// Nonblocking-socket ioctl command.
        pub const FIONBIO: i32 = @bitCast(@as(u32, 0x8004667e));
        /// Shutdown receive operations.
        pub const SD_RECEIVE: i32 = 0;
        /// Shutdown send operations.
        pub const SD_SEND: i32 = 1;
        /// Shutdown both directions.
        pub const SD_BOTH: i32 = 2;
        /// IPv6 protocol level.
        pub const IPPROTO_IPV6: i32 = 41;
        /// IPv6-only socket option.
        pub const IPV6_V6ONLY: i32 = 27;

        /// Address family constants used by Born.
        pub const AF = struct {
            /// Unspecified family.
            pub const UNSPEC = 0;
            /// Unix domain sockets.
            pub const UNIX = 1;
            /// IPv4.
            pub const INET = 2;
            /// IPv6.
            pub const INET6 = 23;
        };

        /// Socket type constants used by Born.
        pub const SOCK = struct {
            /// Stream socket.
            pub const STREAM = 1;
            /// Datagram socket.
            pub const DGRAM = 2;
            /// Compatibility close-on-exec flag, stripped before Winsock calls.
            pub const CLOEXEC = 0x10000;
            /// Compatibility nonblocking flag, applied with ioctlsocket.
            pub const NONBLOCK = 0x20000;
        };

        /// Socket option levels used by Born.
        pub const SOL = struct {
            /// Socket-level options.
            pub const SOCKET = 65535;
        };

        /// Socket options used by Born and its test helpers.
        pub const SO = struct {
            /// Address reuse.
            pub const REUSEADDR = 4;
            /// Read the pending socket error.
            pub const ERROR = 4103;
            /// Complete AcceptEx context setup.
            pub const UPDATE_ACCEPT_CONTEXT = 28683;
            /// Complete ConnectEx context setup.
            pub const UPDATE_CONNECT_CONTEXT = 28688;
        };

        /// IP protocol constants used by Born.
        pub const IPPROTO = struct {
            /// Default protocol.
            pub const IP = 0;
            /// TCP.
            pub const TCP = 6;
            /// IPv6.
            pub const IPV6 = 41;
        };

        /// Winsock address-layout definitions, identical to the native SDK.
        pub const sockaddr = extern struct {
            family: ADDRESS_FAMILY,
            data: [14]u8,

            /// Maximum generic socket-address storage.
            pub const SS_MAXSIZE = 128;
            /// Native `SOCKADDR_STORAGE` layout.
            pub const storage = extern struct {
                family: ADDRESS_FAMILY align(8),
                padding: [SS_MAXSIZE - @sizeOf(ADDRESS_FAMILY)]u8 = undefined,
            };
            /// Native IPv4 socket address.
            pub const in = extern struct {
                family: ADDRESS_FAMILY = windows.ws2_32.AF.INET,
                port: u16,
                addr: u32,
                zero: [8]u8 = @splat(0),
            };
            /// Native IPv6 socket address.
            pub const in6 = extern struct {
                family: ADDRESS_FAMILY = windows.ws2_32.AF.INET6,
                port: u16,
                flowinfo: u32,
                addr: [16]u8,
                scope_id: u32,
            };
            /// Native Windows Unix-domain socket address.
            pub const un = extern struct {
                family: ADDRESS_FAMILY = windows.ws2_32.AF.UNIX,
                path: [108]u8,
            };
        };

        /// Winsock `WSADATA`, including the architecture-dependent field order.
        pub const WSADATA = if (@sizeOf(usize) == 8)
            extern struct {
                wVersion: WORD,
                wHighVersion: WORD,
                iMaxSockets: u16,
                iMaxUdpDg: u16,
                lpVendorInfo: *u8,
                szDescription: [257]u8,
                szSystemStatus: [129]u8,
            }
        else
            extern struct {
                wVersion: WORD,
                wHighVersion: WORD,
                szDescription: [257]u8,
                szSystemStatus: [129]u8,
                iMaxSockets: u16,
                iMaxUdpDg: u16,
                lpVendorInfo: *u8,
            };

        /// Native Winsock scatter/gather buffer.
        pub const WSABUF = extern struct {
            len: ULONG,
            buf: [*]u8,
        };

        /// Winsock address-information flags.
        pub const AI = packed struct(u32) {
            PASSIVE: bool = false,
            CANONNAME: bool = false,
            NUMERICHOST: bool = false,
            NUMERICSERV: bool = false,
            DNS_ONLY: bool = false,
            _5: u3 = 0,
            ALL: bool = false,
            _9: u1 = 0,
            ADDRCONFIG: bool = false,
            V4MAPPED: bool = false,
            _12: u2 = 0,
            NON_AUTHORITATIVE: bool = false,
            SECURE: bool = false,
            RETURN_PREFERRED_NAMES: bool = false,
            FQDN: bool = false,
            FILESERVER: bool = false,
            DISABLE_IDN_ENCODING: bool = false,
            _20: u10 = 0,
            RESOLUTION_HANDLE: bool = false,
            EXTENDED: bool = false,
        };

        /// Native `ADDRINFOA` layout.
        pub const addrinfo = extern struct {
            flags: AI,
            family: i32,
            socktype: i32,
            protocol: i32,
            addrlen: usize,
            canonname: ?[*:0]u8,
            addr: ?*windows.ws2_32.sockaddr,
            next: ?*addrinfo,
        };

        /// Overlapped completion callback accepted by Winsock calls.
        pub const LPWSAOVERLAPPED_COMPLETION_ROUTINE = *const fn (
            dwError: u32,
            cbTransferred: u32,
            lpOverlapped: *OVERLAPPED,
            dwFlags: u32,
        ) callconv(.winapi) void;

        /// Opaque protocol-information record used only as a nullable pointer here.
        pub const WSAPROTOCOL_INFOW = opaque {};

        /// Winsock errors surfaced by Born, address resolution, and test helpers.
        pub const WinsockError = enum(u16) {
            WSA_NOT_ENOUGH_MEMORY = 8,
            WSA_OPERATION_ABORTED = 995,
            WSA_IO_INCOMPLETE = 996,
            WSA_IO_PENDING = 997,
            WSAEINTR = 10004,
            WSAEBADF = 10009,
            WSAEACCES = 10013,
            WSAEFAULT = 10014,
            WSAEINVAL = 10022,
            WSAEMFILE = 10024,
            WSAEWOULDBLOCK = 10035,
            WSAEINPROGRESS = 10036,
            WSAEALREADY = 10037,
            WSAENOTSOCK = 10038,
            WSAEDESTADDRREQ = 10039,
            WSAEMSGSIZE = 10040,
            WSAEPROTOTYPE = 10041,
            WSAENOPROTOOPT = 10042,
            WSAEPROTONOSUPPORT = 10043,
            WSAESOCKTNOSUPPORT = 10044,
            WSAEOPNOTSUPP = 10045,
            WSAEPFNOSUPPORT = 10046,
            WSAEAFNOSUPPORT = 10047,
            WSAEADDRINUSE = 10048,
            WSAEADDRNOTAVAIL = 10049,
            WSAENETDOWN = 10050,
            WSAENETUNREACH = 10051,
            WSAENETRESET = 10052,
            WSAECONNABORTED = 10053,
            WSAECONNRESET = 10054,
            WSAENOBUFS = 10055,
            WSAEISCONN = 10056,
            WSAENOTCONN = 10057,
            WSAESHUTDOWN = 10058,
            WSAETIMEDOUT = 10060,
            WSAECONNREFUSED = 10061,
            WSAEHOSTUNREACH = 10065,
            WSANOTINITIALISED = 10093,
            WSATYPE_NOT_FOUND = 10109,
            WSAHOST_NOT_FOUND = 11001,
            WSATRY_AGAIN = 11002,
            WSANO_RECOVERY = 11003,
            WSANO_DATA = 11004,
            _,
        };

        /// Starts a Winsock reference.
        pub extern "ws2_32" fn WSAStartup(WORD, *WSADATA) callconv(.winapi) i32;
        /// Releases a Winsock reference.
        pub extern "ws2_32" fn WSACleanup() callconv(.winapi) i32;
        /// Returns the calling thread's Winsock error.
        pub extern "ws2_32" fn WSAGetLastError() callconv(.winapi) WinsockError;
        /// Creates a socket with native Winsock flags.
        pub extern "ws2_32" fn WSASocketW(
            af: i32,
            @"type": i32,
            protocol: i32,
            lpProtocolInfo: ?*WSAPROTOCOL_INFOW,
            g: u32,
            dwFlags: u32,
        ) callconv(.winapi) SOCKET;
        /// Creates a blocking socket.
        pub extern "ws2_32" fn socket(i32, i32, i32) callconv(.winapi) SOCKET;
        /// Closes a socket. No retry is attempted.
        pub extern "ws2_32" fn closesocket(SOCKET) callconv(.winapi) i32;
        /// Binds a socket address.
        pub extern "ws2_32" fn bind(
            SOCKET,
            *const windows.ws2_32.sockaddr,
            i32,
        ) callconv(.winapi) i32;
        /// Connects a socket.
        pub extern "ws2_32" fn connect(
            SOCKET,
            *const windows.ws2_32.sockaddr,
            i32,
        ) callconv(.winapi) i32;
        /// Marks a socket as listening.
        pub extern "ws2_32" fn listen(SOCKET, i32) callconv(.winapi) i32;
        /// Accepts a connection.
        pub extern "ws2_32" fn accept(
            SOCKET,
            ?*windows.ws2_32.sockaddr,
            ?*i32,
        ) callconv(.winapi) SOCKET;
        /// Returns the local socket address.
        pub extern "ws2_32" fn getsockname(
            SOCKET,
            *windows.ws2_32.sockaddr,
            *i32,
        ) callconv(.winapi) i32;
        /// Returns the peer socket address.
        pub extern "ws2_32" fn getpeername(
            SOCKET,
            *windows.ws2_32.sockaddr,
            *i32,
        ) callconv(.winapi) i32;
        /// Gets a socket option.
        pub extern "ws2_32" fn getsockopt(SOCKET, i32, i32, [*]u8, *i32) callconv(.winapi) i32;
        /// Sets a socket option.
        pub extern "ws2_32" fn setsockopt(
            SOCKET,
            i32,
            i32,
            ?[*]const u8,
            i32,
        ) callconv(.winapi) i32;
        /// Changes blocking or another socket mode.
        pub extern "ws2_32" fn ioctlsocket(SOCKET, i32, *u32) callconv(.winapi) i32;
        /// Performs a Winsock ioctl.
        pub extern "ws2_32" fn WSAIoctl(
            s: SOCKET,
            dwIoControlCode: u32,
            lpvInBuffer: ?*const anyopaque,
            cbInBuffer: u32,
            lpvOutbuffer: ?*anyopaque,
            cbOutbuffer: u32,
            lpcbBytesReturned: *u32,
            lpOverlapped: ?*OVERLAPPED,
            lpCompletionRoutine: ?LPWSAOVERLAPPED_COMPLETION_ROUTINE,
        ) callconv(.winapi) i32;
        /// Starts an overlapped or synchronous receive.
        pub extern "ws2_32" fn WSARecv(
            s: SOCKET,
            lpBuffers: [*]WSABUF,
            dwBufferCount: u32,
            lpNumberOfBytesRecv: ?*u32,
            lpFlags: *u32,
            lpOverlapped: ?*OVERLAPPED,
            lpCompletionRoutine: ?LPWSAOVERLAPPED_COMPLETION_ROUTINE,
        ) callconv(.winapi) i32;
        /// Starts an overlapped or synchronous send.
        pub extern "ws2_32" fn WSASend(
            s: SOCKET,
            lpBuffers: [*]WSABUF,
            dwBufferCount: u32,
            lpNumberOfBytesSent: ?*u32,
            dwFlags: u32,
            lpOverlapped: ?*OVERLAPPED,
            lpCompletionRoutine: ?LPWSAOVERLAPPED_COMPLETION_ROUTINE,
        ) callconv(.winapi) i32;
        /// Receives bytes from a blocking socket.
        pub extern "ws2_32" fn recv(SOCKET, [*]u8, i32, i32) callconv(.winapi) i32;
        /// Sends bytes on a blocking socket.
        pub extern "ws2_32" fn send(SOCKET, [*]const u8, i32, u32) callconv(.winapi) i32;
        /// Shuts down one or both socket directions.
        pub extern "ws2_32" fn shutdown(SOCKET, i32) callconv(.winapi) i32;
        /// Resolves names through the system `getaddrinfo` provider.
        pub extern "ws2_32" fn getaddrinfo(
            ?[*:0]const u8,
            ?[*:0]const u8,
            ?*const addrinfo,
            *?*addrinfo,
        ) callconv(.winapi) i32;
        /// Frees a Winsock address-information chain.
        pub extern "ws2_32" fn freeaddrinfo(?*addrinfo) callconv(.winapi) void;
    };
};

/// Native POSIX descriptor on POSIX targets.
pub const fd_t = std.c.fd_t;
/// Native socket handle for the current target.
pub const socket_t = if (is_windows) windows.ws2_32.SOCKET else fd_t;
/// Native process identifier.
pub const pid_t = std.c.pid_t;
/// Native file mode type.
pub const mode_t = std.c.mode_t;
/// Native socket length type used by this compatibility surface.
pub const socklen_t = if (is_windows) i32 else std.c.socklen_t;
/// Native socket-address layouts.
pub const sockaddr = if (is_windows) windows.ws2_32.sockaddr else std.c.sockaddr;
/// Native errno enumeration.
pub const E = std.c.E;
/// Native open flags.
pub const O = std.c.O;
/// Native fcntl commands.
pub const F = std.c.F;
/// Native `AT_*` flags.
pub const AT = std.c.AT;
/// Native address-family constants.
pub const AF = if (is_windows) windows.ws2_32.AF else std.c.AF;
/// Native socket-type constants.
pub const SOCK = if (is_windows) windows.ws2_32.SOCK else std.c.SOCK;
/// Native socket-option constants.
pub const SO = if (is_windows) windows.ws2_32.SO else std.c.SO;
/// Native socket-option levels.
pub const SOL = if (is_windows) windows.ws2_32.SOL else std.c.SOL;
/// Native IP protocol constants.
pub const IPPROTO = if (is_windows) windows.ws2_32.IPPROTO else std.c.IPPROTO;
/// Native send flags.
pub const MSG = std.c.MSG;
/// Native shutdown constants.
pub const SHUT = std.c.SHUT;
/// Native close-on-exec descriptor flag.
pub const FD_CLOEXEC = std.c.FD_CLOEXEC;
/// Native clock identifier type.
pub const clockid_t = std.c.clockid_t;
/// Native clock identifiers.
pub const CLOCK = std.c.CLOCK;
/// Native timespec layout.
pub const timespec = std.c.timespec;
/// Native signal-set layout.
pub const sigset_t = std.c.sigset_t;
/// Native signal-action layout.
pub const Sigaction = std.c.Sigaction;
/// Native file-type and permission constants.
pub const S = std.c.S;
/// Native kqueue event layout where kqueue exists.
pub const Kevent = std.c.Kevent;
/// An otherwise unclassified operating-system refusal.
pub const UnexpectedError = error{Unexpected};

fn errno(rc: anytype) E {
    return std.posix.errno(rc);
}

fn unexpected() UnexpectedError {
    return error.Unexpected;
}

/// Socket creation failures, preserving the former `std.posix` names.
pub const SocketError = error{
    AccessDenied,
    AddressFamilyNotSupported,
    ProtocolFamilyNotAvailable,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    ProtocolNotSupported,
    SocketTypeNotSupported,
    Unexpected,
};

/// Bind failures.
pub const BindError = error{
    AccessDenied,
    AddressInUse,
    AddressNotAvailable,
    AddressFamilyNotSupported,
    SymLinkLoop,
    NameTooLong,
    FileNotFound,
    SystemResources,
    NotDir,
    ReadOnlyFileSystem,
    NetworkSubsystemFailed,
    FileDescriptorNotASocket,
    AlreadyBound,
    Unexpected,
};

/// Listen failures.
pub const ListenError = error{
    AddressInUse,
    FileDescriptorNotASocket,
    OperationNotSupported,
    NetworkSubsystemFailed,
    SystemResources,
    AlreadyConnected,
    SocketNotBound,
    Unexpected,
};

/// Accept failures.
pub const AcceptError = error{
    ConnectionAborted,
    FileDescriptorNotASocket,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    SocketNotListening,
    ProtocolFailure,
    BlockedByFirewall,
    WouldBlock,
    ConnectionResetByPeer,
    NetworkSubsystemFailed,
    OperationNotSupported,
    Unexpected,
};

/// Connect failures.
pub const ConnectError = error{
    AccessDenied,
    PermissionDenied,
    AddressInUse,
    AddressNotAvailable,
    AddressFamilyNotSupported,
    SystemResources,
    ConnectionRefused,
    NetworkUnreachable,
    ConnectionTimedOut,
    WouldBlock,
    FileNotFound,
    ConnectionResetByPeer,
    ConnectionPending,
    Unexpected,
};

/// Socket-option query failures.
pub const GetSockOptError = error{
    AccessDenied,
    InvalidProtocolOption,
    SystemResources,
    Unexpected,
};

/// Socket-option update failures.
pub const SetSockOptError = error{
    AlreadyConnected,
    InvalidProtocolOption,
    TimeoutTooBig,
    SystemResources,
    PermissionDenied,
    OperationNotSupported,
    NetworkSubsystemFailed,
    FileDescriptorNotASocket,
    SocketNotBound,
    NoDevice,
    Unexpected,
};

/// Local or peer socket-name query failures.
pub const GetSockNameError = error{
    SystemResources,
    NetworkSubsystemFailed,
    SocketNotBound,
    FileDescriptorNotASocket,
    Unexpected,
};

/// Read failures.
pub const ReadError = error{
    InputOutput,
    SystemResources,
    IsDir,
    OperationAborted,
    BrokenPipe,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    NotOpenForReading,
    SocketNotConnected,
    WouldBlock,
    Canceled,
    AccessDenied,
    ProcessNotFound,
    LockViolation,
    InvalidArgument,
    NoDevice,
    MessageTooBig,
    Unexpected,
};

/// Write failures.
pub const WriteError = error{
    DiskQuota,
    FileTooBig,
    InputOutput,
    NoSpaceLeft,
    DeviceBusy,
    InvalidArgument,
    AccessDenied,
    PermissionDenied,
    BrokenPipe,
    SystemResources,
    OperationAborted,
    NotOpenForWriting,
    LockViolation,
    WouldBlock,
    ConnectionResetByPeer,
    ProcessNotFound,
    NoDevice,
    MessageTooBig,
    Unexpected,
};

/// Send failures.
pub const SendError = error{
    AccessDenied,
    WouldBlock,
    FastOpenAlreadyInProgress,
    ConnectionResetByPeer,
    MessageTooBig,
    SystemResources,
    BrokenPipe,
    FileDescriptorNotASocket,
    NetworkUnreachable,
    NetworkSubsystemFailed,
    ConnectionRefused,
    Unexpected,
};

/// Open failures needed by Born's process and file helpers.
pub const OpenError = error{
    AccessDenied,
    PermissionDenied,
    SymLinkLoop,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    NoDevice,
    FileNotFound,
    NameTooLong,
    SystemResources,
    FileTooBig,
    IsDir,
    NoSpaceLeft,
    NotDir,
    PathAlreadyExists,
    DeviceBusy,
    FileBusy,
    WouldBlock,
    BadPathName,
    ProcessNotFound,
    Unexpected,
};

/// Fcntl failures.
pub const FcntlError = error{
    PermissionDenied,
    FileBusy,
    ProcessFdQuotaExceeded,
    Locked,
    DeadLock,
    LockedRegionLimitExceeded,
    Unexpected,
};

/// Pipe creation failures.
pub const PipeError = error{
    SystemFdQuotaExceeded,
    ProcessFdQuotaExceeded,
    Unexpected,
};

/// Kqueue creation failures.
pub const KQueueError = error{
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    Unsupported,
    Unexpected,
};

/// Clock query failures.
pub const ClockGetTimeError = error{ UnsupportedClock, Unexpected };

/// Shutdown direction.
pub const ShutdownHow = enum { recv, send, both };

/// Shutdown failures.
pub const ShutdownError = error{
    ConnectionAborted,
    ConnectionResetByPeer,
    BlockingOperationInProgress,
    NetworkSubsystemFailed,
    SocketNotConnected,
    SystemResources,
    Unexpected,
};

/// Symlink creation failures.
pub const SymLinkError = error{
    AccessDenied,
    PermissionDenied,
    DiskQuota,
    PathAlreadyExists,
    FileSystem,
    SymLinkLoop,
    FileNotFound,
    SystemResources,
    NoSpaceLeft,
    ReadOnlyFileSystem,
    NotDir,
    NameTooLong,
    Unexpected,
};

/// Unlink failures.
pub const UnlinkError = error{
    FileNotFound,
    AccessDenied,
    PermissionDenied,
    FileBusy,
    FileSystem,
    IsDir,
    SymLinkLoop,
    NameTooLong,
    NotDir,
    SystemResources,
    ReadOnlyFileSystem,
    Unexpected,
};

/// File-stat failures.
pub const FStatAtError = error{
    SystemResources,
    AccessDenied,
    PermissionDenied,
    NameTooLong,
    FileNotFound,
    SymLinkLoop,
    Unexpected,
};

/// chmod-by-path failures, including Linux procfs fallback failures.
pub const FChmodAtError = error{
    AccessDenied,
    PermissionDenied,
    InputOutput,
    SymLinkLoop,
    FileNotFound,
    SystemResources,
    ReadOnlyFileSystem,
    NameTooLong,
    OperationNotSupported,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    Unexpected,
};

/// Kill failures.
pub const KillError = error{ ProcessNotFound, PermissionDenied, Unexpected };

/// Raise failures.
pub const RaiseError = error{Unexpected};

/// Closes a descriptor once. EINTR is treated as closure and never retried.
pub fn close(fd: fd_t) void {
    if (comptime is_windows) @compileError("close is POSIX-only; use closesocket for Winsock");
    _ = std.c.close(fd);
}

/// Creates a socket and applies nonblocking and close-on-exec flags atomically
/// where the target supports them, with fcntl fallback on Darwin. Windows uses
/// WSA_FLAG_NO_HANDLE_INHERIT and ioctlsocket. The Windows caller must already
/// hold a WSAStartup reference; this function never acquires or releases one.
pub fn socket(domain: u32, socket_type: u32, protocol: u32) SocketError!socket_t {
    if (comptime is_windows) {
        var flags: u32 = windows.ws2_32.WSA_FLAG_OVERLAPPED;
        if ((socket_type & windows.ws2_32.SOCK.CLOEXEC) != 0) {
            flags |= windows.ws2_32.WSA_FLAG_NO_HANDLE_INHERIT;
        }
        const compatibility_flags = windows.ws2_32.SOCK.NONBLOCK | windows.ws2_32.SOCK.CLOEXEC;
        const filtered = socket_type & ~@as(u32, compatibility_flags);
        const s = windows.ws2_32.WSASocketW(
            @intCast(domain),
            @intCast(filtered),
            @intCast(protocol),
            null,
            0,
            flags,
        );
        if (s == windows.ws2_32.INVALID_SOCKET) {
            return mapWsaSocket(windows.ws2_32.WSAGetLastError());
        }
        errdefer _ = windows.ws2_32.closesocket(s);
        if ((socket_type & windows.ws2_32.SOCK.NONBLOCK) != 0) {
            var mode: u32 = 1;
            if (windows.ws2_32.ioctlsocket(s, windows.ws2_32.FIONBIO, &mode) != 0) {
                return error.Unexpected;
            }
        }
        return s;
    }

    const have_flags = !is_darwin;
    const filtered = if (have_flags)
        socket_type
    else
        socket_type & ~@as(u32, SOCK.NONBLOCK | SOCK.CLOEXEC);
    const rc = std.c.socket(domain, filtered, protocol);
    switch (errno(rc)) {
        .SUCCESS => {
            const fd: fd_t = @intCast(rc);
            errdefer close(fd);
            if (!have_flags) try setSocketFlags(fd, socket_type);
            return fd;
        },
        .ACCES => return error.AccessDenied,
        .AFNOSUPPORT => return error.AddressFamilyNotSupported,
        .INVAL => return error.ProtocolFamilyNotAvailable,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOBUFS, .NOMEM => return error.SystemResources,
        .PROTONOSUPPORT => return error.ProtocolNotSupported,
        .PROTOTYPE => return error.SocketTypeNotSupported,
        else => return unexpected(),
    }
}

fn mapWsaSocket(err: windows.ws2_32.WinsockError) SocketError {
    return switch (err) {
        .WSAEACCES => error.AccessDenied,
        .WSAEAFNOSUPPORT => error.AddressFamilyNotSupported,
        .WSAEPFNOSUPPORT => error.ProtocolFamilyNotAvailable,
        .WSAEMFILE => error.ProcessFdQuotaExceeded,
        .WSAENOBUFS => error.SystemResources,
        .WSAEPROTONOSUPPORT => error.ProtocolNotSupported,
        .WSAEPROTOTYPE => error.SocketTypeNotSupported,
        else => error.Unexpected,
    };
}

fn setSocketFlags(fd: fd_t, flags: u32) SocketError!void {
    if ((flags & SOCK.CLOEXEC) != 0) {
        _ = fcntl(fd, F.SETFD, FD_CLOEXEC) catch return error.Unexpected;
    }
    if ((flags & SOCK.NONBLOCK) != 0) {
        const current = fcntl(fd, F.GETFL, 0) catch return error.Unexpected;
        const nonblock: u32 = @bitCast(@as(O, .{ .NONBLOCK = true }));
        _ = fcntl(fd, F.SETFL, current | nonblock) catch return error.Unexpected;
    }
}

/// Binds a native socket address.
pub fn bind(sock: socket_t, addr: *const sockaddr, len: socklen_t) BindError!void {
    if (comptime is_windows) {
        if (windows.ws2_32.bind(sock, addr, len) == 0) return;
        return switch (windows.ws2_32.WSAGetLastError()) {
            .WSAEACCES => error.AccessDenied,
            .WSAEADDRINUSE => error.AddressInUse,
            .WSAEADDRNOTAVAIL => error.AddressNotAvailable,
            .WSAEAFNOSUPPORT => error.AddressFamilyNotSupported,
            .WSAENOBUFS => error.SystemResources,
            .WSAENETDOWN => error.NetworkSubsystemFailed,
            .WSAENOTSOCK => error.FileDescriptorNotASocket,
            .WSAEINVAL => error.AlreadyBound,
            else => error.Unexpected,
        };
    }
    switch (errno(std.c.bind(sock, addr, len))) {
        .SUCCESS => return,
        .ACCES, .PERM => return error.AccessDenied,
        .ADDRINUSE => return error.AddressInUse,
        .AFNOSUPPORT => return error.AddressFamilyNotSupported,
        .ADDRNOTAVAIL => return error.AddressNotAvailable,
        .LOOP => return error.SymLinkLoop,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOMEM => return error.SystemResources,
        .NOTDIR => return error.NotDir,
        .ROFS => return error.ReadOnlyFileSystem,
        .BADF, .INVAL, .NOTSOCK, .FAULT => unreachable,
        else => return unexpected(),
    }
}

/// Starts listening with the supplied backlog.
pub fn listen(sock: socket_t, backlog: u31) ListenError!void {
    if (comptime is_windows) {
        if (windows.ws2_32.listen(sock, backlog) == 0) return;
        return switch (windows.ws2_32.WSAGetLastError()) {
            .WSAEADDRINUSE => error.AddressInUse,
            .WSAENOTSOCK => error.FileDescriptorNotASocket,
            .WSAEOPNOTSUPP => error.OperationNotSupported,
            .WSAENETDOWN => error.NetworkSubsystemFailed,
            .WSAEMFILE, .WSAENOBUFS => error.SystemResources,
            .WSAEISCONN => error.AlreadyConnected,
            .WSAEINVAL => error.SocketNotBound,
            else => error.Unexpected,
        };
    }
    switch (errno(std.c.listen(sock, backlog))) {
        .SUCCESS => return,
        .ADDRINUSE => return error.AddressInUse,
        .NOTSOCK => return error.FileDescriptorNotASocket,
        .OPNOTSUPP => return error.OperationNotSupported,
        .BADF => unreachable,
        else => return unexpected(),
    }
}

/// Accepts one connection, retrying EINTR and applying flags with Darwin's
/// accept-plus-fcntl fallback. Nonblocking sockets return `error.WouldBlock`.
pub fn accept(
    sock: socket_t,
    addr: ?*sockaddr,
    addr_size: ?*socklen_t,
    flags: u32,
) AcceptError!socket_t {
    if (comptime is_windows) {
        const accepted = windows.ws2_32.accept(sock, addr, addr_size);
        if (accepted == windows.ws2_32.INVALID_SOCKET) {
            return switch (windows.ws2_32.WSAGetLastError()) {
                .WSAECONNRESET => error.ConnectionResetByPeer,
                .WSAECONNABORTED => error.ConnectionAborted,
                .WSAENOTSOCK => error.FileDescriptorNotASocket,
                .WSAEINVAL => error.SocketNotListening,
                .WSAEMFILE => error.ProcessFdQuotaExceeded,
                .WSAENOBUFS => error.SystemResources,
                .WSAEACCES => error.BlockedByFirewall,
                .WSAENETDOWN => error.NetworkSubsystemFailed,
                .WSAEOPNOTSUPP => error.OperationNotSupported,
                .WSAEWOULDBLOCK => error.WouldBlock,
                else => error.Unexpected,
            };
        }
        if ((flags & windows.ws2_32.SOCK.NONBLOCK) != 0) {
            var mode: u32 = 1;
            if (windows.ws2_32.ioctlsocket(accepted, windows.ws2_32.FIONBIO, &mode) != 0) {
                _ = windows.ws2_32.closesocket(accepted);
                return error.Unexpected;
            }
        }
        return accepted;
    }

    const accepted: fd_t = while (true) {
        const rc = if (comptime !is_darwin)
            std.c.accept4(sock, addr, addr_size, flags)
        else
            std.c.accept(sock, addr, addr_size);
        switch (errno(rc)) {
            .SUCCESS => break @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .CONNABORTED => return error.ConnectionAborted,
            .INVAL => return error.SocketNotListening,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .PROTO => return error.ProtocolFailure,
            .PERM => return error.BlockedByFirewall,
            .BADF, .FAULT, .NOTSOCK, .OPNOTSUPP => unreachable,
            else => return unexpected(),
        }
    };
    errdefer close(accepted);
    if (comptime is_darwin) {
        if ((flags & SOCK.CLOEXEC) != 0) {
            _ = fcntl(accepted, F.SETFD, FD_CLOEXEC) catch return error.Unexpected;
        }
        if ((flags & SOCK.NONBLOCK) != 0) {
            const current = fcntl(accepted, F.GETFL, 0) catch return error.Unexpected;
            const nonblock: u32 = @bitCast(@as(O, .{ .NONBLOCK = true }));
            _ = fcntl(accepted, F.SETFL, current | nonblock) catch return error.Unexpected;
        }
    }
    return accepted;
}

/// Accepts with native accept4 flags, using accept plus fcntl on Darwin.
pub fn accept4(
    sock: socket_t,
    addr: ?*sockaddr,
    addr_size: ?*socklen_t,
    flags: u32,
) AcceptError!socket_t {
    return this.accept(sock, addr, addr_size, flags);
}

/// Connects a socket. Nonblocking EINPROGRESS is `error.WouldBlock`.
pub fn connect(sock: socket_t, addr: *const sockaddr, len: socklen_t) ConnectError!void {
    if (comptime is_windows) {
        if (windows.ws2_32.connect(sock, addr, len) == 0) return;
        return switch (windows.ws2_32.WSAGetLastError()) {
            .WSAEADDRINUSE => error.AddressInUse,
            .WSAEADDRNOTAVAIL => error.AddressNotAvailable,
            .WSAECONNREFUSED => error.ConnectionRefused,
            .WSAECONNRESET => error.ConnectionResetByPeer,
            .WSAETIMEDOUT => error.ConnectionTimedOut,
            .WSAEHOSTUNREACH, .WSAENETUNREACH => error.NetworkUnreachable,
            .WSAEWOULDBLOCK => error.WouldBlock,
            .WSAEALREADY => error.ConnectionPending,
            .WSAENOBUFS => error.SystemResources,
            .WSAEAFNOSUPPORT => error.AddressFamilyNotSupported,
            else => error.Unexpected,
        };
    }
    while (true) {
        switch (errno(std.c.connect(sock, addr, len))) {
            .SUCCESS => return,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .ADDRINUSE => return error.AddressInUse,
            .ADDRNOTAVAIL => return error.AddressNotAvailable,
            .AFNOSUPPORT => return error.AddressFamilyNotSupported,
            .AGAIN, .INPROGRESS => return error.WouldBlock,
            .ALREADY => return error.ConnectionPending,
            .CONNREFUSED => return error.ConnectionRefused,
            .CONNRESET => return error.ConnectionResetByPeer,
            .HOSTUNREACH, .NETUNREACH => return error.NetworkUnreachable,
            .TIMEDOUT => return error.ConnectionTimedOut,
            .NOENT => return error.FileNotFound,
            .INTR => continue,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .BADF, .FAULT, .ISCONN, .NOTSOCK, .PROTOTYPE, .CONNABORTED => unreachable,
            else => return unexpected(),
        }
    }
}

/// Reads a socket option into `opt`.
pub fn getsockopt(sock: socket_t, level: i32, option: u32, opt: []u8) GetSockOptError!void {
    if (comptime is_windows) {
        var len: i32 = @intCast(opt.len);
        if (windows.ws2_32.getsockopt(sock, level, @intCast(option), opt.ptr, &len) == 0) return;
        return switch (windows.ws2_32.WSAGetLastError()) {
            .WSAEACCES => error.AccessDenied,
            .WSAENOPROTOOPT => error.InvalidProtocolOption,
            .WSAENOBUFS => error.SystemResources,
            else => error.Unexpected,
        };
    }
    var len: std.c.socklen_t = @intCast(opt.len);
    switch (errno(std.c.getsockopt(sock, level, option, opt.ptr, &len))) {
        .SUCCESS => std.debug.assert(len == opt.len),
        .NOPROTOOPT => return error.InvalidProtocolOption,
        .NOMEM, .NOBUFS => return error.SystemResources,
        .ACCES => return error.AccessDenied,
        .BADF, .NOTSOCK, .INVAL, .FAULT => unreachable,
        else => return unexpected(),
    }
}

/// Sets a socket option from the bytes in `opt`.
pub fn setsockopt(sock: socket_t, level: i32, option: u32, opt: []const u8) SetSockOptError!void {
    if (comptime is_windows) {
        const ptr: ?[*]const u8 = if (opt.len == 0) null else opt.ptr;
        const rc = windows.ws2_32.setsockopt(
            sock,
            level,
            @intCast(option),
            ptr,
            @intCast(opt.len),
        );
        if (rc == 0) return;
        return switch (windows.ws2_32.WSAGetLastError()) {
            .WSAENETDOWN => error.NetworkSubsystemFailed,
            .WSAENOTSOCK => error.FileDescriptorNotASocket,
            .WSAEINVAL => error.SocketNotBound,
            .WSAEACCES => error.PermissionDenied,
            .WSAENOPROTOOPT => error.InvalidProtocolOption,
            .WSAENOBUFS => error.SystemResources,
            else => error.Unexpected,
        };
    }
    switch (errno(std.c.setsockopt(sock, level, option, opt.ptr, @intCast(opt.len)))) {
        .SUCCESS => return,
        .DOM => return error.TimeoutTooBig,
        .ISCONN => return error.AlreadyConnected,
        .NOPROTOOPT => return error.InvalidProtocolOption,
        .NOMEM, .NOBUFS => return error.SystemResources,
        .PERM => return error.PermissionDenied,
        .NODEV => return error.NoDevice,
        .OPNOTSUPP => return error.OperationNotSupported,
        .BADF, .NOTSOCK, .INVAL, .FAULT => unreachable,
        else => return unexpected(),
    }
}

/// Writes the local socket address into caller-provided native storage.
pub fn getsockname(sock: socket_t, addr: *sockaddr, len: *socklen_t) GetSockNameError!void {
    if (comptime is_windows) {
        if (windows.ws2_32.getsockname(sock, addr, len) == 0) return;
        return switch (windows.ws2_32.WSAGetLastError()) {
            .WSAENOTSOCK => error.FileDescriptorNotASocket,
            .WSAENOBUFS => error.SystemResources,
            .WSAENETDOWN => error.NetworkSubsystemFailed,
            .WSAEINVAL => error.SocketNotBound,
            else => error.Unexpected,
        };
    }
    switch (errno(std.c.getsockname(sock, addr, len))) {
        .SUCCESS => return,
        .NOBUFS, .NOMEM => return error.SystemResources,
        .NOTSOCK => return error.FileDescriptorNotASocket,
        .BADF, .INVAL, .FAULT => unreachable,
        else => return unexpected(),
    }
}

/// Writes the peer socket address into caller-provided native storage.
pub fn getpeername(sock: socket_t, addr: *sockaddr, len: *socklen_t) GetSockNameError!void {
    if (comptime is_windows) {
        if (windows.ws2_32.getpeername(sock, addr, len) == 0) return;
        return switch (windows.ws2_32.WSAGetLastError()) {
            .WSAENOTSOCK => error.FileDescriptorNotASocket,
            .WSAENOBUFS => error.SystemResources,
            .WSAENETDOWN => error.NetworkSubsystemFailed,
            .WSAEINVAL => error.SocketNotBound,
            else => error.Unexpected,
        };
    }
    switch (errno(std.c.getpeername(sock, addr, len))) {
        .SUCCESS => return,
        .NOBUFS, .NOMEM => return error.SystemResources,
        .NOTSOCK => return error.FileDescriptorNotASocket,
        .BADF, .INVAL, .FAULT => unreachable,
        else => return unexpected(),
    }
}

/// Largest byte count passed to one native read or write call.
pub const max_io_count: usize = if (is_linux)
    0x7ffff000
else if (is_darwin)
    std.math.maxInt(i32)
else
    std.math.maxInt(isize);

/// Reads bytes, retrying EINTR and preserving nonblocking `WouldBlock`.
pub fn read(fd: fd_t, buffer: []u8) ReadError!usize {
    if (comptime is_windows) @compileError("POSIX read is unavailable on Windows");
    if (buffer.len == 0) return 0;
    const max_count = max_io_count;
    while (true) {
        const rc = std.c.read(fd, buffer.ptr, @min(buffer.len, max_count));
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .CANCELED => return error.Canceled,
            .BADF => return error.NotOpenForReading,
            .SRCH => return error.ProcessNotFound,
            .INVAL => return error.InvalidArgument,
            .NXIO => return error.NoDevice,
            .MSGSIZE => return error.MessageTooBig,
            .IO => return error.InputOutput,
            .ISDIR => return error.IsDir,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .NOTCONN => return error.SocketNotConnected,
            .CONNRESET => return error.ConnectionResetByPeer,
            .TIMEDOUT => return error.ConnectionTimedOut,
            .FAULT => unreachable,
            else => return unexpected(),
        }
    }
}

/// Writes bytes, retrying EINTR and preserving nonblocking `WouldBlock`.
pub fn write(fd: fd_t, bytes: []const u8) WriteError!usize {
    if (comptime is_windows) @compileError("POSIX write is unavailable on Windows");
    if (bytes.len == 0) return 0;
    const max_count = max_io_count;
    while (true) {
        const rc = std.c.write(fd, bytes.ptr, @min(bytes.len, max_count));
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .BADF => return error.NotOpenForWriting,
            .SRCH => return error.ProcessNotFound,
            .INVAL => return error.InvalidArgument,
            .NXIO => return error.NoDevice,
            .MSGSIZE => return error.MessageTooBig,
            .DQUOT => return error.DiskQuota,
            .FBIG => return error.FileTooBig,
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .PERM => return error.PermissionDenied,
            .ACCES => return error.AccessDenied,
            .PIPE => return error.BrokenPipe,
            .BUSY => return error.DeviceBusy,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .CONNRESET => return error.ConnectionResetByPeer,
            .FAULT, .DESTADDRREQ => unreachable,
            else => return unexpected(),
        }
    }
}

/// Sends bytes with the caller's native flags, retrying EINTR. Empty sends
/// return zero without entering the kernel.
pub fn send(sock: socket_t, bytes: []const u8, flags: u32) SendError!usize {
    if (bytes.len == 0) return 0;
    if (comptime is_windows) {
        const rc = windows.ws2_32.send(sock, bytes.ptr, @intCast(bytes.len), flags);
        if (rc >= 0) return @intCast(rc);
        return switch (windows.ws2_32.WSAGetLastError()) {
            .WSAEACCES => error.AccessDenied,
            .WSAEWOULDBLOCK => error.WouldBlock,
            .WSAECONNRESET => error.ConnectionResetByPeer,
            .WSAEMSGSIZE => error.MessageTooBig,
            .WSAENOBUFS => error.SystemResources,
            .WSAENOTSOCK => error.FileDescriptorNotASocket,
            .WSAENETUNREACH => error.NetworkUnreachable,
            .WSAENETDOWN => error.NetworkSubsystemFailed,
            .WSAECONNREFUSED => error.ConnectionRefused,
            .WSAESHUTDOWN => error.BrokenPipe,
            else => error.Unexpected,
        };
    }
    while (true) {
        const rc = std.c.send(sock, bytes.ptr, bytes.len, flags);
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .ACCES => return error.AccessDenied,
            .AGAIN => return error.WouldBlock,
            .ALREADY => return error.FastOpenAlreadyInProgress,
            .CONNRESET => return error.ConnectionResetByPeer,
            .MSGSIZE => return error.MessageTooBig,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .PIPE => return error.BrokenPipe,
            .NOTSOCK => return error.FileDescriptorNotASocket,
            .NETUNREACH => return error.NetworkUnreachable,
            .NETDOWN => return error.NetworkSubsystemFailed,
            .CONNREFUSED => return error.ConnectionRefused,
            .BADF, .FAULT, .INVAL => unreachable,
            else => return unexpected(),
        }
    }
}

/// Runs fcntl, retrying EINTR and preserving the former error mapping.
pub fn fcntl(fd: fd_t, command: i32, argument: usize) FcntlError!usize {
    if (comptime is_windows) @compileError("fcntl is POSIX-only");
    while (true) {
        const rc = std.c.fcntl(fd, command, argument);
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN, .ACCES => return error.Locked,
            .BUSY => return error.FileBusy,
            .PERM => return error.PermissionDenied,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .DEADLK => return error.DeadLock,
            .NOLCK => return error.LockedRegionLimitExceeded,
            .BADF, .INVAL, .NOTDIR => unreachable,
            else => return unexpected(),
        }
    }
}

const max_path_bytes = 4096;
const PathBuffer = [max_path_bytes:0]u8;

fn pathBuffer(path: []const u8, buffer: *PathBuffer) error{NameTooLong}![:0]u8 {
    if (path.len >= buffer.len) return error.NameTooLong;
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;
    return buffer[0..path.len :0];
}

/// Opens a path, retrying EINTR.
pub fn open(path: []const u8, flags: O, permissions: mode_t) OpenError!fd_t {
    var buffer: PathBuffer = undefined;
    const path_z = try pathBuffer(path, &buffer);
    return openZ(path_z.ptr, flags, permissions);
}

/// Opens a sentinel-terminated path, retrying EINTR.
pub fn openZ(path: [*:0]const u8, flags: O, permissions: mode_t) OpenError!fd_t {
    if (comptime is_windows) @compileError("open is POSIX-only");
    while (true) {
        const rc = std.c.open(path, flags, permissions);
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .LOOP => return error.SymLinkLoop,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NODEV => return error.NoDevice,
            .NOENT => return error.FileNotFound,
            .NAMETOOLONG => return error.NameTooLong,
            .NOMEM => return error.SystemResources,
            .FBIG => return error.FileTooBig,
            .ISDIR => return error.IsDir,
            .NOSPC => return error.NoSpaceLeft,
            .NOTDIR => return error.NotDir,
            .EXIST => return error.PathAlreadyExists,
            .BUSY => return error.DeviceBusy,
            .TXTBSY => return error.FileBusy,
            .AGAIN => return error.WouldBlock,
            .INVAL => return error.BadPathName,
            .OVERFLOW => return error.FileTooBig,
            .SRCH => return error.ProcessNotFound,
            .FAULT => unreachable,
            else => return unexpected(),
        }
    }
}

/// Opens a directory descriptor for anchoring `*at` operations against a
/// parent-directory swap. Uses O_PATH where the platform has it (Linux,
/// FreeBSD) so no read permission on the directory is required; O_RDONLY
/// elsewhere. The descriptor is close-on-exec and never used for read/write.
pub fn openDirAnchor(path: []const u8) OpenError!fd_t {
    if (comptime is_windows) @compileError("openDirAnchor is POSIX-only");
    var flags: O = .{ .DIRECTORY = true, .CLOEXEC = true };
    if (comptime @hasField(O, "PATH")) flags.PATH = true;
    return open(path, flags, 0);
}

/// Duplicates a descriptor.
pub fn dup(fd: fd_t) OpenError!fd_t {
    if (comptime is_windows) @compileError("dup is POSIX-only");
    const rc = std.c.dup(fd);
    switch (errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .MFILE => return error.ProcessFdQuotaExceeded,
        .BADF => unreachable,
        else => return unexpected(),
    }
}

/// Duplicates a descriptor onto `target`, retrying EINTR.
pub fn dup2(fd: fd_t, target: fd_t) OpenError!void {
    if (comptime is_windows) @compileError("dup2 is POSIX-only");
    while (true) {
        switch (errno(std.c.dup2(fd, target))) {
            .SUCCESS => return,
            .BUSY, .INTR => continue,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .INVAL, .BADF => unreachable,
            else => return unexpected(),
        }
    }
}

/// Creates a pipe with native flags, or Darwin's pipe-plus-fcntl fallback.
pub fn pipe2(flags: O) PipeError![2]fd_t {
    if (comptime is_windows) @compileError("pipe2 is POSIX-only");
    if (comptime !is_darwin) {
        var fds: [2]fd_t = undefined;
        switch (errno(std.c.pipe2(&fds, flags))) {
            .SUCCESS => return fds,
            .NFILE => return error.SystemFdQuotaExceeded,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .INVAL, .FAULT => unreachable,
            else => return unexpected(),
        }
    } else {
        var fds: [2]fd_t = undefined;
        switch (errno(std.c.pipe(&fds))) {
            .SUCCESS => {},
            .NFILE => return error.SystemFdQuotaExceeded,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .INVAL, .FAULT => unreachable,
            else => return unexpected(),
        }
        errdefer {
            close(fds[0]);
            close(fds[1]);
        }
        if (flags.CLOEXEC) {
            for (fds) |fd| _ = fcntl(fd, F.SETFD, FD_CLOEXEC) catch return error.Unexpected;
        }
        if (flags.NONBLOCK) {
            const nonblock: u32 = @bitCast(@as(O, .{ .NONBLOCK = true }));
            for (fds) |fd| {
                const current = fcntl(fd, F.GETFL, 0) catch return error.Unexpected;
                _ = fcntl(fd, F.SETFL, current | nonblock) catch return error.Unexpected;
            }
        }
        return fds;
    }
}

/// Creates a kqueue descriptor on kqueue targets.
pub fn kqueue() KQueueError!fd_t {
    if (comptime is_windows or is_linux) return error.Unsupported;
    const rc = std.c.kqueue();
    switch (errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        else => return unexpected(),
    }
}

/// Reads a native clock.
pub fn clock_gettime(clock: clockid_t) ClockGetTimeError!timespec {
    if (comptime is_windows) @compileError("use monotonicNs on Windows");
    var value: timespec = undefined;
    switch (errno(std.c.clock_gettime(clock, &value))) {
        .SUCCESS => return value,
        .INVAL => return error.UnsupportedClock,
        .FAULT => unreachable,
        else => return unexpected(),
    }
}

/// Shuts down socket reads, writes, or both.
pub fn shutdown(sock: socket_t, how: ShutdownHow) ShutdownError!void {
    const native: i32 = switch (how) {
        .recv => if (is_windows) windows.ws2_32.SD_RECEIVE else SHUT.RD,
        .send => if (is_windows) windows.ws2_32.SD_SEND else SHUT.WR,
        .both => if (is_windows) windows.ws2_32.SD_BOTH else SHUT.RDWR,
    };
    if (comptime is_windows) {
        if (windows.ws2_32.shutdown(sock, native) == 0) return;
        return switch (windows.ws2_32.WSAGetLastError()) {
            .WSAECONNABORTED => error.ConnectionAborted,
            .WSAECONNRESET => error.ConnectionResetByPeer,
            .WSAEINPROGRESS => error.BlockingOperationInProgress,
            .WSAENETDOWN => error.NetworkSubsystemFailed,
            .WSAENOTCONN => error.SocketNotConnected,
            .WSAENOBUFS => error.SystemResources,
            else => error.Unexpected,
        };
    }
    switch (errno(std.c.shutdown(sock, native))) {
        .SUCCESS => return,
        .CONNABORTED => return error.ConnectionAborted,
        .CONNRESET => return error.ConnectionResetByPeer,
        .INPROGRESS => return error.BlockingOperationInProgress,
        .NETDOWN => return error.NetworkSubsystemFailed,
        .NOTCONN => return error.SocketNotConnected,
        .NOBUFS => return error.SystemResources,
        .BADF, .NOTSOCK, .INVAL => unreachable,
        else => return unexpected(),
    }
}

/// Creates a symbolic link.
pub fn symlink(target: []const u8, link_path: []const u8) SymLinkError!void {
    var target_buffer: PathBuffer = undefined;
    var link_buffer: PathBuffer = undefined;
    const target_z = try pathBuffer(target, &target_buffer);
    const link_z = try pathBuffer(link_path, &link_buffer);
    return symlinkZ(target_z.ptr, link_z.ptr);
}

/// Creates a symbolic link from sentinel-terminated paths.
pub fn symlinkZ(target: [*:0]const u8, link_path: [*:0]const u8) SymLinkError!void {
    if (comptime is_windows) @compileError("symlink is POSIX-only");
    switch (errno(std.c.symlink(target, link_path))) {
        .SUCCESS => return,
        .ACCES => return error.AccessDenied,
        .PERM => return error.PermissionDenied,
        .DQUOT => return error.DiskQuota,
        .EXIST => return error.PathAlreadyExists,
        .IO => return error.FileSystem,
        .NOENT => return error.FileNotFound,
        .NAMETOOLONG => return error.NameTooLong,
        .NOMEM => return error.SystemResources,
        .NOSPC => return error.NoSpaceLeft,
        .ROFS => return error.ReadOnlyFileSystem,
        .NOTDIR => return error.NotDir,
        .LOOP => return error.SymLinkLoop,
        .INVAL, .FAULT => unreachable,
        else => return unexpected(),
    }
}

/// Removes a file.
pub fn unlink(path: []const u8) UnlinkError!void {
    var buffer: PathBuffer = undefined;
    const path_z = try pathBuffer(path, &buffer);
    return unlinkZ(path_z.ptr);
}

/// Removes a sentinel-terminated file path.
pub fn unlinkZ(path: [*:0]const u8) UnlinkError!void {
    if (comptime is_windows) @compileError("unlink is POSIX-only");
    switch (errno(std.c.unlink(path))) {
        .SUCCESS => return,
        .ACCES => return error.AccessDenied,
        .PERM => return error.PermissionDenied,
        .NOENT => return error.FileNotFound,
        .BUSY => return error.FileBusy,
        .IO => return error.FileSystem,
        .NAMETOOLONG => return error.NameTooLong,
        .ISDIR => return error.IsDir,
        .NOMEM => return error.SystemResources,
        .ROFS => return error.ReadOnlyFileSystem,
        .NOTDIR => return error.NotDir,
        .LOOP => return error.SymLinkLoop,
        .INVAL, .FAULT => unreachable,
        else => return unexpected(),
    }
}

/// Removes a file relative to a directory descriptor.
pub fn unlinkat(dirfd: fd_t, path: []const u8, flags: u32) UnlinkError!void {
    var buffer: PathBuffer = undefined;
    const path_z = try pathBuffer(path, &buffer);
    return unlinkatZ(dirfd, path_z.ptr, flags);
}

/// Removes a sentinel-terminated file path relative to a directory descriptor.
pub fn unlinkatZ(dirfd: fd_t, path: [*:0]const u8, flags: u32) UnlinkError!void {
    if (comptime is_windows) @compileError("unlinkat is POSIX-only");
    switch (errno(std.c.unlinkat(dirfd, path, flags))) {
        .SUCCESS => return,
        .ACCES => return error.AccessDenied,
        .PERM => return error.PermissionDenied,
        .NOENT => return error.FileNotFound,
        .BUSY => return error.FileBusy,
        .IO => return error.FileSystem,
        .NAMETOOLONG => return error.NameTooLong,
        .ISDIR => return error.IsDir,
        .NOMEM => return error.SystemResources,
        .ROFS => return error.ReadOnlyFileSystem,
        .NOTDIR => return error.NotDir,
        .LOOP => return error.SymLinkLoop,
        .INVAL, .FAULT, .BADF => unreachable,
        else => return unexpected(),
    }
}

/// Sends a signal to a process using Born's public `u8` signal representation.
pub fn kill(pid: pid_t, signal: u8) KillError!void {
    if (comptime is_windows) @compileError("kill is POSIX-only");
    switch (errno(std.c.kill(pid, nativeSignal(signal)))) {
        .SUCCESS => return,
        .PERM => return error.PermissionDenied,
        .SRCH => return error.ProcessNotFound,
        .INVAL => unreachable,
        else => return unexpected(),
    }
}

/// Raises a signal in the calling thread using Born's `u8` representation.
pub fn raise(signal: u8) RaiseError!void {
    if (comptime is_windows) @compileError("raise is POSIX-only");
    switch (errno(std.c.raise(nativeSignal(signal)))) {
        .SUCCESS => return,
        else => return unexpected(),
    }
}

/// Changes or queries a signal action using Born's `u8` representation.
pub fn sigaction(signal: u8, action: ?*const Sigaction, old: ?*Sigaction) void {
    if (comptime is_windows) @compileError("sigaction is POSIX-only");
    switch (errno(std.c.sigaction(nativeSignal(signal), action, old))) {
        .SUCCESS => return,
        else => unreachable,
    }
}

/// Returns an empty native signal set.
pub fn sigemptyset() sigset_t {
    if (comptime is_windows) @compileError("signal sets are POSIX-only");
    var set: sigset_t = undefined;
    switch (errno(std.c.sigemptyset(&set))) {
        .SUCCESS => return set,
        else => unreachable,
    }
}

/// Returns a full native signal set.
pub fn sigfillset() sigset_t {
    if (comptime is_windows) @compileError("signal sets are POSIX-only");
    var set: sigset_t = undefined;
    switch (errno(std.c.sigfillset(&set))) {
        .SUCCESS => return set,
        else => unreachable,
    }
}

/// Adds Born's `u8` signal to a native set.
pub fn sigaddset(set: *sigset_t, signal: u8) void {
    if (comptime is_windows) @compileError("signal sets are POSIX-only");
    switch (errno(std.c.sigaddset(set, nativeSignal(signal)))) {
        .SUCCESS => return,
        else => unreachable,
    }
}

/// Tests whether Born's `u8` signal belongs to a native set.
pub fn sigismember(set: *const sigset_t, signal: u8) bool {
    if (comptime is_windows) @compileError("signal sets are POSIX-only");
    const rc = std.c.sigismember(set, nativeSignal(signal));
    switch (errno(rc)) {
        .SUCCESS => return rc == 1,
        else => unreachable,
    }
}

/// Sets the process signal mask and treats invalid input as a programmer error.
pub fn sigprocmask(how: u32, set: ?*const sigset_t, old: ?*sigset_t) void {
    if (comptime is_windows) @compileError("sigprocmask is POSIX-only");
    switch (errno(std.c.sigprocmask(@bitCast(how), set, old))) {
        .SUCCESS => return,
        else => unreachable,
    }
}

/// Calls `pthread_sigmask` and returns its native error number.
pub fn pthreadSigmask(how: c_int, set: *const sigset_t, old: *sigset_t) c_int {
    if (comptime is_windows) @compileError("pthreadSigmask is POSIX-only");
    return std.c.pthread_sigmask(how, set, old);
}

/// Decodes a raw Linux syscall result without consulting libc's thread-local errno.
pub fn linuxErrno(rc: usize) std.os.linux.E {
    if (comptime builtin.zig_version.minor < 16) return std.os.linux.E.init(rc);
    return std.os.linux.errno(rc);
}

/// Minimal native file identity used by Born's Unix-listener ownership checks.
pub const FileStat = struct {
    /// Filesystem device identity. Linux uses major in the high 32 bits.
    dev: u64,
    /// Native inode number.
    ino: u64,
    /// Native file type and permission bits.
    mode: u32,
};

/// Stats a path with Linux statx and native fstatat elsewhere.
pub fn fstatat(dirfd: fd_t, path: []const u8, flags: u32) FStatAtError!FileStat {
    var buffer: PathBuffer = undefined;
    const path_z = try pathBuffer(path, &buffer);
    return fstatatZ(dirfd, path_z.ptr, flags);
}

/// Stats a sentinel-terminated path with Linux statx and native fstatat elsewhere.
pub fn fstatatZ(dirfd: fd_t, path: [*:0]const u8, flags: u32) FStatAtError!FileStat {
    if (comptime is_windows) @compileError("fstatat is POSIX-only");
    if (comptime is_linux) {
        const linux = std.os.linux;
        var stat: linux.Statx = std.mem.zeroes(linux.Statx);
        const mask = if (comptime builtin.zig_version.minor < 16)
            @as(u32, linux.STATX_TYPE | linux.STATX_MODE | linux.STATX_INO)
        else
            linux.STATX{ .TYPE = true, .MODE = true, .INO = true };
        const rc = linux.statx(dirfd, path, flags, mask, &stat);
        switch (linuxErrno(rc)) {
            .SUCCESS => return .{
                .dev = (@as(u64, stat.dev_major) << 32) | stat.dev_minor,
                .ino = stat.ino,
                .mode = stat.mode,
            },
            .NOMEM => return error.SystemResources,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .NAMETOOLONG => return error.NameTooLong,
            .NOENT, .NOTDIR => return error.FileNotFound,
            .LOOP => return error.SymLinkLoop,
            .BADF, .FAULT => unreachable,
            else => return unexpected(),
        }
    } else {
        var stat: std.c.Stat = std.mem.zeroes(std.c.Stat);
        switch (errno(std.c.fstatat(dirfd, path, &stat, flags))) {
            .SUCCESS => return .{
                .dev = @intCast(stat.dev),
                .ino = @intCast(stat.ino),
                .mode = @intCast(stat.mode),
            },
            .NOMEM => return error.SystemResources,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .NAMETOOLONG => return error.NameTooLong,
            .NOENT, .NOTDIR => return error.FileNotFound,
            .LOOP => return error.SymLinkLoop,
            .BADF, .FAULT, .INVAL => unreachable,
            else => return unexpected(),
        }
    }
}

fn mapChmodErrno(err: E) FChmodAtError {
    return switch (err) {
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .IO => error.InputOutput,
        .LOOP => error.SymLinkLoop,
        .NOENT, .NOTDIR => error.FileNotFound,
        .NOMEM => error.SystemResources,
        .ROFS => error.ReadOnlyFileSystem,
        .NAMETOOLONG => error.NameTooLong,
        .OPNOTSUPP => error.OperationNotSupported,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        else => error.Unexpected,
    };
}

/// Changes path permissions. Flags zero uses libc fchmodat and follows links.
/// Linux uses fchmodat2 plus a procfs fallback only for AT_SYMLINK_NOFOLLOW.
pub fn fchmodat(dirfd: fd_t, path: []const u8, mode: mode_t, flags: u32) FChmodAtError!void {
    return fchmodatWithPolicy(dirfd, path, mode, flags, false);
}

/// Changes path permissions with an explicit Linux fallback policy. Setting
/// `force_procfs` skips fchmodat2 for AT_SYMLINK_NOFOLLOW so older-kernel
/// behavior can be tested; it has no effect for flags zero or other targets.
pub fn fchmodatWithPolicy(
    dirfd: fd_t,
    path: []const u8,
    mode: mode_t,
    flags: u32,
    force_procfs: bool,
) FChmodAtError!void {
    var buffer: PathBuffer = undefined;
    const path_z = try pathBuffer(path, &buffer);
    return fchmodatZPolicy(dirfd, path_z.ptr, mode, flags, force_procfs);
}

/// Changes a sentinel-terminated path's permissions with Linux's procfs fallback.
pub fn fchmodatZ(dirfd: fd_t, path: [*:0]const u8, mode: mode_t, flags: u32) FChmodAtError!void {
    return fchmodatZPolicy(dirfd, path, mode, flags, false);
}

fn fchmodatZPolicy(
    dirfd: fd_t,
    path: [*:0]const u8,
    mode: mode_t,
    flags: u32,
    force_procfs: bool,
) FChmodAtError!void {
    if (comptime is_windows) @compileError("fchmodat is POSIX-only");
    if (comptime is_linux) {
        if (flags == AT.SYMLINK_NOFOLLOW) {
            return fchmodatNoFollowLinux(dirfd, path, mode, force_procfs);
        }
    }
    return fchmodatLibc(dirfd, path, mode, flags);
}

fn fchmodatLibc(dirfd: fd_t, path: [*:0]const u8, mode: mode_t, flags: u32) FChmodAtError!void {
    while (true) {
        const err = errno(std.c.fchmodat(dirfd, path, mode, flags));
        switch (err) {
            .SUCCESS => return,
            .INTR => continue,
            .BADF, .FAULT, .INVAL => unreachable,
            else => return mapChmodErrno(err),
        }
    }
}

fn fchmodatNoFollowLinux(
    dirfd: fd_t,
    path: [*:0]const u8,
    mode: mode_t,
    force_procfs: bool,
) FChmodAtError!void {
    if (comptime !is_linux) unreachable;
    const linux = std.os.linux;
    const flags: u32 = AT.SYMLINK_NOFOLLOW;
    while (!force_procfs) {
        const rc = linux.fchmodat2(dirfd, path, mode, flags);
        const err = linuxErrno(rc);
        switch (err) {
            .SUCCESS => return,
            .INTR => continue,
            .NOSYS => break,
            .BADF, .FAULT, .INVAL => unreachable,
            else => return mapChmodErrno(@enumFromInt(@intFromEnum(err))),
        }
    }

    const open_flags: linux.O = .{ .PATH = true, .NOFOLLOW = true, .CLOEXEC = true };
    const path_fd = while (true) {
        const rc = linux.openat(dirfd, path, open_flags, 0);
        const err = linuxErrno(rc);
        switch (err) {
            .SUCCESS => break @as(fd_t, @intCast(rc)),
            .INTR => continue,
            .BADF, .FAULT, .INVAL => unreachable,
            else => return mapChmodErrno(@enumFromInt(@intFromEnum(err))),
        }
    };
    defer close(path_fd);

    var empty: [1:0]u8 = .{0};
    const stat = fstatatZ(path_fd, &empty, linux.AT.EMPTY_PATH) catch |err| return err;
    if ((stat.mode & S.IFMT) == S.IFLNK) return error.OperationNotSupported;

    var proc_buffer: [64:0]u8 = undefined;
    const proc_slice = std.fmt.bufPrint(
        &proc_buffer,
        "/proc/self/fd/{d}",
        .{path_fd},
    ) catch unreachable;
    proc_buffer[proc_slice.len] = 0;
    const proc_path: [*:0]const u8 = @ptrCast(&proc_buffer);
    while (true) {
        const rc = linux.chmod(proc_path, mode);
        const err = linuxErrno(rc);
        switch (err) {
            .SUCCESS => return,
            .INTR => continue,
            .NOENT => return error.OperationNotSupported,
            .BADF, .FAULT, .INVAL => unreachable,
            else => return mapChmodErrno(@enumFromInt(@intFromEnum(err))),
        }
    }
}

/// Whether the target exposes Unix-domain socket addresses.
pub const has_unix_sockets = switch (native_os) {
    .windows => builtin.os.version_range.windows.isAtLeast(.win10_rs4) orelse false,
    .wasi => false,
    else => true,
};

/// IP parsing failures shared by IPv4 and IPv6.
pub const IPParseError = error{ Overflow, InvalidEnd, InvalidCharacter, Incomplete };
/// IPv4 parsing failures, including rejection of noncanonical leading zeroes.
pub const IPv4ParseError = IPParseError || error{NonCanonical};
/// IPv6 parsing failures.
pub const IPv6ParseError = IPParseError || error{InvalidIpv4Mapping};

/// Native-layout socket address owned by Born rather than the standard library.
pub const Address = extern union {
    /// Generic native sockaddr view.
    any: sockaddr,
    /// Native IPv4 sockaddr view.
    in: sockaddr.in,
    /// Native IPv6 sockaddr view.
    in6: sockaddr.in6,
    /// Native Unix-domain sockaddr view where supported.
    un: if (has_unix_sockets) sockaddr.un else void,

    /// Parses a canonical IPv4 address and native-endian port.
    pub fn parseIp4(text: []const u8, port: u16) IPv4ParseError!Address {
        var result: Address = .{ .in = .{
            .port = std.mem.nativeToBig(u16, port),
            .addr = undefined,
        } };
        const output = std.mem.asBytes(&result.in.addr);
        var value: u8 = 0;
        var index: u8 = 0;
        var saw_digits = false;
        var has_zero_prefix = false;
        for (text) |char| {
            if (char == '.') {
                if (!saw_digits) return error.InvalidCharacter;
                if (index == 3) return error.InvalidEnd;
                output[index] = value;
                index += 1;
                value = 0;
                saw_digits = false;
                has_zero_prefix = false;
            } else if (char >= '0' and char <= '9') {
                if (char == '0' and !saw_digits) {
                    has_zero_prefix = true;
                } else if (has_zero_prefix) {
                    return error.NonCanonical;
                }
                saw_digits = true;
                value = try std.math.mul(u8, value, 10);
                value = try std.math.add(u8, value, char - '0');
            } else {
                return error.InvalidCharacter;
            }
        }
        if (index != 3 or !saw_digits) return error.Incomplete;
        output[index] = value;
        return result;
    }

    /// Parses an IPv6 address, including numeric scope IDs and IPv4 mappings.
    pub fn parseIp6(text: []const u8, port: u16) IPv6ParseError!Address {
        var result: Address = .{ .in6 = .{
            .scope_id = 0,
            .port = std.mem.nativeToBig(u16, port),
            .flowinfo = 0,
            .addr = undefined,
        } };
        var ip_slice: *[16]u8 = result.in6.addr[0..];
        var tail: [16]u8 = undefined;
        var value: u16 = 0;
        var saw_digits = false;
        var index: u8 = 0;
        var in_scope = false;
        var abbreviated = false;
        for (text, 0..) |char, i| {
            if (in_scope) {
                if (char < '0' or char > '9') return error.InvalidCharacter;
                const digit = char - '0';
                const multiplied = @mulWithOverflow(result.in6.scope_id, 10);
                if (multiplied[1] != 0) return error.Overflow;
                result.in6.scope_id = multiplied[0];
                const added = @addWithOverflow(result.in6.scope_id, digit);
                if (added[1] != 0) return error.Overflow;
                result.in6.scope_id = added[0];
            } else if (char == ':') {
                if (!saw_digits) {
                    if (abbreviated) return error.InvalidCharacter;
                    if (i != 0) abbreviated = true;
                    @memset(ip_slice[index..], 0);
                    ip_slice = tail[0..];
                    index = 0;
                    continue;
                }
                if (index == 14) return error.InvalidEnd;
                ip_slice[index] = @truncate(value >> 8);
                index += 1;
                ip_slice[index] = @truncate(value);
                index += 1;
                value = 0;
                saw_digits = false;
            } else if (char == '%') {
                if (!saw_digits) return error.InvalidCharacter;
                in_scope = true;
                saw_digits = false;
            } else if (char == '.') {
                if (!abbreviated or ip_slice[0] != 0xff or ip_slice[1] != 0xff) {
                    return error.InvalidIpv4Mapping;
                }
                const start = std.mem.lastIndexOfScalar(u8, text[0..i], ':').? + 1;
                const ipv4 = (Address.parseIp4(text[start..], 0) catch {
                    return error.InvalidIpv4Mapping;
                }).in.addr;
                ip_slice = result.in6.addr[0..];
                ip_slice[10] = 0xff;
                ip_slice[11] = 0xff;
                const bytes = std.mem.sliceAsBytes(@as(*const [1]u32, &ipv4)[0..]);
                ip_slice[12] = bytes[0];
                ip_slice[13] = bytes[1];
                ip_slice[14] = bytes[2];
                ip_slice[15] = bytes[3];
                return result;
            } else {
                const digit = try std.fmt.charToDigit(char, 16);
                const multiplied = @mulWithOverflow(value, 16);
                if (multiplied[1] != 0) return error.Overflow;
                value = multiplied[0];
                const added = @addWithOverflow(value, digit);
                if (added[1] != 0) return error.Overflow;
                value = added[0];
                saw_digits = true;
            }
        }
        if (!saw_digits and !abbreviated) return error.Incomplete;
        if (!abbreviated and index < 14) return error.Incomplete;
        if (index == 14) {
            ip_slice[14] = @truncate(value >> 8);
            ip_slice[15] = @truncate(value);
            return result;
        }
        ip_slice[index] = @truncate(value >> 8);
        index += 1;
        ip_slice[index] = @truncate(value);
        index += 1;
        @memcpy(result.in6.addr[16 - index ..][0..index], ip_slice[0..index]);
        return result;
    }

    /// Creates a zero-terminated Unix-domain address without truncation.
    pub fn initUnix(path: []const u8) error{NameTooLong}!Address {
        if (comptime !has_unix_sockets) unreachable;
        var address: Address = .{ .un = std.mem.zeroes(sockaddr.un) };
        address.un.family = AF.UNIX;
        if (@hasField(sockaddr.un, "len")) address.un.len = @sizeOf(sockaddr.un);
        if (path.len + 1 > address.un.path.len) return error.NameTooLong;
        @memcpy(address.un.path[0..path.len], path);
        return address;
    }

    /// Copies a native IPv4 or IPv6 sockaddr into the owned union.
    pub fn initPosix(address: *align(4) const sockaddr) Address {
        return switch (address.family) {
            AF.INET => .{ .in = @as(*const sockaddr.in, @ptrCast(address)).* },
            AF.INET6 => .{ .in6 = @as(*const sockaddr.in6, @ptrCast(address)).* },
            else => unreachable,
        };
    }

    /// Returns the native sockaddr length for the active address family.
    pub fn getOsSockLen(self: Address) socklen_t {
        return switch (self.any.family) {
            AF.INET => @sizeOf(sockaddr.in),
            AF.INET6 => @sizeOf(sockaddr.in6),
            AF.UNIX => if (has_unix_sockets) @sizeOf(sockaddr.un) else unreachable,
            else => unreachable,
        };
    }

    /// Returns the port in native endian for an IPv4 or IPv6 address.
    pub fn getPort(self: Address) u16 {
        return switch (self.any.family) {
            AF.INET => std.mem.bigToNative(u16, self.in.port),
            AF.INET6 => std.mem.bigToNative(u16, self.in6.port),
            else => unreachable,
        };
    }

    /// Compares the complete native address bytes of the same family.
    pub fn eql(a: Address, b: Address) bool {
        if (a.any.family != b.any.family) return false;
        const a_bytes = @as([*]const u8, @ptrCast(&a.any))[0..@intCast(a.getOsSockLen())];
        const b_bytes = @as([*]const u8, @ptrCast(&b.any))[0..@intCast(b.getOsSockLen())];
        return std.mem.eql(u8, a_bytes, b_bytes);
    }

    /// Options for the raw blocking `Server` test helper.
    pub const ListenOptions = struct {
        /// Kernel accept-queue length.
        kernel_backlog: u31 = 128,
        /// Set address-reuse options before binding.
        reuse_address: bool = false,
        /// Make the listening descriptor nonblocking.
        force_nonblocking: bool = false,
    };

    /// Opens a blocking or nonblocking listener suitable for Born's tests.
    pub fn listen(address: Address, options: ListenOptions) AddressListenError!Server {
        const nonblock: u32 = if (options.force_nonblocking) SOCK.NONBLOCK else 0;
        const close_exec: u32 = SOCK.CLOEXEC;
        var wsa_started = false;
        if (comptime is_windows) {
            try ensureWsaStartup();
            wsa_started = true;
        }
        errdefer {
            if (comptime is_windows) {
                if (wsa_started) _ = windows.ws2_32.WSACleanup();
            }
        }

        const protocol: u32 = if (address.any.family == AF.UNIX) 0 else IPPROTO.TCP;
        const fd = try socket(
            address.any.family,
            SOCK.STREAM | close_exec | nonblock,
            protocol,
        );
        var server: Server = .{
            .listen_address = undefined,
            .stream = .{ .handle = fd, .wsa_started = wsa_started },
        };
        wsa_started = false;
        errdefer server.stream.close();

        if (options.reuse_address) {
            try setsockopt(fd, SOL.SOCKET, SO.REUSEADDR, std.mem.asBytes(&@as(c_int, 1)));
            if (!is_windows and @hasDecl(SO, "REUSEPORT") and address.any.family != AF.UNIX) {
                try setsockopt(fd, SOL.SOCKET, SO.REUSEPORT, std.mem.asBytes(&@as(c_int, 1)));
            }
        }
        var length = address.getOsSockLen();
        try bind(fd, &address.any, length);
        try this.listen(fd, options.kernel_backlog);
        try getsockname(fd, &server.listen_address.any, &length);
        return server;
    }
};

/// Address-listen failures.
pub const AddressListenError = SocketError || BindError || ListenError ||
    SetSockOptError || GetSockNameError;

/// Raw blocking stream used by Born's socket and listener tests.
pub const Stream = struct {
    /// Native descriptor or Winsock handle.
    handle: socket_t,
    wsa_started: bool = false,

    /// Closes the stream once and releases its Winsock reference, if any.
    pub fn close(self: Stream) void {
        if (comptime is_windows) {
            _ = windows.ws2_32.closesocket(self.handle);
            if (self.wsa_started) _ = windows.ws2_32.WSACleanup();
        } else {
            this.close(self.handle);
        }
    }

    /// Reads bytes from a blocking stream.
    pub fn read(self: Stream, buffer: []u8) ReadError!usize {
        if (comptime !is_windows) return this.read(self.handle, buffer);
        if (buffer.len == 0) return 0;
        const rc = windows.ws2_32.recv(self.handle, buffer.ptr, @intCast(buffer.len), 0);
        if (rc >= 0) return @intCast(rc);
        return switch (windows.ws2_32.WSAGetLastError()) {
            .WSAEWOULDBLOCK => error.WouldBlock,
            .WSAECONNRESET => error.ConnectionResetByPeer,
            .WSAETIMEDOUT => error.ConnectionTimedOut,
            .WSAENOTCONN => error.SocketNotConnected,
            .WSAENETDOWN, .WSAENOBUFS => error.SystemResources,
            .WSAEINTR => error.OperationAborted,
            else => error.Unexpected,
        };
    }

    /// Writes bytes to a blocking stream.
    pub fn write(self: Stream, bytes: []const u8) WriteError!usize {
        if (comptime !is_windows) return this.write(self.handle, bytes);
        if (bytes.len == 0) return 0;
        const rc = windows.ws2_32.send(self.handle, bytes.ptr, @intCast(bytes.len), 0);
        if (rc >= 0) return @intCast(rc);
        return switch (windows.ws2_32.WSAGetLastError()) {
            .WSAEWOULDBLOCK => error.WouldBlock,
            .WSAECONNRESET => error.ConnectionResetByPeer,
            .WSAEMSGSIZE => error.MessageTooBig,
            .WSAEACCES => error.AccessDenied,
            .WSAENOBUFS => error.SystemResources,
            .WSAESHUTDOWN => error.BrokenPipe,
            else => error.Unexpected,
        };
    }
};

/// Raw blocking TCP server used by Born's tests.
pub const Server = struct {
    /// Actual bound address, including a kernel-selected port.
    listen_address: Address,
    /// Listening stream.
    stream: Stream,

    /// Accepted connection and its native peer address.
    pub const Connection = struct {
        /// Accepted blocking stream.
        stream: Stream,
        /// Native peer address.
        address: Address,
    };

    /// Closes the listener.
    pub fn deinit(self: *Server) void {
        self.stream.close();
        self.* = undefined;
    }

    /// Accepts one connection and preserves nonblocking `WouldBlock` behavior.
    pub fn accept(self: *Server) AcceptError!Connection {
        var address: Address = undefined;
        var length: socklen_t = @sizeOf(Address);
        const fd = try this.accept4(
            self.stream.handle,
            &address.any,
            &length,
            SOCK.CLOEXEC,
        );
        var wsa_started = false;
        if (comptime is_windows) {
            ensureWsaStartup() catch |err| {
                _ = windows.ws2_32.closesocket(fd);
                return switch (err) {
                    error.AccessDenied => error.Unexpected,
                    error.AddressFamilyNotSupported => error.Unexpected,
                    error.ProtocolFamilyNotAvailable => error.Unexpected,
                    error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
                    error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
                    error.SystemResources => error.SystemResources,
                    error.ProtocolNotSupported => error.Unexpected,
                    error.SocketTypeNotSupported => error.Unexpected,
                    error.Unexpected => error.Unexpected,
                };
            };
            wsa_started = true;
        }
        return .{
            .stream = .{ .handle = fd, .wsa_started = wsa_started },
            .address = address,
        };
    }
};

/// Failures from a blocking connect to an owned `Address`.
pub const TcpConnectToAddressError = SocketError || ConnectError;

/// Connects a raw blocking stream to `address`.
pub fn tcpConnectToAddress(address: Address) TcpConnectToAddressError!Stream {
    var wsa_started = false;
    if (comptime is_windows) {
        try ensureWsaStartup();
        wsa_started = true;
    }
    errdefer {
        if (comptime is_windows) {
            if (wsa_started) _ = windows.ws2_32.WSACleanup();
        }
    }
    const protocol: u32 = if (address.any.family == AF.UNIX) 0 else IPPROTO.TCP;
    const fd = try socket(address.any.family, SOCK.STREAM | SOCK.CLOEXEC, protocol);
    errdefer if (is_windows) {
        _ = windows.ws2_32.closesocket(fd);
    } else {
        close(fd);
    };
    try connect(fd, &address.any, address.getOsSockLen());
    return .{ .handle = fd, .wsa_started = wsa_started };
}

fn ensureWsaStartup() SocketError!void {
    if (comptime !is_windows) return;
    var data: windows.ws2_32.WSADATA = undefined;
    if (windows.ws2_32.WSAStartup(0x0202, &data) != 0) return error.Unexpected;
}

/// Allocated result of `getAddressList`.
pub const AddressList = struct {
    gpa: std.mem.Allocator,
    /// Resolved addresses owned by this list.
    addrs: []Address,
    /// Optional canonical name owned by this list.
    canon_name: ?[]u8,

    /// Frees the addresses, optional canonical name, and the list itself.
    pub fn deinit(self: *AddressList) void {
        const gpa = self.gpa;
        if (self.canon_name) |name| gpa.free(name);
        gpa.free(self.addrs);
        gpa.destroy(self);
    }
};

/// Address-resolution failures surfaced by the system resolver.
pub const GetAddressListError = error{
    OutOfMemory,
    NameTooLong,
    TemporaryNameServerFailure,
    NameServerFailure,
    AddressFamilyNotSupported,
    UnknownHostName,
    HostLacksNetworkAddresses,
    ServiceUnavailable,
    Unexpected,
};

/// Resolves `name` and `port` through native getaddrinfo. The returned pointer
/// and every slice it owns must be released with `AddressList.deinit`.
pub fn getAddressList(
    gpa: std.mem.Allocator,
    name: []const u8,
    port: u16,
) GetAddressListError!*AddressList {
    const name_z = gpa.alloc(u8, name.len + 1) catch return error.OutOfMemory;
    defer gpa.free(name_z);
    @memcpy(name_z[0..name.len], name);
    name_z[name.len] = 0;
    var port_buffer: [6:0]u8 = undefined;
    const port_slice = std.fmt.bufPrint(&port_buffer, "{d}", .{port}) catch unreachable;
    port_buffer[port_slice.len] = 0;
    const name_ptr: [*:0]const u8 = @ptrCast(name_z.ptr);
    const port_ptr: [*:0]const u8 = @ptrCast(&port_buffer);

    if (comptime is_windows) return getAddressListWindows(gpa, name_ptr, port_ptr);
    return getAddressListPosix(gpa, name_ptr, port_ptr);
}

fn getAddressListPosix(
    gpa: std.mem.Allocator,
    name: [*:0]const u8,
    port: [*:0]const u8,
) GetAddressListError!*AddressList {
    if (comptime is_windows) unreachable;
    const hints: std.c.addrinfo = .{
        .flags = .{ .NUMERICSERV = true },
        .family = AF.UNSPEC,
        .socktype = SOCK.STREAM,
        .protocol = IPPROTO.TCP,
        .canonname = null,
        .addr = null,
        .addrlen = 0,
        .next = null,
    };
    var result: ?*std.c.addrinfo = null;
    const rc = std.c.getaddrinfo(name, port, &hints, &result);
    if (@intFromEnum(rc) != 0) return mapGaiError(rc);
    defer if (result) |first| std.c.freeaddrinfo(first);
    return addressListFromPosix(gpa, result);
}

/// Maps a native getaddrinfo result to Born's resolver error set.
pub fn mapGaiError(rc: std.c.EAI) GetAddressListError {
    return switch (rc) {
        .ADDRFAMILY, .NODATA => error.HostLacksNetworkAddresses,
        .AGAIN => error.TemporaryNameServerFailure,
        .FAIL => error.NameServerFailure,
        .FAMILY => error.AddressFamilyNotSupported,
        .MEMORY => error.OutOfMemory,
        .NONAME => error.UnknownHostName,
        .SERVICE => error.ServiceUnavailable,
        else => error.Unexpected,
    };
}

/// Copies a native POSIX resolver chain into an owned address list.
pub fn addressListFromPosix(
    gpa: std.mem.Allocator,
    result: ?*std.c.addrinfo,
) GetAddressListError!*AddressList {
    var count: usize = 0;
    var iterator = result;
    while (iterator) |info| : (iterator = info.next) {
        if (info.addr != null and (info.family == AF.INET or info.family == AF.INET6)) count += 1;
    }
    const list = gpa.create(AddressList) catch return error.OutOfMemory;
    errdefer gpa.destroy(list);
    const addresses = gpa.alloc(Address, count) catch return error.OutOfMemory;
    errdefer gpa.free(addresses);
    var index: usize = 0;
    iterator = result;
    while (iterator) |info| : (iterator = info.next) {
        if (info.addr == null or (info.family != AF.INET and info.family != AF.INET6)) continue;
        addresses[index] = Address.initPosix(@ptrCast(@alignCast(info.addr.?)));
        index += 1;
    }
    var canonical: ?[]u8 = null;
    var canonical_iterator = result;
    while (canonical_iterator) |info| : (canonical_iterator = info.next) {
        const name = info.canonname orelse continue;
        canonical = gpa.dupe(u8, std.mem.sliceTo(name, 0)) catch return error.OutOfMemory;
        break;
    }
    list.* = .{ .gpa = gpa, .addrs = addresses, .canon_name = canonical };
    return list;
}

fn getAddressListWindows(
    gpa: std.mem.Allocator,
    name: [*:0]const u8,
    port: [*:0]const u8,
) GetAddressListError!*AddressList {
    if (comptime !is_windows) unreachable;
    const ws2 = windows.ws2_32;
    const hints: ws2.addrinfo = .{
        .flags = .{ .NUMERICSERV = true },
        .family = ws2.AF.UNSPEC,
        .socktype = ws2.SOCK.STREAM,
        .protocol = ws2.IPPROTO.TCP,
        .canonname = null,
        .addr = null,
        .addrlen = 0,
        .next = null,
    };
    var wsa_started = false;
    defer {
        if (wsa_started) _ = ws2.WSACleanup();
    }
    var result: ?*ws2.addrinfo = null;
    var attempt: u2 = 0;
    while (attempt < 2) : (attempt += 1) {
        const rc = ws2.getaddrinfo(name, port, &hints, &result);
        if (rc == 0) break;
        const err: ws2.WinsockError = @enumFromInt(@as(u16, @intCast(rc)));
        if (err == .WSANOTINITIALISED and !wsa_started) {
            ensureWsaStartup() catch return error.Unexpected;
            wsa_started = true;
            continue;
        }
        return switch (err) {
            .WSATRY_AGAIN => error.TemporaryNameServerFailure,
            .WSANO_RECOVERY => error.NameServerFailure,
            .WSAEAFNOSUPPORT => error.AddressFamilyNotSupported,
            .WSA_NOT_ENOUGH_MEMORY => error.OutOfMemory,
            .WSAHOST_NOT_FOUND => error.UnknownHostName,
            .WSANO_DATA => error.HostLacksNetworkAddresses,
            .WSATYPE_NOT_FOUND => error.ServiceUnavailable,
            else => error.Unexpected,
        };
    } else return error.Unexpected;
    defer ws2.freeaddrinfo(result);
    return addressListFromWindows(gpa, result);
}

fn addressListFromWindows(
    gpa: std.mem.Allocator,
    result: ?*windows.ws2_32.addrinfo,
) GetAddressListError!*AddressList {
    if (comptime !is_windows) unreachable;
    const ws2 = windows.ws2_32;
    var count: usize = 0;
    var iterator = result;
    while (iterator) |info| : (iterator = info.next) {
        const ip_family = info.family == ws2.AF.INET or info.family == ws2.AF.INET6;
        if (info.addr != null and ip_family) count += 1;
    }
    const list = gpa.create(AddressList) catch return error.OutOfMemory;
    errdefer gpa.destroy(list);
    const addresses = gpa.alloc(Address, count) catch return error.OutOfMemory;
    errdefer gpa.free(addresses);
    var index: usize = 0;
    iterator = result;
    while (iterator) |info| : (iterator = info.next) {
        const ip_family = info.family == ws2.AF.INET or info.family == ws2.AF.INET6;
        if (info.addr == null or !ip_family) continue;
        addresses[index] = Address.initPosix(@ptrCast(@alignCast(info.addr.?)));
        index += 1;
    }
    var canonical: ?[]u8 = null;
    var canonical_iterator = result;
    while (canonical_iterator) |info| : (canonical_iterator = info.next) {
        const name = info.canonname orelse continue;
        canonical = gpa.dupe(u8, std.mem.sliceTo(name, 0)) catch return error.OutOfMemory;
        break;
    }
    list.* = .{ .gpa = gpa, .addrs = addresses, .canon_name = canonical };
    return list;
}

/// Monotonic clock failures.
pub const MonotonicError = error{Unsupported};

/// Returns monotonic nanoseconds using QPC on Windows and CLOCK_MONOTONIC elsewhere.
pub fn monotonicNs() MonotonicError!u64 {
    if (comptime is_windows) {
        var ticks: i64 = 0;
        var frequency: i64 = 0;
        if (windows.kernel32.QueryPerformanceCounter(&ticks) == 0) return error.Unsupported;
        if (windows.kernel32.QueryPerformanceFrequency(&frequency) == 0) return error.Unsupported;
        if (ticks < 0 or frequency <= 0) return error.Unsupported;
        const whole = @divFloor(@as(u64, @intCast(ticks)), @as(u64, @intCast(frequency)));
        const remainder = @as(u64, @intCast(ticks)) % @as(u64, @intCast(frequency));
        const seconds_ns = @as(u128, whole) * std.time.ns_per_s;
        const fraction_ns = @as(u128, remainder) * std.time.ns_per_s /
            @as(u64, @intCast(frequency));
        const total = seconds_ns + fraction_ns;
        if (total > std.math.maxInt(u64)) return error.Unsupported;
        return @intCast(total);
    }
    const value = clock_gettime(.MONOTONIC) catch return error.Unsupported;
    if (value.sec < 0 or value.nsec < 0) return error.Unsupported;
    return @as(u64, @intCast(value.sec)) * std.time.ns_per_s + @as(u64, @intCast(value.nsec));
}

/// Sleeps for at least `nanoseconds`, restarting POSIX nanosleep after EINTR.
pub fn sleepNs(nanoseconds: u64) void {
    if (comptime is_windows) {
        var remaining = nanoseconds;
        while (true) {
            const rounded = remaining / std.time.ns_per_ms +
                @intFromBool(remaining % std.time.ns_per_ms != 0);
            const milliseconds: u64 = @min(rounded, windows.INFINITE - 1);
            windows.kernel32.Sleep(@intCast(milliseconds));
            if (remaining <= milliseconds * std.time.ns_per_ms) return;
            remaining -= milliseconds * std.time.ns_per_ms;
        }
    } else {
        var request: timespec = .{
            .sec = @intCast(nanoseconds / std.time.ns_per_s),
            .nsec = @intCast(nanoseconds % std.time.ns_per_s),
        };
        var remaining: timespec = undefined;
        while (true) {
            const rc = std.c.nanosleep(&request, &remaining);
            switch (errno(rc)) {
                .SUCCESS => return,
                .INTR => request = remaining,
                else => unreachable,
            }
        }
    }
}

/// Native mutex with static `.{} initialization and Born's lock/unlock shape.
pub const Mutex = if (is_windows) struct {
    raw: windows.SRWLOCK = .{},

    /// Acquires the mutex exclusively. Zero-initialized SRW locks are valid.
    pub fn lock(self: *Mutex) void {
        windows.kernel32.AcquireSRWLockExclusive(&self.raw);
    }

    /// Releases the mutex.
    pub fn unlock(self: *Mutex) void {
        windows.kernel32.ReleaseSRWLockExclusive(&self.raw);
    }

    /// Releases native resources. SRW locks need no destruction.
    pub fn deinit(self: *Mutex) void {
        self.* = .{};
    }
} else struct {
    raw: std.c.pthread_mutex_t = .{},

    /// Acquires the mutex. A pthread failure is a broken synchronization invariant.
    pub fn lock(self: *Mutex) void {
        std.debug.assert(std.c.pthread_mutex_lock(&self.raw) == .SUCCESS);
    }

    /// Releases the mutex.
    pub fn unlock(self: *Mutex) void {
        std.debug.assert(std.c.pthread_mutex_unlock(&self.raw) == .SUCCESS);
    }

    /// Destroys the native mutex after all users have stopped.
    pub fn deinit(self: *Mutex) void {
        std.debug.assert(std.c.pthread_mutex_destroy(&self.raw) == .SUCCESS);
        self.* = .{};
    }
};

// A pointer on FreeBSD/OpenBSD, 4 bytes on glibc, and 16 on NetBSD. Darwin
// returns before using this storage; 64 bytes covers every non-Darwin layout.
const PthreadCondattr = extern struct { bytes: [64]u8 align(16) };

extern "c" fn pthread_condattr_init(attr: *PthreadCondattr) c_int;
extern "c" fn pthread_condattr_setclock(attr: *PthreadCondattr, clock: clockid_t) c_int;
extern "c" fn pthread_condattr_destroy(attr: *PthreadCondattr) c_int;
extern "c" fn pthread_cond_init(cond: *std.c.pthread_cond_t, attr: *const PthreadCondattr) c_int;
extern "c" fn pthread_cond_timedwait_relative_np(
    cond: *std.c.pthread_cond_t,
    mutex: *std.c.pthread_mutex_t,
    timeout: *const timespec,
) c_int;

/// Native condition variable paired with `Mutex`.
pub const Condition = if (is_windows) struct {
    raw: windows.CONDITION_VARIABLE = .{},

    /// Atomically releases `mutex` and waits for a signal or broadcast.
    pub fn wait(self: *Condition, mutex: *Mutex) void {
        std.debug.assert(windows.kernel32.SleepConditionVariableSRW(
            &self.raw,
            &mutex.raw,
            windows.INFINITE,
            0,
        ) != 0);
    }

    /// Waits with a relative monotonic timeout, splitting waits that exceed
    /// the native millisecond range instead of returning early.
    pub fn timedWait(self: *Condition, mutex: *Mutex, timeout_ns: u64) error{Timeout}!void {
        const start = monotonicNs() catch unreachable;
        const deadline = start +| timeout_ns;
        while (true) {
            const now = monotonicNs() catch unreachable;
            const remaining = deadline -| now;
            const rounded = remaining / std.time.ns_per_ms +
                @intFromBool(remaining % std.time.ns_per_ms != 0);
            const milliseconds: u32 = @intCast(@min(rounded, @as(u64, windows.INFINITE - 1)));
            const rc = windows.kernel32.SleepConditionVariableSRW(
                &self.raw,
                &mutex.raw,
                milliseconds,
                0,
            );
            if (rc != 0) return;
            if (windows.kernel32.GetLastError() != .TIMEOUT) unreachable;
            if (monotonicNs() catch unreachable >= deadline) return error.Timeout;
        }
    }

    /// Wakes one waiter.
    pub fn signal(self: *Condition) void {
        windows.kernel32.WakeConditionVariable(&self.raw);
    }

    /// Wakes every waiter.
    pub fn broadcast(self: *Condition) void {
        windows.kernel32.WakeAllConditionVariable(&self.raw);
    }

    /// Releases native resources. Condition variables need no destruction.
    pub fn deinit(self: *Condition) void {
        self.* = .{};
    }
} else struct {
    raw: std.c.pthread_cond_t = .{},
    init_state: std.atomic.Value(u8) = .init(0),

    fn ensureInit(self: *Condition) void {
        if (comptime is_darwin) return;
        if (self.init_state.load(.acquire) == 2) return;
        if (self.init_state.cmpxchgStrong(0, 1, .acquire, .acquire) == null) {
            var attr: PthreadCondattr = std.mem.zeroes(PthreadCondattr);
            std.debug.assert(pthread_condattr_init(&attr) == 0);
            defer std.debug.assert(pthread_condattr_destroy(&attr) == 0);
            std.debug.assert(pthread_condattr_setclock(&attr, .MONOTONIC) == 0);
            std.debug.assert(pthread_cond_init(&self.raw, &attr) == 0);
            self.init_state.store(2, .release);
            return;
        }
        while (self.init_state.load(.acquire) != 2) std.atomic.spinLoopHint();
    }

    /// Atomically releases `mutex` and waits for a signal or broadcast.
    pub fn wait(self: *Condition, mutex: *Mutex) void {
        self.ensureInit();
        std.debug.assert(std.c.pthread_cond_wait(&self.raw, &mutex.raw) == .SUCCESS);
    }

    /// Waits with a relative monotonic timeout. Darwin uses its native
    /// relative-wait API; other POSIX targets use a monotonic condattr.
    pub fn timedWait(self: *Condition, mutex: *Mutex, timeout_ns: u64) error{Timeout}!void {
        self.ensureInit();
        if (comptime is_darwin) {
            const timeout = nsToTimespec(timeout_ns);
            const rc = pthread_cond_timedwait_relative_np(&self.raw, &mutex.raw, &timeout);
            if (rc == 0) return;
            if (rc == @intFromEnum(E.TIMEDOUT)) return error.Timeout;
            unreachable;
        } else {
            const deadline_ns = (monotonicNs() catch unreachable) +| timeout_ns;
            const deadline = nsToTimespec(deadline_ns);
            const rc = std.c.pthread_cond_timedwait(&self.raw, &mutex.raw, &deadline);
            switch (rc) {
                .SUCCESS => return,
                .TIMEDOUT => return error.Timeout,
                else => unreachable,
            }
        }
    }

    /// Wakes one waiter.
    pub fn signal(self: *Condition) void {
        self.ensureInit();
        std.debug.assert(std.c.pthread_cond_signal(&self.raw) == .SUCCESS);
    }

    /// Wakes every waiter.
    pub fn broadcast(self: *Condition) void {
        self.ensureInit();
        std.debug.assert(std.c.pthread_cond_broadcast(&self.raw) == .SUCCESS);
    }

    /// Destroys the condition variable after all waiters have left.
    pub fn deinit(self: *Condition) void {
        self.ensureInit();
        std.debug.assert(std.c.pthread_cond_destroy(&self.raw) == .SUCCESS);
        self.* = .{};
    }
};

fn nsToTimespec(nanoseconds: u64) timespec {
    return .{
        .sec = @intCast(nanoseconds / std.time.ns_per_s),
        .nsec = @intCast(nanoseconds % std.time.ns_per_s),
    };
}

/// Manual-reset event backed by the native mutex and condition variable.
pub const ResetEvent = struct {
    mutex: Mutex = .{},
    condition: Condition = .{},
    state: std.atomic.Value(bool) = .init(false),

    /// Reports whether the event is set with acquire semantics.
    pub fn isSet(self: *const ResetEvent) bool {
        return self.state.load(.acquire);
    }

    /// Blocks until the event is set.
    pub fn wait(self: *ResetEvent) void {
        if (self.isSet()) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.isSet()) self.condition.wait(&self.mutex);
    }

    /// Blocks until set or until `timeout_ns` elapses.
    pub fn timedWait(self: *ResetEvent, timeout_ns: u64) error{Timeout}!void {
        if (self.isSet()) return;
        const start = monotonicNs() catch unreachable;
        const deadline = start +| timeout_ns;
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.isSet()) {
            const now = monotonicNs() catch unreachable;
            if (now >= deadline) return error.Timeout;
            self.condition.timedWait(&self.mutex, deadline - now) catch |err| switch (err) {
                error.Timeout => if (!self.isSet()) return error.Timeout,
            };
        }
    }

    /// Sets the event and wakes all current and future waiters.
    pub fn set(self: *ResetEvent) void {
        if (self.isSet()) return;
        self.mutex.lock();
        self.state.store(true, .release);
        self.condition.broadcast();
        self.mutex.unlock();
    }

    /// Clears the event. Resetting with blocked waiters is a caller invariant violation.
    pub fn reset(self: *ResetEvent) void {
        self.state.store(false, .monotonic);
    }

    /// Destroys the event after all threads have stopped using it.
    pub fn deinit(self: *ResetEvent) void {
        self.condition.deinit();
        self.mutex.deinit();
        self.* = .{};
    }
};

/// Best-effort diagnostic thread naming without the newer standard-library
/// I/O parameter. Unsupported targets and naming refusals leave the name unchanged.
pub fn setThreadName(thread: std.Thread, name: []const u8) void {
    if (comptime builtin.zig_version.minor < 16) {
        thread.setName(name) catch return;
        return;
    }
    if (comptime native_os != .linux and native_os != .freebsd) return;
    if (name.len > 15) return;
    var buffer: [16:0]u8 = @splat(0);
    @memcpy(buffer[0..name.len], name);
    if (comptime native_os == .linux) {
        _ = std.c.pthread_setname_np(thread.getHandle(), &buffer);
    } else if (comptime native_os == .freebsd) {
        std.c.pthread_set_name_np(thread.getHandle(), &buffer);
    }
}
