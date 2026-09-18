# Mosaic — orientation for Claude

Per-project dev environment builder for Moodle / Workplace / Totara and
Laravel. macOS hosts get a Lima VM per project; Linux hosts get a
distrobox container per project on rootless podman. Distributed via
Homebrew tap `arcticfulmar/homebrew-mosaic` (macOS) and as a git
checkout (Linux). Source: `arcticfulmar/mosaic` on GitHub, Apache-2.0.

This file is for you (Claude) in future sessions. If something here
disagrees with the code, the code wins — update this file.

## Branches

- `main` — the v2 line (this layout). Fresh history; no merge base
  with v1.
- `v1` — the pre-rewrite line (monolithic `justfile`, `bake.sh`,
  `install-*.sh`). Frozen; the old CLAUDE.md there describes it.
- `multi-target` — v2 + a `targets:`/`teardown`/`switch` feature.
  Designed, implemented against host-only tests, never run against a
  real guest. `docs/multi-target-handoff.md` there is the brief.

## Mental model

One project = one directory with `mosaic.yaml` + `.mosaic/` (rendered
configs, generated justfile) + the app tree at the project root. One
guest per project named `mosaic-<dir-name>`.

Three orthogonal axes, deliberately kept apart:

| axis | lives in | knows about |
|---|---|---|
| **core** (lifecycle) | `core/core.just`, `scripts/{build,up,down,status,resolve,in-vm,in-project,render-services}.sh` | sequencing only |
| **flavour** (framework) | `flavours/<moodle|laravel>/{recipes.just,hooks/*}` | plugins, artisan, install.php… never a backend name |
| **backend** (runtime) | `backends/<lima|distrobox>/driver` | limactl / podman / distrobox… never a framework name |

`scripts/resolve.sh` is the data boundary: manifest + framework profile
(`frameworks/<fw>/<ver>.yaml`, `extends:` chains) + backend facts → one
JSON. Hooks get it on stdin; scripts call `load_config` + `cfg`.
`mosaic config` prints it.

Guest paths every backend provides: `/srv/project` (host project root,
rw), `/srv/mosaic` (MOSAIC_HOME, ro), `/srv/moodledata`,
`/srv/phpunitdata`, systemd, passwordless sudo for the exec user.

## The two storage models (read this before touching Moodle code)

`.backend.native_storage` decides everything about where the served
tree is:

- **false (Lima/virtiofs)** — bake mode: the framework is cloned twice,
  host root (IDE) and `/srv/<framework>` in the guest (served, native
  ext4). Plugins are cloned on the host at canonical paths and
  bind-mounted over the baked tree by `scripts/apply-graft` (a systemd
  oneshot in the guest). `config.php` is moved to the host and
  symlinked back, with its `require_once` pinned to the baked path.
  Service user is `www-data`. IDE path mapping must target
  `/srv/<framework>`, never `/srv/project` (redeclare trap).
- **true (distrobox)** — the host tree is served in place. No second
  clone, no bind mounts, no symlink dance. `vm_paths.framework` is
  `/srv/project`; `/srv/<framework>` is a symlink to it. Service user
  is the host user (rootless podman enforces DAC on bind mounts).
  Paths are identical on both sides.

`scripts/in-project.sh` is how recipes run PHP "in the framework root as
the right user" without knowing which model is active. Use it.

## Backend driver contract

`backends/README.md` is authoritative. Commands: `facts create exists
status start stop destroy exec shell endpoint services doctor add-host
remove-host`. `scripts/in-vm <guest> <cmd…>` → `driver exec`;
`scripts/backend-driver <cmd>` is what `core.just` calls.
`MOSAIC_FORWARD_AGENT=1` on `in-vm` requests the host ssh agent.

Backend selection: `backend:` in mosaic.yaml → `$MOSAIC_BACKEND` →
platform default (Darwin lima, Linux distrobox).

### Lima specifics
`scripts/render-lima.sh` renders `templates/lima-<flavour>.yaml` and
`limactl start`s; provisioning is a sentinel-guarded cloud-init script
in the template (see the template comments for every gotcha: Go-template
`{{` in provision scripts, the podman.socket stop/start cycle, brew
Cellar path rewriting, the `~` mount override). `scripts/reap-hostagents`
handles zombie hostagents. Compose runs *inside* the VM with no `-p`
(changing that would orphan existing users' db volumes).

### distrobox specifics
`docs/linux-backend.md` has the full rationale. In short: image per PHP
version from `backends/distrobox/Containerfile` (`localhost/mosaic:php<v>`);
`distrobox create --init`; host network namespace (nginx must bind
loopback — `render-services.sh` does this from `host_netns`); compose
stack runs on the **host** podman with `-p mosaic-<project>`; the
driver enables the user `podman.socket` so `podman compose` has a
provider; dataroots under `~/.local/state/mosaic/projects/<name>/`.
`driver create` re-applies guest provisioning (run-as user, framework
symlink) every time, because distrobox-init creates the user only at
first boot.

## Verified state (2026-09-18)

On secureblue 44 / podman 5.8 / distrobox 1.8.2: Laravel 13 (pgsql 18)
and Moodle 4.5 (mariadb 10.11) build, serve on loopback, survive
down/up, run tests; Moodle plugin sync-graft + phpunit init work. The
Lima driver was refactored without a macOS host to test on — treat the
first macOS run after this change as a smoke test (`mosaic build` on
an existing project; expect byte-identical behaviour).

## Conventions and gotchas

- `@@VAR@@` placeholders in templates (not `__VAR__`; PHP magic
  constants appear in comments).
- Bash 3.2 compatible (macOS): no `mapfile`, `${arr[@]+"${arr[@]}"}`
  for possibly-empty arrays under `set -u`.
- `die` inside `$( )` does not stop the caller (bash drops errexit in
  command substitution; no `inherit_errexit` on 3.2). Capture sites
  append `|| exit 1`.
- Argument passthrough is verbatim end to end (`set
  positional-arguments` + `%q` quoting across every boundary). If a
  wrapped tool "eats" a flag, suspect the tool.
- The repo umask may be 0027 on Linux checkouts: anything COPY'd into
  an image needs `--chmod` (the ondrej keyring bit us).
- `podman compose` may delegate to docker-compose, which needs the
  user `podman.socket`; `-p` is mandatory on a shared host podman.
- Test projects live under `~/projects/mosaic-lab/` on the Linux dev
  machine (`lara1`, `moodle1`); `mosaic nuke` + `rm -rf` to reset.

## Release flow

Small focused commits → tag `vX.Y.Z` → push main + tag → bump the
Homebrew formula (url + sha256) in `homebrew-mosaic` → push tap. Each
release is one concept. The tap formula still `depends_on "lima"`;
Linux users install from a checkout, so that is fine.

## Backlog

- Moodle 5.x / Workplace on the distrobox backend: needs a real run.
- Lima driver smoke test on macOS after the seam refactor.
- sshd in the distrobox guest on `ports.ssh` (PhpStorm SSH-interpreter
  parity), or a `mosaic export-tools` recipe wrapping `distrobox-export`.
- Reap stale 5.x `project_files` symlinks on native storage.
- `mosaic logs` / `mosaic reprovision` / `mosaic pause` (Lima) /
  frankenstyle destination suggestions in `mosaic new` / `~/.npmrc`
  into the guest — carried over from the v1 backlog.
- `multi-target` branch integration (PHP switch = image tag switch on
  distrobox).
- A tiny host-only test suite (backend resolution, `updirs`, resolve
  output shape). The multi-target branch has a pattern to copy.
