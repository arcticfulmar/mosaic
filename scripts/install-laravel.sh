#!/usr/bin/env bash
# install-laravel: clone the project repo to the host, install
# composer + npm dependencies inside the VM, and bring the app to a
# servable state (.env present, APP_KEY generated, optionally migrate).
#
# Run from inside a Mosaic project. Assumes:
#   - VM is running, provisioned (Round A — composer + nodejs + nginx
#     + php-fpm available; nginx vhost symlinks live at
#     /etc/nginx/sites-enabled/laravel.conf → /srv/project/.devenv/nginx.conf).
#   - render-services.sh has produced .devenv/services-compose.yaml
#     and `mosaic up`'s podman start has put the db online.
#
# Idempotent on re-run. Won't clobber an existing local clone
# (rebuild's responsibility — see build.sh's repo-state check).

set -euo pipefail
. "$(dirname "$0")/lib.sh"

require_project
HOME_DIR=$(mosaic_home)
PROJECT_DIR=$(pwd)
VM_NAME=$(project_vm_name)
PROJECT_NAME=$(basename "$(pwd)")

FRAMEWORK=$(project_yaml_get framework)
[[ $FRAMEWORK == "laravel" ]] || die "install-laravel: framework $FRAMEWORK not supported"

PROJECT_SOURCE=$(project_yaml_get project.source)
PROJECT_BRANCH=$(project_yaml_get_or project.branch main)
PROJECT_DEST=$(project_yaml_get project.destination)

DB_TYPE=$(project_yaml_get db.type)
DB_PORT=$(project_yaml_get ports.db)
WEB_PORT=$(project_yaml_get ports.web)
WWWROOT=$(project_yaml_get_or wwwroot localhost)

HOST_PROJECT="$PROJECT_DIR/$PROJECT_DEST"
# In mount mode there's no separate baked tree — the host project is
# mounted as /srv/project, so the Laravel app lives at
# /srv/project/<destination> from the VM's perspective. Different
# from bake mode (Moodle's /srv/moodle is a VM-side bake).
VM_PROJECT="/srv/project/$PROJECT_DEST"

# --- clone the project repo on the host ------------------------------------
# Mount mode: a single bind-mount of the host clone covers everything,
# so we don't need a parallel VM-side clone (unlike bake mode).

info "==> Cloning $PROJECT_SOURCE @ $PROJECT_BRANCH → ./$PROJECT_DEST"
rm -rf "$HOST_PROJECT"
GIT_TERMINAL_PROMPT=0 \
GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=accept-new' \
    git clone --depth 1 --branch "$PROJECT_BRANCH" "$PROJECT_SOURCE" "$HOST_PROJECT"

# --- composer install + npm install (in VM) --------------------------------
# Run as the lima user (non-root) so vendor/ and node_modules/ end up
# with sane host-visible permissions via virtiofs UID mapping. Composer
# and npm are happy to run in user mode.

info "==> composer install"
"$HOME_DIR/scripts/in-vm" "$VM_NAME" \
    sh -c "cd '$VM_PROJECT' && composer install --no-interaction --prefer-dist"

if "$HOME_DIR/scripts/in-vm" "$VM_NAME" test -f "$VM_PROJECT/package.json"; then
    # `npm install` is non-fatal: unlike composer (which provides
    # vendor/autoload.php — without it the framework literally can't
    # boot), npm only handles frontend assets. A failed `npm install`
    # most commonly means a missing auth token for a private registry
    # or package (e.g. a GitHub Packages dep needing NPM_TOKEN in
    # .env / ~/.npmrc). The PHP side of the app still serves, the
    # user can edit .env, and `mosaic npm install` retries cleanly
    # once the token is in place — so warn loudly and continue rather
    # than nuking the whole build.
    info "==> npm install"
    npm_install_ok=1
    "$HOME_DIR/scripts/in-vm" "$VM_NAME" \
        sh -c "cd '$VM_PROJECT' && npm install" || {
            npm_install_ok=0
            warn "npm install failed — frontend assets won't be available until resolved."
            warn "Common cause: missing auth token for a private package."
            warn "Fix and retry with: mosaic npm install"
        }

    # Run `npm run build` if defined — needed for Laravel apps using
    # Vite (the standard since Laravel 9.x). Without it the welcome
    # page returns 500 "Vite manifest not found". For day-to-day dev
    # the user runs `mosaic dev` (vite-dev-server, hot reload); the
    # one-shot build here just makes the first page-load work.
    #
    # Skip entirely if npm install failed — node_modules is missing
    # or partial, so build would fail noisily on missing binaries
    # rather than telling the user anything they don't already know.
    if [[ $npm_install_ok == 1 ]] && \
       "$HOME_DIR/scripts/in-vm" "$VM_NAME" \
           sh -c "cd '$VM_PROJECT' && npm pkg get scripts.build" 2>/dev/null \
           | grep -qv '^{}$'; then
        info "==> npm run build (initial Vite asset compile)"
        "$HOME_DIR/scripts/in-vm" "$VM_NAME" \
            sh -c "cd '$VM_PROJECT' && npm run build" || \
            warn "npm run build failed — run 'mosaic dev' or 'mosaic npm run build' to retry"
    fi
