# Mosaic — orientation for Claude

Per-project Lima-VM dev environment builder for Moodle / Workplace /
Totara (bake mode) and Laravel (mount mode) on macOS. Replaces the
older `titus-devenv` build tool with a leaner per-project model.
Distributed via Homebrew tap `arcticfulmar/homebrew-mosaic`,
source at `arcticfulmar/mosaic` on GitHub (Apache-2.0).

This file is for you (Claude) in future sessions. The user-facing
spec lives in `Mosaic.md`; the README has install/quickstart. If
something in this file disagrees with the code, the code wins —
update this file.


## Mental model

One project = one Lima VM named `mosaic-<dir-name>`, scaffolded by
`mosaic new`, brought up by `mosaic build`. The project's host
directory holds three kinds of file:

- `mosaic.yaml` (project manifest)
- `.devenv/` (rendered configs: lima.yaml, nginx.conf, php.ini,
  services-compose.yaml, plus the provisioning sentinel)
- the app itself (Laravel files OR Moodle/Workplace tree + plugins)

The app lives **at the project root**, not in a subdirectory — this
matters and was changed deliberately in v0.3.0/v0.3.1. PhpStorm and
similar tools open the project root and see the framework root, which
keeps composer.json, phpunit.xml, etc. where every Moodle/Laravel
convention expects them.

Inside the VM:
- `/srv/project` — virtiofs mount of the host project root (writable)
- `/srv/mosaic` — virtiofs mount of Mosaic's `libexec/` (read-only)
- `/srv/<framework>` — the VM-baked framework tree (bake mode only;
  on native ext4 for fast file IO)
- `/srv/moodledata`, `/srv/phpunitdata` — runtime dataroots


## Two modes

### Bake mode (Moodle / Workplace / Totara)
- Framework cloned **twice**: once VM-side at `/srv/<framework>` for
  PHP to serve, once host-side at the project root for IDE indexing.
  Both clones happen in parallel during `bake.sh`.
- Host-side clone has `.git` and `.gitignore` stripped (we treat it
  as a plain working tree; plugins nested inside are independent repos).
- Plugins are cloned **on the host** at their canonical Moodle paths
  (e.g. `./local/foo`, `./mod/bar`, or `./public/local/foo` for
  Moodle 5.x). `apply-plugins` (systemd unit in the VM) bind-mounts
  each plugin's host path over the canonical baked path so PHP sees
  one tree but plugin edits-on-host take effect instantly.
- `config.php` lives at the project root as the canonical file; a
  symlink at `/srv/<framework>/config.php` points back to it so the
  user can edit on host without ssh-ing in. `install-moodle.sh`
  rewrites the install.php-generated `require_once(__DIR__.'/lib/
  setup.php')` to an absolute path so the symlink doesn't redirect
  `$CFG->dirroot` away from the baked tree.

### Mount mode (Laravel)
- Single virtiofs mount of the project root at `/srv/project`. No
  bake. nginx serves from `/srv/project/public`.
- `install-laravel.sh` either `git clone`s a configured source repo
  OR runs `composer create-project laravel/laravel` (no `source:`
  set in mosaic.yaml). Either way, the scaffold lands in a tempdir
  first (`.mosaic-scaffold.<pid>/`) and gets moved into the project
  root afterwards, because neither tool accepts a populated target.


## Moodle/Workplace 5.x specifics

Moodle 5 moved web-accessible files into a `public/` subdirectory of
the framework root, while keeping `config.php` and `admin/cli/`
scripts at the root. Mosaic handles this via:
- `frameworks/moodle/5.x.yaml` sets `plugins_root: "public"`
- `frameworks/workplace/5.x.yaml` extends moodle/5.x, overrides
  `source` + `git_ref_pattern`
- `render-services.sh` derives `WEBROOT` from `plugins_root` and
  substitutes into nginx's `root` directive
- `apply-plugins` and `sync-plugins` consume `plugins_root` to
  compute the right host+VM paths for plugin bind-mounts
