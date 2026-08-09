# Runtime evaluation: Lima vs apple/container

Measured 2026-08-09 on macOS 26.5.2, Apple M5 Pro, `container` 1.2.2
(kernel 6.18.15), Lima 2.2.0 (vz + virtiofs). Every result below is from
a run on this machine, not from documentation.

## Summary

`container` clears the bar on every *mechanism* Mosaic depends on, and
it solves the plugin-linking problem outright — see
[link-architecture.md](link-architecture.md). The DNS problem that
looked like a blocker resolved into a sudo-free path — but the deeper
finding stands: **under a leak-protection VPN (Mullvad, connected),
apple/container guests have no outbound network at all, while Lima's
host-process networking is unaffected** (see Networking). On a machine
where such a VPN is daily reality, that finding dominates the backend
choice.

| Question | Answer |
|---|---|
| Can plugins be grafted onto a baked tree? | Yes — at container-create time, no in-guest agent |
| Does `__DIR__` still resolve canonically? | Yes — it's a real mount, not a symlink |
| Do host mounts need ownership management? | No — writes succeed as any uid |
| Does systemd work? | Yes — PID 1, zero failed units, custom units fine |
| Is the filesystem faster than Lima? | No — identical; both are vz + virtiofs |
| Does service discovery work? | By name: only with one-time sudo setup. Sudo-free answer: single-container topology (see Networking) |

## Mount and linking semantics

The load-bearing question for Mosaic: can a host directory appear at a
canonical path *inside* the framework tree, such that PHP's `__DIR__`
resolves to the canonical path rather than the host path? In v1 this is
what forced `mount --bind` and, with it, the whole `apply-graft`
apparatus.

| Test | Result |
|---|---|
| `mount --bind` inside a default container | **Fails** — `CapEff=00000000a80425fb`, no `CAP_SYS_ADMIN` |
| `mount --bind` with `--cap-add CAP_SYS_ADMIN` | Works |
| `mount --bind` inside a `container machine` | Works — machines get `CapEff=000001ffffffffff` (full) |
| Create-time `-v host:/srv/fw/local/plugin_a` over image content | **Works** — shadows the baked stub |
| `pwd -P` inside that mount | `/srv/fw/local/plugin_a` (canonical, not host path) |
| `realpath ../../config.php` from inside it | `/srv/fw/config.php` — **image content, correct** |
| Single-*file* mount (`-v host/.env:/srv/fw/.env`) | Works |
| Write container → host | Works; host file stays `work:wheel` |

The fourth row is the finding that changes the architecture. A create-time
`--volume` gives exactly the semantics `apply-graft`'s bind mounts were
built to produce, declaratively, with no in-guest script, no systemd unit
and no state file. And because single files work too, the v1 split of
"directories get bind mounts, files get symlinks" is no longer forced by
the mechanism — it becomes a semantic choice.

Re-creating a container with a different mount set: **0.49s**. That is
what makes declarative mounts ergonomic here; on Lima the equivalent is a
`lima.yaml` edit plus a VM restart, which is why `apply-graft` had to
exist at all.

## Ownership and permissions

