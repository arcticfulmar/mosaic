#!/usr/bin/env bash
# sync-graft: incrementally apply mosaic.yaml's plugin list.
#
# Use this after editing mosaic.yaml to add or remove plugin entries.
# It's the safe alternative to `mosaic build`, which would drop the DB
# and re-clone the framework.
#
# Three steps:
#   1. Clone any plugin source missing from the host (in your project
#      root at the canonical path). Plugins already present are left
#      untouched — your local work-in-progress (uncommitted changes,
#      branch checkouts, manually nested repos) is preserved.
#   2. Restart apply-graft.service in the VM so the graft matches the
#      current manifest (attaches new entries, detaches removed ones).
#      This picks up project_files changes too.
#   3. Run Moodle's admin/cli/upgrade.php so new plugins' DB tables
#      install. Idempotent: a no-op when nothing changed.
#
# Removing a plugin from mosaic.yaml: this recipe unbinds it inside
# the VM but leaves the host clone in place. `rm -rf` the directory
# yourself when you're sure you no longer need the files. Moodle's
# database tables for the removed plugin will also linger — clean
# them up via the web UI's plugin management page if desired.

set -euo pipefail
. "$(dirname "$0")/lib.sh"

require_project
command -v yq >/dev/null 2>&1 || die "yq not found"

HOME_DIR=$(mosaic_home)
PROJECT_DIR=$(pwd)
VM_NAME=$(project_vm_name)
FRAMEWORK=$(project_yaml_get framework)
VERSION=$(project_yaml_get version)

case $FRAMEWORK in
    moodle|workplace|totara) ;;
    *) die "sync-graft only supports bake-mode frameworks (got: $FRAMEWORK)" ;;
esac

count=$(project_plugin_count)
if [[ $count -eq 0 ]]; then
    info "no plugins declared in mosaic.yaml — nothing to sync"
    # Still re-run apply-graft so any stale binds get unmounted and
    # project_files stay current (covers the case where the user
    # removed the last plugin entry).
    "$HOME_DIR/scripts/in-vm" "$VM_NAME" sudo systemctl restart apply-graft.service
    exit 0
fi

plugin_base=$(project_host_plugin_base "$FRAMEWORK" "$VERSION")

info "==> Syncing $count plugin(s) from mosaic.yaml"

cloned=0
kept=0
for ((i=0; i<count; i++)); do
    p_source=$(yq -r ".plugins[$i].source" mosaic.yaml)
    p_branch=$(yq -r ".plugins[$i].branch // \"main\"" mosaic.yaml)
    p_dest=$(yq -r ".plugins[$i].destination" mosaic.yaml)

    # Moodle 4.x: plugin_base = "."  → target = $PROJECT_DIR/$p_dest
    # Moodle 5.x: plugin_base = "public" → $PROJECT_DIR/public/$p_dest
    if [[ $plugin_base == "." ]]; then
        target="$PROJECT_DIR/$p_dest"
    else
        target="$PROJECT_DIR/$plugin_base/$p_dest"
    fi

    # Already-present, non-empty: leave it alone. Preserves any local
    # work (uncommitted changes, branch checkouts, custom edits).
    if [[ -e $target && -n "$(ls -A "$target" 2>/dev/null || true)" ]]; then
        say "  = $p_dest  (already present; left untouched)"
        kept=$((kept + 1))
        continue
    fi

    say "  + $p_dest  ← $p_source @ $p_branch"
    install -d "$(dirname "$target")"
    rm -rf "$target"
    GIT_TERMINAL_PROMPT=0 \
    GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=accept-new' \
        git clone --depth 1 --branch "$p_branch" "$p_source" "$target"
    cloned=$((cloned + 1))
done

say ""
ok "Synced: $cloned cloned, $kept already present"

# --- re-graft the current set inside the VM ---------------------------------
# apply-graft.service unbinds any stale binds under /srv/<framework>,
# reaps stale project-file symlinks, and re-applies according to the
# current mosaic.yaml. This is what picks up removals as well as
# additions.
info "==> Re-applying the graft"
"$HOME_DIR/scripts/in-vm" "$VM_NAME" sudo systemctl restart apply-graft.service

# --- plugin composer deps ----------------------------------------------------
# Same requirement as at build time: upgrade.php instantiates plugin
# task classes, so a newly-added plugin shipping a composer.json needs
# vendor/ populated before the upgrade runs, or it aborts.
dests=()
for ((i=0; i<count; i++)); do
    dests+=("$(yq -r ".plugins[$i].destination" mosaic.yaml)")
done
"$HOME_DIR/scripts/install-plugin-deps.sh" "$VM_NAME" "$plugin_base" "${dests[@]}"

# --- run Moodle upgrade so DB schemas install -------------------------------
# Idempotent — Moodle's upgrade.php short-circuits if all components
# are at their declared version. Running unconditionally keeps the
# recipe's contract simple ("everything's caught up afterwards").
info "==> Running Moodle upgrade for plugin schemas"
"$HOME_DIR/scripts/upgrade-moodle.sh"

ok "Graft synced"
