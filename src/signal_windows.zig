//! Signals on Windows: console control events. Owned by born#17: this file
//! plus the EvPort.watchSignal/unwatchSignal bodies in evport_iocp.zig.
//!
//! One SetConsoleCtrlHandler routine serves the process. It maps
//! CTRL_C_EVENT to `.interrupt` and CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT and
//! CTRL_SHUTDOWN_EVENT to `.terminate`, and only
//! `post(EvPort.internalKey(.signal), null, @intFromEnum(sig))`s to the
//! owning port; wait() hands that completion to `harvest`, which emits
//! Event{ .signal, .fired = 1, .udata }. For a watched event the routine
//! returns TRUE, so the default handler does not end the process; for an
//! unwatched one it returns FALSE and the default action runs.
//! `.hangup`, `.user1` and `.user2` are error.Unsupported, and so is every
//! signal in a process without a console (a service, a GUI program, a
//! DETACHED_PROCESS child): console events never reach it.
//!
//! CTRL_CLOSE_EVENT and CTRL_SHUTDOWN_EVENT: the system ends the process
//! as soon as the routine returns, or after its timeout (about 5 s for
//! CTRL_CLOSE_EVENT). After posting one, the routine therefore holds its
//! system thread until the process exits, so the loop gets that time to
//! shut down; the program ends by returning from main. A program that
//! loads user32.dll or gdi32.dll gets no CTRL_SHUTDOWN_EVENT (the console
//! handler is skipped for it), only window messages.
//!
//! CTRL+C: the routine is only called while the process does not ignore
//! CTRL+C. A process started with CREATE_NEW_PROCESS_GROUP, or by a parent
//! that ignores CTRL+C, has the ignore flag set (born-tests.exe under
//! OpenSSH on win11-dev starts with it). Watching `.interrupt` clears the
//! flag (SetConsoleCtrlHandler(NULL, FALSE)); its last unwatch sets it
//! again if it was set, mirroring the POSIX backends' disposition restore.
//!
//! Ownership is process-wide like on kqueue and epoll: at most one port
//! watches a signal, and a second port gets error.SignalInUse until the
//! first unwatches it or is deinitialized. The routine is installed by the
//! first watch in the process and removed by the last unwatch, which
//! State.deinit runs before the port handle closes (the #5 lifetime rule).
//! A port must not move while it watches a signal: the routine posts
//! through the port's address.
//!
//! Locking: the routine runs on a system thread while the console's
//! handler-list lock is held, and every SetConsoleCtrlHandler call waits
//! for that lock (measured on Windows 11 26100: an add waited 1.8 s behind
//! a handler that slept 2 s). So:
//!   - `owners_lock` guards the owner table. The routine reads the owner
//!     and posts with it held, and unwatch clears the owner with it held,
//!     so once unwatch returns no routine posts to that port: a routine
//!     that ran first has finished its post, and a later one finds no
//!     owner. Nothing holds `owners_lock` across SetConsoleCtrlHandler.
//!   - `config_lock` serializes watch and unwatch (and their
//!     SetConsoleCtrlHandler calls); the routine never takes it.
//!   - A routine holding its thread after CTRL_CLOSE/SHUTDOWN keeps the
//!     handler-list lock forever, so it first sets `ending` under
//!     `owners_lock`, and later watch/unwatch calls skip their
//!     SetConsoleCtrlHandler calls (the process is ending; the routine
//!     stays installed and returns FALSE once nothing is owned). If a
//!     close arrives while such a call is in flight (`configuring`), the
//!     routine posts and returns at once, so the call cannot hang; the
//!     process then ends without the grace period.
//!
//! Changing the process's console (FreeConsole, AllocConsole,
//! AttachConsole) clears its handler list, so a routine installed before
//! the change is gone (Windows 11 26100). No API reports it, and the
//! parameter block's console handle can have the same value on the new
//! console, so born cannot detect it. Change consoles before watching, or
//! unwatch every signal afterwards (the routine's removal then fails and
//! the next watch installs it again) and watch again.

const std = @import("std");
const windows = std.os.windows;
const kernel32 = windows.kernel32;
const iocp = @import("evport_iocp.zig");
const EvPort = iocp.EvPort;
const Event = iocp.Event;
const SignalError = iocp.SignalError;
const Signal = iocp.Signal;

extern "kernel32" fn GetConsoleProcessList(lpdwProcessList: [*]windows.DWORD, dwProcessCount: windows.DWORD) callconv(.winapi) windows.DWORD;

/// The port that receives each signal, null while unwatched.
var owners: std.EnumArray(Signal, ?*EvPort) = .initFill(null);
/// Guards `owners`, `ending` and `configuring`; see the file comment.
var owners_lock: std.Thread.Mutex = .{};
/// A routine holds its thread after CTRL_CLOSE/SHUTDOWN_EVENT.
var ending = false;
/// A SetConsoleCtrlHandler call is in flight.
var configuring = false;

/// Serializes watch and unwatch across threads; guards the fields below.
var config_lock: std.Thread.Mutex = .{};
/// `onConsoleEvent` is registered.
var installed = false;
/// CTRL+C was ignored before `.interrupt` was watched.
var restore_ignore = false;

/// Per-port watch bookkeeping, a field of EvPort (`signals`). Read and
/// written only by the thread that owns the port.
pub const State = struct {
    watched: std.EnumSet(Signal) = .initEmpty(),
    udata: std.EnumArray(Signal, ?*anyopaque) = .initFill(null),

    pub fn init(alloc: std.mem.Allocator) State {
        _ = alloc;
        return .{};
    }

    /// Unwatches every signal the port watches, removing the console
    /// routine when no other port watches one.
    pub fn deinit(self: *State, port: *EvPort) void {
        const set = self.watched;
        var it = set.iterator();
        while (it.next()) |sig| unwatch(port, sig);
    }
};

