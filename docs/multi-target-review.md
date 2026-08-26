# Review handoff: multi-target implementation

For the reviewer. The design brief is
[multi-target-handoff.md](multi-target-handoff.md); this is what actually
got built against it, where I departed from it, and what is still
unverified. Everything is uncommitted on `multi-target` (forked from `v2`
at 3c0e6ab) so the diff is readable in one pass.

**State:** all ten implementation steps done; 67 VM-free tests pass
(`tests/multi-target.sh`); **nothing has been run against a real VM.**
That last point is the main thing this review can't cover — see
[Unverified](#unverified) for the exact list.

## Shape of the change

```
 17 files changed, ~650 insertions           7 new files
```

| Design § | Where it landed |
|---|---|
| 1 Schema, 3 Resolution | `scripts/lib.sh` (targets section), `scripts/resolve.sh` |
| 2 State model | `.mosaic/active-target` (switch.sh), `.mosaic/installed.json` (build.sh) |
| 3 Choke points | `scripts/get.sh`, `bin/mosaic`, `core/core.just`, `flavours/moodle/recipes.just`, `sync-graft.sh`, `plugins.sh` |
| 4 Bake manifest | `flavours/moodle/hooks/fetch` (`host_clone`) |
| 5 Teardown | `scripts/teardown.sh` + `flavours/moodle/hooks/teardown` |
| 6 On-demand PHP | `scripts/vm-ensure-php`, `templates/lima-moodle.yaml`, `scripts/build.sh` |
| 7 Commands | `core/core.just`, `scripts/switch.sh`, `scripts/targets.sh` |
| 10 Norse manifest | `/Users/work/titus/repos/norse/mosaic.yaml` (outside this repo — see below) |

## Departures from the brief

Ordered by how much I'd want a second opinion on them.

### 1. `die` inside `$( )` did not actually stop anything (bug, fixed)

The brief's whole validation story rests on dying when a target name is
bogus. It didn't work. Bash unsets `errexit` inside command
substitutions unless `inherit_errexit` is set — and that shopt doesn't
exist on macOS's bash 3.2, which this codebase deliberately targets. So
`project_yaml_get` → `_project_overlay_read` → `project_active_target` →
`die` printed its message, the subshell carried on with an empty target
name, and **every field silently resolved to the top-level layer** — the
precise failure the validation exists to prevent.

Fixed by `|| exit 1` at each internal capture (`lib.sh`, and
`FLAVOUR=$(flavour_for …)` in resolve.sh), with the reasoning in a
comment at the first occurrence.

**This bug class predates the change**: `profile_get` and `profile_caps`
capture `profile_file`, which dies. I fixed those two the same way
because they're in the same file and the same shape, but there may be
more elsewhere — worth a sweep. `tests/multi-target.sh` §3 covers the
target-related ones.

### 2. Target-key validation runs on every read, not just in resolve.sh

The brief put the allowlist check in resolve.sh. But `mosaic status`,
`sync-graft`, `plugins` and the justfile recipes read through
`project_yaml_get` without ever calling resolve.sh, so a target
declaring `ports:` would be honoured by those and ignored by
render-lima — the exact half-application the brief wants refused.

Folding it into the resolver in `lib.sh` costs nothing: name resolution,
existence check and the allowlist are one yq pass emitting four facts
(`_MOSAIC_TARGET_FACTS_YQ`). Note it validates **all** targets, not just
the active one, so a typo in an inactive target is loud immediately.

mikefarah's yq has no `if/then/else` — hence facts-out, logic-in-bash
rather than the more obvious single expression.

### 3. "Installed" vs "desired" extended beyond the justfile

The brief applies this to `get.sh` and apply-graft. I extended it to
every host script that addresses the tree that *exists* rather than the
one that's wanted: `in-project.sh` (composer/npm), `upgrade-moodle.sh`,
`init-phpunit.sh`, `db.sh`. Shared helper `project_installed_get` in
lib.sh; `get.sh --installed` is a thin wrapper over it.

Rationale: those all address `/srv/<framework>` or a running container.
Between `switch` writing the desired target and the build finishing,
reading the manifest points them at a tree that doesn't exist yet.

### 4. New: `scripts/vm-sync-tools`

Not in the brief, and I think it's load-bearing. `apply-graft` is
*installed* into `/usr/local/sbin` at provision time; Lima only re-runs
provisioning at boot, and `build`/`apply-graft`/`sync-graft` all restart
the service without rebooting. That was harmless while apply-graft's
behaviour was fixed. It isn't now: an old copy reads the top-level
`plugins:` instead of the target's, grafting the wrong plugin set with
no error at all.

`vm-sync-tools` streams the current apply-graft into the VM (write +
rename, not truncate-in-place) before every restart. Streamed rather
than copied from `/srv/mosaic` for the documented stale-mount reason.

### 5. New: `mosaic build` refuses to build over a different target

Building B while A is installed wipes A's VM tree and drops its db, but
leaves A's plugin clones at the project root for the graft to pick up.
Silently half-torn-down. build.sh now compares `installed.json`'s
`.target` with the resolved one and points at `mosaic switch`.

### 6. `project_files` is *not* overlaid in apply-graft

The brief says to overlay `.plugins`/`.project_files` reads. I overlaid
only `.plugins`. `project_files` is on the rejected-keys list, so an
overlay read could never return a per-target value — writing one would
imply a per-target `project_files` exists. Left top-level with a comment
saying why. Same for `ports`.

### 7. Smaller additions

- **`confirm_tty` in lib.sh** — the teardown hook can't use `ask_yn`:
  its stdin is the config JSON and is at EOF. Reads `/dev/tty`; honours
  `MOSAIC_ASSUME_YES` (set by `--yes` and by switch after its own
  combined prompt); refuses rather than assuming yes when there's no tty.
- **`has_hook` + a contract assertion** — a flavour without a `teardown`
  hook can't be torn down, and `run_hook`'s missing-hook no-op would
  report success and let `switch` build over a live install.
  `teardown.sh` refuses up front, and afterwards treats a surviving
  `installed.json` as an incomplete tear-down.
- **`mosaic down` tolerates a failed `systemctl stop`** — between a
  teardown and the next build the manifest's php-fpm unit may not exist
  in the VM, and failing there strands the VM running, which is the one
  thing `down` exists to prevent.
- **The fetch hook warns at build time** when it skips the host clone
  and finds no bake-manifest, instead of leaving the user to discover it
  at the teardown that refuses.
- **Empty-clone guard** in `host_clone`: a clone that produced no files
  would otherwise write an empty manifest, which teardown would treat as
  "nothing to remove". Also keeps `"${moved[@]}"` clear of bash 3.2's
  empty-array `set -u` trap.
- **`status` and `targets`** surface active-vs-installed, since after an
  interrupted switch the numbers on screen describe a target that isn't
  on disk.
- **`tests/multi-target.sh`** — not requested; drop it if you'd rather
  not carry tests yet. It's the evidence for everything below.

## What the tests cover

`tests/multi-target.sh` (67 assertions, no VM, ~15s). Nothing touches a
real project; everything runs in a temp dir.

The two worth knowing about:

- **§1 runs `git show HEAD:scripts/{lib,resolve}.sh` into a scratch
  MOSAIC_HOME** and diffs old-vs-new resolve output for a legacy
  manifest. Byte-identical modulo the new `.target` key — that's the
  backward-compatibility claim, mechanically checked rather than
  asserted.
- **§6 rehearses the teardown hook against real git repos** (a bare
  remote + a `--depth 1 --branch <tag>` clone, i.e. the real pristine
  state) with a VM name that doesn't exist, so the VM leg skips and the
  host wipe runs for real. Covers all six guard states including the two
  that matter most: clean-at-tag detached HEAD **passes**,
  detached-at-a-different-commit **refuses**. Also checks that a file of
  the user's own at the project root survives, and that installed.json
  goes last.

## Unverified

**No VM was involved in any of this.** The brief's VM-required list is
untouched, plus two things I added:

1. The real compose volume name, and that `down --volumes` removes it.
2. `vm-ensure-php` on an existing VM: second version installed,
   alternatives flipped both ways (`php -v` after each), fpm units
   enabled/disabled correctly.
3. A full `switch moodle-45 → moodle-51 → moodle-45` cycle, including
   one deliberately interrupted between teardown and install.
4. **New:** the factored provision script still provisions a VM from
   scratch — `vm-ensure-php` now runs *before* the main `apt-get install`
   so that `composer`'s php-cli dependency resolves to the project's
   version rather than dragging Ubuntu's default in alongside it. That
   ordering is reasoned, not observed.
5. **New:** `vm-sync-tools` — `sudo sh -c 'cat > tmp && chmod && mv'`
   over `in-vm` with piped stdin.
6. **New:** the teardown hook's VM leg. In particular that
   `podman compose down --volumes` works as the lima user through
   `in-vm` with a heredoc on stdin (it must *not* be sudo — rootless
   podman belongs to that user).

`shellcheck` was not run: it isn't installed and Homebrew here is
admin-owned. Every touched script passes `bash -n`. A shellcheck pass is
worth doing before merge — I'd expect SC2086 on `apt-get install $PKGS`
in vm-ensure-php (intentional word-splitting, matching the provision
script it was factored out of) and possibly SC2181-ish noise around the
`|| exit 1` idiom.

## Open question for you

**Pre-feature projects can't be torn down.** A project built before this
change has a framework tree at its root and no bake-manifest, and the
brief is explicit: manifest missing → refuse, never guess. So the
migration is "delete the framework files by hand and rebuild clean",
which the teardown message spells out.

The norse project hasn't been built yet, so it's unaffected — it gets a
manifest on its first build. But if you have another project mid-flight,
the wall is real.

There is a non-guessing way out I deliberately didn't build: the VM's
`/srv/<framework>` is a clone of the same ref, so its top-level entries
*are* the manifest (plus `.git`, minus nothing). Reconstructing from
observed state isn't the allowlist-guessing the brief rejects. I left it
out because it's more machinery for a one-time migration, and because
"start clean" is already this design's posture. Your call.

## Where I'd look hardest

1. **`lib.sh`'s `project_target_init`** — the four-fact yq expression and
   its bash-side interpretation. Everything else reads through it.
2. **The teardown hook's guard loop** — specifically the detached-HEAD
   logic. It's the difference between "refuses always" (tags are the
   normal state) and "deletes work".
