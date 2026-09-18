# Linux backend: distrobox on rootless podman

Status: **implemented and verified** (2026-09-18) on secureblue 44 (Fedora
Atomic, x86_64, SELinux enforcing), podman 5.8, distrobox 1.8.2. Both a
Laravel 13 project (scaffolded, pgsql 18) and a Moodle 4.5 project
(mariadb 10.11, plugin sync, phpunit) build and serve.

This is the second backend behind the driver seam described in
[link-architecture.md](link-architecture.md). Flavours are unchanged in
what they *do*; what changed is that they now read backend *properties*
from the resolved config instead of assuming Lima.

## What is different from the Lima backend, and why

### There is no bake

Bake mode exists for one reason: on a VM, the host filesystem arrives
over virtiofs, and a Moodle-sized tree served over virtiofs is ~30×
slower than guest-native storage
([runtime-findings.md](runtime-findings.md)). On Linux there is no VM.
The container's bind mount *is* the host filesystem, at native speed.
So the v1/v2 machinery that existed to work around virtiofs — the
second clone at `/srv/<framework>`, the bind-mount grafts, the
`apply-graft.service` oneshot, the `config.php` symlink dance and the
`require_once` pin — has nothing to do here.

The distrobox driver reports `native_storage: true`. With that:

- `resolve.sh` sets `vm_paths.framework` to `/srv/project`. Every
  recipe and hook that used to hardcode `/srv/<framework>` now reads
  this, so the same code serves the host tree in place.
- The moodle `fetch` hook skips the guest-side clone. The host clone it
  already made (framework at the project root, `.git` stripped, plugins
  cloned at canonical paths) is the served tree.
- The moodle `install` hook skips the pin + host-link steps.
  `config.php` is written by `install.php` straight into the project
  root, because the project root is the framework root.
- `apply-graft.sh` (host side) has nothing to bind. The only thing it
  does on native storage is Moodle 5.x `project_files`: those are
  declared relative to the project root but read relative to
  `$CFG->dirroot` (`public/`), so it drops a relative symlink
  `public/<file> → ../<file>`.
- `/srv/<framework>` still exists in the guest, as a symlink to
  `/srv/project`, so anything written against the Lima layout keeps
  resolving.

The redeclare trap (two inodes for one core library) cannot occur with
one tree, so the PhpStorm "map to `/srv/<framework>`, NOT
`/srv/project`" warning goes away: `mosaic status` reports an identity
path mapping.

### The service user is you

Rootless podman enforces DAC on bind mounts (unlike apple/container,
where DAC is not enforced). Verified on this host: inside the container,
`www-data` cannot read files the host user owns with `0640`/`0750`
modes, and anything root or `www-data` writes lands on the host owned
by a subuid (`589824+n`), which would pollute the IDE tree.

So nginx workers and the php-fpm pool run as the host user. The driver
rewrites `user` in `/etc/nginx/nginx.conf` and `user/group/listen.owner/
listen.group` in the php-fpm pool at `create` time — it has to be then,
because distrobox-init only creates the user at the container's first
boot. The driver reports `service_user: ""`, which `in-project.sh` and
the hooks read as "no `sudo -u` prefix".

Nothing ever `chown`s a bind mount.

### Host network namespace

distrobox shares it. nginx binding `127.0.0.1:<web port>` inside the
container *is* the host port; there are no port forwards and the
pinned SSH port is unused. `render-services.sh` reads
`host_netns: true` and renders `listen 127.0.0.1:<port>` / `[::1]:<port>`
rather than the VM's all-interfaces bind, so a dev site never appears
on the LAN.

The db + mailpit stack runs as **sibling rootless containers on the
host** via `podman compose`, not nested inside the guest. Their
`127.0.0.1`-published ports are reachable from inside the container at
the same address, so `--dbhost=127.0.0.1 --dbport=<port>` works
unchanged. This removes nested podman, `uidmap`, the podman.socket
enable-then-reboot hack and the provisioning sentinel.

Because the host podman is shared by every project, the driver passes
`-p mosaic-<project>` to compose; without it every project would derive
the same compose project name (`mosaic`, from the `.mosaic/` directory)
and share one db volume. The Lima driver does *not* pass `-p` — its
compose runs inside a per-project VM, and changing the name there would
orphan the volumes of existing macOS projects.

### Provisioning is an image build

