# Mosaic — top-level recipes.
#
# Invoked via the `mosaic` shim (which sets MOSAIC_HOME and execs `just`
# against this file with --working-directory=<user's cwd>). Every recipe
# carries a one-line comment immediately above it — this is what `mosaic`
# (no args) prints for that recipe.
#
# Recipes that operate on a Mosaic project (build, up, down, ...) read
# the project's mosaic.yaml from {{invocation_directory()}} and use it
# to drive what they do. There is no per-project justfile — the whole
# tool surface lives here.
#
# Recipe groups (`[group('...')]`):
#   tool      — works without a project context (new, frameworks, defaults, …)
#   project   — works in any project; framework-agnostic (build, up, down, db, …)
#   moodle    — Moodle / Workplace / Totara only (install-moodle, plugins, …)
#   laravel   — Laravel only (artisan, dev, migrate, …)
#
# The bare `mosaic` listing is filtered to just the relevant groups for
# the cwd's framework — see the `default:` recipe below. Framework-
# specific recipes also call `require-framework.sh` so running e.g.
# `mosaic init-phpunit` inside a Laravel project errors clearly rather
# than half-succeeding against the wrong tree.

home_dir := justfile_directory()

# Print a context-filtered list of recipes.
#
# Out of a project: shows tool-level recipes only (new, frameworks, …).
# In a Moodle/Workplace/Totara project: tool + project + moodle.
# In a Laravel project: tool + project + laravel.
# Recipes are runnable from any context regardless of listing — group
# filtering is cosmetic; framework-specific recipes self-guard via
# require-framework.sh.
default:
    #!/usr/bin/env bash
    set -e
    fw=""
    if [ -f mosaic.yaml ]; then
        fw=$(yq -r '.framework // ""' mosaic.yaml 2>/dev/null || true)
    fi
    # `just --list --group X` prints a `[X]` annotation on its own line
    # at the top of the listing (no flag suppresses it). We render our
    # own headings, so strip just's annotation via grep.
    list_group() {
        local group=$1 heading=$2
        just --justfile "{{home_dir}}/justfile" --list --unsorted --group "$group" \
             --list-heading "$heading"$'\n' \
            | grep -vE '^    \['"$group"'\]$'
    }
    list_group tool 'Tool recipes (no project required):'
    case "$fw" in
        moodle|workplace|totara)
            echo
            list_group project 'Project lifecycle:'
            echo
            list_group moodle  'Moodle / Workplace / Totara:'
            ;;
        laravel)
            echo
            list_group project 'Project lifecycle:'
            echo
            list_group laravel 'Laravel:'
            ;;
        "")
            echo
            echo "(no mosaic.yaml in $(pwd) — project recipes hidden; cd into a project to see them)"
            ;;
        *)
            echo
            echo "(unknown framework '$fw' in mosaic.yaml; project recipes hidden)"
            ;;
    esac

# --- tool: no project context required --------------------------------------

# Scaffold a new Mosaic project under cwd.
[group('tool')]
new NAME *FLAGS='':
    @"{{home_dir}}/scripts/new.sh" "{{NAME}}" {{FLAGS}}
# Examples:
#   mosaic new myproj                                 # interactive
#   mosaic new myproj --framework=moodle --version=4.5
#   mosaic new myproj --framework=laravel --source=git@…:repo.git --no-confirm

# Show the current port-offset (next `mosaic new` writes one above this).
[group('tool')]
port-offset:
    @"{{home_dir}}/scripts/port-offset.sh" show

# List available framework profiles (framework/version combinations).
[group('tool')]
frameworks:
    @find "{{home_dir}}/frameworks" -name '*.yaml' \
        | sed -e "s|{{home_dir}}/frameworks/||" -e 's|\.yaml$||' \
        | sort

# Print resolved cross-project defaults.
[group('tool')]
defaults:
    @cat "{{home_dir}}/defaults.yaml"

# Print MOSAIC_HOME (Mosaic's install location).
[group('tool')]
home:
    @echo "{{home_dir}}"

# --- project: framework-agnostic, run inside a Mosaic project ---------------

# Provision the VM, fetch source, install the framework.
[group('project')]
build:
    @"{{home_dir}}/scripts/build.sh"

# Drop into the VM at /srv/project.
[group('project')]
shell:
    @vm="mosaic-$(basename "$(pwd)")" && limactl shell --workdir=/srv/project "$vm"

# Start the VM, db + mailpit containers, nginx + php-fpm.
[group('project')]
up:
    @vm="mosaic-$(basename "$(pwd)")" && \
        "{{home_dir}}/scripts/reap-hostagents" "$vm" && \
        limactl start "$vm" && \
        php_v=$(yq -r '.php.version' mosaic.yaml) && \
        "{{home_dir}}/scripts/in-vm" "$vm" \
            podman compose -f /srv/project/.devenv/services-compose.yaml up -d --force-recreate && \
        "{{home_dir}}/scripts/in-vm" "$vm" sudo systemctl start "php$php_v-fpm" nginx

