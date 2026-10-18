//! Portable deadline heap for backends with one kernel timer per port
//! (timer_epoll.zig, timer_iocp.zig). Owned by born#11: this file and its
//! unit tests.
//!
//! Contract #11 implements:
//!   - a min-heap of { deadline_ns, id, udata, period_ns } on a monotonic
//!     clock, never wall time;
//!   - add (replaces a live id), cancel, next (earliest deadline) and
//!     expire (pops due entries, re-inserts repeating ones without drift
//!     and reports missed periods as `fired`);
//!   - O(log n) operations with an id index, allocation only through the
//!     caller's allocator, failures returned rather than swallowed.
//!
//! Empty until #11 lands. kqueue does not use it (native EVFILT_TIMER).
