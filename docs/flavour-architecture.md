# Core and flavours

Goal: Moodle and Laravel become self-contained bundles that *add* to a
core command surface. Adding Totara should mean adding a directory, with
no edits to core.

## What blocks that in v1

The whole tool surface is one 371-line `justfile`. Framework-specific
recipes are marked `[group('moodle')]` / `[group('laravel')]`, and each
one opens with a `require-framework.sh` guard because group membership is
cosmetic — every recipe is runnable in every project regardless of
listing. The bare `mosaic` listing is a hand-rolled `default:` recipe that
shells out to `just --list --group X` three times and greps out `just`'s
own annotation lines.

So a new framework means: editing the justfile, adding a group, adding
guards to each recipe, adding a case to `default:`, and touching
`build.sh`, `bake.sh` and `render-services.sh` where they dispatch on
mode. Framework knowledge is spread across core rather than contained.

## The seam

**Core owns the lifecycle. Flavours own the steps.** Core sequences the
work and never learns what a "plugin" or an "artisan command" is;
flavours fill in slots and never learn which backend they're running on.

Two independent axes — flavour (moodle/laravel/totara) × backend (Lima
on macOS, distrobox/podman on Linux) — kept orthogonal. A flavour that
references `limactl` or `distrobox` by name is a design failure.

## Loading: generate the justfile per project

`just` resolves `import` statically, so conditional loading has to happen
before `just` starts. The `bin/mosaic` shim already walks up to find
`mosaic.yaml` and resolves `MOSAIC_HOME`; it gains one job — read
`framework:` and write `.mosaic/justfile`:

```just
import '/opt/homebrew/opt/mosaic/libexec/core/core.just'
import '/opt/homebrew/opt/mosaic/libexec/flavours/moodle/recipes.just'
```

then `exec just --justfile .mosaic/justfile --working-directory <cwd>`.
Regenerate when `mosaic.yaml` is newer than the generated file.

This one change deletes:

- every `[group('...')]` annotation
- every `require-framework.sh` guard — **a recipe that isn't loaded can't
  be run in the wrong project**, so the guard becomes structural instead
  of defensive
- the entire hand-rolled `default:` recipe — plain `just --list` now
  shows exactly the right surface, because only the right recipes exist

Recipe names stay flat (`mosaic phpunit`, not `mosaic moodle::phpunit`) —
`just`'s module system would namespace them, which is worse UX for no
gain here.

## Flavour bundle layout

```
flavours/moodle/
├── flavour.yaml           # identity, capabilities, defaults
├── recipes.just           # recipes added to the core surface
├── versions/
│   ├── 4.x.yaml
│   └── 5.x.yaml           # extends: moodle/4.x
├── hooks/
│   ├── resolve            # mosaic.yaml + profile -> resolved config
│   ├── plan-links         # resolved config -> link plan entries
│   ├── fetch              # populate the base tree
│   ├── install            # install.php / composer create-project
│   ├── teardown           # destroy an install (fed installed.json)
│   ├── test               # backs core's `mosaic test`
│   └── verify             # post-build health check
└── templates/
    ├── nginx.conf.tmpl
    └── php.ini.tmpl
```

`flavours/workplace/` becomes a three-line `flavour.yaml` with
`extends: moodle` and an overridden source — which is the real test of
whether the seam is in the right place.

## The hook contract

Hooks are **executables**, not sourced shell fragments. Core invokes them
with resolved config as JSON on stdin, reads JSON from stdout, and treats
a non-zero exit as an abort with stderr as the message.

That boundary matters: a sourced `lib.sh` lets a flavour reach into core
helpers and quietly couple to them, which is how `plugins_root` ended up
in five files. A process boundary makes the contract explicit, and a
flavour can be written in anything.

```
stdin   {"framework":"moodle","version":"4.5","php":"8.3","base":"/srv/moodle",
         "project_dir":"/Users/work/…/mylms","plugins_root":".", …}
stdout  hook-specific JSON
exit    0 = ok, non-zero = abort, stderr shown to the user
```

`plan-links` emits the entries described in
[link-architecture.md](link-architecture.md) — this is where the Moodle
flavour, and nothing else, applies the `public/` layer for 5.x.

`teardown` is the one hook fed something other than a fresh resolve:
core hands it `.mosaic/installed.json`, the resolved config of the last
successful build. Same JSON shape, different meaning — it describes the
install being destroyed, which may no longer be what mosaic.yaml
describes. A flavour that ships no `teardown` cannot be torn down, and
core says so rather than reporting a no-op as success.

## Lifecycle

`mosaic build`, core-sequenced. Flavour steps marked ▸:

```
1. ▸ resolve        mosaic.yaml + version profile -> resolved config
2. ▸ plan-links     resolved config -> .mosaic/links.json
3.   validate       sources exist, conflict policies satisfied   [host-side, fails fast]
4.   render         runtime spec + stubs from the plan
5.   create         backend driver: create + start
6. ▸ fetch          populate the base tree
7.   apply-links    backend driver applies the plan
8. ▸ install        framework installer
9.   services       start web + php + db
10. ▸ verify        health check
```

Steps 3-5, 7 and 9 are core and identical for every framework. Steps 1,
2, 6, 8 and 10 are the entire flavour surface. `mosaic build` for Totara
is then a bundle directory and no core changes — which is the thing to
hold the design to.

## Capabilities

`flavour.yaml` declares what the flavour supports:

```yaml
name: moodle
capabilities: [phpunit, grunt, mixins, cli]
defaults:
  php: "8.2"
  db: { type: mariadb, version: "10.11" }
```

Core exposes generic recipes that dispatch to hooks — `mosaic test` calls
the `test` hook, so it's `phpunit` under Moodle and `artisan test` under
Laravel, which is exactly the surface you asked for. A flavour that
declares no `test` capability doesn't get the recipe at all, rather than
getting one that errors.

Flavour-specific verbs that have no generic equivalent (`mosaic artisan`,
`mosaic purge`) live in the flavour's `recipes.just` and are loaded only
in matching projects.

## Which recipes go where

| Core (always) | Flavour |
|---|---|
| `new` `build` `up` `down` `status` `nuke` `doctor` | `artisan` `tinker` `queue` `migrate` (laravel) |
| `targets` `teardown` `switch` | |
| `shell` `links` `link` `db` `composer` `npm` | `cli` `purge` `cron` `plugins` (moodle) |
| `test` (dispatches to the `test` hook) | `init-phpunit` `upgrade-moodle` (moodle) |

`mosaic shell` stays core: it's `limactl shell` or `distrobox enter`
depending on the backend — a driver concern, not a flavour one.

## Migration order

The two changes are independent; do them in this order so each is
verifiable on its own:

1. **Justfile generation.** Split `justfile` into `core/core.just` plus
   two `recipes.just`, teach the shim to generate. Deletes the guards and
   the `default:` recipe. No behaviour change — testable against the
   existing v1 scripts.
2. **Hook contract.** Convert `bake.sh` / `install-moodle.sh` /
   `install-laravel.sh` into `fetch` / `install` hooks behind the JSON
   boundary.
3. **Link plan.** Add `plan-links`, retire `apply-graft` and its systemd
   unit.
4. **Backend drivers.** Lima first (primary target, with Mosaic-
   published prebuilt VM images replacing cloud-init provisioning),
   then distrobox/podman for Linux. An apple/container driver is
   deferred until its guests can egress under leak-protection VPNs —
   see [runtime-findings.md](runtime-findings.md).
