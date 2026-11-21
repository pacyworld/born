# Vendored nats.zig e2e tests

`tests/` is a byte-identical copy of the upstream test tree at the pinned
commit:

- Upstream: https://github.com/lalinsky/nats.zig
- Pin: `b8ffdd9285a30b0251123122a4fa9e3a12a74fb9`
- License: Apache-2.0 (`LICENSE`, copied from upstream)

Vendoring is necessary because nats's own `build.zig.zon` `.paths` is
`{ "build.zig", "build.zig.zon", "src" }`: the fetched package tarball
contains no `tests/` entries, so the e2e tree cannot come from the package
fetch. The pin's `src/`, `build.zig` and `build.zig.zon` were verified
byte-identical to the fetched tarball before vendoring.

`manifest.sha256` records the upstream sha256 of every vendored file.
`../build.zig` verifies every listed file at configure time and aborts on
any mismatch or unlisted file (review 192 carry-in 4). The generated e2e
tree is the verified vendored bytes with the born-owned overrides listed
in `e2e_overrides` (`../build.zig`). Each vendored original is kept
byte-identical for provenance and hash verification and is never compiled:

- `tests/utils.zig` is replaced by the born-owned facade in `utils.zig`
  (this directory), which implements the same public surface with native
  nats-server v2.15.0 provisioning instead of docker compose (design 7.2,
  adjudicated Q4).
- `tests/pending_msgs_test.zig` is replaced by the born-owned copy in
  `pending_msgs_test.zig` (this directory), which carries the #128 fix for
  the async pending-counter race (see below). Its other tests are
  unchanged from upstream.

Each override entry pins the upstream sha256 it was derived from
(`base_sha256`); `generateE2eTree` panics if the vendored path is missing
from the verified tree or its hash differs, so a pin bump forces a
deliberate re-derive or drop of each override (review 724).

Runtime CWD contract (same as upstream): the e2e executable runs with a
CWD containing `tests/configs/` (`TestUser.creds` is read relative to the
CWD; the nkey/jwt servers are started with `--config tests/configs/...`).
The build's `test-e2e` step sets the CWD to this directory; CI uploads
`tests/configs/` alongside the cross-built executable. TLS configs and
certs are vendored for completeness but unused: TLS is compiled out
(`use_tls = false`) and the TLS nodes are not provisioned.
## Known upstream gaps

### Zig 0.16.0 Threaded Windows refusal mapping (W3, born#118)

On Windows with Zig 0.16.0, `std.Io.Threaded` maps a refused TCP connect
(`CONNECTION_REFUSED`, NTSTATUS `0xC0000236`) to `error.Unexpected` instead
of `error.ConnectionRefused`: `netConnectIpWindows` handles only
`.SUCCESS`, `.CANCELLED` and `.INSUFFICIENT_RESOURCES` from the AFD connect
and sends every other status through `windows.unexpectedStatus`. 0.17.1
adds the `.CONNECTION_REFUSED` case. Consequences for this suite:

- The vendored `net_util` test "tcpConnectToHost with nothing listening"
  asserts `error.ConnectionRefused` and fails on the **threaded control**
  Windows 0.16.0 unit leg (118 passed; 2 skipped; 1 failed). The **born
  route passes the identical test**: Born's IOCP connect maps the refusal
  correctly. The vendored test is hash-verified upstream code and is not
  patched, and the born gate is not relaxed; the threaded control leg
  stays known-failing on Windows 0.16.0 until the 0.17 migration (#109)
  or an upstream backport.
- The fixture health probe never branches on connect error identity (any
  connect failure means "not open yet", bounded retry), so the mapping
  cannot change probe behavior; startup refusals are expected noise on
  every platform. The probe records the last error per service and
  surfaces it, with the failing stage, on a ServicesNotHealthy timeout.

Tracking: born#118 (Windows nats evidence rows + W3). The upstream Zig
issue body is prepared there; filing is pending while ziglang/zig
restricts issue creation to collaborators, and the upstream link will be
added here once filed.

### Async pending-counter race in the vendored test (born#128)

The upstream async test waits for `processed_count == 3` and then asserts
`pending_msgs == 0` and `pending_bytes == 0`. The client's handler fiber
(`src/subscription.zig` `handlerLoop`) calls the handler and only then
`decrementPending`, so the counters can still be non-zero when the
handler's last statement has run: the test infers a condition it does not
wait for. The client is correct ("pending" includes the message in
flight); the race is in the test. It surfaced on Windows with Zig 0.16.0
on the born route in both Debug and ReleaseSafe (dispatch runs 483 and
537).

The born-owned copy waits bounded (200 x 10 ms) on `pending_msgs == 0`
and `pending_bytes == 0` as its own condition, and prints
`processed_count`, `pending_msgs` and `pending_bytes` with a label naming
the assertion before each expect, so a future failure names its line. An
"after processed wait" counter line prints between the processed wait and
the pending wait (the observable race window), and the pending wait's
iteration count prints after it; the `std.debug.print` output is
intentional diagnostics. The final assertions are unchanged. The vendored
original is not patched (same policy as W3 above). The override is pinned
to the upstream hash it was derived from: a pin bump that changes the
vendored file fails the build until the override is re-derived or dropped
(review 724).
