# Mosaic core recipes — framework-agnostic and backend-agnostic.
#
# Never invoked directly: bin/mosaic generates a root justfile (in the
# project's .mosaic/, or ~/.cache/mosaic/ outside a project) that
# imports this file plus at most one flavours/<flavour>/recipes.just.
# The generated root carries `set positional-arguments`, so argv
# boundaries survive into recipes exactly as in v1 — see the v1
# justfile header for the quoting rationale.
#
# Anything that touches the guest goes through scripts/in-vm (exec) or
# the active backend driver (lifecycle) — backends/README.md. Recipes
# never name limactl, podman or distrobox.
#
# Recipe groups are cosmetic labels for the listing:
#   tool      — works without a project context
#   project   — needs a mosaic.yaml; framework-agnostic
# Flavour recipes bring their own group (moodle, laravel). There are no
# runtime framework guards anywhere: a recipe that isn't imported
# doesn't exist, which is the whole point of the generated justfile.

home_dir := env('MOSAIC_HOME')

# Resolve the active backend's driver. Each recipe re-evaluates it so a
# `backend:` edit in mosaic.yaml takes effect immediately.
driver := home_dir + "/scripts/backend-driver"

# Print available recipes (tool-only outside a project). Underscore-
# prefixed so it stays out of the listing; the generated root justfile
# points its _default at this.
_list:
    #!/usr/bin/env bash
    set -e
    if [ -f mosaic.yaml ]; then
        just --justfile "{{justfile()}}" --list --unsorted
    else
        just --justfile "{{justfile()}}" --list --unsorted \
             --group tool --list-heading 'Tool recipes (no project required):'$'\n' \
            | grep -vE '^    \[tool\]$'
        echo
        echo "(not inside a Mosaic project — cd into one, or start with 'mosaic new <name>')"
    fi

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

# Check host prerequisites for the active backend (and the project, if in one).
[group('tool')]
doctor:
    @"{{driver}}" doctor

# --- project: framework-agnostic, run inside a Mosaic project ---------------

# Provision the guest, fetch source, install the framework.
[group('project')]
build:
    @"{{home_dir}}/scripts/build.sh"

# Drop into the guest at /srv/project.
[group('project')]
shell:
    @"{{driver}}" shell

# Start the guest, db + mailpit, nginx + php-fpm.
[group('project')]
up:
    @"{{home_dir}}/scripts/up.sh"

# Stop services without losing state. Project files + db data survive.
[group('project')]
down:
    @"{{home_dir}}/scripts/down.sh"

# Reload nginx + php-fpm (after editing nginx.conf or php.ini in .mosaic/).
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

# One-screen summary: project, guest status, ports, IDE wiring.
[group('project')]
status:
    @"{{home_dir}}/scripts/status.sh"

# Destroy the guest and its db data (project files on disk survive).
[group('project')]
nuke:
    @"{{driver}}" destroy

# Print the resolved project config as JSON (what hooks and drivers see).
[group('project')]
config:
    @"{{home_dir}}/scripts/resolve.sh"

# Drop into the database shell (auto-dispatches on db.type).
[group('project')]
db:
    @"{{home_dir}}/scripts/db.sh"

# Run composer in the active project's tree (framework-aware cwd + user).
[group('project')]
composer +ARGS:
    @"{{home_dir}}/scripts/in-project.sh" composer "$@"

# Run npm in the active project's tree (framework-aware cwd + user).
[group('project')]
npm +ARGS:
    @"{{home_dir}}/scripts/in-project.sh" npm "$@"
# For the Vite dev server, use `mosaic dev` (Laravel only) — `mosaic npm
# run dev` runs Vite with its default port and won't be reachable from
# the host.
# Arguments forward verbatim (`--` and quoting included), so npm's own
# conventions apply: flags meant for the underlying script need npm's
# `--`, e.g. `mosaic npm run test:filter -- --test-name-pattern=x 'glob'`.

# Make HOSTNAME resolve to the host from inside the guest (custom wwwroot).
[group('project')]
add-host HOSTNAME:
    @"{{driver}}" add-host "$1"

# Undo add-host.
[group('project')]
remove-host HOSTNAME:
    @"{{driver}}" remove-host "$1"