# Stop services without losing state. Project files + db data survive.
[group('project')]
down:
    @vm="mosaic-$(basename "$(pwd)")" && \
        php_v=$(yq -r '.php.version' mosaic.yaml) && \
        "{{home_dir}}/scripts/in-vm" "$vm" sudo systemctl stop nginx "php$php_v-fpm" && \
        "{{home_dir}}/scripts/in-vm" "$vm" \
            podman compose -f /srv/project/.devenv/services-compose.yaml down && \
        limactl stop "$vm"

# Reload nginx + php-fpm (after editing nginx.conf or php.ini in .devenv/).
[group('project')]
reload-web:
    @vm="mosaic-$(basename "$(pwd)")" && \
        php_v=$(yq -r '.php.version' mosaic.yaml) && \
        "{{home_dir}}/scripts/in-vm" "$vm" sudo nginx -t && \
        "{{home_dir}}/scripts/in-vm" "$vm" sudo systemctl reload nginx && \
        "{{home_dir}}/scripts/in-vm" "$vm" sudo systemctl restart "php$php_v-fpm"

# Tail nginx + php-fpm logs (Ctrl-C to exit).
[group('project')]
tail-web:
    @vm="mosaic-$(basename "$(pwd)")" && \
        php_v=$(yq -r '.php.version' mosaic.yaml) && \
        "{{home_dir}}/scripts/in-vm" "$vm" sudo journalctl -u nginx -u "php$php_v-fpm" -f

# One-screen summary: project, VM status, ports.
[group('project')]
status:
    @"{{home_dir}}/scripts/status.sh"

# Destroy the VM (project files on disk survive).
[group('project')]
nuke:
    @vm="mosaic-$(basename "$(pwd)")" && \
        (limactl stop "$vm" 2>/dev/null || true) && \
        limactl delete -f "$vm" && \
        "{{home_dir}}/scripts/reap-hostagents" "$vm"

# Diagnose Lima zombie hostagents holding ports against stopped VMs.
[group('project')]
doctor:
    @vm="mosaic-$(basename "$(pwd)")" && "{{home_dir}}/scripts/reap-hostagents" "$vm"

# Drop into the database shell (auto-dispatches on db.type).
[group('project')]
db:
    @"{{home_dir}}/scripts/db.sh"

# Run composer in the active project's tree (framework-aware cwd + user).
[group('project')]
composer +ARGS:
    @"{{home_dir}}/scripts/in-project.sh" composer {{ARGS}}

# Run npm in the active project's tree (framework-aware cwd + user).
[group('project')]
npm +ARGS:
    @"{{home_dir}}/scripts/in-project.sh" npm {{ARGS}}
# For the Vite dev server, use `mosaic dev` (Laravel only) — `mosaic npm
# run dev` runs Vite with its default port and won't be reachable from
# the host.

# Add a hostname → host-gateway entry to this VM's /etc/hosts.
[group('project')]
add-host HOSTNAME:
    @vm="mosaic-$(basename "$(pwd)")" && \
        "{{home_dir}}/scripts/in-vm" "$vm" sudo /srv/mosaic/scripts/vm-host-add {{HOSTNAME}}

# Remove a hostname entry from this VM's /etc/hosts.
[group('project')]
remove-host HOSTNAME:
    @vm="mosaic-$(basename "$(pwd)")" && \
        "{{home_dir}}/scripts/in-vm" "$vm" sudo /srv/mosaic/scripts/vm-host-remove {{HOSTNAME}}

# --- moodle / workplace / totara --------------------------------------------

# Run admin/cli/install.php (creates DB schema + admin user + config.php).
[group('moodle')]
install-moodle:
    @"{{home_dir}}/scripts/require-framework.sh" moodle workplace totara
    @"{{home_dir}}/scripts/install-moodle.sh"

# Run admin/cli/upgrade.php (picks up plugin schemas, bumps versions).
[group('moodle')]
upgrade-moodle:
    @"{{home_dir}}/scripts/require-framework.sh" moodle workplace totara
    @"{{home_dir}}/scripts/upgrade-moodle.sh"

# composer install + phpunit init (set up the test database).
[group('moodle')]
init-phpunit:
    @"{{home_dir}}/scripts/require-framework.sh" moodle workplace totara
    @"{{home_dir}}/scripts/init-phpunit.sh"

# Run a Moodle CLI script. Example: mosaic cli admin/cli/cfg.php --name=debug
[group('moodle')]
cli +ARGS:
    @"{{home_dir}}/scripts/require-framework.sh" moodle workplace totara
    @vm="mosaic-$(basename "$(pwd)")" && \
        fw=$(yq -r '.framework' mosaic.yaml) && \
        "{{home_dir}}/scripts/in-vm" "$vm" sudo -u www-data php "/srv/$fw/{{ARGS}}"

# Purge Moodle caches.
[group('moodle')]
purge:
    @"{{home_dir}}/scripts/require-framework.sh" moodle workplace totara
    @vm="mosaic-$(basename "$(pwd)")" && \
        fw=$(yq -r '.framework' mosaic.yaml) && \
        "{{home_dir}}/scripts/in-vm" "$vm" sudo -u www-data php "/srv/$fw/admin/cli/purge_caches.php"

