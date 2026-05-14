#!/usr/bin/env bash
# status: print a one-screen summary of the project rooted at cwd —
# project name + framework, VM status, host-side ports.

set -euo pipefail
. "$(dirname "$0")/lib.sh"

require_project
command -v yq      >/dev/null 2>&1 || die "yq not found"
command -v limactl >/dev/null 2>&1 || die "limactl not found"

VM_NAME=$(project_vm_name)
FRAMEWORK=$(project_yaml_get framework)
VERSION=$(project_yaml_get version)
PHP_VERSION=$(project_yaml_get php.version)
DB_TYPE=$(project_yaml_get db.type)
DB_VERSION=$(project_yaml_get db.version)
WWWROOT=$(project_yaml_get_or wwwroot localhost)
WEB_PORT=$(project_yaml_get ports.web)
DB_PORT=$(project_yaml_get ports.db)
MAILPIT_UI=$(project_yaml_get ports.mailpit_ui)
MAILPIT_SMTP=$(project_yaml_get ports.mailpit_smtp)
MODE=$(profile_get "$FRAMEWORK" "$VERSION" 'mode')

# What an IDE's path mapping should target. Bake mode (Moodle family)
# has the dual-clone architecture — mapping to /srv/project would hit
# the host clone and cause require_once redeclare fatals when phpunit
# runs (core lib loaded via both paths). The baked /srv/<framework>
# tree is the canonical one; plugin bind-mounts make plugin edits in
# the host clone still flow through. Mount mode (Laravel) only has
# one tree at /srv/project.
case $MODE in
    bake)  REMOTE_PROJECT_PATH="/srv/$FRAMEWORK" ;;
    mount) REMOTE_PROJECT_PATH="/srv/project"    ;;
    *)     REMOTE_PROJECT_PATH=""                ;;
esac

vm_status=$(limactl list --format='{{.Name}} {{.Status}}' 2>/dev/null \
            | awk -v v="$VM_NAME" '$1==v{print $2}')
[[ -z $vm_status ]] && vm_status="(not created)"

# SSH endpoint: Lima writes a per-VM ssh.config we can both report
# verbatim and parse for the bits an IDE's "SSH interpreter" form
# wants individually. Port is dynamic — Lima reassigns on restart —
# so this should always be checked fresh rather than memorised.
SSH_CONFIG="$HOME/.lima/$VM_NAME/ssh.config"
SSH_HOST=""; SSH_PORT=""; SSH_USER=""; SSH_KEY=""
if [[ -f $SSH_CONFIG ]]; then
    SSH_HOST=$(awk '$1=="Hostname"{print $2; exit}'    "$SSH_CONFIG")
    SSH_PORT=$(awk '$1=="Port"{print $2; exit}'        "$SSH_CONFIG")
    SSH_USER=$(awk '$1=="User"{print $2; exit}'        "$SSH_CONFIG")
    SSH_KEY=$(awk  '$1=="IdentityFile"{print $2; exit}' "$SSH_CONFIG")
fi

info "=== Project ==="
kv "name"      "$(basename "$(pwd)")"
kv "framework" "$FRAMEWORK $VERSION"
kv "php"       "$PHP_VERSION"
kv "db"        "$DB_TYPE $DB_VERSION"
echo

info "=== VM ==="
kv "name"      "$VM_NAME"
kv "status"    "$vm_status"
echo

info "=== SSH (for PhpStorm / IDE remote interpreters) ==="
if [[ -n $SSH_PORT ]]; then
    kv "host"        "$SSH_HOST"
    kv "port"        "$SSH_PORT"
    kv "user"        "$SSH_USER"
    kv "identity"    "$SSH_KEY"
    kv "ssh config"  "$SSH_CONFIG"
else
    kv "(unavailable — VM not created yet)"  ""
fi
# Path mapping doesn't depend on VM state, so show it regardless.
if [[ -n $REMOTE_PROJECT_PATH ]]; then
    if [[ $MODE == "bake" ]]; then
        kv "path mapping"  "$(pwd) → $REMOTE_PROJECT_PATH  (NOT /srv/project — that's the host clone)"
    else
        kv "path mapping"  "$(pwd) → $REMOTE_PROJECT_PATH"
    fi
fi
echo

info "=== Web ==="
kv "wwwroot"   "http://$WWWROOT:$WEB_PORT"
kv "db"        "127.0.0.1:$DB_PORT"
kv "mailpit"   "http://localhost:$MAILPIT_UI (smtp 127.0.0.1:$MAILPIT_SMTP)"
