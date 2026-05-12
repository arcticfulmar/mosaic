#!/usr/bin/env bash
# bake: clone the framework source into both /srv/<framework> on the VM
# and the project root on the host.
#
# Why both:
#   1. The VM clone (on native ext4) is what nginx/php-fpm serve. Source
#      file lookups stay native — no virtiofs round-trips per file, no
#      20k-file penalty on every Moodle request.
#   2. The host clone (at the project root, alongside mosaic.yaml and
#      .devenv/) is for IDE indexing (PhpStorm, VSCode), and is where
#      plugin git repos sit nested at their canonical Moodle paths
#      (./local/<plugin>, ./mod/<plugin>, etc.). Opening the project
#      root in the IDE shows the deployed file layout — exactly what
#      PHP sees in the VM.
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

# Path conventions:
#   host: $PROJECT_DIR              (Moodle/Workplace tree at the project root)
#   VM:   /srv/<framework>          (the canonical baked path)
#
# The VM clone always lands at /srv/<framework> even for Workplace /
# Totara, because Moodle's admin/cli scripts and routing expect their
# own canonical paths (config.php, admin/upgrade.php etc.) and the
# framework name in the URL would break them.
HOST_CLONE="$PROJECT_DIR"
VM_CLONE="/srv/$FRAMEWORK"

# Idempotency marker. Moodle/Workplace ships version.php at the
# framework root; its presence on the host means a previous bake
# already laid the tree down here. Skip re-cloning to keep `mosaic
# build` re-runs fast and safe (we can't `rm -rf $PROJECT_DIR` — the
# manifest and rendered .devenv live there).
HOST_FRAMEWORK_MARKER="$PROJECT_DIR/version.php"

info "==> Baking $FRAMEWORK @ $VERSION → $GIT_REF"
say  "    source:    $SOURCE_URL"
say  "    host:      (project root)"
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
# Clones into a scratch dir at the project root, then atomically moves
# contents into the project root itself. Can't clone in place because
# `git clone <url> <target>` refuses a non-empty target and the project
# root already contains mosaic.yaml + .devenv/.
#
# Cleans up two things in the scratch before moving:
#   - .gitignore — Moodle's ships entries like /local/* and /mod/* that
#     would ignore plugin directories nested inside the project root
#     (which is the opposite of what's wanted: plugins are first-class
#     code under IDE/git management here).
#   - .git — the host clone is plain working tree, not a tracking copy
#     of upstream Moodle; plugins nested inside are independent repos.

host_clone() {
    if [[ -f $HOST_FRAMEWORK_MARKER ]]; then
        echo 'bake: framework already laid down at project root (version.php present); skipping host clone.'
        return 0
    fi

    local scratch="$PROJECT_DIR/.mosaic-bake.$$"
    rm -rf "$scratch"

    GIT_TERMINAL_PROMPT=0 \
    GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=accept-new' \
        git clone --depth 1 --branch "$GIT_REF" "$SOURCE_URL" "$scratch"
    rm -f "$scratch/.gitignore"
    rm -rf "$scratch/.git"

    # Pre-flight conflict scan. Moodle's root has hundreds of entries;
    # any collision with what's already at the project root (mosaic.yaml,
    # .devenv/, anything the user put there) would clobber data.
    shopt -s dotglob nullglob
    local conflicts=()
    for entry in "$scratch"/*; do
        local base
        base=$(basename "$entry")
        if [[ -e "$PROJECT_DIR/$base" ]]; then
            conflicts+=("$base")
        fi
    done

    if (( ${#conflicts[@]} > 0 )); then
        shopt -u dotglob nullglob
        die "framework clone would clobber existing files at project root: ${conflicts[*]} (scratch left at $scratch for inspection)"
    fi

    mv "$scratch"/* "$PROJECT_DIR/"
    shopt -u dotglob nullglob

    rm -rf "$scratch"
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
# Plugins live as their own git repos at canonical Moodle paths under
# the project root — e.g. ./local/foo for Moodle 4.x, ./public/local/foo
# for Moodle 5.x. They are NOT cloned into the VM; instead, apply-plugins
# (next step in build.sh) bind-mounts each plugin's host path over the
# canonical baked path. This keeps plugin code single-sourced (one git
# repo, one set of files on disk) while presenting it at the canonical
# location both to the IDE on the host and to PHP in the VM.
#
# Clones run on the HOST so they pick up the host SSH agent for
# private repos. Public URLs work too — git just doesn't ask the
# agent for them.

count=$(project_plugin_count)
if [[ $count -gt 0 ]]; then
    info "==> Cloning $count plugin(s) at canonical paths"
    plugin_base=$(project_host_plugin_base "$FRAMEWORK" "$VERSION")

    for ((i=0; i<count; i++)); do
        p_source=$(yq -r ".plugins[$i].source" mosaic.yaml)
        p_branch=$(yq -r ".plugins[$i].branch // \"main\"" mosaic.yaml)
        p_dest=$(yq -r ".plugins[$i].destination" mosaic.yaml)

        # Moodle 4.x: plugin_base = "."  →  target = $PROJECT_DIR/$p_dest
        # Moodle 5.x: plugin_base = "public" → target = $PROJECT_DIR/public/$p_dest
        if [[ $plugin_base == "." ]]; then
            target="$PROJECT_DIR/$p_dest"
        else
            target="$PROJECT_DIR/$plugin_base/$p_dest"
        fi

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
