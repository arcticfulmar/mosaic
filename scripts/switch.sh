#!/usr/bin/env bash
# switch: tear down the installed target and build another one.
#
# Usage: mosaic switch <target> [--yes]
#
#   1. validate that <target> exists in mosaic.yaml
#   2. ask once — what dies, and what gets built
#   3. teardown, if a different target is installed
#   4. write .mosaic/active-target
#   5. exec build.sh
#
# The ordering of 3 and 4 is load-bearing. Writing active-target *first*
# would look tidier, but a crash between the two would leave the desired
# target pointing at B while A's framework tree is still sitting at the
# project root — and the fetch hook skips the host clone when it finds
# version.php there. The next build would then serve B in the VM with A's
# files on the host: no error, no clue, and an IDE indexing the wrong
# tree. Tearing down first means the host root is empty before anything
# claims the new target.
#
# Every step is individually re-runnable, which is what makes an
# interrupted switch recoverable by re-running the same command:
#
#   crash after teardown  → installed.json is gone, so teardown is a
#                           no-op and the retry goes straight to build
#   crash during build    → the retry rebuilds; the fetch hook is
#                           destructive-then-idempotent by design
#
# Switching between flavours is refused (resolve.sh) — the VM is built
# for one.

set -euo pipefail
. "$(dirname "$0")/lib.sh"

require_project
HOME_DIR=$(mosaic_home)

TARGET=${1:-}
[[ -n $TARGET ]] || die "usage: mosaic switch <target> [--yes]   ('mosaic targets' lists them)"
shift

ASSUME_YES=0
for arg in "$@"; do
    case $arg in
        --yes|-y) ASSUME_YES=1 ;;
        *) die "unknown flag: $arg   (usage: mosaic switch <target> [--yes])" ;;
    esac
done

# --- validate the requested target -------------------------------------------
# Deliberately not via project_active_target: we're validating a name the
# user just typed, not the one that's active.
kind=$(yq -r '.targets | type' mosaic.yaml)
if [[ $kind != "!!map" ]]; then
    die "mosaic.yaml declares no 'targets:' — nothing to switch between.
       Add a targets: map (see docs/multi-target-handoff.md) or just use 'mosaic build'."
fi

if [[ $(T="$TARGET" yq -r '.targets | has(strenv(T))' mosaic.yaml) != "true" ]]; then
    known=$(yq -r '.targets | keys | .[]' mosaic.yaml | tr '\n' ' ')
    die "no target '$TARGET' in mosaic.yaml (known: ${known% })"
fi

INSTALLED_JSON=.mosaic/installed.json

installed_target=''
if [[ -f $INSTALLED_JSON ]]; then
    installed_target=$(yq -p json -r '.target // ""' "$INSTALLED_JSON")
elif [[ -f version.php || -f .mosaic/plugin-context || -f .mosaic/bake-manifest ]]; then
    # Built, but by a Mosaic that predates installed.json. The "nothing
    # installed" branch below would skip teardown and build straight over
    # it — and the fetch hook, finding version.php at the root, would
    # skip the host clone, leaving the old install's files under the new
    # target's VM tree. teardown.sh knows how to handle this state (it
    # resolves the manifest with a loud warning, and its hook refuses
    # cleanly when there's no bake-manifest to delete from); go through
    # it first.
    die "this project was built before Mosaic recorded installs (.mosaic/installed.json is missing)
       run 'mosaic teardown' to remove that install first, then re-run 'mosaic switch $TARGET'"
fi

# What the new target will be, read straight from the manifest (the
# active-target file still names the old one at this point).
new_framework=$(T="$TARGET" yq -r '.targets[strenv(T)].framework // .framework // "?"' mosaic.yaml)
new_version=$(T="$TARGET"   yq -r '.targets[strenv(T)].version   // .version   // "?"' mosaic.yaml)
new_php=$(T="$TARGET"       yq -r '.targets[strenv(T)].php.version // .php.version // "?"' mosaic.yaml)
new_plugins=$(T="$TARGET"   yq -r '(.targets[strenv(T)].plugins // .plugins // []) | length' mosaic.yaml)

# --- already there? -----------------------------------------------------------
# Same target installed: switching to it is a rebuild, and `mosaic build`
# is the recipe for that. Say so rather than tearing down a working
# install to put the same thing back.
if [[ -n $installed_target && $installed_target == "$TARGET" ]]; then
    ok "target '$TARGET' is already installed"
    say "  mosaic build    # rebuild it from scratch (drops the db, re-clones plugins)"
    exit 0
fi

# --- one combined confirmation ------------------------------------------------
# The teardown hook would ask its own question; we answer it on the
# user's behalf (MOSAIC_ASSUME_YES below) so the switch is one decision,
# taken with both halves visible.
echo
info "Switch to target '$TARGET'"
if [[ -n $installed_target ]]; then
    kv "tear down"  "$installed_target"
    installed_fw=$(yq -p json -r '.framework + " " + .version' "$INSTALLED_JSON")
    installed_php=$(yq -p json -r '.php.version' "$INSTALLED_JSON")
    installed_plugins=$(yq -p json -r '.plugins | length' "$INSTALLED_JSON")
    kv ""           "$installed_fw (php $installed_php), $installed_plugins plugin clone(s), database — all destroyed"
else
    kv "tear down"  "(nothing installed)"
fi
kv "build"      "$TARGET"
kv ""           "$new_framework $new_version (php $new_php), $new_plugins plugin(s) cloned fresh"
echo

if [[ $ASSUME_YES -ne 1 ]]; then
    ask_yn "Go ahead?" n || die "aborted — nothing was changed"
fi

# --- teardown -----------------------------------------------------------------
if [[ -n $installed_target ]]; then
    "$HOME_DIR/scripts/teardown.sh" --yes
    echo
fi

# Belt and braces: teardown.sh already treats a surviving installed.json
# as a failed tear-down, but this is the point of no return for the state
# file, so check the invariant here too rather than inferring it.
[[ ! -f $INSTALLED_JSON ]] ||
    die "$INSTALLED_JSON still exists after teardown — refusing to switch onto a live install"

# --- claim the new target -----------------------------------------------------
mkdir -p .mosaic
printf '%s\n' "$TARGET" > .mosaic/active-target
ok "active target is now '$TARGET'"
echo

# exec, not call: build.sh owns the rest of the output and the exit
# status, and there is nothing left for this script to do afterwards.
exec "$HOME_DIR/scripts/build.sh"
