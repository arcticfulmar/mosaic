#!/usr/bin/env bash
# build: bring up the guest, run the flavour's fetch + install hooks,
# light up nginx + php-fpm + db so the user can browse to it.
#
# Core sequences the lifecycle; flavours own the framework-specific
# steps via hooks (docs/flavour-architecture.md); the backend driver
# owns the runtime (backends/README.md). No mode, framework or backend
# branching here — build.sh runs the same sequence everywhere:
#
#   1. resolve         mosaic.yaml + profile + backend facts → config JSON
#   2. driver create   guest up + provisioned (idempotent)
#   3. hook: fetch     populate the base tree (no db yet)
#   4. render          service configs (nginx, php.ini, compose)
#   5. services        db + mailpit stack up
#   6. hook: install   framework installer (db available)
#   7. restart web     nginx + php-fpm re-read freshly rendered config
#
# At the end the user can `curl http://<wwwroot>:<web_port>/`.
# Moodle: log in as admin/Password1!.

set -euo pipefail
. "$(dirname "$0")/lib.sh"

require_project
HOME_DIR=$(mosaic_home)

# --- resolve ---------------------------------------------------------------
load_config

FLAVOUR=$(cfg .flavour)
MODE=$(cfg .mode)
VM_NAME=$(cfg .project.vm)
PHP_VERSION=$(cfg .php.version)
WEB_PORT=$(cfg .ports.web)
WWWROOT=$(cfg .wwwroot)
BACKEND=$(cfg .backend.name)
DRIVER=$(backend_driver "$BACKEND") || exit 1

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
say  "    backend:   $BACKEND"
say  "    guest:     $VM_NAME"
echo

# --- guest up ----------------------------------------------------------------
"$DRIVER" create
echo

# --- fetch ---------------------------------------------------------------
# Destructive for bake-mode flavours on virtiofs backends (the hook
# wipes and re-clones the guest tree); each hook documents its guards.
run_hook fetch
echo

# --- render service configs ----------------------------------------------
"$HOME_DIR/scripts/render-services.sh"
echo

# --- services (db + mailpit) -----------------------------------------------
info "==> Starting services (db, mailpit)"
"$DRIVER" services up
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
say  "  mosaic shell         # drop into the guest at /srv/project"
say  "  mosaic down          # stop services without losing state"
