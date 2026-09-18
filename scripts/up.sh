#!/usr/bin/env bash
# up: start the guest, the db + mailpit stack, then nginx + php-fpm.
# Keeps state — project files, db data and dataroots all survive a
# down/up cycle. A guest that was never built can't be started; say so
# and offer the build instead of failing several confusing steps later.

set -euo pipefail
. "$(dirname "$0")/lib.sh"

require_project
HOME_DIR=$(mosaic_home)
VM_NAME=$(project_vm_name)
DRIVER=$(backend_driver) || exit 1
PHP_VERSION=$(project_yaml_get php.version) || exit 1

if ! "$DRIVER" exists; then
    info "Guest '$VM_NAME' does not exist — there is nothing to start."
    say  "This is normal after 'mosaic nuke' (or before a first build):"
    say  "the guest is created and provisioned by 'mosaic build'."
    if [[ -t 0 ]] && ask_yn "Run 'mosaic build' now?" y; then
        echo
        exec "$HOME_DIR/scripts/build.sh"
    fi
    die "run 'mosaic build' to (re)create the guest, then 'mosaic up' works again"
fi

"$DRIVER" start
# --force-recreate: the previous boot's stopped containers linger in
# the store and `up -d` would try to create-rather-than-start them.
# Named volumes are independent of containers, so no data is lost.
"$DRIVER" services up --force-recreate
"$HOME_DIR/scripts/in-vm" "$VM_NAME" sudo systemctl start "php${PHP_VERSION}-fpm" nginx
ok "up: http://$(project_yaml_get_or wwwroot localhost):$(project_yaml_get ports.web)/"