else
    info "==> no package.json; skipping npm install"
fi

# --- .env + APP_KEY ---------------------------------------------------------
# Laravel's typical "post composer create-project" steps. If the
# project ships a .env.example (most do), copy it; otherwise leave
# .env management to the user.

if "$HOME_DIR/scripts/in-vm" "$VM_NAME" test -f "$VM_PROJECT/.env.example"; then
    if ! "$HOME_DIR/scripts/in-vm" "$VM_NAME" test -f "$VM_PROJECT/.env"; then
        info "==> Copying .env.example to .env"
        "$HOME_DIR/scripts/in-vm" "$VM_NAME" \
            cp "$VM_PROJECT/.env.example" "$VM_PROJECT/.env"
    fi

    # Wire DB connection settings into .env so the app talks to our
    # podman container without the user editing anything.
    #
    # Modern Laravel skeletons ship a minimal .env.example (just
    # `DB_CONNECTION=sqlite`, no DB_HOST/PORT/etc.) — the other
    # connection details are commented out or absent, leaving them
    # to defaults. A naive `sed s|^DB_PORT=.*|...|` is then a no-op
    # and the migration can't reach our podman container.
    #
    # set-or-append handles both cases: rewrite the line if present,
    # append it if not. Idempotent on rebuild.
    info "==> Wiring DB settings into .env"
    "$HOME_DIR/scripts/in-vm" "$VM_NAME" sh -c "
        env_file='$VM_PROJECT/.env'
        env_set() {
            key=\$1; value=\$2
            if grep -qE \"^\${key}=\" \"\$env_file\"; then
                sed -i \"s|^\${key}=.*|\${key}=\${value}|\" \"\$env_file\"
            else
                printf '%s=%s\\n' \"\$key\" \"\$value\" >> \"\$env_file\"
            fi
        }
        env_set DB_CONNECTION '$DB_TYPE'
        env_set DB_HOST 127.0.0.1
        env_set DB_PORT '$DB_PORT'
        env_set DB_DATABASE app
        env_set DB_USERNAME app
        env_set DB_PASSWORD app
        env_set APP_URL 'http://$WWWROOT:$WEB_PORT'
    "

    # APP_KEY: only generate if missing/empty, so re-runs don't
    # invalidate sessions.
    if ! "$HOME_DIR/scripts/in-vm" "$VM_NAME" \
            sh -c "grep -qE '^APP_KEY=base64:.+' '$VM_PROJECT/.env'"; then
        info "==> php artisan key:generate"
        "$HOME_DIR/scripts/in-vm" "$VM_NAME" \
            sh -c "cd '$VM_PROJECT' && php artisan key:generate --force"
    fi
fi

# --- artisan migrate --------------------------------------------------------
# Only if migrations exist; the laravel/laravel skeleton ships some
# (cache, sessions, jobs, users), so the test path will hit this.
# `--force` is required outside of the local environment by some
# Laravel versions; harmless when local.

if "$HOME_DIR/scripts/in-vm" "$VM_NAME" test -d "$VM_PROJECT/database/migrations"; then
    info "==> php artisan migrate"
    "$HOME_DIR/scripts/in-vm" "$VM_NAME" \
        sh -c "cd '$VM_PROJECT' && php artisan migrate --force" || \
        warn "migrate failed — leaving the rest of the build to continue; check 'mosaic shell' to investigate"
fi

ok "Laravel app installed at ./$PROJECT_DEST"