/// Deliver `sig` as Event{ .signal, .fired = 1, .udata } from the port's
/// wait(). Re-watching a signal the port already watches replaces its udata.
pub fn watch(port: *EvPort, sig: Signal, udata: ?*anyopaque) SignalError!void {
    switch (sig) {
        .interrupt, .terminate => {},
        .hangup, .user1, .user2 => return SignalError.Unsupported,
    }
    config_lock.lock();
    defer config_lock.unlock();
    const st = &port.signals;
    if (st.watched.contains(sig)) {
        st.udata.set(sig, udata);
        return;
    }
    {
        owners_lock.lock();
        defer owners_lock.unlock();
        if (owners.get(sig) != null) return SignalError.SignalInUse;
    }
    if (!hasConsole()) return SignalError.Unsupported;
    if (!installed) {
        // Skipped only while ending, when the routine is still registered.
        if (setHandler(onConsoleEvent, true) == false) return SignalError.SystemResources;
        installed = true;
    }
    {
        owners_lock.lock();
        defer owners_lock.unlock();
        owners.set(sig, port);
    }
    st.watched.insert(sig);
    st.udata.set(sig, udata);
    if (sig == .interrupt and ctrlCIgnored()) {
        // Owner first: CTRL+C reaches the routine from here on. Clearing
        // the flag only writes the process parameter block; it cannot fail.
        _ = setHandler(null, false);
        restore_ignore = true;
    }
}

/// Stop watching `sig` and release it to other ports. Unwatched signals
/// are a no-op.
pub fn unwatch(port: *EvPort, sig: Signal) void {
    const st = &port.signals;
    if (!st.watched.contains(sig)) return;
    config_lock.lock();
    defer config_lock.unlock();
    if (sig == .interrupt and restore_ignore) {
        // Ignore CTRL+C again before releasing it, as before the watch.
        _ = setHandler(null, true);
        restore_ignore = false;
    }
    var any_owned = false;
    {
        owners_lock.lock();
        defer owners_lock.unlock();
        owners.set(sig, null);
        for (owners.values) |owner| any_owned = any_owned or owner != null;
    }
    st.watched.remove(sig);
    st.udata.set(sig, null);
    if (!any_owned and installed) {
        // A failed removal means the routine is no longer registered (a
        // console change cleared the list). Skipped while ending: the
        // routine stays and returns FALSE with nothing owned.
        if (setHandler(onConsoleEvent, false) != null) installed = false;
    }
}

/// Handles one internal signal completion (`payload` is the Signal
/// ordinal). Writes at most `out.len` (>= 1) events and returns the count.
pub fn harvest(port: *EvPort, payload: usize, out: []Event) usize {
    if (payload >= std.meta.fields(Signal).len) @panic("born: signal_windows.harvest with an invalid payload");
    const sig: Signal = @enumFromInt(payload);
    const st = &port.signals;
    // Posted before an unwatch on this port: stale, not delivered.
    if (!st.watched.contains(sig)) return 0;
    out[0] = .{ .signal = sig, .fired = 1, .udata = st.udata.get(sig) };
    return 1;
}

/// Windows has no signal mask to set: a documented no-op so portable
/// programs call it unconditionally.
pub fn blockSignals(sigs: []const Signal) SignalError!void {
    _ = sigs;
}

/// The console control routine. Runs on a system thread with the
/// console's handler-list lock held; it only posts.
fn onConsoleEvent(ctrl: windows.DWORD) callconv(.winapi) windows.BOOL {
    const sig: Signal, const ends_process = switch (ctrl) {
        windows.CTRL_C_EVENT => .{ .interrupt, false },
        windows.CTRL_BREAK_EVENT => .{ .terminate, false },
        windows.CTRL_CLOSE_EVENT, windows.CTRL_SHUTDOWN_EVENT => .{ .terminate, true },
        else => return windows.FALSE,
    };
    {
        owners_lock.lock();
        defer owners_lock.unlock();
        const port = owners.get(sig) orelse return windows.FALSE;
        // A failed post is stashed on the port and reported by its next wait().
        port.post(EvPort.internalKey(.signal), null, @intFromEnum(sig));
        if (!ends_process or configuring) return windows.TRUE;
        ending = true;
    }
    // Returning ends the process: hold this thread until the program
    // exits or the system's timeout passes.
    kernel32.Sleep(windows.INFINITE);
    return windows.TRUE;
}

/// One SetConsoleCtrlHandler call, made outside `owners_lock`. Returns
/// its result, or null when skipped because the process is ending.
/// Callers hold `config_lock`.
fn setHandler(routine: ?windows.HANDLER_ROUTINE, add: bool) ?bool {
    {
        owners_lock.lock();
        defer owners_lock.unlock();
        if (ending) return null;
        configuring = true;
    }
    const ok = kernel32.SetConsoleCtrlHandler(routine, @intFromBool(add)) != 0;
    owners_lock.lock();
    configuring = false;
    owners_lock.unlock();
    return ok;
}

/// The process is attached to a console (GetConsoleProcessList fails
/// without one).
fn hasConsole() bool {
    var pid: [1]windows.DWORD = undefined;
    return GetConsoleProcessList(&pid, pid.len) != 0;
}

/// The process ignores CTRL+C: bit 0 of the parameter block's
/// ConsoleFlags, which SetConsoleCtrlHandler(NULL, ...) writes.
fn ctrlCIgnored() bool {
    return windows.peb().ProcessParameters.ConsoleFlags & 1 != 0;
}
