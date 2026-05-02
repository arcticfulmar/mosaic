#!/usr/bin/env bash
# in-project: run a command inside the VM at the project's working
# directory, with the right user for the framework's runtime mode.
#
# Usage: in-project <command> [args...]
#
# bake mode (Moodle / Workplace / Totara):
#   cwd  = /srv/<framework>                  (the baked tree on VM ext4)
#   user = www-data                          (the tree's owner post-install,
#                                             so composer/npm caches under
#                                             /var/www stay writable)
#
# mount mode (Laravel):
#   cwd  = /srv/project/<destination>        (virtiofs view of host clone)
#   user = default lima user                 (matches host UID via virtiofs)

set -euo pipefail
. "$(dirname "$0")/lib.sh"

require_project
[[ $# -ge 1 ]] || die "usage: in-project <command> [args...]"

HOME_DIR=$(mosaic_home)
VM_NAME=$(project_vm_name)
FRAMEWORK=$(project_yaml_get framework)

case $FRAMEWORK in
    moodle|workplace|totara)
        cwd="/srv/$FRAMEWORK"
        prefix=(sudo -u www-data -H)
        ;;
    laravel)
        dest=$(project_yaml_get project.destination)
        cwd="/srv/project/$dest"
        prefix=()
        ;;
    *)
        die "in-project: unknown framework '$FRAMEWORK'"
        ;;
esac

# Build a single shell command string with each arg %q-quoted so
# spaces/quotes/etc. survive the sh -c boundary intact.
#
# `${prefix[@]+"${prefix[@]}"}` is the bash-3.2-safe way to expand an
# array that may be empty under `set -u`. Plain "${prefix[@]}" errors
# with "unbound variable" on bash 3.2 when the array is empty (the
# Laravel case here). bash 4+ would be lenient, but macOS ships 3.2.
cmd="cd $(printf '%q' "$cwd") && "
for arg in ${prefix[@]+"${prefix[@]}"} "$@"; do
    cmd+=$(printf '%q ' "$arg")
done

exec "$HOME_DIR/scripts/in-vm" "$VM_NAME" sh -c "$cmd"
