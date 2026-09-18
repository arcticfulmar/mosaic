#!/usr/bin/env bash
# in-project: run a command inside the guest at the served tree's root,
# as the user that owns that tree.
#
# Usage: in-project <command> [args...]
#
# Where and as whom come from the resolved config, not from the
# framework name:
#   cwd  = .vm_paths.framework      (/srv/<framework> for a baked tree
#                                    on a virtiofs backend; /srv/project
#                                    everywhere else)
#   user = .backend.service_user    (www-data on Lima, where the baked
#                                    tree is chowned to it post-install;
#                                    empty = the exec user on distrobox,
#                                    where the tree is the host user's)

set -euo pipefail
. "$(dirname "$0")/lib.sh"

require_project
[[ $# -ge 1 ]] || die "usage: in-project <command> [args...]"

HOME_DIR=$(mosaic_home)
load_config
VM_NAME=$(cfg .project.vm)
cwd=$(cfg .vm_paths.framework)
svc_prefix

# Build a single shell command string with each arg %q-quoted so
# spaces/quotes/etc. survive the sh -c boundary intact.
#
# `${SVC[@]+"${SVC[@]}"}` is the bash-3.2-safe way to expand an
# array that may be empty under `set -u`.
cmd="cd $(printf '%q' "$cwd") && "
for arg in ${SVC[@]+"${SVC[@]}"} "$@"; do
    cmd+=$(printf '%q ' "$arg")
done

exec "$HOME_DIR/scripts/in-vm" "$VM_NAME" sh -c "$cmd"
