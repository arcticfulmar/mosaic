#!/usr/bin/env bash
# render-lima: substitute project values into the Lima template and run
# `limactl start`.
#
# Reads cwd's mosaic.yaml + the active framework profile to compute the
# values, sed-substitutes them into MOSAIC_HOME/templates/lima-<framework>.yaml,
# writes the result to ./.devenv/lima.yaml (so it's inspectable post-mortem),
# and starts the VM.
#
# Run from inside a Mosaic project — uses cwd to locate mosaic.yaml and
# to derive the VM name (mosaic-<dirname>).

set -euo pipefail
. "$(dirname "$0")/lib.sh"

require_project
command -v yq      >/dev/null 2>&1 || die "yq not found (brew install yq)"
command -v limactl >/dev/null 2>&1 || die "limactl not found (brew install lima)"

HOME_DIR=$(mosaic_home)
PROJECT_DIR=$(pwd)
VM_NAME=$(project_vm_name)

# --- read project values -----------------------------------------------------

FRAMEWORK=$(project_yaml_get framework)
VERSION=$(project_yaml_get version)
PHP_VERSION=$(project_yaml_get php.version)
WEB_PORT=$(project_yaml_get ports.web)
DB_PORT=$(project_yaml_get ports.db)
MAILPIT_UI_PORT=$(project_yaml_get ports.mailpit_ui)
MAILPIT_SMTP_PORT=$(project_yaml_get ports.mailpit_smtp)
# Vite dev port is Laravel-only; default to web_port - 8000 + 5173
# for projects scaffolded before vite_dev was added to the schema.
VITE_DEV_PORT=$(project_yaml_get_or ports.vite_dev "$((WEB_PORT - 8000 + 5173))")
VM_CPUS=$(project_yaml_get vm.cpus)
VM_MEMORY=$(project_yaml_get vm.memory)
VM_DISK=$(project_yaml_get vm.disk)

# --- pick template by framework ----------------------------------------------
# For Round A only Moodle/Workplace/Totara are wired up (all "bake" mode,
# all share lima-moodle.yaml). Laravel will get its own template in a
# later round.

case $FRAMEWORK in
    moodle|workplace|totara) template_basename=moodle ;;
    laravel)                 template_basename=laravel ;;
    *)                       die "unknown framework: $FRAMEWORK" ;;
esac

template="$HOME_DIR/templates/lima-${template_basename}.yaml"
[[ -f $template ]] || die "missing Lima template: $template"

# --- substitute --------------------------------------------------------------
# Sed-based substitution. The template uses @@NAME@@ markers because
# they don't collide with PHP magic constants (__DIR__, __FILE__, ...)
# that often appear in Mosaic's docs and provision-script comments.

mkdir -p .devenv
rendered=.devenv/lima.yaml

sed \
    -e "s|@@PROJECT_DIR@@|$PROJECT_DIR|g" \
    -e "s|@@MOSAIC_DIR@@|$HOME_DIR|g" \
    -e "s|@@VM_CPUS@@|$VM_CPUS|g" \
    -e "s|@@VM_MEMORY@@|$VM_MEMORY|g" \
    -e "s|@@VM_DISK@@|$VM_DISK|g" \
    -e "s|@@PHP_VERSION@@|$PHP_VERSION|g" \
    -e "s|@@WEB_PORT@@|$WEB_PORT|g" \
    -e "s|@@DB_PORT@@|$DB_PORT|g" \
    -e "s|@@MAILPIT_UI_PORT@@|$MAILPIT_UI_PORT|g" \
    -e "s|@@MAILPIT_SMTP_PORT@@|$MAILPIT_SMTP_PORT|g" \
    -e "s|@@VITE_DEV_PORT@@|$VITE_DEV_PORT|g" \
    "$template" > "$rendered"

# Sanity: catch any placeholder we forgot to substitute (sed-renamed
# but not handled here, etc.). Errors loudly with the offending line so
# the user sees exactly what's missing.
if grep -nE '@@[A-Z_]+@@' "$rendered"; then
    die "Lima template has unsubstituted placeholders (above)"
fi

