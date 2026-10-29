#!/usr/bin/env bash
# down: stop nginx + php-fpm, the db + mailpit stack, then the guest.
# Nothing is deleted; `mosaic up` brings it all back.

set -euo pipefail
. "$(dirname "$0")/lib.sh"

require_project
VM_NAME=$(project_vm_name)
DRIVER=$(backend_driver) || exit 1

if [[ $("$DRIVER" status) == "Running" ]]; then
    "$DRIVER" web stop || true
fi
"$DRIVER" services down || true
"$DRIVER" stop
ok "down: guest '$VM_NAME' stopped (state kept)"
