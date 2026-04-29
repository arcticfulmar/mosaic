# Mosaic

A local development environment builder for Moodle / Workplace / Totara
and Laravel projects (with WordPress to follow). Lima-backed on macOS,
single source of truth in `mosaic.yaml`, plugins and mixins laid out
the way an IDE expects them.

Mosaic supersedes the prior `tapestry` tool and consolidates the
lessons of `titus-devenv`.

---

## Scope

### v1 (initial release)

- Project scaffolding (`mosaic new`).
- Lima provisioning for **Moodle 4.x**, **Workplace 4.x**, and **Laravel**.
- Moodle/Workplace: plugins and mixins as host-editable, bind-mounted git repos.
- Laravel: whole-project bind-mount, nginx serving the project's `public/`.
- Host-editable `nginx.conf`, `php.ini`, `config.php`.
- PHPUnit + grunt (Moodle-likes); artisan + pest (Laravel).
- Plugin-state warnings on rebuild.
- macOS only.

### Soon after v1

- **Moodle 5.x** (the `/public` layout).
- **Totara** (own `/server`, `/client` directory architecture).
- **Linux** support (distrobox substrate; same recipe surface).

### Out of scope (for now)

- WordPress profile.
- Behat / Selenium.
- Publish/packaging workflows (tapestry's tarball-of-plugins).
- Multi-environment-per-project (one project = one env in v1).
- Overlays for core-file edits (use the VM directly for throwaway tweaks).

---

## Architecture

### Substrate: Lima

One Lima VM per project. Ubuntu 24.04, with nginx, php-fpm, podman,
plus tooling (composer, npm, just, direnv, yq, mariadb-client / postgresql-client).
Ancillary services (mariadb / postgres, mailpit) run as podman containers
**inside** the VM.

There are two runtime modes, selected by the framework profile:

- **Bake** (Moodle, Workplace, Totara): the framework source tree
  (~20k files) is downloaded into the VM's native ext4 because
  virtiofs is too slow for that many files. Plugins, mixins, and
  config files are bind-mounted from the host over the baked tree on
  every boot via a systemd oneshot service.
- **Mount** (Laravel): the whole project is cloned into the host and
  bind-mounted into the VM as-is. No bake step; the repo is small
  enough that virtiofs handles it.

### Distribution: installed tool

Mosaic installs as a system tool, not a sibling clone:

- **macOS:** Homebrew tap — `brew install titus-learning/mosaic/mosaic`.
- **Linux:** install script — `curl -fsSL https://… | bash`.

Both lay the tool out at a canonical location and put a `mosaic` shim
on PATH. The shim resolves `MOSAIC_HOME` (from the environment, or by
walking up from its own location) and execs `just` against
`MOSAIC_HOME/justfile`, with `--working-directory` set to the user's
cwd. `mosaic self-upgrade` delegates to `brew upgrade` (macOS) or
re-runs the install script (Linux).

There is **no per-project justfile**. Every Mosaic recipe lives in
`MOSAIC_HOME/justfile` and acts on the project found in cwd (via its
`mosaic.yaml`). This avoids any pinning of paths into projects at
scaffold time — when Mosaic upgrades, every project picks up the new
recipes immediately, with no per-project sync step.

The implementation language is `bash` + `just` + `yaml`, not a compiled
binary. This keeps the tool readable and modifiable by its users (PHP
developers), and removes any per-release compile/publish step.

### Per-project layout

#### Moodle / Workplace / Totara

```
testproject/
  mosaic.yaml             # source of truth — every other file derives from this
  moodle/                 # host clone of framework source (for IDE indexing)
                          # NOT a git repo at root; .gitignore is removed at extract time
    local/
      titusconnect/       # plugin: own git repo (.git inside)
    theme/
      norse/              # plugin: own git repo
    mixins/               # mixins repo + locally-copied mixin classes (.gitignored)
  .devenv/
    nginx.conf            # host-editable, bind-mounted into VM
    php.ini               # host-editable, bind-mounted into VM
    auto-prepend.ini      # mixin on/off switch (drop file or remove the line)
    config.php            # host-editable Moodle config, symlinked into VM
```

Plugins live at canonical Moodle paths so:

- PhpStorm sees no duplicates and needs no Excluded folders.
- `__DIR__/../../config.php` resolves to the same file in the IDE and at
  runtime in the VM (via per-plugin bind-mount).

The host clone of `./moodle` is for IDE indexing, *not* the runtime
source of truth — that lives baked at `/srv/moodle` inside the VM.

#### Laravel

```
testproject/
  mosaic.yaml             # source of truth
  laravel/                # the project repo, cloned in full (own .git)
                          # whole tree is bind-mounted into the VM at /srv/laravel
  .devenv/
    nginx.conf            # host-editable, bind-mounted into VM
    php.ini               # host-editable, bind-mounted into VM
```

`destination` (e.g. `laravel`) is a directory under the project root.
Nginx inside the VM serves `<destination>/public` — no extra config
needed; the framework profile knows.

There is no `./moodle/`, no plugins block, no mixins, no
auto-prepend.ini. Laravel's package management is composer, internal
to the project.

---

## Configuration: `mosaic.yaml`

`mosaic.yaml` is the only durable input to Mosaic. Prompts at
`mosaic new` time populate it; everything afterwards reads it and never
re-prompts.

### Moodle / Workplace / Totara

```yaml
# Mosaic version this project was scaffolded against. Used by the
# build-time compatibility check.
mosaic_version: "0.1"

framework: moodle              # moodle | workplace | totara
version: "4.5"                 # selects the (framework, version) profile

php:
  version: "8.2"

db:
  type: mariadb                # mariadb | mysql | pgsql
  version: "10.11"

# Optional. If omitted, Mosaic increments .port-offset and writes the
# resulting ports back into this file at scaffold time so subsequent
# rebuilds are deterministic.
ports:
  web:           8001
  db:            3306
  mailpit_ui:    8025
  mailpit_smtp:  1025

# Optional VM tuning. Defaults from MOSAIC_HOME/defaults.yaml apply
# unless overridden here.
vm:
  cpus:    4
  memory:  6GiB
  disk:    40GiB

# Plugins. Each clone-into-host-moodle, bind-mount-into-VM. `destination`
# is the LOGICAL Moodle path (translated to physical by the active
# framework profile — e.g. `local/foo` becomes `public/local/foo` on
# Moodle 5.x, but the entry here stays unchanged).
plugins:
  - source: git@bitbucket.org:titus-learning/local_titusconnect.git
    branch: main
    destination: local/titusconnect

  - source: https://bitbucket.org/titus-learning/theme_norse.git
    branch: 1.3.5
    destination: theme/norse

  # Mixins activate by being a plugin entry with destination: mixins.
  # The active framework profile must list `mixins` as a capability;
  # Mosaic refuses if not.
  - source: git@bitbucket.org:titus-learning/mixins.git
    branch: main
    destination: mixins
```

### Laravel

```yaml
mosaic_version: "0.1"

framework: laravel
version: "13"

php:
  version: "8.4"

db:
  type: pgsql
  version: "18"

ports:
  web:           8001
  db:            5432
  mailpit_ui:    8025
  mailpit_smtp:  1025

vm:
  cpus:    2
  memory:  3GiB
  disk:    20GiB

# A Laravel project is a single repo, cloned into the host and
# bind-mounted whole into the VM. `destination` is a directory name
# under the project root (typically `laravel`). The framework profile
# tells nginx to serve `<destination>/public`.
project:
  source: git@bitbucket.org:titus-learning/titus-connect.git
  branch: main
  destination: laravel
```

### Resolution rules

1. A field set in `mosaic.yaml` always wins.
2. Otherwise, the active framework profile provides the value.
3. Otherwise, `MOSAIC_HOME/defaults.yaml` provides the value.
4. Otherwise, Mosaic fails fast with a clear error citing the missing field.

---

## Framework profiles

Profiles describe a (framework, version) pair. They live at
`MOSAIC_HOME/frameworks/<framework>/<version>.yaml`. Inheritance via
`extends:` keeps adjacent versions DRY without coupling unrelated ones.

```yaml
# frameworks/moodle/4.x.yaml
mode: bake
source: https://github.com/moodle/moodle.git
git_ref_pattern: "MOODLE_{major}{minor}_STABLE"

plugins_root: "."             # → ./moodle/<destination>
capabilities: [phpunit, grunt, mixins]   # behat post-v1
default_php: "8.2"
```

```yaml
# frameworks/moodle/5.x.yaml  (NOT in v1; sketch only, profile owner verifies)
extends: moodle/4.x
plugins_root: "public"        # → ./moodle/public/<destination>
default_php: "8.3"
# Note: mixins still live at ./moodle/mixins (not under /public — not HTTP-exposed).
# Verified at the time mixins are confirmed 5.x-aware.
```

```yaml
# frameworks/workplace/4.x.yaml
extends: moodle/4.x
source: git@bitbucket.org:titus-learning/workplace.git
git_ref_pattern: "WORKPLACE_{major}{minor}_{patch}"
licence: proprietary          # forbids any future cache-pushing to public registries
```

```yaml
# frameworks/totara/18.yaml  (NOT in v1; sketch only — Totara may bend the
# plugins_root rule or require additional fields)
extends: moodle/4.x
source: <…>
git_ref_pattern: "TOTARA_{major}_RELEASE"
plugins_root: "server"
capabilities: [phpunit, grunt, mixins]
```

```yaml
# frameworks/laravel/13.yaml
mode: mount
web_root: "public"            # nginx serves <destination>/public
capabilities: [artisan, pest, npm-dev]
default_php: "8.4"
```

### Capabilities

A profile's `capabilities` list gates Mosaic features. If a feature
isn't listed, Mosaic refuses with a clear message rather than failing
opaquely later. Capabilities recognised in v1:

| Capability | Effect |
|------------|--------|
| `phpunit`  | `mosaic phpunit` and `mosaic phpunit-init` are wired up. |
| `grunt`    | `mosaic grunt` is wired up. |
| `mixins`   | Plugins with `destination: mixins` are accepted; auto-prepend.ini is generated. |
| `artisan`  | `mosaic artisan` and friends are wired up. |
| `pest`     | `mosaic pest` is wired up. |
| `npm-dev`  | `mosaic dev` (npm run dev) is wired up. |
| `behat`    | Reserved for post-v1. |

---

## Build & rebuild

### First build

```
mosaic new <name>
mosaic build
```

`mosaic new`:

1. Interactive prompts (or flags — see below) populate `mosaic.yaml`.
2. Allocates ports: increment `~/.local/state/mosaic/port-offset`,
   compute ports from base ranges, **write them into `mosaic.yaml`** so
   subsequent rebuilds are deterministic.
3. Creates project skeleton (`mosaic.yaml`, `justfile`, `.devenv/`).
4. Shows the final yaml and prompts to confirm. `n` re-prompts with
   previous answers as defaults.

`mosaic build` (Moodle / Workplace / Totara — `mode: bake`):

1. Read `mosaic.yaml`; resolve framework profile.
2. Run version compatibility check (see *Self-upgrade*).
3. Render Lima template → `limactl start`.
4. Run provision scripts (apt packages, php, nginx, podman, locale-gen
   `en_AU.UTF-8`, mark `/etc/lima-guest`, etc.).
5. Download framework source into `/srv/moodle` inside the VM **and**
   into `./moodle` on the host. Remove the root `.gitignore` from the
   host clone so nested plugin git repos don't conflict.
6. Clone each plugin into `./moodle/<resolved-destination>` using the
   host SSH agent (private repos work directly; no creds-on-disk).
7. Install systemd oneshot for per-plugin bind-mounts; first run wires
   them up (host `./moodle/<dest>` → VM `/srv/moodle/<resolved-dest>`).
8. Generate `./.devenv/config.php`; symlink into VM at `/srv/moodle/config.php`.
9. Bind-mount `./.devenv/nginx.conf` into nginx; bind-mount
   `./.devenv/php.ini` and `./.devenv/auto-prepend.ini` into php-fpm.
10. Run framework install (`admin/cli/install.php`).
11. `mosaic phpunit-init` if `phpunit` is in profile capabilities.

`mosaic build` (Laravel — `mode: mount`):

1. Read `mosaic.yaml`; resolve framework profile.
2. Version compatibility check.
3. Render Lima template → `limactl start`.
4. Run provision scripts (apt packages, php, nginx, podman, etc.).
5. Clone the project repo into `./<destination>` on the host (using the
   host SSH agent).
6. Bind-mount `./<destination>` into the VM at `/srv/<destination>`.
7. Configure nginx to serve `/srv/<destination>/public`.
8. Bind-mount `./.devenv/nginx.conf` and `./.devenv/php.ini` into the VM.
9. Run `composer install` and `npm install` inside the VM.
10. Run `php artisan migrate` if the project ships migrations and the
    user opts in (default yes; configurable in `mosaic.yaml`).

### Rebuild

`mosaic build` re-run is a clean slate by design.

1. Read `mosaic.yaml`.
2. **Repo state check**: for each git repo Mosaic owns the layout of
   (Moodle plugins under `./moodle/`, the Laravel project under
   `./<destination>/`), run `git status --porcelain` and
   `git log @{u}..` (and check for missing upstream). Collect repos
   flagged as:
   - **dirty** (uncommitted changes — staged or unstaged),
   - **unpushed** (local commits not on remote),
   - **missing upstream** (local-only branch).
   Gitignored files are not flagged (so locally-copied mixin classes
   under `./moodle/mixins/` do not produce noise).
3. If any flagged: list each, prompt `Continue? [y/N]`, default `N`.
4. (Proceed) Tear down VM, delete `./moodle` (or `./<destination>` for
   Laravel), then re-run first-build steps from (3) onwards.

No state is preserved across rebuild beyond what `mosaic.yaml` declares.
The warning is the safety net.

### Plugin destination collisions

If a plugin's resolved destination is a non-empty existing directory in
the freshly-extracted framework tree (e.g. someone configured
`destination: admin/cli`), Mosaic aborts with a clear error before any
clone runs.

### Compatibility check

If `mosaic.yaml`'s `mosaic_version` differs in major or breaking-minor
from the installed Mosaic, `mosaic build` warns and exits unless run
with `MOSAIC_VERSION_OVERRIDE=1` or after `mosaic migrate`.

---

## Plugins

- Each plugin is its own git repo at its canonical Moodle path inside
  `./moodle` (e.g. `./moodle/local/titusconnect`).
- The host's `./moodle` itself is **not** a git repo.
- Bind-mount granularity is **per-plugin**, never per-tree — so plugins
  Moodle ships with under `local/*` aren't accidentally hidden by an
  overlay mount.
- Plugin clones run on the **host**, picking up the host SSH agent for
  private repos. (Different from titus-devenv's bake-time clone, which
  ran inside the VM specifically to reach the agent — moot here.)
- `mosaic plugins` prints the plugin list from `mosaic.yaml`.

---

## Mixins

Mixins are an ordinary plugin with `destination: mixins`. Same clone
flow, same per-plugin bind-mount.

The active framework profile must list `mixins` as a capability;
Mosaic refuses any plugin with `destination: mixins` if the profile
doesn't (e.g. future Laravel/WordPress profiles).

### Activation switch

`./.devenv/auto-prepend.ini` (bind-mounted into php-fpm and php-cli) is
the activation toggle:

```ini
auto_prepend_file = /srv/moodle/mixins/<bootstrap>.php
```

Remove the file (or comment the line) and `mosaic web-reload` to
deactivate. No rebuild needed.

### Locally-copied mixin classes

Mosaic does not manage individual mixin classes. The dev manually copies
class files into `./moodle/mixins/` as needed; those files are
.gitignored within the mixins repo so the dirty-plugin check ignores
them.

---

## Networking

### Port allocation

- If `mosaic.yaml` specifies a port, use it as-is.
- Otherwise (only at `mosaic new`), increment
  `~/.local/state/mosaic/port-offset` and compute from base ranges:
  - `web`: 8001+
  - `db`: 3306+ (mariadb/mysql), 5432+ (pgsql)
  - `mailpit_ui`: 8025+
  - `mailpit_smtp`: 1025+
- Write resolved ports back into `mosaic.yaml`. Subsequent rebuilds are
  deterministic.
- Mosaic does NOT free offsets on project teardown. Collisions are the
  user's responsibility (override in yaml or delete a line and re-run
  `mosaic new`-style port allocation via a future `mosaic alloc-ports`
  recipe).

