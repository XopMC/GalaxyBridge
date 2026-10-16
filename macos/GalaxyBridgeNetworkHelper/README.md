# Optional network helper

The installed helper runs as root; packet parsing, SOCKS and TLS run in the
ordinary Mac application. No NetworkExtension entitlement, kext or SIP change is
used. Merely building the app does not install or launch this helper.

`GBNetworkLease.h` exposes a fixed-size AF_UNIX request/reply ABI. Launchd owns the
fixed socket `/var/run/GalaxyBridgeNetworkHelper.sock`; the client receives only
a utun descriptor through SCM_RIGHTS. There is no command/path/script argument.
The peer's public Darwin `LOCAL_PEERTOKEN` audit token identifies its live code.
The code signature must validate, its CDHash must match the root-installed pin,
and its effective UID must be the active console user's UID. Both installation
approval and live IPC also require Hardened Runtime, with no enabled exception
for library validation, DYLD environment variables, debugging, JIT, unsigned
executable memory or executable-page protection. A pinned ordinary ad-hoc client
is rejected; the client must be signed with `--options runtime`. Explicit false
Boolean entitlements grant no exception; malformed metadata fails closed.

`trial_seconds=0` supports normal sustained sharing, subject to a 15-second
heartbeat expiry. Values 1..30 add a hard QA deadline. Heartbeats must arrive
more frequently than that expiry; the app uses five seconds. Product opt-in
(`GB_NETWORK_MUTATION_APPROVED`) is distinct from the independent test harness's
reserve/guardian/permission gate.

The helper allocates one utun, configures fixed IPv4 and a lease-specific IPv6
ownership marker, and adds split default routes without replacing existing
routes. Existing connected-interface routes outrank those /1 additions. Physical
gateways must be on a non-utun connected subnet; localhost USB needs no gateway
entry. `UPDATE_GATEWAYS` validates additions against this invariant while a
second peer is admitted. An existing default through utun/tun/ppp, or a foreign
split route, causes refusal before route mutation; updating the current lease
permits only its own interface and live ownership marker.

DNS uses only 127.0.0.1 at the unprivileged DNS relay's typed ephemeral port
(`kSCPropNetDNSServerPort`); complete UDP/TCP DNS wire messages use authenticated
`dns-wire-v1` TLS channels and Android's selected-Network resolver, including
Private DNS. There is no public third-party DNS fallback.

DNS uses a unique lease-keyed SystemConfiguration entry and is removed only if
its complete current value equals the helper's value. Route deletion requires
exact prefix, interface index and the unique live interface marker. A changed
route or DNS entry is preserved and cleanup remains failed/fenced. Route ADD
uses a persisted PREPARED state, becomes committed only after success, and an
EEXIST response never grants ownership of the existing route. Uncertain writes
require the same exact current ownership proof during recovery.

A root-only, no-follow journal is fsynced before mutation. On daemon restart,
owned state is restored before new admission. An independent five-second
launchd guardian checks the same monotonic lease deadline. A boot-session UUID
prevents old journals from modifying reused interface IDs after reboot. The
interface is explicitly brought down before its descriptor is closed, because
an app may still own its duplicate descriptor.

## Offline installer approval

`python3 scripts/package-network-helper.py --app <signed-app> --output <pkg>`
creates an optional unsigned package and never installs it. The package embeds
a SHA-256 fingerprint of the actual thin 64-bit Mach-O program, normalized to
exclude its LC_CODE_SIGNATURE/blob and signature contribution to __LINKEDIT.
Embedding this package in app Resources and resigning the app therefore does
not create a self-referential CDHash dependency.

The installer's fixed `--approve-app` operation validates the complete signature
and resources of `/Applications/Galaxy Bridge.app`, checks that immutable program
fingerprint, then writes the actual final CDHash pin as root. It accepts no app
path or generic approval request. An app update requires renewed installation
approval. Ad-hoc signatures are supported; a paid developer certificate is not
required. Universal/fat app executables are currently rejected by the packager.

`UNINSTALL` is a pinned-caller-only typed operation. It restores the caller's
owned lease first, rejects cleanup conflicts, and removes only fixed helper,
launchdaemon, approval and journal paths. It never recursively deletes unknown
files. The reply precedes unloading the current launchd job.

Run `bash scripts/test-network-helper.sh` for pure lifecycle/flow tests, Darwin
compilation and a real ad-hoc-sign/resign program-fingerprint test. This test
never starts the daemon, installs a package, allocates utun or changes networking.
Privileged runtime behavior and recovery after real process/network failures
remain unverified until separately authorized guarded acceptance.
