#!/usr/bin/env bash
# build: provision the VM, run the flavour's fetch + install hooks,
# light up nginx + php-fpm + db so the user can browse to it.
#
# Core sequences the lifecycle; flavours own the framework-specific
# steps via hooks (docs/flavour-architecture.md). There is no
# mode/framework branching here — build.sh runs the same sequence for
# every flavour:
#
#   1. resolve         mosaic.yaml + profile → config JSON
#   2. render + start  VM (render-lima.sh; idempotent)
#   3. hook: fetch     populate the base tree (no db yet)
#   4. render          service configs (nginx, php.ini, compose)
#   5. services        podman compose up (db + mailpit)
#   6. hook: install   framework installer (db available)
#   7. restart web     nginx + php-fpm re-read freshly rendered config
#
# v1's ordering difference (Laravel fetched after services) was
# incidental — nothing in either flavour's fetch needs the db, and
# everything that does lives in install.
#
# At the end the user can `curl http://<wwwroot>:<web_port>/`.
# Moodle: log in as admin/Password1!.

set -euo pipefail
. "$(dirname "$0")/lib.sh"

require_project
HOME_DIR=$(mosaic_home)

# --- resolve ---------------------------------------------------------------
CONFIG_JSON=$("$HOME_DIR/scripts/resolve.sh")

cfg() { printf '%s' "$CONFIG_JSON" | yq -r "$1"; }

FLAVOUR=$(cfg .flavour)
MODE=$(cfg .mode)
VM_NAME=$(cfg .project.vm)
PHP_VERSION=$(cfg .php.version)
WEB_PORT=$(cfg .ports.web)
WWWROOT=$(cfg .wwwroot)

# Run a flavour hook: config JSON on stdin, progress on the terminal
# (hooks route it to stderr), JSON result on stdout — captured and
# currently unused; later lifecycle steps will consume it. A missing
# hook is fine (a flavour without one has nothing to do at that step).
run_hook() {
    local name=$1
    local exe="$HOME_DIR/flavours/$FLAVOUR/hooks/$name"
    [[ -e $exe ]] || return 0
    [[ -x $exe ]] || die "hook exists but is not executable: $exe"
    local out
    out=$(printf '%s' "$CONFIG_JSON" | "$exe")
}

info "==> mosaic build"
say  "    project:   $(cfg .project.name)"
say  "    framework: $(cfg .framework) $(cfg .version)"
say  "    flavour:   $FLAVOUR"
say  "    vm:        $VM_NAME"
echo

# --- VM up -------------------------------------------------------------------
# Idempotent — render-lima.sh's `limactl start` is a no-op if the VM
# already exists and is healthy.
"$HOME_DIR/scripts/render-lima.sh"
echo

# --- fetch ---------------------------------------------------------------
# Destructive for bake-mode flavours (the hook wipes and re-clones the
# framework tree); each hook documents its own guards.
run_hook fetch
echo

# --- render service configs ----------------------------------------------
"$HOME_DIR/scripts/render-services.sh"
echo

# --- podman services (db + mailpit) ----------------------------------------
info "==> Starting podman services (db, mailpit)"
"$HOME_DIR/scripts/in-vm" "$VM_NAME" \
    podman compose -f /srv/project/.mosaic/services-compose.yaml up -d
echo

# --- install ---------------------------------------------------------------
run_hook install
echo

# --- (re)start nginx + php-fpm ---------------------------------------------
# render-services.sh just rewrote .mosaic/nginx.conf. nginx may already
# be running bound against the PREVIOUS config (e.g. a stale port when
# rebuilding a re-ported project); `start` would be a no-op and strand
# it there, so `restart` to force a re-read + rebind.
info "==> Restarting nginx + php-fpm"
"$HOME_DIR/scripts/in-vm" "$VM_NAME" \
    sudo systemctl restart "php${PHP_VERSION}-fpm" nginx
echo

ok "Build complete"
echo
info "Open it:"
say  "  http://${WWWROOT}:${WEB_PORT}/"
if [[ $MODE == "bake" ]]; then
    say  "  admin / Password1!"
fi
echo
info "Next:"
say  "  mosaic status        # one-screen summary"
if [[ $MODE == "bake" ]]; then
    say  "  mosaic init-phpunit  # set up the phpunit test database"
fi
say  "  mosaic shell         # drop into the VM at /srv/project"
say  "  mosaic down          # stop services without losing state"