- `install-moodle.sh` runs `composer install` at the framework root
  before `install.php` — Moodle 5+ installer's prerequisite checks
  fail without `vendor/` populated. Harmless on 4.x.

The user types canonical plugin destinations regardless of version
(e.g. `local/foo` not `public/local/foo`); Mosaic prepends the
`public/` layer for 5.x automatically.


## Project layout

```
mosaic/
├── bin/mosaic                  # CLI shim; resolves MOSAIC_HOME, walks up to find mosaic.yaml, exec's just
├── justfile                    # recipe definitions, grouped by tag (tool/project/moodle/laravel)
├── defaults.yaml               # cross-project defaults (port bases, vm sizing, framework default)
├── scripts/                    # bash scripts the recipes call
│   ├── lib.sh                  # shared helpers (info/say/die, profile_get, project_yaml_get, etc.)
│   ├── new.sh                  # scaffold a project (writes mosaic.yaml)
│   ├── build.sh                # full build (dispatches on mode)
│   ├── bake.sh                 # bake-mode framework + plugin clones
│   ├── install-moodle.sh       # composer install + install.php + config.php symlink dance
│   ├── install-laravel.sh      # clone-or-scaffold + composer install + npm + .env + migrate
│   ├── apply-plugins           # VM-side systemd-triggered plugin bind-mounts
│   ├── sync-plugins.sh         # incremental plugin add/remove (avoids full mosaic build)
│   ├── render-lima.sh          # substitute @@VARS@@ → ./.devenv/lima.yaml → limactl start
│   ├── render-services.sh      # substitute @@VARS@@ → ./.devenv/{nginx.conf,php.ini,services-compose.yaml}
│   ├── in-vm, in-project.sh    # ssh wrappers for VM commands at the right cwd/user
│   ├── status.sh               # one-screen project summary
│   └── ...
├── templates/                  # Lima yaml, nginx conf, php.ini, podman compose YAMLs
├── frameworks/<fw>/<ver>.yaml  # framework profiles with `extends:` for inheritance
└── Mosaic.md                   # user-facing spec
```

Key naming convention: `@@VAR@@` for sed-substitutable placeholders
(NOT `__VAR__` — that collides with PHP magic constants like
`__DIR__` which often appear in template comments).


## Per-project resources (allocated by `mosaic new`)

A monotonic offset counter at `~/.local/state/mosaic/port-offset`
is bumped on each `mosaic new`. Ports derive from base + offset:

| Field | Base | Notes |
|---|---|---|
| `ports.web` | 8000 | nginx forward |
| `ports.db` | 3306 / 5432 | mariadb/mysql or pgsql |
| `ports.mailpit_ui` | 8025 | Mailpit web UI |
| `ports.mailpit_smtp` | 1025 | Mailpit SMTP intake |
| `ports.vite_dev` | 5173 | Laravel Vite HMR |
| `ports.ssh` | 60000 | Lima SSH (pinned via `ssh.localPort`) |

The SSH port pin matters: without it, Lima asks the kernel for any
free ephemeral port at boot and the number drifts on every restart,
breaking IDE remote-interpreter configs.


## Common workflows

```bash
# new project
mosaic new <name> [--framework=X] [--version=Y] [--source=URL] [--no-confirm]
cd <name>
mosaic build                    # provision VM + install framework

# day-to-day
mosaic up / down                # start / stop services + VM (keeps state)
mosaic stop                     # full VM shutdown (rare; usually leave running)
mosaic shell                    # drop into VM at /srv/project
mosaic status                   # one-screen summary incl. SSH endpoint + IDE path mapping

# Moodle/Workplace
mosaic sync-plugins             # safe alternative to `mosaic build` after editing plugins:
mosaic apply-plugins            # just refresh bind-mounts (no clone, no upgrade)
mosaic upgrade-moodle           # admin/cli/upgrade.php (idempotent)
mosaic init-phpunit             # composer install + phpunit init.php + phpunit perm normalise
mosaic phpunit <test-path>      # run from /srv/<framework> as www-data (avoids redeclare trap)
mosaic cli <script.php> [args]  # generic admin/cli/* wrapper
mosaic purge / cron             # purge_caches.php / cron.php

# Laravel
mosaic artisan <subcommand>     # php artisan ...
mosaic tinker / queue / dev     # convenience wrappers
mosaic test / pest [args]       # phpunit / pest from /srv/project
mosaic migrate / migrate-fresh

# universal
mosaic composer <args>          # in-project composer
mosaic npm <args>               # in-project npm
mosaic db                       # native client (mariadb/psql) against the project's db
```


