# Mosaic core recipes — framework-agnostic.
#
# Never invoked directly: bin/mosaic generates a root justfile (in the
# project's .mosaic/, or ~/.cache/mosaic/ outside a project) that
# imports this file plus at most one flavours/<flavour>/recipes.just.
# The generated root carries `set positional-arguments`, so argv
# boundaries survive into recipes exactly as in v1 — see the v1
# justfile header for the quoting rationale.
#
# Recipe groups are cosmetic labels for the listing:
#   tool      — works without a project context
#   project   — needs a mosaic.yaml; framework-agnostic
# Flavour recipes bring their own group (moodle, laravel). There are no
# runtime framework guards anywhere: a recipe that isn't imported
# doesn't exist, which is the whole point of the generated justfile.

home_dir := env('MOSAIC_HOME')

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