3. **The `|| exit 1` convention** — I applied it where the feature needs
   it. If you'd rather have a global fix (a `die` that signals the parent
   shell, say), now is the moment.
4. **build.sh's ordering** — ensure-php and vm-sync-tools land between VM
   start and fetch. Both are streamed over stdin; both are new failure
   points on the happy path of every build, including single-target ones.
5. **`switch.sh`'s teardown-before-active-target ordering** — the header
   explains why the tidier order is wrong. Worth a second read.

## Note on the Norse manifest

Step 10 writes `/Users/work/titus/repos/norse/mosaic.yaml`, which is
outside this repo and not under version control, so it won't appear in
the diff. The original is backed up alongside it as
`mosaic.yaml.pre-targets.bak`. Both targets resolve correctly
(`moodle-45` → `MOODLE_405_STABLE`, `plugins_root: .`, 11 plugins;
`moodle-51` → `MOODLE_501_STABLE`, `plugins_root: public`, 11 plugins;
shared ports and wwwroot unchanged).

## Running the tests

```
tests/multi-target.sh          # 83 assertions, no VM, ~15s
```

## Post-review fixes (2026-08-26)

The review found two gaps in the plugin-deletion safety story; both are
fixed on this branch, still uncommitted:

1. **Plugins outside installed.json escaped the work-loss guard.** A
   clone made by `sync-graft` after the build (or by hand) sat inside
   the bake manifest's deletion scope with no entry vouching for it.
   Fixed twice over: `sync-graft.sh` now merges the synced list into
   installed.json's `.plugins` (merge, not replace — entries for
   still-on-disk clones from earlier lists survive; written before the
   VM leg so the record lands even if the graft fails), and the
   teardown hook grew a backstop that `find`s every `.git` under the
   manifest entries (node_modules pruned), runs the same work-loss
   checks on any repo installed.json doesn't declare, and — having no
   pinned ref for those — accepts a detached HEAD only when a tag or
   remote branch already holds its commit. The per-repo checks are one
   shared `check_repo` function now.
2. **`switch` skipped teardown for pre-installed.json builds.** It saw
   "nothing installed" and built the new target over the old host tree
   (fetch then skips the host clone — version.php present). `switch.sh`
   now refuses when a build's traces exist without installed.json and
   routes through `mosaic teardown`, whose fallback detection also
   gained `version.php` as a marker so a tree whose .mosaic state was
   lost reaches the hook's proper migration refusal instead of
   "nothing to tear down".

Plus one hardening: `confirm_tty` tests /dev/tty by opening it, not
`-e` — the node exists even with no controlling terminal.

Tests §6j/§6k (backstop refuse/pass), §7 (version.php-only tree), §8
(pre-feature switch), §8b (sync-graft records clones) cover the above:
67 → 80 assertions.

And one quality-of-life addition (same date): `mosaic up` on a project
whose VM doesn't exist — the `mosaic nuke && mosaic up` trap — now
offers to run `mosaic build` (interactive; default yes) instead of
failing several confusing steps later. Non-interactively it dies
pointing at build. The recipe body moved to `scripts/up.sh` in the
process, matching the build.sh/teardown.sh pattern. Test §10; 83
assertions total.