## Gotchas worth remembering

### Lima's default `~` mount (killed in v0.2.8)
Lima used to mount the host home directory at the same path on the
guest, read-only. Any PHP code that resolved `__DIR__` to a host
path then ran from a parallel-universe RO filesystem — `require_once`
keyed on inode would *also* load core files from the canonical mount,
producing dual class definitions and "cannot redeclare" fatals.
Mosaic now overrides this in the lima templates by mapping `~` to
`/mnt/host-home` instead — host home is still accessible if anyone
wants it, but no longer shadows the canonical filesystem.

### PhpStorm path mapping (bake mode)
The dual-tree architecture means PhpStorm's SSH remote interpreter
**must** map the host project root to `/srv/<framework>` (the
baked tree), NOT `/srv/project` (the host clone). Same redeclare
trap as above if it maps to /srv/project — phpunit will load core
lib via two different inodes, fail.
`mosaic status` surfaces the right target with a "NOT /srv/project"
warning for bake-mode projects.

### Sentinel-guarded provisioning
The heavyweight `mode: system` provision block (apt installs, ondrej
PPA, yq download, etc.) writes a sentinel at
`/srv/project/.devenv/mosaic-provisioned` when it succeeds. Future
boots short-circuit, saving ~2 minutes of warm-boot time. `mosaic
build` wipes the sentinel before `limactl start` so config changes
re-provision. Manual re-provision: `mosaic shell` + `sudo rm
/srv/project/.devenv/mosaic-provisioned` + `mosaic stop && mosaic up`.

### Walk-up project resolution
`bin/mosaic` walks up from cwd looking for `mosaic.yaml`, stopping
at `/` or `$HOME`. Lets you run `mosaic <recipe>` from any subfolder.
`mosaic new` refuses if cwd already has a mosaic.yaml (would create a
nested project).

### MOSAIC_HOME after `brew upgrade`
`realpath /opt/homebrew/bin/mosaic` resolves all the way to
`/opt/homebrew/Cellar/mosaic/<version>/libexec/bin/mosaic`. The
versioned Cellar path gets baked into the rendered Lima yaml as the
`/srv/mosaic` mount source. After `brew upgrade`, that Cellar dir
disappears, the mount fails. `bin/mosaic` now rewrites any
`*/Cellar/mosaic/<ver>/<rest>` path to `*/opt/mosaic/<rest>` —
`/opt/homebrew/opt/mosaic` is brew's stable symlink that retargets
on upgrade.

### `--force-recreate` on `mosaic up`
Without it, the previous boot's stopped podman containers linger in
the store; `podman compose up -d` tries to create-rather-than-start
and prints "container name already in use" errors. Named volumes
(`mosaic-db-data`) are independent of containers, so recreate
doesn't lose data.

### Lima provision scripts are Go-templated
Lima parses `provision[].script` blocks as Go templates and silently
refuses to run them if a `{{...}}` directive references something
it doesn't know about. The VM still comes up — un-provisioned. The
sentinel file `/etc/lima-guest` is the last action of the system
provision script, so render-lima.sh checks for it post-start. Also:
no `{{...}}` syntax in provision comments — render-lima.sh greps
the rendered yaml and refuses to start if any unescaped `{{` appears.