### add-host

`mosaic add-host moodle.test` adds a host-gateway entry to the VM's
`/etc/hosts` so code in the VM can reach the host (or another VM
forwarded by the host) under a stable hostname. Verb-first by
convention (titus-devenv's `vm-host-add` is renamed).

---

## Testing

### PHPUnit (Moodle / Workplace / Totara)

Provisioning generates the `en_AU.UTF-8` locale required by Moodle's
test bootstrap.

`mosaic phpunit-init` runs `admin/tool/phpunit/cli/init.php` — drops
and rebuilds the `phpu_` test tables. Use it on first install **and**
whenever a plugin's `version.php` bumps. Cheap to re-run.

`mosaic phpunit [args]` runs phpunit inside the VM against the baked
tree. Plugin tests work transparently because plugin code is bind-mounted
into the canonical path.

### Grunt (Moodle / Workplace / Totara)

`mosaic grunt <target> <task>` runs grunt against a plugin path
(default `local/titusconnect`, task `amd`).

### Pest (Laravel)

`mosaic pest [args]` runs pest inside the VM against the bind-mounted
project. `mosaic test [args]` is an alias for `php artisan test`.

All gated by framework profile `capabilities`.

---

## Composer & npm

In v1, composer and npm install in the **VM only** for Moodle-likes:

- `/srv/moodle/vendor` and `/srv/moodle/node_modules` live in the VM's
  ext4 — *not* bind-mounted to the host.
- The host clone of `./moodle` carries no `vendor/` or `node_modules/`.
- IDE indexing on the host works without them; if PhpStorm-side indexing
  proves to need vendor for completion of phpunit/behat classes, the
  fix is straightforward (extend `mosaic composer` to install on the
  host as well, costing disk).

For Laravel (`mode: mount`) it doesn't matter: the project is
bind-mounted whole, so composer/npm artefacts land in the host's
project tree by definition. The IDE sees them.

---

## Recipe inventory (v1)

All recipes are verb-first. Every recipe carries a `# comment` line so
`mosaic` (no args) prints a useful hint list.

```
# scaffolding & build
new <name> [--framework= --version= --php= --db=]   # interactive scaffold; flags skip prompts
build                                               # provision/bake/install or rebuild
self-upgrade                                        # delegate to brew or install script
migrate                                             # stub: print yaml schema diffs

# lifecycle
up                                                  # start nginx/fpm/podman services
down                                                # stop services (state preserved)
shell                                               # drop into the VM at /srv/project
status                                              # one-screen: vm + services + ports
nuke                                                # destroy VM (does NOT delete project files)
doctor                                              # diagnose lima zombies, port collisions

# project
plugins                                             # list plugins from mosaic.yaml
add-host <name>                                     # add VM /etc/hosts entry
remove-host <name>                                  # remove VM /etc/hosts entry
ssh-config                                          # symlink Lima ssh.config to ~/.ssh/conf.d/

# moodle/workplace/totara (gated by framework)
cli <script> [args]                                 # run admin/cli/<script>
purge                                               # admin/cli/purge_caches.php
cron                                                # admin/cli/cron.php
phpunit-init                                        # drop + rebuild phpu_ tables
phpunit [args]                                      # run phpunit
grunt <target> <task>                               # run grunt

# laravel (gated by framework)
artisan [args]                                      # php artisan ...
tinker                                              # php artisan tinker
queue                                               # php artisan queue:work
schedule-run                                        # php artisan schedule:run
migrate                                             # php artisan migrate
migrate-fresh [--seed]                              # php artisan migrate:fresh
test [args]                                         # php artisan test
pest [args]                                         # ./vendor/bin/pest
dev                                                 # npm run dev

# common (every framework)
db                                                  # database shell (auto: mysql/psql)
web-reload                                          # reload nginx + php-fpm
web-logs                                            # tail nginx + php-fpm logs
composer [args]                                     # composer in VM (against active project)
npm [args]                                          # npm in VM (against active project)
```

---

## Self-upgrade

Minimum viable shape for v1:

1. `mosaic.yaml` records `mosaic_version` at scaffold time.
2. `mosaic build` checks: if installed Mosaic is significantly newer
   (different major or breaking minor), warn and exit unless
   `MOSAIC_VERSION_OVERRIDE=1` is set or the user has run
   `mosaic migrate`.
3. `mosaic migrate` is a stub: prints schema diffs only. Real migration
   logic is written when shipping the first breaking change.
4. `mosaic self-upgrade` delegates to `brew upgrade` (macOS) or re-runs
   the install script (Linux).

This is the smallest investment that doesn't paint a corner.

---

## Distribution & releases

- **Source repo:** GitHub, public, under the project owner's account
  (TBC). GitHub specifically — Homebrew taps expect GitHub by default,
  and using anything else complicates distribution.
- **Versioning:** SemVer. Tagged releases (`v0.1.0`, etc.). Each tag's
  GitHub-generated tarball is what the Homebrew formula points at.
- **Homebrew tap:** a separate GitHub repo `<owner>/homebrew-mosaic`,
  containing one Ruby formula file (`Formula/mosaic.rb`) declaring the
  tarball URL, version, and dependencies (`lima`, `just`, `yq`,
  `direnv`, `coreutils`, `gnu-sed`). No registration with Homebrew
  itself is required for personal taps. Users tap once
  (`brew tap <owner>/mosaic`) then `brew install mosaic` /
  `brew upgrade mosaic` work normally.
- **Linux install script:** drops the tree to `~/.local/share/mosaic`
  and a shim to `~/.local/bin/mosaic`. Documents the apt/dnf packages
  required.
- **`MOSAIC_HOME`** is overridable for development; defaults are derived
  from install layout.

---

## Patterns lifted from prior tools

From `titus-devenv`:

- `{{prefix}}` dispatch — recipe runs in-VM if inside, via `limactl
  shell` if outside. Eliminates host/VM recipe duplication.
- Plugin bind-mounts via systemd oneshot — `__DIR__` works correctly.
- Host-symlinked `config.php` — host-editable, served by VM.
- `reap-hostagents` pre-flight before `limactl start` — Lima hostagent
  zombies hold ports against stopped VMs.
- `configure-phpunit` + `locale-gen en_AU.UTF-8` + Moodle CFG injection.
- `vm-ssh-config` symlinking Lima's own `ssh.config` — propagates port
  changes after stop/start without re-running.
- `/etc/lima-guest` marker file for in-VM-vs-on-host auto-detection.

From `tapestry`:

- Plugins inside `./moodle` at canonical paths (IDE-friendly).
- A versioned project manifest as the unit of project identity.
- Per-plugin bind-mount list (one mount per plugin, not per-tree).
- Branch pinning per plugin.

Deliberate departures:

- Bitbucket username/password creds → host SSH agent into VM.
- Per-PHP-version Docker images on Docker Hub → Lima provisioning
  (no registry maintenance burden).
- Manual `/etc/hosts` editing → `mosaic add-host` recipe.
- Sibling-folder relative `import?` → installed tool with
  `MOSAIC_HOME`-resolved imports.

---

## Future

- Moodle 5.x profile (the `/public` layout — re-test mixins).
- Totara profile (own dirroot layout, capability subset).
- Linux support (distrobox substrate, same recipe surface).
- WordPress profile.
- Behat + Selenium browser drivers.
- Publish/packaging workflow (tapestry-style tarball).
- `mosaic free-offset` to recycle `.port-offset` slots on teardown.
- `mosaic migrate` — real schema migration when shipping the first
  breaking change.
- Optional host-side `composer install` for IDE indexing of dev deps.
- Overlays for core-file edits that survive rebuild.

### Recipe catalogues

Pre-canned `mosaic.yaml` files served from one or more Git-hosted
catalogues, so onboarding a dev to an existing client project becomes
`mosaic init bluecoat && cd bluecoat && mosaic build`. Validates
tapestry's per-client recipe model under the new yaml shape. Sketch:

- **What's in a recipe.** A `mosaic.yaml`, optionally with companion
  files (custom `.devenv/php.ini`, etc.). Plain text under Git — no
  registry to push to, no images to maintain.
- **Catalogue addressing.** Registered catalogues
  (`mosaic catalogues add <name> <git-url>`) plus an ad-hoc URL form
  (`mosaic init git+https://…/recipes#bluecoat`) for one-offs. Maps
  onto Homebrew taps mentally: one private catalogue (Titus internal),
  one or more public, anyone can have their own. `mosaic init bluecoat`
  searches all registered catalogues; `mosaic init titus/bluecoat`
  disambiguates.
- **Versioning.** Recipes referenced by Git tag (`mosaic init bluecoat@v2`),
  with `latest` (effectively `main`) as the default. Lets a recipe
  ship breaking changes without breaking devs already mid-project.
- **Ports are NOT pinned in published recipes.** Tapestry pinned them
  per-client (8200, 9200, ...) and devs collided constantly. Mosaic
  lets the local `.port-offset` allocate at `init` time, exactly as
  `mosaic new` does — recipes are templates, ports get filled in
  per-machine.
- **Credentials.** Recipes ship `git@bitbucket.org:…` URLs that work
  for any dev with the right SSH access via the host agent. No
  `user:pass@`-rewriting like tapestry, no credentials on disk.
- **Update flow.** Mosaic doesn't track which recipe a project was
  initialised from. Once cloned, the yaml is yours. To pick up
  upstream changes, manually copy the new yaml over the top and
  rebuild — same clean-slate model as everything else.
- **Surface.** `mosaic init <recipe>` (a sibling to `mosaic new` —
  same endpoint, different entry point), plus
  `mosaic catalogues add | list | remove | update`. Caches cloned
  catalogue repos at `~/.cache/mosaic/catalogues/<name>/`.
