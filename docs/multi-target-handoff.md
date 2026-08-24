# Handoff: multi-target mosaic.yaml (tear-down / rebuild across Moodle & Workplace versions)

Status: **designed, reviewed, not implemented**. This document is the implementation
brief. It was produced from a full read of this repo plus an adversarial design review;
file:line references below were verified against the current `multi-target` branch head
(forked from `v2` at 59e8f7d).

## Problem

A Mosaic project describes exactly one framework+version+php+plugins combination.
Developing the Norse theme suite against several Moodle/Workplace versions (with a
plugin tag/branch per Moodle version) currently means one project folder per version —
one VM, ports allocation, and checkout each. Cumbersome.

Goal: one project, one VM, one `mosaic.yaml` holding multiple named **targets** — each
a framework (moodle/workplace), version, PHP version, and plugin set pinned per target —
plus commands to tear down the currently installed target and build another:

```
mosaic targets              # list targets; mark active + installed
mosaic teardown [--yes]     # destroy the installed target (guards first)
mosaic switch TARGET [--yes]# teardown current, build TARGET
```

## Decisions already taken with the user (do not relitigate)

- **Plugins**: wipe and re-clone at the new target's ref. Teardown refuses if a plugin
  repo would lose work (see guards, §Teardown).
- **PHP**: install missing versions on demand inside the existing VM. No VM rebuild.
- **Data**: full wipe — drop DB, wipe moodledata/phpunitdata. Every build is a clean
  install.
- **Only one target installed at a time.** This is the load-bearing simplification:
  every singleton in Mosaic (one `/srv/<framework>` tree, one `config.php` at
  `/srv/project`, one `/srv/moodledata`, one db container/volume, one `ports:` block,
  one VM) remains valid. Do not introduce per-target paths anywhere.

## Confirmed constraints (verified in this repo)

- Lima never re-provisions an existing VM: `.mosaic/lima.yaml` is passed to `limactl`
  only at instance creation (scripts/render-lima.sh:128-148); restarts use the instance
  copy under `~/.lima/<vm>/` with the original `@@PHP_VERSION@@` baked in. Deleting the
  `.mosaic/provisioned` sentinel re-runs the *old* provision script. Hence on-demand
  PHP install, not template re-render.
- `/srv/mosaic` and `/srv/project` are mounted while `mode: system` provisioning runs
  (templates/lima-moodle.yaml:134,167-168,317), so provision scripts can call scripts
  from the repo mount.
- yq overlay mechanics (verified on yq 4.53): `.targets[strenv(T)].field // .field`
  works, handles dots/dashes in target names, and falls through cleanly when `targets:`
  is absent. Footgun: `T=""` or a bogus name also silently falls through — must be
  guarded with explicit validation (see §Resolution).
- `(.db // {}) * (.targets[strenv(T)].db // {})` deep-merges correctly.
- An empty `plugins: []` in a target *overrides* the top-level list (yq `//` treats
  `[]` as truthy). Document as: omit the key to inherit, `[]` means none.
- podman-compose namespaces named volumes with the compose project name — the volume is
  NOT literally `mosaic-db-data`. Teardown must use
  `podman compose -f /srv/project/.mosaic/services-compose.yaml down --volumes`, never
  `podman volume rm mosaic-db-data`. Verify the real name once in a live VM.
