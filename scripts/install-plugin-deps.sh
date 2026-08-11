#!/usr/bin/env bash
# install-plugin-deps: run `composer install` for each declared plugin
# that ships a composer.json.
#
# Usage: install-plugin-deps.sh <vm-name> <plugins_root> <dest> [<dest>…]
#
# Why this exists: install.php's upgrade step instantiates every
# plugin's scheduled-task classes, and a task class that require_once's
# its plugin's vendor/autoload.php aborts the whole install when
# vendor/ is missing. So plugin composer deps must be in place before
# install.php (mosaic build) and before upgrade.php (mosaic sync-graft).
#
# Mechanics:
#   - Runs inside the VM (platform checks match the PHP that will
#     execute the code), via the plugin's /srv/project/… path — visible
#     through the project mount regardless of graft state, and the same
#     files as the canonical bind-mounted path.
#   - Runs as the default in-vm user, NOT www-data: plugin dirs are
#     host repos seen through virtiofs, owned by the mapped host user;
#     www-data cannot write vendor/ there. Written this way, vendor/
#     lands in the host plugin repo (IDE sees it, and it survives
#     rebuilds now that fetch keeps existing plugin clones).
#   - Idempotent: composer install with a populated vendor/ is a fast
#     no-op.
#
# Callers pass plugin destinations explicitly (no mosaic.yaml reads
# here) so the flavour-hook data boundary stays intact.

set -euo pipefail
. "$(dirname "$0")/lib.sh"

[[ $# -ge 2 ]] || die "usage: install-plugin-deps.sh <vm-name> <plugins_root> [<dest>…]"

HOME_DIR=$(mosaic_home)
VM_NAME=$1
PLUGINS_ROOT=$2
shift 2

for dest in "$@"; do
    if [[ $PLUGINS_ROOT == "." ]]; then
        vm_dir="/srv/project/$dest"
    else
        vm_dir="/srv/project/$PLUGINS_ROOT/$dest"
    fi

    if "$HOME_DIR/scripts/in-vm" "$VM_NAME" test -f "$vm_dir/composer.json"; then
        info "==> composer install for plugin $dest"
        "$HOME_DIR/scripts/in-vm" "$VM_NAME" \
            sh -c "cd '$vm_dir' && composer install --no-interaction"
    fi
done
