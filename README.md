# Mosaic

Per-project dev environments for Moodle / Workplace / Totara and
Laravel. One project directory, one `mosaic.yaml`, one isolated guest
that runs nginx + php-fpm, with the database and Mailpit alongside.

| host  | backend | guest |
|-------|---------|-------|
| macOS | Lima    | a VM per project (vz + virtiofs) |
| Linux | distrobox | a container per project on rootless podman |

The command surface is the same on both. `mosaic` is a thin shim over
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
├── .mosaic/           # rendered configs (nginx.conf, php.ini, services-compose.yaml, justfile)
└── …                  # the framework tree itself (Moodle at the root; Laravel at the root)
```

The app lives **at the project root**, so IDEs open the project and see
the framework root. Moodle plugins declared in `mosaic.yaml` are cloned
at their canonical paths (`local/foo`, `mod/bar`, `public/local/foo` on
5.x) as independent repos. A sub-plugin may be declared with a
destination inside another declared plugin (`local/foo/subplugin/bar`);
it is cloned there on the host and reached through the parent's graft
in the guest. The parent repo should `.gitignore` the sub-plugin
directory.

## How it works

- `bin/mosaic` finds `mosaic.yaml` (walking up), generates
  `.mosaic/justfile` importing `core/core.just` plus one
  `flavours/<flavour>/recipes.just`, and execs `just`.
- `scripts/resolve.sh` turns manifest + framework profile
  (`frameworks/<fw>/<ver>.yaml`, with `extends:`) + backend facts into
  one JSON document that hooks and scripts consume.
- Flavours (`flavours/moodle`, `flavours/laravel`) own the
  framework-specific steps as executable hooks (`fetch`, `install`)
  with JSON on stdin. They never name a backend.
- Backends (`backends/lima`, `backends/distrobox`) own the runtime
  behind one driver contract (`backends/README.md`). `scripts/in-vm`
  dispatches every guest command to the active driver.

Design notes: `docs/flavour-architecture.md`, `docs/link-architecture.md`,
`docs/linux-backend.md`, `docs/runtime-findings.md`.

## Licence

Apache-2.0. See `LICENCE`.