The known upstream complaint (issues
[#333](https://github.com/apple/container/issues/333),
[#165](https://github.com/apple/container/issues/165)) is real but much
less harmful than it reads:

| Test | Result |
|---|---|
| `chown`/`chmod` on a mounted host path | **Fails** — `Operation not permitted` |
| `chown`/`chmod` on an image-rootfs path | Works normally |
| Mount ownership as seen in-container | Always `0:0`, regardless of `-u` |
| Write into a mount as `-u 1000:1000` (dir is `0:0`, mode 755) | **Succeeds** |

That last row is the important one: DAC is not enforced on host mounts.
Whatever uid the process runs as can read and write mounted content. So
Moodle's `www-data` needs no ownership management for host-mounted code —
the entire `chown www-data` dance in v1's provisioning applies only to
paths that need real ownership (`moodledata`, `phpunitdata`), and those
live in the container's own filesystem where `chown` works.

Caveat worth writing down: because permissions aren't enforced on mounts,
nothing inside a mount can be relied on for isolation. Fine for a dev
tool; don't build anything security-relevant on it.

## systemd

Works as PID 1. The initial failure was missing tmpfs, nothing else:

| Configuration | Result |
|---|---|
| `/sbin/init` with no extra flags | Container exits immediately |
| `--tmpfs /run --tmpfs /run/lock` | **`is-system-running: running`**, nginx active, 0 failed units |
| Adding `--cap-add CAP_SYS_ADMIN` or `ALL` | No further improvement — not needed |
| Installing and starting a custom unit at runtime | Works |

So the v1 model (one pet environment running nginx + php-fpm under
systemd) ports directly, without privileged mode. PID 1 in a plain
container is your own process; Apple's `vminitd` is only PID 1 inside a
`container machine`.

## Filesystem performance

19,800 small PHP files across 600 directories — same script, same 4 CPU /
6 GB sizing in both runtimes. Times in seconds.

| Target | create | traverse | stat | read | grep | delete |
|---|---|---|---|---|---|---|
| container rootfs (block dev) | 0.254 | 0.011 | 0.017 | **0.058** | 0.023 | 0.037 |
| Lima guest ext4 | 0.282 | 0.008 | 0.019 | **0.088** | 0.031 | 0.083 |
| macOS APFS (host reference) | 1.786 | 0.036 | 0.035 | 0.255 | 0.407 | 0.912 |
| container host mount (virtiofs) | 5.085 | 0.119 | 0.137 | **2.371** | 1.954 | 1.947 |
| Lima host mount (virtiofs) | 5.564 | 0.112 | 0.354 | **2.506** | 2.393 | 2.028 |

Two conclusions:

1. **The runtimes are indistinguishable.** Same Virtualization.framework,
   same virtiofs implementation. There is no filesystem performance
   argument for switching, in either direction.
2. **v1's core constraint holds unchanged.** Guest-native storage is
   ~30-40× faster than a host mount on read-heavy work. Never serve the
   framework tree from a host mount, on either runtime. What changes is
   only *where* guest-native lives: an image layer (cacheable, shared
   across projects) instead of a per-project bake onto ext4.

## Networking

| Test | Result |
|---|---|
| `-p 127.0.0.1:8099:80` → host | Works — HTTP 200 |
| Isolated network via `container network create` | Works — 192.168.65.0/24 |
| Cross-network reachability | Correctly blocked |
| Container → sibling by IP | Works — but IPs change on every stop/start |
| Container → sibling **by name** | Fails without the one-time sudo domain setup |
| Container → external DNS (gateway resolver, UDP) | **Works** after evicting the port-53 squatter (was: mullvad-daemon) |
| Container → external DNS (gateway resolver, TCP) | Works |
| Container → external DNS with `--dns-option use-vc` (glibc TCP mode) | Works — sudo-free fallback when UDP is blocked |
| Container → external DNS with `--dns 1.1.1.1` | Works (but replaces the sibling-name resolver) |

### The DNS story, resolved

Follow-up testing dissected the failure into three independent facts:

1. **The gateway resolver was alive but TCP-only — root cause found and
   fixed.** `dig +tcp @192.168.65.1 apple.com` answered while UDP got
   `connection refused`; `getent`, apt, composer and PHP query over UDP,
   which is why everything appeared dead. The culprit was **not** the
   VPN/filter stack (Little Snitch, Tailscale and both VPNs were
   disabled with no effect): a `mullvad-daemon` LaunchDaemon — running
   from boot, tunnel disconnected, invisible in the VPN & Filters panel
   — held `udp4 127.84.247.91:53`. On BSD-derived stacks a wildcard bind
   conflicts with an existing specific bind, so when the container
   network came up, mDNSResponder's IPv4 UDP `*:53` bind failed while
   its IPv6-UDP and both TCP binds succeeded (visible in
   `netstat -anv`). Stopping the daemon
   (`sudo launchctl bootout system/net.mullvad.daemon`) and restarting
   `container system` restored plain UDP resolution: `getent hosts`
   works from containers with no flags. Caveat: the daemon returns on
   reboot unless Mullvad is uninstalled or the daemon kept disabled,
   which would silently re-break DNS.
2. **Even unfixed, outbound resolution has a sudo-free workaround.**
   `--dns-option use-vc` makes glibc use TCP for DNS:
   `getent hosts apple.com` succeeds against the gateway resolver even
   with UDP blocked. Mosaic images are Debian/Ubuntu (glibc), so this is
   a complete fallback for runtime containers; `container build` accepts
   the same `--dns` flag family. Worth shipping as a driver default
   anyway — any daemon that squats port 53 early (Mullvad here; other
   DNS-proxying tools behave similarly) reproduces the breakage, and
   TCP-mode DNS costs nothing at dev-environment query volume.
3. **Sibling-by-name genuinely requires the sudo feature.** The network
   attachment registers each container's hostname, but the resolver
   serves nothing for it — bare or domain-qualified, UDP or TCP — until
   a local domain exists. `container system dns create <domain>` is
   **once per machine, not per project** (it writes one
   `/etc/resolver/<domain>` entry; per-project would just be names under
   the shared domain), but it is real escalation, it disables Private
   Relay, and its packet-filter rule drops on restart. v1 requires no
   escalation at all.

And the fact that decides the topology:

4. **Container IPs are not stable.** A plain stop/start moved a
   container from `.8` to `.9`; rm + re-create gave `.10`. Sequential
   allocation, no reuse. Wiring services by IP would break on every
   `mosaic down && mosaic up`.

With unstable IPs and name-resolution behind sudo, **sibling-service
topology is out for the default path**. The sudo-free wiring that
survives all four facts is v1's own topology, transplanted: one
systemd container per project with nginx, php-fpm, db and mailpit inside
it, talking over localhost, with ports published to `127.0.0.1` exactly
as v1 allocates them today (`-p 127.0.0.1:8099:80` → HTTP 200,
verified). v1 already runs mariadb *inside* the project VM via podman —
this is the same shape with one less layer, and DB connections become
plain `127.0.0.1` instead of a nested container's forwarded port.

`container system dns create mosaic` stays available as an optional,
once-per-machine enhancement (`<project>.mosaic` URLs, host-side name
resolution) rather than a requirement.

### The Mullvad-connected finding (decisive)

Tested side by side with the tunnel up, identical probes in both
runtimes:

| Under Mullvad tunnel | apple/container | Lima |
|---|---|---|
| Guest outbound (TCP, any destination, v4+v6) | **Blocked — zero exceptions** | **Works** |
| Guest DNS | Works (`use-vc` via host-process resolver) | Works |
| Host → dev site (published/forwarded ports) | Works | Works |
| Image pulls (`container` pulls are host-side) | Works | n/a |
| Builds, composer/npm/git *inside* the guest | Blocked | Works |

No Mullvad setting changes this (local network sharing on, DNS content
blockers off — tested). The mechanism: Mullvad's PF rules pass traffic
originating from host processes and drop forwarded packets that belong
to no process. apple/container's vmnet networking emits raw NATed
packets; Lima's default network egresses via its hostagent process.
Split tunneling cannot help — the dropped packets aren't attributable
to an app. This is structural, not a bug on one machine: any
leak-protection VPN behaves this way.

What still works under the tunnel with apple/container: the dev site,
tests, DB — everything local — plus image pulls. What dies: `container
build` and any in-guest fetch (composer, npm, git, apt).

**Measurement trap, recorded for posterity:** `apt-get update` exits 0
even when every index fetch fails. Early probes using its exit code
produced false "works under tunnel" positives and a phantom
intermittency; only `update` + `install` + running the installed binary
is a valid probe.

Also found while isolating this: guest IPv6 egress is dead on this
machine in *all* states, and apt handles AAAA-first answers badly —
`Acquire::ForceIPv4` (or v4-preference in `gai.conf`) belongs in the
image defaults regardless of backend.

## Revised recommendation

My earlier read — stay on Lima, revisit later — was based on the
bind-mount permission story being a blocker. The tests show it isn't:
writes succeed regardless of uid, and the only thing that actually fails
(`chown` on a mount) is something Mosaic no longer needs to do. Weigh the
decision on the real trade instead:

**For `container`:** create-time mounts eliminate `apply-graft` entirely;
0.49s re-link; the framework becomes a cached image layer shared across
projects rather than a 5-10 minute per-project bake; systemd ports over
unchanged.

**Against:** Apple Silicon and macOS 26 only, which drops the Intel
support the v1 README advertises; sibling-service topology needs either
one-time sudo or abandoning it for the (v1-shaped) single-container
model; the `--dns-option use-vc` fallback should ship by default so
machines with port-53-squatting daemons (Mullvad et al.) work out of the
box.

The filesystem numbers are a wash, so that argument is off the table for
both sides.

Since the linking design in
[link-architecture.md](link-architecture.md) keeps the plan as data and
puts the runtime behind a driver interface, the backend choice stays a
one-module decision either way. With DNS dissected, the tested blocker
that remains is the Mullvad-connected finding above: **on a machine
that runs a leak-protection VPN daily, apple/container guests lose all
outbound network whenever the tunnel is up.** The candidate mitigations
change the decision space:

- **Lima + prebuilt VM images.** Lima survives the VPN out of the box.
  Its historical cost — 5-10 minute cloud-init provisioning — is not
  intrinsic: Lima boots custom disk images, so Mosaic can publish
  pre-provisioned images (PHP/nginx/db baked in) and recover most of
  the image-caching win. The linking model still needs the in-guest
  reconciler rather than create-time mounts.
- **container + host-side egress proxy.** A small proxy on the vmnet
  gateway (host process → rides the tunnel) with `http_proxy`/
  `ProxyCommand` injected into guests would restore composer/npm/git
  under VPN. Adds a moving part to every network path; tools that
  ignore proxy env vars fail mysteriously.
- **container, accepting "disconnect to fetch".** Everything local
  works under the tunnel; builds and dependency fetches require
  dropping the VPN. Zero engineering, permanent workflow tax.
