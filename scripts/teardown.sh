#!/usr/bin/env bash
# teardown: destroy the currently-installed target, leaving the VM and
# the project's own files intact.
#
# Usage: mosaic teardown [--yes]
#
# Core sequences; the flavour's `teardown` hook does the work, exactly
# as with fetch/install (docs/flavour-architecture.md). What core
# contributes is the *input*: the hook is fed .mosaic/installed.json —
# the resolved config of the last successful build — and never
# mosaic.yaml.
#
# That distinction is the whole design. Teardown has to remove what is
# actually on disk: the framework tree that was cloned, the PHP version
# whose fpm unit is running, the plugin repos that were checked out at
# the refs recorded then. A manifest edited since the build (a bumped
# version, a renamed target, a plugin removed from the list) describes a
# different install, and re-resolving would leave the real one's remains
# behind — or, worse, delete something that belongs to a target that was
# never built.
#
# Re-runnable by construction: the hook removes installed.json as its
# last act, so a second run finds nothing installed and says so. That's
# what makes `mosaic switch` safe to re-run after an interrupted one.

set -euo pipefail
. "$(dirname "$0")/lib.sh"

require_project
HOME_DIR=$(mosaic_home)

ASSUME_YES=0
for arg in "$@"; do
    case $arg in
        --yes|-y) ASSUME_YES=1 ;;
        *) die "unknown flag: $arg   (usage: mosaic teardown [--yes])" ;;
    esac
done

INSTALLED_JSON=.mosaic/installed.json

# --- what is installed? -------------------------------------------------------
# installed.json is authoritative. Without it we look for the state a
# build leaves behind before deciding whether there is anything to do at
# all — a never-built project should say "nothing to tear down", not
# start resolving and prompting.
if [[ -f $INSTALLED_JSON ]]; then
    CONFIG_JSON=$(cat "$INSTALLED_JSON")
elif [[ -f version.php || -f .mosaic/plugin-context || -f .mosaic/bake-manifest ]]; then
    # version.php is in the markers: a baked tree always has it at the
    # root, even if .mosaic/ state was lost — and the hook's own
    # manifest guard is the right place for that case to end up
    # (a clear refusal with migration instructions, not "nothing to
    # tear down").
    # Built by a Mosaic that predates installed.json. Resolving the
    # active target is a guess — a good one on an unedited manifest, and
    # the only thing available — so say so loudly rather than quietly
    # deleting on the strength of it.
    warn "no $INSTALLED_JSON, but this project has been built before."
    warn "Falling back to resolving mosaic.yaml as it stands NOW — if it has been"
    warn "edited since that build, what gets removed may not match what is installed."
    CONFIG_JSON=$("$HOME_DIR/scripts/resolve.sh")
else
    ok "nothing installed — nothing to tear down"
    exit 0
fi

FLAVOUR=$(printf '%s' "$CONFIG_JSON" | yq -p json -r .flavour)

# A flavour with no teardown hook cannot be torn down. Saying so beats
# the alternative — run_hook's missing-hook no-op would report success,
# and `mosaic switch` would then build a new target straight over the
# live install.
has_hook "$FLAVOUR" teardown ||
    die "flavour '$FLAVOUR' has no teardown hook — nothing was removed.
       Remove the install by hand, or 'mosaic nuke' to destroy the VM."

export MOSAIC_ASSUME_YES=$ASSUME_YES
run_hook "$FLAVOUR" teardown "$CONFIG_JSON" > /dev/null

# Contract assertion. The hook owns the deletion (it is the last thing it
# does, after everything else succeeded), so a lingering installed.json
# means the tear-down did not finish — and `mosaic switch` reads this
# same file to decide whether it may proceed.
if [[ -f $INSTALLED_JSON ]]; then
    die "the $FLAVOUR teardown hook left $INSTALLED_JSON in place — treating the tear-down as incomplete"
fi

ok "Teardown complete"