# Run Moodle cron once.
[group('moodle')]
cron:
    @"{{home_dir}}/scripts/require-framework.sh" moodle workplace totara
    @vm="mosaic-$(basename "$(pwd)")" && \
        fw=$(yq -r '.framework' mosaic.yaml) && \
        "{{home_dir}}/scripts/in-vm" "$vm" sudo -u www-data php "/srv/$fw/admin/cli/cron.php"

# List plugin entries from mosaic.yaml.
[group('moodle')]
plugins:
    @"{{home_dir}}/scripts/require-framework.sh" moodle workplace totara
    @"{{home_dir}}/scripts/plugins.sh"

# Re-apply plugin bind-mounts in the VM (after editing mosaic.yaml's plugins). Doesn't re-clone — use `mosaic build` for that.
[group('moodle')]
apply-plugins:
    @"{{home_dir}}/scripts/require-framework.sh" moodle workplace totara
    @vm="mosaic-$(basename "$(pwd)")" && \
        "{{home_dir}}/scripts/in-vm" "$vm" sudo systemctl restart apply-plugins.service

# --- laravel ----------------------------------------------------------------
# All Laravel recipes run inside the project root (= /srv/project in
# the VM). The host project is virtiofs-mounted there; the Laravel app
# sits at the root of the mount (no subdirectory).

# Run an artisan subcommand (e.g. `mosaic artisan migrate:status`).
[group('laravel')]
artisan +ARGS:
    @"{{home_dir}}/scripts/require-framework.sh" laravel
    @vm="mosaic-$(basename "$(pwd)")" && \
        "{{home_dir}}/scripts/in-vm" "$vm" sh -c "cd /srv/project && php artisan {{ARGS}}"

# Open `php artisan tinker`.
[group('laravel')]
tinker:
    @"{{home_dir}}/scripts/require-framework.sh" laravel
    @vm="mosaic-$(basename "$(pwd)")" && \
        "{{home_dir}}/scripts/in-vm" "$vm" sh -c "cd /srv/project && php artisan tinker"

# Process the queue (Ctrl-C to exit).
[group('laravel')]
queue:
    @"{{home_dir}}/scripts/require-framework.sh" laravel
    @vm="mosaic-$(basename "$(pwd)")" && \
        "{{home_dir}}/scripts/in-vm" "$vm" sh -c "cd /srv/project && php artisan queue:work"

# Run scheduled tasks once (the equivalent of one cron tick).
[group('laravel')]
schedule-run:
    @"{{home_dir}}/scripts/require-framework.sh" laravel
    @vm="mosaic-$(basename "$(pwd)")" && \
        "{{home_dir}}/scripts/in-vm" "$vm" sh -c "cd /srv/project && php artisan schedule:run"

# Run pending migrations.
[group('laravel')]
migrate:
    @"{{home_dir}}/scripts/require-framework.sh" laravel
    @vm="mosaic-$(basename "$(pwd)")" && \
        "{{home_dir}}/scripts/in-vm" "$vm" sh -c "cd /srv/project && php artisan migrate"

# Drop everything and re-migrate from scratch (optionally with --seed).
[group('laravel')]
migrate-fresh *FLAGS:
    @"{{home_dir}}/scripts/require-framework.sh" laravel
    @vm="mosaic-$(basename "$(pwd)")" && \
        "{{home_dir}}/scripts/in-vm" "$vm" sh -c "cd /srv/project && php artisan migrate:fresh {{FLAGS}}"

# Run the Laravel test suite (`php artisan test`).
[group('laravel')]
test +ARGS='':
    @"{{home_dir}}/scripts/require-framework.sh" laravel
    @vm="mosaic-$(basename "$(pwd)")" && \
        "{{home_dir}}/scripts/in-vm" "$vm" sh -c "cd /srv/project && php artisan test {{ARGS}}"

# Run pestphp directly (`./vendor/bin/pest`).
[group('laravel')]
pest +ARGS='':
    @"{{home_dir}}/scripts/require-framework.sh" laravel
    @vm="mosaic-$(basename "$(pwd)")" && \
        "{{home_dir}}/scripts/in-vm" "$vm" sh -c "cd /srv/project && ./vendor/bin/pest {{ARGS}}"

# Run the dev frontend bundler (Vite). Ctrl-C to exit.
[group('laravel')]
dev:
    @"{{home_dir}}/scripts/require-framework.sh" laravel
    @vm="mosaic-$(basename "$(pwd)")" && \
        port=$(yq -r '.ports.vite_dev // 5173' mosaic.yaml) && \
        "{{home_dir}}/scripts/in-vm" "$vm" sh -c "cd /srv/project && npm run dev -- --host localhost --port $port"
# `--host localhost` (NOT bare `--host`): bare `--host` makes Vite bind on
# all interfaces incl. IPv6 `[::]`, and Laravel's Vite plugin then writes
# `http://[::]:<port>` into public/hot. Browsers (Safari, content-blockers)
# refuse to load resources from the IPv6 unspecified address. Pinning the
# bind to `localhost` makes the hot-file URL `http://localhost:<port>`,
# which every browser will accept. Lima's port forward catches the
# 127.0.0.1 binding fine.