`backends/distrobox/Containerfile` is the Lima provision script turned
into an image: Ubuntu 24.04, ondrej/php PPA only when Ubuntu's archive
lacks the requested PHP, nodesource Node 22, nginx, php-fpm and
extensions, upstream composer, db clients, plus systemd (distrobox
`--init`) and the packages distrobox-init would otherwise apt-install on
first boot. One image per PHP version (`localhost/mosaic:php<ver>`),
shared by every project on the machine; ~3 minutes to build, ~700 MB.

What the image cannot contain — the `/srv/<framework>` symlink and the
run-as user — is applied by `driver create` on every build, idempotently.

### Where things live

| | |
|---|---|
| project tree | wherever you scaffolded it; `/srv/project` in the guest |
| dataroots | `~/.local/state/mosaic/projects/<name>/{moodledata,phpunitdata}` (bind-mounted at `/srv/{moodledata,phpunitdata}`) |
| db data | podman named volume `mosaic-<name>_mosaic-db-data` |
| Mosaic itself | `/srv/mosaic` (read-only) |
| guest marker | `/etc/mosaic-guest`, `/etc/mosaic-php-version` |

`mosaic nuke` removes the container and the compose stack *with*
volumes (parity with deleting a Lima VM). The dataroots under
`~/.local/state` are left alone.

## Driver commands, mapped

| contract | distrobox |
|---|---|
| `create` | `podman build` (if the tag is missing) → `distrobox create --init --volume …` → start → wait for `/.containersetupdone` + dbus → provision |
| `start` | `podman start` + readiness wait |
| `stop` | `podman stop` |
| `destroy` | `podman compose down --volumes` + `distrobox rm --force` |
| `exec` | `podman exec --user <uid>:<gid> --workdir /srv/project … bash -c '<%q-quoted argv>'` |
| `shell` | `distrobox enter` |
| `services up/down/exec` | `podman compose -p mosaic-<name> …` on the host / `podman exec` |
| `add-host` | append `127.0.0.1 <name>` to the host's `/etc/hosts` (the container bind-mounts it) |

`exec` uses `podman exec` rather than `distrobox enter` because it is
faster (no wrapper shell) and argv survives intact. It passes
`SSH_AUTH_SOCK=/run/host$SSH_AUTH_SOCK` when `MOSAIC_FORWARD_AGENT=1`:
distrobox mounts the host's `/` at `/run/host`, and in `--init` mode it
does *not* mount `/run/user/<uid>` directly. Plugin and framework
clones happen on the host anyway; the agent only matters for private
composer packages.

## Host requirements

- rootless podman with a compose provider (`podman-compose` or
  docker-compose; `podman compose` picks one) — the driver enables the
  user `podman.socket` so the docker-compose provider works;
- distrobox ≥ 1.8;
- `just`, `yq` (mikefarah), `git` on the host;
- `~/.local/bin` on `PATH` for the `mosaic` symlink.

`mosaic doctor` checks all of this.

## IDE

Paths are identical on both sides, so PhpStorm can treat the project
as local and use any PHP that behaves like the container's. Two
sudo-free options:

- `distrobox-export --bin /usr/bin/php --export-path ~/.local/bin`
  from inside `mosaic shell` writes a wrapper that runs php in that
  container. One container per project means one wrapper per PHP
  version; rename the wrapper if you run projects on different versions.
- PhpStorm's Docker/Podman remote interpreter against the container
  (`podman.socket` is already enabled).

An sshd inside the container on the pinned `ports.ssh` would give
exact parity with the macOS SSH-interpreter flow; not done yet.

## Not done / open

- **Moodle 5.x / Workplace** on this backend: the `public/` layer is
  handled by the same host-tree code paths (`plugins_root`,
  `project_files` symlinks) and needs a real run — Workplace needs the
  Bitbucket ssh alias, which the host clone covers.
- **Lima driver** is wrapped, not re-tested: this session had no macOS.
  Behaviour is meant to be byte-identical (same scripts, same paths,
  same compose project name); the one intentional change is that the
  moodle `fetch` hook now requests agent forwarding through
  `in-vm` (`MOSAIC_FORWARD_AGENT=1` → `ssh -o ControlPath=none -o
  ForwardAgent=yes`) instead of opening its own ssh session.
- **`multi-target`** (branch): its `vm-ensure-php` step becomes "switch
  to a different image tag and recreate the container" here; not
  integrated.
- The `.env`-style `project_files` symlink for 5.x is created on the
  host and never reaped; removing an entry from `mosaic.yaml` leaves
  the symlink behind (harmless, dangling only if the source is deleted).
