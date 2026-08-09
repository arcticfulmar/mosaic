#!/usr/bin/env bash
# install-laravel: fetch the project (clone an existing repo OR scaffold
# a fresh laravel/laravel app when no source is configured), install
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
# The Laravel app lives at the project root (= /srv/project in the VM),
# alongside mosaic.yaml and .devenv/. Cloning/scaffolding into a non-
# empty directory requires a tempdir + move-into-root dance since
# neither `git clone` nor `composer create-project` accepts a populated
# target.
#
# Idempotent on re-run: presence of composer.json at the project root
# means the app is already laid down; the fetch step is skipped and
# subsequent steps (composer install, .env wiring, migrate) repeat
# cleanly.

set -euo pipefail
. "$(dirname "$0")/lib.sh"

require_project
HOME_DIR=$(mosaic_home)
PROJECT_DIR=$(pwd)
VM_NAME=$(project_vm_name)
PROJECT_NAME=$(basename "$(pwd)")

FRAMEWORK=$(project_yaml_get framework)
[[ $FRAMEWORK == "laravel" ]] || die "install-laravel: framework $FRAMEWORK not supported"

PROJECT_SOURCE=$(project_yaml_get_or project.source "")
PROJECT_BRANCH=$(project_yaml_get_or project.branch main)

DB_TYPE=$(project_yaml_get db.type)
DB_PORT=$(project_yaml_get ports.db)
WEB_PORT=$(project_yaml_get ports.web)
WWWROOT=$(project_yaml_get_or wwwroot localhost)

# Project root === Laravel app root on both sides of the mount:
#   host: $PROJECT_DIR              (cwd)
#   VM:   /srv/project              (virtiofs of $PROJECT_DIR, writable)
VM_PROJECT="/srv/project"

# --- fetch the project ------------------------------------------------------
# Two paths depending on whether the user supplied a source repo at
# `mosaic new` time:
#   (a) source set    → git clone on the host (host has the user's ssh
#                       keys for private repos).
#   (b) source empty  → composer create-project inside the VM (no host
#                       composer requirement — composer is guaranteed
#                       installed in the VM via provisioning).
#
# Either way the framework's CLI refuses to write into a non-empty
# directory, and the project root already contains mosaic.yaml +
# .devenv/. So fetch into a scratch sibling dir at the project root
# (host-visible at ./.mosaic-scaffold.<pid>, VM-visible at
# /srv/project/.mosaic-scaffold.<pid>) and atomically move the result
# into the project root afterwards.

if [[ -f "$PROJECT_DIR/composer.json" ]]; then
    info "==> Laravel app already laid down (found composer.json); skipping fetch"
else
    SCAFFOLD_NAME=".mosaic-scaffold.$$"
    HOST_SCAFFOLD="$PROJECT_DIR/$SCAFFOLD_NAME"
    VM_SCAFFOLD="/srv/project/$SCAFFOLD_NAME"

    cleanup_scaffold() {
        if [[ -d "$HOST_SCAFFOLD" ]]; then
            rm -rf "$HOST_SCAFFOLD"
        fi
    }
    trap cleanup_scaffold EXIT

    if [[ -n $PROJECT_SOURCE ]]; then
        info "==> Cloning $PROJECT_SOURCE @ $PROJECT_BRANCH"
        GIT_TERMINAL_PROMPT=0 \
        GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=accept-new' \
            git clone --depth 1 --branch "$PROJECT_BRANCH" "$PROJECT_SOURCE" "$HOST_SCAFFOLD"
    else
        info "==> Scaffolding fresh Laravel app (composer create-project laravel/laravel)"
        "$HOME_DIR/scripts/in-vm" "$VM_NAME" \
            sh -c "composer create-project --prefer-dist --no-interaction laravel/laravel '$VM_SCAFFOLD'"
    fi

    # Pre-flight conflict scan. With dotglob the pattern matches dotfiles
    # like .env.example and .gitignore; nullglob protects the empty-
    # scaffold case (shouldn't happen post-clone, but cheap to guard).
    info "==> Moving scaffold contents into project root"
    shopt -s dotglob nullglob
    conflicts=()
    for entry in "$HOST_SCAFFOLD"/*; do
        base=$(basename "$entry")
        if [[ -e "$PROJECT_DIR/$base" ]]; then
            conflicts+=("$base")
        fi
    done

    if (( ${#conflicts[@]} > 0 )); then
        shopt -u dotglob nullglob
        die "scaffold would clobber existing files at project root: ${conflicts[*]}"
    fi

    mv "$HOST_SCAFFOLD"/* "$PROJECT_DIR/"
    shopt -u dotglob nullglob
    # (trap removes the now-empty $HOST_SCAFFOLD on exit)
fi

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

ok "Laravel app installed at $PROJECT_DIR"
