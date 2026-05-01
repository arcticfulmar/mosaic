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

vm_status=$(limactl list --format='{{.Name}} {{.Status}}' 2>/dev/null \
            | awk -v v="$VM_NAME" '$1==v{print $2}')
[[ -z $vm_status ]] && vm_status="(not created)"

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

info "=== Web ==="
kv "wwwroot"   "http://$WWWROOT:$WEB_PORT"
kv "db"        "127.0.0.1:$DB_PORT"
kv "mailpit"   "http://localhost:$MAILPIT_UI (smtp 127.0.0.1:$MAILPIT_SMTP)"
