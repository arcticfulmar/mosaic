#!/usr/bin/env bash
# bake: clone the framework source into both /srv/<framework> on the VM
# and ./<framework> on the host.
#
# Why both:
#   1. The VM clone (on native ext4) is what nginx/php-fpm serve. Source
#      file lookups stay native — no virtiofs round-trips per file, no
#      20k-file penalty on every Moodle request.
#   2. The host clone is for IDE indexing (PhpStorm, VSCode) — and is
#      where, in Round B, plugin git repos will live nested at canonical
#      paths.
#
# The two clones run in parallel — they hit the same remote, but
# `git clone --depth=1` is mostly network-bound, so doubling the wall
# time would hurt for no gain.
#
# Run from inside a Mosaic project. The VM must already be running.

set -euo pipefail
. "$(dirname "$0")/lib.sh"

require_project
command -v yq      >/dev/null 2>&1 || die "yq not found"
command -v limactl >/dev/null 2>&1 || die "limactl not found"

PROJECT_DIR=$(pwd)
VM_NAME=$(project_vm_name)
FRAMEWORK=$(project_yaml_get framework)
VERSION=$(project_yaml_get version)

case $FRAMEWORK in
    moodle|workplace|totara) ;;
    *) die "bake.sh only handles bake-mode frameworks (got: $FRAMEWORK)" ;;
esac

# --- resolve source URL + git ref -------------------------------------------
# `source` and `git_ref_pattern` come from the framework profile. The
# project may override `source` in mosaic.yaml (e.g. to point at a fork);
# we honour that first.

SOURCE_URL=$(project_yaml_get_or 'source' '')
[[ -n $SOURCE_URL ]] || SOURCE_URL=$(profile_get "$FRAMEWORK" "$VERSION" 'source')
[[ -n $SOURCE_URL ]] || die "no source URL — set 'source' in mosaic.yaml or in the framework profile"

REF_PATTERN=$(profile_get "$FRAMEWORK" "$VERSION" 'git_ref_pattern')
[[ -n $REF_PATTERN ]] || die "framework profile has no 'git_ref_pattern'"
GIT_REF=$(resolve_git_ref "$REF_PATTERN" "$VERSION")

# Path conventions on both filesystems. We use the framework name as
# the directory name (./moodle, /srv/moodle for moodle/workplace; the
# Workplace clone still lands at /srv/moodle inside the VM because
# Workplace IS Moodle as far as nginx/php-fpm care, and routes for
# admin/cli etc. expect the canonical paths).
HOST_CLONE="$PROJECT_DIR/$FRAMEWORK"
VM_CLONE="/srv/$FRAMEWORK"

info "==> Baking $FRAMEWORK @ $VERSION → $GIT_REF"
say  "    source:    $SOURCE_URL"
say  "    host:      ./$FRAMEWORK"
say  "    vm:        $VM_CLONE"

# --- VM-side clone -----------------------------------------------------------
# Runs inside the VM via ssh — explicitly opening a one-shot session
# with agent forwarding (-A + ControlPath=none) so private-repo clones
# work even though the Lima template intentionally leaves agent
# forwarding off by default.
#
# Why ControlPath=none: Lima sets ControlMaster persistent in its
# generated ssh.config. Without overriding, a second ssh would reuse
# the master that was opened WITHOUT -A, silently dropping agent
# forwarding.

vm_inner_script="\
set -euo pipefail
sudo rm -rf $VM_CLONE
sudo install -d -o \"\$USER\" -g \"\$USER\" $VM_CLONE
GIT_TERMINAL_PROMPT=0 \\
GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=accept-new' \\
git clone --depth 1 --branch '$GIT_REF' '$SOURCE_URL' $VM_CLONE
sudo chown -R www-data:www-data $VM_CLONE
echo 'bake: VM clone done.'
"

lima_ssh_config="$HOME/.lima/$VM_NAME/ssh.config"
[[ -f $lima_ssh_config ]] || die "Lima ssh config not found at $lima_ssh_config — is the VM running?"

# --- host-side clone --------------------------------------------------------
# Cleans up the host clone after fetch:
#   - remove .gitignore at the root, so plugin git repos nested inside
#     don't get treated as ignored when (in Round B) the IDE looks at
#     the project as a whole;
#   - remove .git so the host clone doesn't masquerade as a tracked
#     copy of upstream Moodle (we treat ./moodle as plain working tree
#     with separate plugin git repos nested inside).

host_clone() {
    rm -rf "$HOST_CLONE"
    GIT_TERMINAL_PROMPT=0 \
    GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=accept-new' \
        git clone --depth 1 --branch "$GIT_REF" "$SOURCE_URL" "$HOST_CLONE"
    rm -f "$HOST_CLONE/.gitignore"
    rm -rf "$HOST_CLONE/.git"
    echo 'bake: host clone done.'
}

# Run both in parallel; surface the first non-zero exit so a failed
# clone is loud rather than silently skipped.
printf '%s' "$vm_inner_script" | ssh \
    -F "$lima_ssh_config" \
    -o ControlPath=none \
    -o ForwardAgent=yes \
    "lima-$VM_NAME" bash &
vm_pid=$!

host_clone &
host_pid=$!

vm_rc=0; host_rc=0
wait "$vm_pid"   || vm_rc=$?
wait "$host_pid" || host_rc=$?
if [[ $vm_rc -ne 0 || $host_rc -ne 0 ]]; then
    die "bake failed (vm=$vm_rc host=$host_rc)"
fi

ok "Framework source baked"

# --- plugin clones (host only) ----------------------------------------------
# Plugins live as their own git repos at canonical paths INSIDE the
# host clone of the framework — e.g. ./moodle/local/foo. They are NOT
# cloned into the VM; instead, apply-plugins (next step in build.sh)
# bind-mounts each plugin's host path over the canonical baked path.
# This keeps plugin code single-sourced (one git repo, one set of
# files on disk) while presenting it at the canonical location both
# to the IDE on the host and to PHP in the VM.
#
# Clones run on the HOST so they pick up the host SSH agent for
# private repos. Public URLs work too — git just doesn't ask the
# agent for them.

count=$(project_plugin_count)
if [[ $count -gt 0 ]]; then
    info "==> Cloning $count plugin(s) into ./$FRAMEWORK"
    plugin_base=$(project_host_plugin_base "$FRAMEWORK" "$VERSION")

    for ((i=0; i<count; i++)); do
        p_source=$(yq -r ".plugins[$i].source" mosaic.yaml)
        p_branch=$(yq -r ".plugins[$i].branch // \"main\"" mosaic.yaml)
        p_dest=$(yq -r ".plugins[$i].destination" mosaic.yaml)

        target="$PROJECT_DIR/$plugin_base/$p_dest"

        # Refuse to overwrite a non-empty destination that wasn't
        # produced by us. The framework just got freshly cloned, so
        # any non-empty existing dir at this path means upstream
        # ships something there — collision must be the user's call.
        if [[ -e $target && -n "$(ls -A "$target" 2>/dev/null || true)" ]]; then
            die "plugin destination collides with framework content: $target"
        fi

        say "  + $p_dest  ← $p_source @ $p_branch"
        install -d "$(dirname "$target")"
        rm -rf "$target"
        GIT_TERMINAL_PROMPT=0 \
        GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=accept-new' \
            git clone --depth 1 --branch "$p_branch" "$p_source" "$target"
    done
    ok "Plugins cloned"
fi