- Plugin clones are **host-side only** (flavours/moodle/hooks/fetch:169-216, over the
  user's ssh agent/config); framework clones also happen VM-side over a forwarded
  agent. The Norse plugin sources below use the host ssh alias `titus-bitbucket:` —
  valid precisely because plugin clones never happen inside the VM. Don't move them.

## Design

### 1. Schema (backward compatible)

Optional `targets:` map + `default_target:` in mosaic.yaml. A target may set only
`framework`, `version`, `php`, `db`, `source`, `plugins`; any other key inside a target
(`ports`, `vm`, `wwwroot`, `project_files`) is a loud error — those stay shared
top-level, since helpers would honour them but render-lima/ports allocation would not.
Per-field overlay: target value shadows top-level. No `targets:` key → byte-identical
behaviour to today. All targets must resolve to the same *flavour* (the Lima template
is fixed at VM creation; render-lima.sh:50-57): validate and tell the user
cross-flavour needs `mosaic nuke`.

The `plugins[].branch` field is passed to `git clone --depth 1 --branch`, which accepts
tags as well as branches — the Norse sets below pin tags. Keep the field name.

### 2. State model (crash-safe switch)

Desired vs installed, two files:

- `.mosaic/active-target` — **desired** target name. Written by `switch` only *after*
  teardown succeeds. Resolution order: state file → `default_target:` → die.
- `.mosaic/installed.json` — the full resolved config JSON of the last **successful**
  build. Written by build.sh as its final step (it already holds `$CONFIG_JSON`,
  scripts/build.sh:32); deleted by teardown as *its* final step.

**Teardown consumes installed.json and never re-resolves.** It must clean exactly what
was installed — old framework name, php version, plugins_root, plugin list — even if
mosaic.yaml was edited or a target renamed since the build. Fallback when residue
exists but installed.json doesn't (pre-feature project): resolve the active target with
a loud warning.

`switch T` = validate T ∈ `.targets`; if installed.json exists and `.target != T` →
teardown; write active-target; exec build.sh. Every leg is individually re-runnable:
crash after teardown → installed.json is gone, re-run skips teardown; crash during
build → re-run retries build only. Rationale for the ordering: writing active-target
*before* teardown would, on a crash, leave the old `version.php` at the host root so
the next fetch skips the host clone (hooks/fetch:62,114-116) — silent divergence
between host tree and VM install.

### 3. Target-aware resolution (fix the choke points, not the call sites)

- **scripts/lib.sh**:
  - `project_active_target()` — state file → `default_target` → die; if `targets:`
    exists, die unless the name is non-empty AND `yq '.targets | has(strenv(T))'`
    (guards the silent-fallback footgun; stale active-target after a rename is the
    realistic trigger).
  - `project_yaml_get` / `project_yaml_get_or` (lib.sh:161,174) become overlay reads:
    `T=… yq -r '.targets[strenv(T)].F // .F // ""'`. Die-on-missing semantics are
    preserved (dies only when the field is in neither place).
  - `project_plugin_count` (lib.sh:286) target-aware; new `project_plugins_json()`
    emitting the overlaid `.plugins` array as JSON.
  - Extract `run_hook()` from build.sh:47-54 (parameterise flavour, hook name, JSON).
  - Free riders once the helpers change: render-lima.sh, render-services.sh,
    status.sh, db.sh, in-project.sh, upgrade-moodle.sh, init-phpunit.sh all read
    through these helpers already.
- **scripts/resolve.sh**: overlay for framework/version/php/source; `.db` deep-merge
  and `.plugins` overlay replacing the `load("mosaic.yaml")` lifts (resolve.sh:84-87);
  add `"target"` to the emitted JSON; target-key allowlist + same-flavour validation.
- **New scripts/get.sh**: `require_project` + one resolved `project_yaml_get "$1"`.
  Failure posture: die only where resolve.sh would; `mosaic down` must keep working in
  odd states. Replace the inline yq in core/core.just:86,95,105,114 (`.php.version`)
  and flavours/moodle/recipes.just:33,40,47,59 (`.framework`).
- **scripts/sync-graft.sh:59-61,105 and scripts/plugins.sh:25-27** iterate
  `project_plugins_json` — otherwise `mosaic sync-graft` on a switched project clones
  the top-level plugin list into the target's tree.
- **bin/mosaic** (flavour detection, line ~71): three lines, standalone (the shim
  deliberately doesn't source lib.sh):

  ```bash
  t=$(cat "$PROJECT_DIR/.mosaic/active-target" 2>/dev/null || true)
  [[ -n "$t" ]] || t=$(yq -r '.default_target // ""' "$PROJECT_DIR/mosaic.yaml")
  framework=$(T="$t" yq -r '.targets[strenv(T)].framework // .framework // ""' "$PROJECT_DIR/mosaic.yaml")
  ```

  Add a keep-in-sync comment mirroring the existing framework→flavour map note
  (bin/mosaic:73-75). Error message for the empty-framework die must mention targets.
- **scripts/apply-graft** runs at every VM boot and must graft the **installed**
  target, never the desired one. The fetch hook extends `.mosaic/plugin-context`
  (hooks/fetch:222-227) to carry `PLUGINS_ROOT`, `TARGET`, `FRAMEWORK`, `PHP_VERSION`;
  apply-graft uses those for its `.framework` (line 73) and `.php.version` (line 238)
  needs, and overlays its `.plugins`/`.project_files` reads (lines 106,108,155,196)
  with `T=$TARGET`. Teardown removes plugin-context; apply-graft already exits
  gracefully when `/srv/<fw>` is absent (lines 101-104), so a boot mid-switch is safe.

### 4. Bake manifest (host wipe done right)

An allowlist wipe is unsound: real project roots contain stray files no allowlist knows
(the norse project already holds `bitbucket-pipelines.yml` and a `mosaicv2` symlink
that predate any bake). Instead: `host_clone` in the fetch hook already iterates every
top-level entry it moves into the project root (hooks/fetch:128-146) — record those
basenames to `.mosaic/bake-manifest` when `FRESH_HOST_CLONE=1`. Teardown deletes
exactly: manifest entries + `config.php` (created by the *install* hook at the host
root, hooks/install:158, so the fetch-time manifest misses it) + framework-generated
extras if present (`node_modules`, `.grunt`). Manifest missing → refuse with
instructions; never guess.

### 5. moodle `teardown` hook (new: flavours/moodle/hooks/teardown + core scripts/teardown.sh)

Core teardown.sh feeds the hook `installed.json` on stdin (same contract as
fetch/install: JSON in, logs to stderr via fd-3 trick, JSON result out). Hook order:

1. **Work-loss guards**, per installed plugin repo: uncommitted changes or untracked
   files (`git status --porcelain`), committed-but-unpushed work
   (`git log --branches --not --remotes --oneline`), non-empty `git stash list`.
   **Detached HEAD is NOT by itself a refusal** — `git clone --branch <tag>` leaves
   detached HEAD, which is now the *normal pristine state* since plugin sets pin tags.
   Refuse on detached HEAD only when HEAD's commit differs from the declared ref's
   commit (`git rev-parse HEAD` vs `git rev-parse <declared>^{commit}`, using the ref
   recorded in installed.json). Die listing every offending repo and why.
2. One confirmation rendered from installed.json — what is actually installed, not
   what mosaic.yaml currently says (`--yes` skips; `switch` forwards `--yes` and shows
   a single combined prompt: what dies + what will be built).
3. VM side — skip cleanly if the VM was deleted (its disk, including the podman
   volume, is gone with it); start it if merely stopped:
   - `systemctl stop nginx php<installed>-fpm` and `systemctl disable` the fpm unit
     (fpm pins graft mounts; provision `enable`d it, a reboot must not resurrect it);
   - graft unmount sweep *with* the belt-and-braces still-mounted refusal recheck,
     reused verbatim from hooks/fetch:83-93 — this is what stands between `rm -rf` and
     deleting host plugin data through a live virtiofs bind;
   - `rm -rf /srv/<installed-framework>`;
   - `find /srv/moodledata /srv/phpunitdata -mindepth 1 -delete` (globs miss dotfiles);
   - `podman compose -f /srv/project/.mosaic/services-compose.yaml down --volumes`;
   - remove `/var/lib/mosaic/grafted-files`.
4. Host side: delete bake-manifest entries + plugin clones + `config.php`.
5. Remove `.mosaic/plugin-context`, `.mosaic/bake-manifest`, and — last —
   `.mosaic/installed.json`.

### 6. On-demand PHP: new scripts/vm-ensure-php

Factor the PHP portion of the provision script out of templates/lima-moodle.yaml —
PPA gating (lines 142-165), package set (lines 187-194), conf.d symlinks (283-289),
`systemctl enable` (291) — into one script taking the version as `$1`. Scope it to PHP
only; nodesource/yq/podman stay in the provision stub.

- Provision stub calls `bash /srv/mosaic/scripts/vm-ensure-php @@PHP_VERSION@@`
  (invoke via `bash` — `/srv/mosaic` is a read-only mount, don't rely on the exec
  bit; precedent at lima-moodle.yaml:317). Move the ondrej keyring install
  (lines 166-168) out of the else-branch so `/etc/apt/keyrings/ondrej-php.asc` always
  exists — then the script never needs the mount for the keyring.
- build.sh gains an ensure-php step after VM start (before fetch — composer in the
  install hook and apply-graft's fpm try-restart want the target PHP early),
  **streamed** so it never trusts a possibly-stale `/srv/mosaic` mount (the documented
  brew-upgrade hazard, lima-moodle.yaml:320-325):
  `in-vm "$VM" sudo bash -s -- "$PHP_VERSION" < "$HOME_DIR/scripts/vm-ensure-php"`
  (piped stdin defeats in-vm's `-t`, which is what you want here).
- **On every call**, not just first install of a version:
  `update-alternatives --set php /usr/bin/php<ver>` (and `phar`, `phar.phar`), and
  `systemctl disable` any other enabled `php*-fpm` units. Without the alternatives
  flip, bare `php` (install hook line 124, `mosaic cli/purge/cron`,
  upgrade-moodle.sh:29, composer) silently runs the newest installed PHP after
  switching back to an older target — right web PHP, wrong CLI PHP.
- Nothing else per version: the nginx vhost socket is already parameterised
  (templates/nginx-moodle.conf:43) and re-rendered each build; ondrej packages ship
  the default `www` pool at that socket.

### 7. New commands

Recipes live in **core** (core/core.just), not the flavour — the flavour can change
mid-switch. `targets` renders from yaml + installed.json; `teardown` and `switch`
dispatch to scripts/teardown.sh and scripts/switch.sh; the hook indirection keeps
core free of framework specifics (a flavour without a teardown hook is a no-op,
matching run_hook's existing missing-hook semantics).

## Norse project manifest (final form)

Target set for `/Users/work/titus/repos/norse/mosaic.yaml`. Plugin compatibility comes
from the Norse developer's suite list (suite 1.9.0+ for Moodle 4.5, updated 25/03/2026;
suite 2.1.0+ for Moodle 5.1+, updated 11/12/2025). Sources use the user's host ssh
alias — clone form `titus-bitbucket:titus-learning/<repo>` (host-side clones only, see
Constraints). PHP stays 8.2 for both targets (frameworks/moodle/5.x.yaml deliberately
keeps 8.2 as default so plugins targeting both LTSes share one PHP; per-target
`php: {version: "8.4"}` remains available).

```yaml
mosaic_version: "0.1"

default_target: moodle-45

targets:
  moodle-45:                     # Theme suite 1.9.0+ (Moodle 4.5)
    framework: moodle
    version: "4.5"
    php: { version: "8.2" }
    plugins:
      - { source: "titus-bitbucket:titus-learning/theme_norse",                    branch: "v1.9.10-m4.5", destination: "theme/norse" }
      - { source: "titus-bitbucket:titus-learning/local_library",                  branch: "v1.3.2-m4.5",  destination: "local/library" }
      - { source: "titus-bitbucket:titus-learning/local_smilify",                  branch: "v1.0.1-m4.5",  destination: "local/smilify" }
      - { source: "titus-bitbucket:titus-learning/block_announcements",            branch: "v1.0.0",       destination: "blocks/announcements" }
      - { source: "titus-bitbucket:titus-learning/block_featuredlearning",         branch: "v2.3.4-m4.5",  destination: "blocks/featuredlearning" }
      - { source: "titus-bitbucket:titus-learning/block_bookmarkedlearning",       branch: "v2.3.1",       destination: "blocks/bookmarkedlearning" }
      - { source: "titus-bitbucket:titus-learning/block_recommendedlearning",      branch: "v2.3.1",       destination: "blocks/recommendedlearning" }
      - { source: "titus-bitbucket:titus-learning/block_recentlyaccessedlearning", branch: "v2.3.1",       destination: "blocks/recentlyaccessedlearning" }
      - { source: "titus-bitbucket:titus-learning/block_learninginprogress",       branch: "v2.3.1",       destination: "blocks/learninginprogress" }
      - { source: "titus-bitbucket:titus-learning/block_unaccessedlearning",       branch: "v2.3.1",       destination: "blocks/unaccessedlearning" }
      - { source: "titus-bitbucket:titus-learning/tool_courserating",              branch: "v1.3.0",       destination: "admin/tool/courserating" }

  moodle-51:                     # Theme suite 2.1.0+ (Moodle 5.1+)
    framework: moodle
    version: "5.1"
    php: { version: "8.2" }
    plugins:
      - { source: "titus-bitbucket:titus-learning/theme_norse",                    branch: "v2.1.0-m5.1", destination: "theme/norse" }
      - { source: "titus-bitbucket:titus-learning/local_library",                  branch: "v2.0.0",      destination: "local/library" }
      - { source: "titus-bitbucket:titus-learning/local_smilify",                  branch: "v2.0.0",      destination: "local/smilify" }
      - { source: "titus-bitbucket:titus-learning/block_announcements",            branch: "v2.0.0",      destination: "blocks/announcements" }
      - { source: "titus-bitbucket:titus-learning/block_featuredlearning",         branch: "v2.4.2-m5.0", destination: "blocks/featuredlearning" }
      - { source: "titus-bitbucket:titus-learning/block_bookmarkedlearning",       branch: "v2.4.0",      destination: "blocks/bookmarkedlearning" }
      - { source: "titus-bitbucket:titus-learning/block_recommendedlearning",      branch: "v2.4.0",      destination: "blocks/recommendedlearning" }
      - { source: "titus-bitbucket:titus-learning/block_recentlyaccessedlearning", branch: "v2.4.0",      destination: "blocks/recentlyaccessedlearning" }
      - { source: "titus-bitbucket:titus-learning/block_learninginprogress",       branch: "v2.4.0",      destination: "blocks/learninginprogress" }
      - { source: "titus-bitbucket:titus-learning/block_unaccessedlearning",       branch: "v2.4.0",      destination: "blocks/unaccessedlearning" }
      - { source: "titus-bitbucket:titus-learning/tool_courserating",              branch: "v2.0.0",      destination: "admin/tool/courserating" }

  # workplace-52:                # Uncomment + pin when a Workplace target is needed.
  #   framework: workplace       # Workplace refs need a 3-part version pin —
  #   version: "5.2.1"           # git_ref_pattern uses {patch} (frameworks/workplace/5.x.yaml).
  #   php: { version: "8.2" }
  #   plugins: []                # presumed: suite 2.1.0+ set as for moodle-51 — confirm tags for MWP.

php:                             # legacy top-level fields kept as the shared/default layer
  version: "8.2"

db:
  type: mariadb
  version: "10.11"

wwwroot: norse.mosaic

ports:                           # unchanged from the existing manifest (shared across targets)
  web: 8029
  db: 3335
  mailpit_ui: 8054
  mailpit_smtp: 1054
  vite_dev: 5202
  ssh: 60029

vm:
  cpus: 4
  memory: 6GiB
  disk: 40GiB
```

Notes: destinations are Moodle canonical plugin paths (`blocks/…` not `block/…`;
`admin/tool/…` for tool plugins). On 5.x targets the resolver prefixes `public/`
automatically via `plugins_root` — destinations stay version-agnostic. The developer's
list had one label typo ("recentlyaccesslearning"); the repo name
`block_recentlyaccessedlearning` is the one used. `blocks/unaccessedlearning` on 4.5 is
the re-imagined plugin (works on both MWP and LMS per the developer's note).

## Implementation order

1. lib.sh — active-target + overlay helpers, `project_plugins_json`, `run_hook`
   extraction
2. resolve.sh — overlay, `.db` merge, `.plugins` lift, `target` in JSON, validation
3. get.sh + core.just / recipes.just inline-yq replacement
4. bin/mosaic flavour detection
5. fetch hook (bake-manifest, extended plugin-context) + apply-graft (context-driven)
6. sync-graft.sh + plugins.sh → project_plugins_json
7. vm-ensure-php + lima-moodle.yaml factoring + build.sh (ensure-php step,
   installed.json write)
8. flavours/moodle/hooks/teardown + scripts/teardown.sh
9. scripts/switch.sh + targets listing + core recipes
10. norse mosaic.yaml (manifest above)

House style: comment-heavy headers explaining *why* (see any script in scripts/);
respect the data boundary — hooks consume resolve JSON / installed.json only, never
mosaic.yaml (docs/flavour-architecture.md); keep the bin/mosaic ↔ resolve.sh duplicated
maps annotated with sync comments.

## Verification

VM-free first:
- Overlay fixtures through resolve.sh in a scratch project: legacy yaml → output
  byte-identical to today; per-target outputs; empty/bogus target name → dies;
  `plugins: []` override; db deep-merge; disallowed key inside a target → dies.
- Flip `.mosaic/active-target` in a fixture; assert `get.sh php.version` and the
  flavour import line in the generated `.mosaic/justfile`.
- Teardown host-wipe rehearsal in a scratch dir: fake bake-manifest + plugin repos in
  states clean-at-tag (detached HEAD — must PASS), dirty, unpushed, stashed,
  detached-at-wrong-commit (must all REFUSE); edit mosaic.yaml after a fake install
  and confirm teardown still targets installed.json values.
- render-services.sh per target: nginx socket version + WEBROOT flip between 4.x/5.x.
- shellcheck every touched script.

VM-required (one throwaway session):
- Actual compose volume name (`podman volume ls`) and that `down --volumes` removes it.
- vm-ensure-php on an existing VM: install a second PHP, flip alternatives both ways
  (`php -v` after each), fpm units enabled/disabled correctly.
- Full `switch moodle-45 → moodle-51 → moodle-45` cycle on the norse project,
  including one deliberately interrupted build between teardown and install.