# Lima parses `provision[].script` blocks as Go templates and silently
# refuses to run them if a `{{...}}` directive references something it
# doesn't know about. The VM still comes up — but un-provisioned, with
# no nginx, no php-fpm, no /etc/lima-guest. That failure mode is hard
# to spot because Lima only emits a warning, not an error. Catch it
# here: any `{{...}}` in the rendered template is suspect and should be
# either a Lima-recognised directive or removed/escaped.
if grep -nE '\{\{' "$rendered"; then
    die "Lima template contains unescaped {{...}} (above) — Lima will fail to template provision scripts. Remove or escape."
fi

info "==> Rendered Lima template → $rendered"

# --- pre-flight + start ------------------------------------------------------
# reap-hostagents handles Lima's zombie-hostagent bug; safe to run even
# when there's nothing to reap. Containerd flags are passed via --set
# rather than the template because Lima 2.1.x has a propagation bug that
# leaves cidata env vars at containerd=on, costing ~15min of
# pam_systemd timeouts on first boot.

"$HOME_DIR/scripts/reap-hostagents" "$VM_NAME"

# Wipe the provisioning sentinel so the heavyweight `mode: system` block
# re-runs on the upcoming boot. This is what makes `mosaic build` the
# right recipe for "apply my mosaic.yaml changes" — daily `mosaic up`
# leaves the sentinel intact and skips re-provisioning (saving ~2min),
# while `mosaic build` opts in to a full re-provision. The sentinel
# itself is written by the provision script at /srv/project/.devenv/
# mosaic-provisioned, which appears here on the host as the path below.
if [[ -f .devenv/mosaic-provisioned ]]; then
    info "==> Removing provisioning sentinel — full re-provision will run on this boot"
    rm -f .devenv/mosaic-provisioned
fi

# `limactl start --name=<vm> <template>` creates+starts a fresh VM
# but errors out if the VM already exists. To make `mosaic build`
# idempotent (rerunning to pick up post-VM changes without nuking),
# detect existing VMs and just start them. Use the rendered template
# only for first creation.
existing_status=$(limactl list --format='{{.Name}} {{.Status}}' 2>/dev/null \
                  | awk -v v="$VM_NAME" '$1==v{print $2}')

case $existing_status in
    "")
        info "==> Creating + starting Lima VM '$VM_NAME' (first run takes a few minutes)"
        limactl start \
            --name="$VM_NAME" \
            --timeout=30m \
            --set='.containerd.user = false' \
            --set='.containerd.system = false' \
            "$rendered"
        ;;
    Running)
        info "==> Lima VM '$VM_NAME' already running, reusing it"
        ;;
    *)
        info "==> Starting existing Lima VM '$VM_NAME' (was: $existing_status)"
        limactl start "$VM_NAME"
        ;;
esac

# Provisioning sanity. Lima silently downgrades a failed provision
# script to a warning — limactl returns 0, and the VM comes up without
# nginx/php-fpm/etc. The marker file `/etc/lima-guest` is the last
# action of the system provision script (see lima-moodle.yaml), so its
# absence is a positive signal that something earlier in the script
# died (typically apt failures).
if ! ssh -F "$HOME/.lima/$VM_NAME/ssh.config" "lima-$VM_NAME" \
        test -f /etc/lima-guest 2>/dev/null; then
    warn "VM came up but provisioning did not complete (no /etc/lima-guest)."
    warn "Inspect the cloud-init log:"
    warn "  ssh -F ~/.lima/$VM_NAME/ssh.config lima-$VM_NAME 'sudo cat /var/log/cloud-init-output.log'"
    die  "aborting build"
fi

# First-boot stop/start cycle: the user-mode provision step
# `systemctl --user enable --now podman.socket` enables the rootless
# podman socket, but the transient user-systemd session that runs
# cloud-init isn't the one subsequent ssh logins land in — so the
# socket is enabled-but-unreachable until the next fresh user session.
# Cycling the VM here gives every later login a clean podman socket.
info "==> Cycling VM so the rootless podman socket is reachable"
limactl stop "$VM_NAME"
limactl start "$VM_NAME"

ok "VM '$VM_NAME' is ready"