### Bash 3.2 compat
macOS ships bash 3.2 by default. Mosaic shouldn't force users to
install bash 4 just to run the scaffolder. Avoid `mapfile`, prefer
`while read` loops. `${arr[@]+"${arr[@]}"}` is the bash-3.2-safe
way to expand a possibly-empty array under `set -u`.

### Argument passthrough is already verbatim (verified 2026-07-20)
`set positional-arguments` + `+ARGS`/`*ARGS` recipes mean just
forwards recipe args untouched — bare dashed flags, literal `--`,
and quoted args with spaces all survive the shim → just →
in-project/in-vm → ssh chain (probed end to end from a Laravel
project). If a wrapped tool seems to "eat" a flag, suspect the
tool's own conventions, not Mosaic: npm swallows unknown flags into
config unless they come after npm's `--`, and `node --test` ignores
runner flags placed after a positional glob (so npm scripts that
should accept appended flags must not end with a positional).


## Framework profile resolution

`frameworks/<fw>/<ver>.yaml` files. Resolution tries:
1. `frameworks/<fw>/<full-version>.yaml` (e.g. `workplace/5.1.4.yaml`)
2. `frameworks/<fw>/<major>.x.yaml` (e.g. `workplace/5.x.yaml`)
3. `frameworks/<fw>/x.yaml`

Profiles can `extends:` other profiles. Inheritance chain example:
`workplace/5.x.yaml` → `moodle/5.x.yaml` → `moodle/4.x.yaml`. Child
overrides win field-by-field.

Required field: `mode` (bake or mount).
Common fields: `source`, `git_ref_pattern`, `plugins_root`,
`capabilities[]` (e.g. phpunit, grunt, mixins), `default_php`,
`default_db_type`, `default_db_version`.

`git_ref_pattern` substitution: `{major}`, `{minor}`, `{minor:02}`,
`{patch}`. `resolve_git_ref` validates that required placeholders
have values — `mosaic new` calls this at scaffold time so a manifest
that can't resolve a git ref refuses early rather than failing
5 minutes into `mosaic build`.


## Distribution

- Source: `https://github.com/arcticfulmar/mosaic` (Apache-2.0)
- Tap: `https://github.com/arcticfulmar/homebrew-mosaic`
- Releases tagged `vX.Y.Z`; formula updated per release with new
  url + sha256
- Dependencies: `lima`, `just`, `yq`, `coreutils` (for GNU realpath)
- Install layout: `libexec.install Dir["*"]` puts everything under
  the formula's libexec; `bin.install_symlink libexec/"bin/mosaic"`
  creates the `mosaic` entry on PATH
- `MOSAIC_HOME` resolves to `libexec/` (the directory with bin,
  scripts, templates, justfile etc.)

## Release flow

The user's preferred rhythm during this session has been:
small focused commits → tag → push main + tag → bump Homebrew
formula → push tap. Each release is a single concept. Don't bundle
unrelated changes.

```bash
git add ...
git commit -m "vX.Y.Z: <one-line summary>

<details>

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
git tag -a vX.Y.Z -m "vX.Y.Z: <short>"
SSH_AUTH_SOCK=/Users/work/.ssh/agent.sock git push origin main
SSH_AUTH_SOCK=/Users/work/.ssh/agent.sock git push origin vX.Y.Z

curl -fsSL https://github.com/arcticfulmar/mosaic/archive/refs/tags/vX.Y.Z.tar.gz | shasum -a 256
# update homebrew-mosaic/Formula/mosaic.rb url + sha256
cd /Users/work/business/repos/homebrew-mosaic
git add Formula/mosaic.rb && git commit -m "mosaic X.Y.Z

<short>

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
SSH_AUTH_SOCK=/Users/work/.ssh/agent.sock git push origin main
```

The `SSH_AUTH_SOCK` prefix points at the user's KeePassXC agent
(see `~/.claude/projects/-Users-work-business-repos-mosaic/memory/MEMORY.md`).
The user has to approve each key use in a dialog. If pushes fail
with "agent refused operation", ask the user to unlock / re-approve.


