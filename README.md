# Mosaic

Per-project dev environments for Moodle / Workplace / Totara and
Laravel. One project directory, one `mosaic.yaml`, one isolated guest
that runs nginx + php-fpm, with the database and Mailpit alongside.

| host  | backend | guest |
|-------|---------|-------|
| macOS | Lima    | a VM per project (vz + virtiofs) |
| Linux | distrobox | a container per project on rootless podman |
| a [kassar](https://github.com/arcticfulmar/kassar) VM | kassi | the kassi itself: mosaic runs inside it, services as user processes |

The command surface is the same on all three. `mosaic` is a thin shim over
[`just`](https://github.com/casey/just): `mosaic` alone lists what is
available where you are.

## Install

**macOS** (Homebrew tap):

```sh
brew install arcticfulmar/mosaic/mosaic
```

**Linux** (git checkout; needs rootless podman, distrobox ≥ 1.8, `just`,
`yq`, `git`):

```sh
git clone https://github.com/arcticfulmar/mosaic.git ~/src/mosaic
ln -s ~/src/mosaic/bin/mosaic ~/.local/bin/mosaic
# yq (mikefarah's) if your distro doesn't package it:
curl -fsSL -o ~/.local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && chmod +x ~/.local/bin/yq
mosaic doctor
```

**Inside a kassi** (a kassar VM with the `web` and `mosaic` recipes):
nothing to install; `mosaic` is in the home and picks the `kassi`
backend by itself. See `docs/kassi-backend.md`.

## Quickstart

```sh
mosaic new mylms --framework=moodle --version=4.5     # writes mylms/mosaic.yaml
cd mylms
mosaic build          # guest + framework + db, then open http://localhost:<port>/
mosaic status         # ports, guest state, IDE wiring
mosaic shell          # a shell in the guest at /srv/project
mosaic down / up      # stop / start, keeping state
mosaic nuke           # destroy the guest and db data (project files survive)
```

Moodle-family projects add `cli`, `purge`, `cron`, `phpunit`,
`init-phpunit`, `upgrade-moodle`, `sync-graft`, `plugins`; Laravel
projects add `artisan`, `tinker`, `queue`, `migrate`, `test`, `pest`,
`dev`. Everything runs inside the guest with your arguments passed
through verbatim.

## Layout of a project

```
mylms/
├── mosaic.yaml        # the manifest: framework, version, php, db, ports, plugins
├── mosaic.<env>.yaml  # optional, local: per-machine overrides (see Environments)
├── .mosaic/           # rendered configs (nginx.conf, php.ini, services-compose.yaml, justfile)
└── …                  # the framework tree itself (Moodle at the root; Laravel at the root)
```

The app lives **at the project root**, so IDEs open the project and see
the framework root. Moodle plugins declared in `mosaic.yaml` are cloned
at their canonical paths (`local/foo`, `mod/bar`, `public/local/foo` on
5.x) as independent repos. Each entry pins either `branch:` (default
`main`) or `tag:` (a release such as `v1.3.2-m4.5`), not both. A
sub-plugin may be declared with a destination inside another declared
plugin (`local/foo/subplugin/bar`);
it is cloned there on the host and reached through the parent's graft
in the guest. The parent repo should `.gitignore` the sub-plugin
directory. On 5.x, destinations are relative to `public/`; root-level
code beside the webroot uses `..` (`../custom/toolkit`), and must stay
inside the project root.

Root-level code that Composer must load, such as a toolkit with its own
namespace, is declared once in `mosaic.yaml`:

```yaml
composer:
  autoload:
    psr-4:
      "titus\\": titus/
```

`mosaic build` merges it into the served tree's `composer.json` just
before `composer install`: a map (`psr-4`, `psr-0`) entry by entry, a
list (`classmap`, `files`) as a union, keeping what the file already
has. A second build changes nothing, and without the key
`composer.json` is never touched. That's the hand edit a fetched core
otherwise needs on every new guest, without committing it to the core.

## Environments

Per-machine settings go in an overlay beside the manifest,
`mosaic.<env>.yaml`, which sets only the keys it changes:

```yaml
# mosaic.kassi.yaml — serve on port 80 to other kassis
listen: all
ports: { web: 80 }
wwwroot: mylms.kassi
```

Select it with `--env <env>` right before or right after the command
(`mosaic build --env kassi`, `mosaic --env kassi up`), or with
`MOSAIC_ENV=kassi`; the flag wins, and `--env ''` turns `MOSAIC_ENV`
off for one command. With no env, `mosaic.yaml` is read as it always
was. Maps merge deeply; lists (`plugins:`) and scalars replace; a key
set to `null` is removed, so Mosaic's default applies again. The
merged manifest is checked like `mosaic.yaml`, a named env with no file
is an error, and nothing picks an env for you. `mosaic config --env
<env>` prints the resolved result (the merged manifest itself is
`.mosaic/manifest.<env>.yaml`), and `mosaic status` shows the env.

In a kassi, don't export `MOSAIC_ENV` globally: a project without the
overlay would then fail. With direnv, put `export MOSAIC_ENV=kassi` in
`~/projects/.envrc` and `source_up` in the `.envrc` of each project that
has a `mosaic.kassi.yaml`.

`build`, `up` and `reload-web` also record the env the guest was set up
with (`.mosaic/manifest.yaml`, which a Lima guest reads at boot). Any
command run with a different env, or none, warns about it; on a
terminal, `build`, `up` and `reload-web` then ask before switching the
guest (scripts keep the warning and carry on). The other commands
leave that record alone, so a forgotten `--env` is noticed before it
rebuilds a kassi on the base ports.

Overlays are meant to stay local: `mosaic new` (and, for Laravel, the
first fetch) ignores `mosaic.*.yaml`, and `mosaic init` does it for an
existing project. In a git repo rooted at the project (a cloned app)
the line goes in `.git/info/exclude`, so the app's committed
`.gitignore` is untouched; otherwise in `.gitignore`. Committing an
overlay with `git add -f` is fine. Tests: `tests/env-overlays.sh` (no guest needed).

## How it works

- `bin/mosaic` finds `mosaic.yaml` (walking up), merges an env
  overlay into it if one is selected (`scripts/manifest.sh`), generates
  `.mosaic/justfile` importing `core/core.just` plus one
  `flavours/<flavour>/recipes.just`, and execs `just`.
- `scripts/resolve.sh` turns manifest + framework profile
  (`frameworks/<fw>/<ver>.yaml`, with `extends:`) + backend facts into
  one JSON document that hooks and scripts consume.
- Flavours (`flavours/moodle`, `flavours/laravel`) own the
  framework-specific steps as executable hooks (`fetch`, `install`)
  with JSON on stdin. They never name a backend.
- Backends (`backends/lima`, `backends/distrobox`, `backends/kassi`) own the runtime
  behind one driver contract (`backends/README.md`). `scripts/in-vm`
  dispatches every guest command to the active driver.

Design notes: `docs/flavour-architecture.md`, `docs/link-architecture.md`,
`docs/linux-backend.md`, `docs/kassi-backend.md`, `docs/runtime-findings.md`.

## Licence

Apache-2.0. See `LICENCE`.
