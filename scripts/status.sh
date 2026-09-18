#!/usr/bin/env bash
# status: print a one-screen summary of the project rooted at cwd —
# project name + framework, backend + guest status, IDE wiring, ports.

set -euo pipefail
. "$(dirname "$0")/lib.sh"

require_project
load_config

FRAMEWORK=$(cfg .framework)
VERSION=$(cfg .version)
MODE=$(cfg .mode)
BACKEND=$(cfg .backend.name)
NATIVE=$(cfg .backend.native_storage)
VM_NAME=$(cfg .project.vm)
GUEST_FRAMEWORK=$(cfg .vm_paths.framework)
DRIVER=$(backend_driver "$BACKEND") || exit 1

info "=== Project ==="
kv "name"      "$(cfg .project.name)"
kv "framework" "$FRAMEWORK $VERSION"
kv "php"       "$(cfg .php.version)"
kv "db"        "$(cfg .db.type) $(cfg .db.version)"
echo

info "=== Guest ==="
kv "backend"   "$BACKEND"
kv "name"      "$VM_NAME"
kv "status"    "$("$DRIVER" status)"
echo

info "=== IDE wiring ==="
# Driver-specific endpoint lines (ssh host/port for Lima, enter/exec
# hints for distrobox), then the path mapping. Bake mode on a virtiofs
# backend has the dual-tree architecture: mapping to /srv/project would
# hit the host clone and cause require_once redeclare fatals when
# phpunit runs (core lib loaded via both paths). The guest tree is the
# canonical one. Native-storage backends serve the host tree directly,
# so paths are identical on both sides.
while IFS=$'\t' read -r k v; do
    kv "$k" "$v"
done < <("$DRIVER" endpoint)
if [[ $MODE == "bake" && $NATIVE != "true" ]]; then
    kv "path mapping" "$(pwd) → $GUEST_FRAMEWORK  (NOT /srv/project — that's the host clone)"
else
    kv "path mapping" "$(pwd) → $GUEST_FRAMEWORK"
fi
echo

info "=== Web ==="
kv "wwwroot"   "http://$(cfg .wwwroot):$(cfg .ports.web)"
kv "db"        "127.0.0.1:$(cfg .ports.db)"
kv "mailpit"   "http://localhost:$(cfg .ports.mailpit_ui) (smtp 127.0.0.1:$(cfg .ports.mailpit_smtp))"