## Active roadmap / backlog

### Logged feature requests
- **Auto-suggest plugin destination from frankenstyle URL**. Moodle
  plugin repos are commonly named `<type>_<name>` (e.g.
  `local_nc3courseguard`, `mod_quiz`). When the user enters a plugin
  source URL in `mosaic new`, suggest a default destination based on
  the URL tail. Watch for special cases: `tool` → `admin/tool/`,
  `block` → `blocks/`, `qtype` → `question/type/`, `qbehaviour` →
  `question/behaviour/`, `qformat` → `question/format/`. Probably a
  small explicit lookup table in lib.sh.
- **`mosaic pause` / `mosaic resume`**. Lima added VZ pause/unpause
  late 2024 — sub-second resume vs ~30-45s cold boot. Wrap as
  recipes, leave `mosaic stop` as the full-shutdown option.
- **`mosaic reprovision`**. Ad-hoc re-run of the provision sentinel
  block without going through full `mosaic build`. Currently the
  manual path is `mosaic shell` + `sudo rm /srv/project/.devenv/
  mosaic-provisioned` + `mosaic stop && mosaic up`.
- **Tiny shell test for `bin/mosaic` MOSAIC_HOME resolution**.
  Three shapes: brew install (Cellar path with libexec suffix),
  bare Cellar path, source checkout. Would have caught the v0.2.4
  regex bug that needed a v0.2.5 follow-up.
- **`~/.npmrc` mount into VM**. Parity with `~/.ssh` — npm auth
  tokens for private packages currently need to be configured
  inside the VM by hand or via env vars. Mount as `/mnt/host-npmrc`
  or similar.
- **Mixins support for Workplace 5.x**. Currently capability gated
  via `mixins` in the profile's `capabilities[]`. Untested on 5.x.
- **`mosaic logs` / `mosaic tail`**. Aggregate nginx + php-fpm
  (+ podman?) log tail. `mosaic tail-web` exists for nginx +
  php-fpm; broader convenience.
- **`mosaic doctor`**. Host-side prereq checker (limactl version,
  yq version, just version, brew tap installed, etc.) plus
  project-layout sanity (e.g. PhpStorm opened at wrong subdir
  hint for bake-mode projects with a `./workplace` subfolder
  left over from pre-v0.3.1).
- **Final-line warn-on-soft-fail**. `install-laravel.sh` and
  `install-moodle.sh` print a green "ok" at the end even if
  earlier steps soft-failed (npm install, migrate). Track a flag
  through the script and emit `warn` instead of `ok` if any
  non-fatal failure happened.
- **Offline `mosaic up` verification**. `mosaic up` on an already-
  built project *should* work offline (Lima boot is local, podman
  images cached, no apt). Hasn't been tested with Wi-Fi off.

### Open design discussions
- **nginx PATH_INFO** — whether to drop the Moodle slasharguments
  rewrite (`rewrite ^(/.*\.php)(/)(.*)$ $1?file=/$3 last;`) in
  favour of native `PATH_INFO` support via `location ~ \.php(/|$)`
  + `fastcgi_split_path_info`. Tradeoff: Moodle plugin code that
  uses `$_GET['file']` (the rewrite's product) vs `$_SERVER
  ['PATH_INFO']` (the native pattern). Most Moodle core handles
  both via `get_file_argument()`; custom plugins may not.


## Honest gotchas in this codebase

- `frameworks/moodle/4.x.yaml` lists `mixins` in capabilities, but
  mixins is Workplace-specific. Pre-existing, harmless because
  Moodle projects don't trigger the mixins prompt unless the user
  manually adds it to mosaic.yaml — but worth cleaning up.
- The repo has a single user (`arcticfulmar`) and a single test
  project family (Titus Learning's Workplace clients). Tested
  paths are real but narrow.
- No automated test suite. Smoke tests are manual ("paste this
  command, eyeball the output"). The v0.2.4 → v0.2.5 regex bug
  is a good example of why even a tiny shell test would help.
