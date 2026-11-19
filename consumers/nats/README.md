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
tree is the verified vendored bytes with exactly one difference:
`tests/utils.zig` is replaced by the born-owned facade in `utils.zig`
(this directory), which implements the same public surface with native
nats-server v2.15.0 provisioning instead of docker compose (design 7.2,
adjudicated Q4). The vendored upstream `tests/utils.zig` is kept for
provenance and hash verification; it is never compiled.

Runtime CWD contract (same as upstream): the e2e executable runs with a
CWD containing `tests/configs/` (`TestUser.creds` is read relative to the
CWD; the nkey/jwt servers are started with `--config tests/configs/...`).
The build's `test-e2e` step sets the CWD to this directory; CI uploads
`tests/configs/` alongside the cross-built executable. TLS configs and
certs are vendored for completeness but unused: TLS is compiled out
(`use_tls = false`) and the TLS nodes are not provisioned.