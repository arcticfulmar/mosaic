# Backends

A backend is the runtime that hosts a project's guest environment:

| name        | platform | guest                                   | storage model |
|-------------|----------|-----------------------------------------|---------------|
| `lima`      | macOS    | Lima VM (vz + virtiofs)                 | virtiofs: bake-mode flavours keep a guest-native copy at `/srv/<framework>` |
| `distrobox` | Linux    | distrobox container on rootless podman  | native: the host project tree is served directly |

Selection: `backend:` in `mosaic.yaml`, else `$MOSAIC_BACKEND`, else the
platform default (Darwin → lima, Linux → distrobox).

Flavours never name a backend. They read `.backend.*` from the resolved
config (`scripts/resolve.sh`) and go through `scripts/in-vm` for
anything that runs in the guest.

## Driver contract

`backends/<name>/driver <command> [args…]`, run from the project
directory unless noted.

| command | notes |
|---|---|
| `facts` | JSON. No project needed. Keys: `native_storage`, `host_netns`, `service_user` (empty = the exec user). |
| `create` | Idempotent: build/pull what's needed, create the guest if missing, start it, apply guest-side provisioning. |
| `exists` | exit 0 if the guest has been created. |
| `status` | one line: `Running`, `Stopped`, or `(not created)`. |
| `start` / `stop` / `destroy` | lifecycle. `destroy` also removes service containers + volumes. |
| `exec <guest> <cmd…>` | run in the guest at `/srv/project`, argv preserved, TTY if interactive. `MOSAIC_FORWARD_AGENT=1` requests the host ssh agent. |
| `shell` | interactive shell at `/srv/project`. |
| `endpoint` | tab-separated `label<TAB>value` lines for `mosaic status` (IDE wiring). |
| `services up|down|exec …` | the db + mailpit compose stack (`.mosaic/services-compose.yaml`), wherever this backend runs it. `exec` forwards to `podman exec`. |
| `add-host <name>` / `remove-host <name>` | make `<name>` resolve to the host from the guest's point of view. |
| `doctor` | host-side prerequisite and health checks. |

Guest-side invariants every backend provides:

- `/srv/project` — the host project root, writable.
- `/srv/mosaic` — Mosaic's own tree, read-only.
- `/srv/moodledata`, `/srv/phpunitdata` — dataroots, writable by the service user.
- `/etc/mosaic-guest` (or Lima's `/etc/lima-guest`) — marker that guest-side scripts can test.
- systemd, with `sudo` available to the exec user, and nginx + `php<ver>-fpm` units.
