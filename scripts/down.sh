#!/usr/bin/env bash
# down: stop nginx + php-fpm, the db + mailpit stack, then the guest.
# Nothing is deleted; `mosaic up` brings it all back.

set -euo pipefail
. "$(dirname "$0")/lib.sh"

require_project
HOME_DIR=$(mosaic_home)
VM_NAME=$(project_vm_name)
DRIVER=$(backend_driver) || exit 1
PHP_VERSION=$(project_yaml_get php.version) || exit 1

if [[ $("$DRIVER" status) == "Running" ]]; then
    "$HOME_DIR/scripts/in-vm" "$VM_NAME" sudo systemctl stop nginx "php${PHP_VERSION}-fpm" || true
fi
"$DRIVER" services down || true
"$DRIVER" stop
ok "down: guest '$VM_NAME' stopped (state kept)"
