#!/usr/bin/env bash
# up: start the VM, db + mailpit containers, nginx + php-fpm.
#
# Moved out of core.just when it grew its first prompt: if the VM does
# not exist, `limactl start` cannot resurrect it — after `mosaic nuke`
# the fix is a full `mosaic build`, and a tired `mosaic nuke && mosaic
# up` used to fail several confusing steps later (or worse, leave Lima
# to conjure an unprovisioned default instance). Catch it at the door
# and offer the build instead.

set -euo pipefail
. "$(dirname "$0")/lib.sh"

require_project
HOME_DIR=$(mosaic_home)
VM_NAME=$(project_vm_name)

command -v limactl >/dev/null 2>&1 || die "limactl not found"

if ! limactl list -q 2>/dev/null | grep -qx "$VM_NAME"; then
    info "VM '$VM_NAME' does not exist — there is nothing to start."
    say  "This is normal after 'mosaic nuke' (or before a first build):"
    say  "the VM is created and provisioned by 'mosaic build'."
    # ask_yn reads stdin; only offer when a human is on the other end,
    # so a scripted `mosaic up` fails fast instead of hanging on a read.
    if [[ -t 0 ]] && ask_yn "Run 'mosaic build' now?" y; then
        echo
        exec "$HOME_DIR/scripts/build.sh"
    fi
    die "run 'mosaic build' to (re)create the VM, then 'mosaic up' works again"
fi

"$HOME_DIR/scripts/reap-hostagents" "$VM_NAME"
limactl start "$VM_NAME"
php_v=$("$HOME_DIR/scripts/get.sh" --installed php.version)
"$HOME_DIR/scripts/in-vm" "$VM_NAME" \
    podman compose -f /srv/project/.mosaic/services-compose.yaml up -d --force-recreate
"$HOME_DIR/scripts/in-vm" "$VM_NAME" sudo systemctl start "php$php_v-fpm" nginx
