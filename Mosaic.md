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

PHP packages: Ubuntu 24.04 ships PHP 8.3 in main. For projects on 8.3,
no extra repo is needed and provisioning never touches Launchpad. For
any other PHP version (8.0–8.2, 8.4+), Mosaic adds the
[ondrej/php PPA](https://launchpad.net/~ondrej/+archive/ubuntu/php)
manually — `add-apt-repository` is bypassed because its Python httplib2
client has fragile TLS handling against `api.launchpad.net`. Mosaic
ships the PPA's signing public key at
[`templates/ondrej-php.asc`](templates/ondrej-php.asc) and writes
the apt source line directly. So the only Launchpad dependency at
provision time is `ppa.launchpadcontent.net` (the package mirror,
which apt itself retries on transient failures), and only for
non-default PHP versions.

There are two runtime modes, selected by the framework profile:

- **Bake** (Moodle, Workplace, Totara): the framework source tree
  (~20k files) is downloaded into the VM's native ext4 because
  virtiofs is too slow for that many files. Plugins, mixins, and
  config files are bind-mounted from the host over the baked tree on
  every boot via a systemd oneshot service.
- **Mount** (Laravel): the whole project is cloned into the host and
  bind-mounted into the VM as-is. No bake step; the repo is small
  enough that virtiofs handles it.

#### Bake invariant: dirroot must stay inside the baked tree

The bake-mode payoff (fast file IO from native ext4) only holds while
Moodle thinks its source root is `/srv/<framework>`. The default
`config.php` that `admin/cli/install.php` writes ends with:

```php
require_once(__DIR__ . '/lib/setup.php');
```

When `config.php` is host-linked (real file at `./<framework>/config.php`,
symlink at `/srv/<framework>/config.php`), `__DIR__` resolves *through*
the symlink to `/srv/project/<framework>`. Moodle's `setup.php` then
sets `$CFG->dirroot = dirname(__DIR__)` based on its own `__DIR__` —
so `dirroot` becomes `/srv/project/<framework>`, and *every subsequent
file load goes through virtiofs*. The bake is silently bypassed; plugin
bind-mounts at `/srv/<framework>/blocks/...` are unused; PHPUnit
tries to load duplicate copies of `lib/testing/lib.php` from both
trees and dies with "Cannot redeclare …".

Mosaic enforces the invariant by rewriting that one line during install,
so `config.php` ends with:

```php
require_once('/srv/<framework>/lib/setup.php');
```

Now `setup.php` always loads from the baked tree regardless of where
`config.php` physically lives, `dirroot` stays `/srv/<framework>`,
plugin bind-mounts work, and PHPUnit doesn't double-load.

The rewrite lives in [scripts/install-moodle.sh](scripts/install-moodle.sh)
between `install.php`'s success and the host-link `mv`. Anyone editing
the install flow needs to preserve this — without it, the whole
bake-vs-mount distinction collapses for Moodle-likes.

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
    config.php            # host-editable Moodle config, symlinked from /srv/moodle/config.php in the VM.
                          # `require_once` to lib/setup.php is rewritten to an absolute path during
                          # install so that __DIR__-resolution through the symlink doesn't matter
                          # (see the Bake invariant section in Architecture).
    local/
      titusconnect/       # plugin: own git repo (.git inside)
    theme/
      norse/              # plugin: own git repo
    mixins/               # mixins repo + locally-copied mixin classes (.gitignored)
  .devenv/
    nginx.conf            # host-editable, bind-mounted into VM at /etc/nginx/sites-enabled/moodle.conf
    php.ini               # host-editable, bind-mounted into VM at /etc/php/<ver>/{fpm,cli}/conf.d/99-moodle.ini
    auto-prepend.ini      # mixin on/off switch (drop file or remove the line)
    services-compose.yaml # podman compose for db + mailpit; read by `mosaic up`/`down`
    plugin-context        # host-resolved profile values, sourced by apply-plugins in the VM
    lima.yaml             # rendered Lima template (inspectable post-mortem)
```

Plugins live at canonical Moodle paths so:

- PhpStorm sees no duplicates and needs no Excluded folders.
- `__DIR__/../../config.php` resolves to the same file in the IDE and at
  runtime in the VM (via per-plugin bind-mount).

Note: `config.php` lives inside `./moodle/`, NOT in `./.devenv/` — earlier
spec drafts said the latter, which broke `__DIR__` resolution at install
time. Files that go in `.devenv/` are configs that get bind-mounted into
system locations (nginx vhost dir, php conf.d), not into the framework
tree itself.

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
version: "4.5"                 # selects the (framework, version) profile.
                               # Workplace must use a 3-part pin
                               # (e.g. 4.5.11) — its git_ref_pattern
                               # references {patch} explicitly.

php:
  version: "8.2"               # any PHP version Mosaic supports — 8.0+. Ubuntu 24.04
                               # ships 8.3 in main; everything else loads from the
                               # ondrej/php PPA whose key is bundled with Mosaic.

db:
  type: mariadb                # mariadb | mysql | pgsql
  version: "10.11"

# Hostname Moodle bakes into wwwroot. `localhost` is friction-free; any
# custom name (e.g. moodle.test) requires an /etc/hosts entry on the host
# (Mosaic doesn't sudo on the host's hosts file — that's left to the user).
wwwroot: localhost

# Optional. Overrides the framework profile's default `source` URL.
# Useful when the dev's ssh config aliases the upstream host — e.g.
# `titus-bitbucket:` instead of `git@bitbucket.org:` for users with
# multiple bitbucket identities. Applies to bake-mode frameworks only;
# Laravel uses the `project:` block below instead.
source: git@bitbucket.org:titus-learning/workplace.git   # example; usually omitted

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
| `phpunit`  | `mosaic phpunit` and `mosaic init-phpunit` are wired up. |
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
3. Writes only `./<name>/mosaic.yaml`. No `.devenv/`, no host clone, no
   project justfile — `mosaic build` produces all of those when it has
   real content to put in them.
4. Shows the final yaml and prompts to confirm.

`mosaic build` (Moodle / Workplace / Totara — `mode: bake`):

1. Read `mosaic.yaml`; resolve framework profile.
2. Run version compatibility check (see *Self-upgrade*).
3. Render Lima template into `./.devenv/lima.yaml`; `limactl start`.
   Provisioning installs nginx, php-fpm (the requested version, via
   ondrej/php PPA only when not Ubuntu's native), podman, yq,
   `locale-gen en_AU.UTF-8`, the apply-plugins systemd oneshot, the
   nginx vhost + php.ini conf.d symlinks (pointing at `./.devenv/...`
   via virtiofs), and finally `touch /etc/lima-guest` as a
   provisioning-completed marker.
4. Post-start: verify `/etc/lima-guest` exists (Lima silently demotes
   provision failures to warnings — explicit check fails the build
   loudly otherwise).
5. Bake step (parallel host + VM `git clone --depth 1`): framework
   source into `/srv/<framework>` inside the VM **and** into
   `./<framework>` on the host. Strip root `.gitignore` and `.git`
   from the host clone so nested plugin repos don't conflict.
6. Clone each plugin into `./<framework>/<plugins_root>/<destination>`
   on the host using the host SSH agent (private repos work directly;
   no creds-on-disk).
7. Write `./.devenv/plugin-context` (host-resolved profile values).
   Trigger `apply-plugins.service` in the VM — bind-mounts each plugin
   per-entry from `/srv/project/<framework>/<plugins_root>/<dest>` to
   `/srv/<framework>/<plugins_root>/<dest>`.
8. Render `./.devenv/{nginx.conf, php.ini, services-compose.yaml}` from
   `MOSAIC_HOME/templates/`. The provision step's symlinks make these
   active without further wiring.
9. `podman compose up -d` inside the VM — starts mariadb + mailpit
   containers. Wait for db readiness (loop on `mariadb-admin ping`
   inside the db container).
10. `admin/cli/install.php` — creates DB schema + admin user +
    `/srv/<framework>/config.php`.
11. **Pin the bake invariant**: rewrite the just-written `config.php`'s
    `require_once(__DIR__ . '/lib/setup.php')` to an absolute path
    `require_once('/srv/<framework>/lib/setup.php')`. Without this,
    the host-link symlink in step 12 redirects Moodle's dirroot away
    from the baked tree (see *Bake invariant* in Architecture).
12. Move `config.php` to the host clone (`./<framework>/config.php`),
    chmod 0644, symlink the baked path back to it.
13. Patch `config.php` with `phpunit_dataroot` + `phpunit_prefix` so
    `init-phpunit` works without further edits. Idempotent.
14. `admin/cli/upgrade.php --non-interactive` — installs plugin schemas.
    Skipped if `mosaic.yaml` declares no plugins.
15. Start nginx + php-fpm. Site is reachable at
    `http://<wwwroot>:<web_port>/`.

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

Remove the file (or comment the line) and `mosaic reload-web` to
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

`mosaic init-phpunit` runs `admin/tool/phpunit/cli/init.php` — drops
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
new <name> [--framework= --version= --php= --db= --source= --wwwroot=]   # interactive scaffold; flags skip prompts
build                                               # provision/bake/install or rebuild
self-upgrade                                        # delegate to brew or install script
migrate                                             # stub: print yaml schema diffs

# lifecycle
up                                                  # start VM, db + mailpit, nginx + php-fpm
down                                                # stop services (state preserved)
shell                                               # drop into the VM at /srv/project
status                                              # one-screen: vm + services + ports
nuke                                                # destroy VM (does NOT delete project files)
doctor                                              # diagnose lima zombies, port collisions

# project
plugins                                             # list plugins from mosaic.yaml
apply-plugins                                       # re-apply plugin bind-mounts (after editing mosaic.yaml plugins)
add-host <name>                                     # add VM /etc/hosts entry
remove-host <name>                                  # remove VM /etc/hosts entry

# moodle/workplace/totara (gated by framework)
install-moodle                                      # admin/cli/install.php (creates DB + admin + config.php)
upgrade-moodle                                      # admin/cli/upgrade.php (picks up plugin schemas)
cli <script> [args]                                 # run admin/cli/<script>
purge                                               # admin/cli/purge_caches.php
cron                                                # admin/cli/cron.php
init-phpunit                                        # composer install + drop+rebuild phpu_ tables
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
reload-web                                          # reload nginx + php-fpm
tail-web                                            # tail nginx + php-fpm logs
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

- **Source repo:** GitHub, public — `arcticfulmar/mosaic`. GitHub
  specifically because Homebrew taps expect GitHub by default, and
  using anything else complicates distribution.
- **Versioning:** SemVer. Tagged releases (`v0.1.0`, etc.). Each tag's
  GitHub-generated tarball is what the Homebrew formula points at.
- **Homebrew tap:** a separate GitHub repo `arcticfulmar/homebrew-mosaic`,
  containing one Ruby formula file (`Formula/mosaic.rb`) declaring the
  tarball URL, version, and dependencies (`lima`, `just`, `yq`,
  `direnv`, `coreutils`, `gnu-sed`). No registration with Homebrew
  itself is required for personal taps. Users tap once
  (`brew tap arcticfulmar/mosaic`) then `brew install mosaic` /
  `brew upgrade mosaic` work normally.
- **What gets shipped:** the entire repo tree — `bin/`, `scripts/`,
  `templates/` (including `ondrej-php.asc`, the bundled PPA signing
  key), `frameworks/`, `defaults.yaml`, `justfile`. The brew formula's
  install block copies all of these to the install prefix; `bin/mosaic`
  becomes the user's `mosaic` shim.
- **Linux install script:** drops the tree to `~/.local/share/mosaic`
  and a shim to `~/.local/bin/mosaic`. Documents the apt/dnf packages
  required.
- **`MOSAIC_HOME`** is overridable for development; defaults are derived
  from install layout.

---

## Build-flow gotchas

Implementation-side traps we've hit and the conventions that prevent
them. Anyone modifying scripts under `scripts/` or `templates/` should
read this.

### Templating syntax: `@@VAR@@`, not `__VAR__`

Mosaic templates (Lima yaml, nginx vhost, php.ini, services-compose.yaml)
use `@@VAR@@` as the placeholder syntax that `scripts/render-lima.sh`
and `scripts/render-services.sh` substitute via sed. Both renderers
include a guard that aborts the build if any `@@[A-Z_]+@@` survives
the substitution — catches "added a new placeholder, forgot to wire
it up" mistakes early.

`__VAR__` was tempting but collides with PHP magic constants (`__DIR__`,
`__FILE__`, `__LINE__`, …) that appear in any docs touching PHP. A
guard regex over `__[A-Z_]+__` would false-positive on those, the
guard would be ignored, and a real missing-substitution would slip
through. `@@…@@` doesn't appear in PHP, YAML, bash, JS, or HTML, so
the guard stays useful.

### Lima `provision[].script` is a Go template too

Lima parses each provision script as a Go template before running it.
Any unintended `{{...}}` directive in the script — even inside a
comment — makes Lima silently downgrade the script to a warning. The
VM still comes up, but un-provisioned (no apt installs, no
`/etc/lima-guest`, etc.). Render-lima includes a `grep '{{'` guard
that fails the build if any double-brace escapes get through.

### `bash -lc` over ssh + `set -e` ⇒ phantom exit 1

Don't use `bash -lc` for non-interactive remote scripts. Ubuntu's
default `~/.bash_logout` runs `[ -x /usr/bin/clear_console ]`. The
binary doesn't exist, the test exits 1, and with `set -e` still
active during shell teardown, that 1 overwrites whatever the script's
own `exit` returned. Symptom: `exit 0` becomes ssh exit 1 mysteriously.
Use `bash -c` (no profile, no logout) for one-shot remote commands.

### `install` doesn't preserve symlinks

GNU `install` removes the destination and writes a fresh file, even
when the destination was a symlink. If a Mosaic script needs to write
through a symlink (e.g. patching `config.php`, which is symlinked from
`/srv/<framework>/config.php` to the host clone), use `cat > "$REAL"`
shell redirection — that follows the symlink and overwrites only the
target's content. Then re-apply ownership/mode separately.
[scripts/configure-phpunit](scripts/configure-phpunit) is the
canonical example.

### `mosaic build` requires a working SSH agent in the calling shell

Plugin and Workplace clones run on the host using the host's SSH
agent. Many devs (especially those using KeePassXC, 1Password, or
hardware tokens) run an agent that's scoped to their interactive
shell session, not a system-wide socket. Run `mosaic build` from the
same shell where `ssh-add -l` shows the keys you need. If the agent
isn't reachable (`SSH_AUTH_SOCK` unset or pointing to an empty agent),
private-repo clones fail with `Permission denied (publickey)`.

### Concurrent first-time provisions on the host

Mosaic's per-project model means each project gets its own Lima VM.
Running `mosaic build` for a fresh project while another project's VM
is still up will compete for host CPU and memory during apt install,
sometimes badly enough that Lima's boot probe times out. If you hit
unexplained provision failures on the second build, `mosaic down` the
first project (or its VM via `limactl stop`), then retry.

### Workplace requires a 3-part version pin

Workplace's `git_ref_pattern` is `WORKPLACE_{major}{minor:02}_{patch}`.
A 2-part `version: "4.5"` would resolve to `WORKPLACE_405_` (trailing
underscore) and fail at clone time. `lib.sh`'s `resolve_git_ref`
refuses incomplete versions up front with a clear message; pin to
e.g. `4.5.11`.

### SSH host alias as `source:` override

Devs with multiple bitbucket identities often configure host aliases
in `~/.ssh/config` (e.g. `titus-bitbucket` for the work account vs
`bitbucket.org` for personal). Setting `source:` in `mosaic.yaml`
overrides the framework profile's default URL, so the alias path
works for that project without editing the global profile:

```yaml
source: titus-bitbucket:titus-learning/workplace.git
```

`mosaic new --source=…` writes this on first scaffold.

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

### Image baking

`mosaic bake` produces a deployable Docker image from a recipe. Same
yaml drives both local dev (`mosaic build`) and shipped images
(`mosaic bake`), so dev environments and prod artefacts stay in
lockstep by construction rather than by convention. Designed for the
client-blend use case: "client X gets Moodle 4.5 + this curated set
of plugins at these versions" baked once, shipped to many environments.

Hard prerequisite: a working conversation with the consuming devops
team about config-injection, registry conventions, and tag policy.
Unilateral decisions here age badly.

- **Output.** A self-contained OCI image: nginx + php-fpm + framework
  baked at canonical paths + plugins cloned at SHA-pinned commits +
  mixins copied in. Single arch — the Titus deployment target is
  arm64 across the board, matching macOS dev hardware, so no buildx
  multi-arch dance and no per-platform image-cache duplication. No
  mosaic-the-tool inside the image; no bind-mounts; no host coupling.
- **Branch pinning at bake time.** A recipe with `branch: main` is
  fine for dev. For a shipped image, `mosaic bake` resolves each
  `branch:` to its current SHA and stamps both the SHA and the
  recipe@version into OCI labels (`mosaic.recipe`,
  `mosaic.recipe.version`, `mosaic.framework`, `mosaic.framework.ref`,
  plus standard `org.opencontainers.image.*`). Image is reproducible
  from labels alone.
- **Licence guardrails.** The framework profile's `licence:` field
  gates registry destinations. Workplace and Totara are
  `licence: proprietary`; `mosaic bake --push` refuses public
  registries (Docker Hub, GHCR public) for proprietary frameworks
  unless an allowlist explicitly permits the destination. Configured
  via `~/.config/mosaic/registries.yaml` (or similar).
- **Env-driven config.** Local dev has a host-editable `config.php`.
  Shipped images need `config.php` reading DB URL, secret key, mail
  config, etc. from environment variables. Templating that config is a
  real chunk of work and is the single biggest item to design with
  devops — what env vars, in what shape, with what defaults, and how
  secrets are injected.
- **What's NOT in the image.** Database, mailpit, anything that isn't
  the framework runtime. Those are sidecar containers/services in the
  deployment topology. `mosaic bake` produces only the application
  image.
- **moodledata.** Created empty + chowned at image build; deployment
  mounts persistent storage there.
- **Image hygiene.** `composer install --no-dev`, multi-stage build to
  drop build-time tools, opcache priming for fast cold starts.
- **Mosaic version stamped in labels** alongside `recipe.version`, so
  devops can audit what tool produced which image.
- **What `mosaic bake` does NOT do.** No deploy step, no helm chart
  generation, no kubectl apply, no compose-for-prod. The hand-off is
  "here is a clean image with these labels at this tag" — devops's
  existing infrastructure (ArgoCD, Flux, helm, plain kubectl, ...)
  takes it from there.
- **Surface.** `mosaic bake [--tag=<repo>:<tag>] [--push]
  [--registry=<host>]`. Default tag derives from recipe name +
  resolved version (e.g. `bluecoat:2.3-mdl405-abc1234` where the
  trailing fragment is a short hash of pinned plugin SHAs).
