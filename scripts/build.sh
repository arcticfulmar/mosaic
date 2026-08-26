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
#   3. ensure php      install/select the target's PHP inside the VM
#   4. hook: fetch     populate the base tree (no db yet)
#   5. render          service configs (nginx, php.ini, compose)
#   6. services        podman compose up (db + mailpit)
#   7. hook: install   framework installer (db available)
#   8. restart web     nginx + php-fpm re-read freshly rendered config
#   9. record          .mosaic/installed.json = what is now installed
#
# v1's ordering difference (Laravel fetched after services) was
# incidental — nothing in either flavour's fetch needs the db, and
# everything that does lives in install.
#
# At the end the user can `curl http://<wwwroot>:<web_port>/`.
# Moodle: log in as admin/Password1!.
#
# On a multi-target project this builds the ACTIVE target (see lib.sh).
# Replacing one target with another is `mosaic switch`, not this — a
# build alone would bake the new framework over the old install without
# dropping its db or removing its plugin clones, so we refuse it below.

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
TARGET=$(cfg .target)

INSTALLED_JSON=.mosaic/installed.json

# run_hook lives in lib.sh (teardown.sh needs the same dispatch); the
# hook's JSON result is discarded here until a lifecycle step consumes
# it. Its progress output goes to stderr and reaches the user directly.
hook() {
    run_hook "$FLAVOUR" "$1" "$CONFIG_JSON" > /dev/null
}

# --- guard: a build is not a switch ------------------------------------------
# Building target B over an installed target A would wipe A's framework
# tree (the fetch hook does that) and drop the db (the install hook does
# that) — but leave A's plugin clones sitting at the project root, where
# the graft would then bind whichever of them share a path with B's.
# Half-torn-down, silently. `mosaic switch` exists to do this properly.
if [[ -f $INSTALLED_JSON ]]; then
    installed_target=$(yq -p json -r '.target // ""' "$INSTALLED_JSON")
    if [[ $installed_target != "$TARGET" ]]; then
        die "target '$installed_target' is currently installed, but this would build '$TARGET'
       run 'mosaic switch $TARGET' instead — it tears '$installed_target' down first
       (its plugin clones, framework tree, data and database), then builds '$TARGET'"
    fi
fi

info "==> mosaic build"
say  "    project:   $(cfg .project.name)"
say  "    framework: $(cfg .framework) $(cfg .version)"
[[ -n $TARGET ]] && say  "    target:    $TARGET"
say  "    flavour:   $FLAVOUR"
say  "    vm:        $VM_NAME"
echo

# --- VM up -------------------------------------------------------------------
# Idempotent — render-lima.sh's `limactl start` is a no-op if the VM
# already exists and is healthy.
"$HOME_DIR/scripts/render-lima.sh"
echo

# --- PHP + VM-side tools ------------------------------------------------------
# Before fetch, because everything after this point wants the target's
# PHP already in place: the install hook runs composer and `php
# admin/cli/install.php`, and the graft's try-restart addresses
# php<version>-fpm by name.
#
# Streamed over stdin rather than run from the /srv/mosaic mount: that
# mount goes stale when brew upgrades Mosaic under a running VM
# (virtiofs resolves the opt symlink at boot), and this is exactly the
# script we cannot afford to run an old copy of. Piped stdin also
# defeats in-vm's `-t`, which is what we want for a non-interactive run.
info "==> Ensuring PHP $PHP_VERSION in the VM"
"$HOME_DIR/scripts/in-vm" "$VM_NAME" sudo bash -s -- "$PHP_VERSION" \
    < "$HOME_DIR/scripts/vm-ensure-php"
"$HOME_DIR/scripts/vm-sync-tools" "$VM_NAME"
echo

# --- fetch ---------------------------------------------------------------
# Destructive for bake-mode flavours (the hook wipes and re-clones the
# framework tree); each hook documents its own guards.
hook fetch
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
hook install
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

# --- record the install --------------------------------------------------
# The resolved config of the last SUCCESSFUL build, written last so its
# presence means "this really is what's on disk". `mosaic teardown` reads
# it instead of re-resolving mosaic.yaml: it must clean up the framework,
# php version and plugin set that were actually installed, even if the
# manifest has been edited — or the target renamed — since. `mosaic
# switch` deletes it (via teardown) before building the next target, so
# an interrupted switch is re-runnable and never tears down twice.
#
# Written via a temp file + mv: a half-written installed.json would be
# worse than none at all.
mkdir -p .mosaic
tmp_installed=$(mktemp .mosaic/.installed.XXXXXX)
printf '%s\n' "$CONFIG_JSON" > "$tmp_installed"
mv "$tmp_installed" "$INSTALLED_JSON"

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
if [[ -n $TARGET ]]; then
    say  "  mosaic targets       # what else this project can build"
fi
