# Mosaic — top-level recipes.
#
# Invoked via the `mosaic` shim (which sets MOSAIC_HOME and execs `just`
# against this file with --working-directory=<user's cwd>). Every recipe
# carries a one-line comment immediately above it — this is what `mosaic`
# (no args) prints for that recipe. Longer explanation, when needed,
# follows the recipe body.
#
# Recipes that operate on a Mosaic project (build, up, down, ...) read
# the project's mosaic.yaml from {{invocation_directory()}} and use it
# to drive what they do. There is no per-project justfile — the whole
# tool surface lives here.

# Compute the Lima VM name for the project rooted at cwd. Used by every
# recipe that talks to a VM. Computed lazily per recipe (via shell `$()`)
# so changing directory between invocations works correctly.
home_dir := justfile_directory()

# Print this list of recipes.
default:
    @just --list --unsorted --justfile "{{home_dir}}/justfile"

# --- scaffolding & build ----------------------------------------------------

# Scaffold a new Mosaic project under cwd.
new NAME *FLAGS='':
    @"{{home_dir}}/scripts/new.sh" "{{NAME}}" {{FLAGS}}
# Examples:
#   mosaic new myproj                                 # interactive
#   mosaic new myproj --framework=moodle --version=4.5
#   mosaic new myproj --framework=laravel --source=git@…:repo.git --no-confirm

# Provision the VM, fetch source, install the framework.
build:
    @"{{home_dir}}/scripts/build.sh"

# --- lifecycle (act on the project in cwd) ----------------------------------

# Drop into the VM at /srv/project.
shell:
    @vm="mosaic-$(basename "$(pwd)")" && limactl shell --workdir=/srv/project "$vm"

# Start the VM, db + mailpit containers, nginx + php-fpm.
up:
    @vm="mosaic-$(basename "$(pwd)")" && \
        "{{home_dir}}/scripts/reap-hostagents" "$vm" && \
        limactl start "$vm" && \
        php_v=$(yq -r '.php.version' mosaic.yaml) && \
        "{{home_dir}}/scripts/in-vm" "$vm" \
            podman compose -f /srv/project/.devenv/services-compose.yaml up -d && \
        "{{home_dir}}/scripts/in-vm" "$vm" sudo systemctl start "php$php_v-fpm" nginx

# Stop services without losing state. Project files + db data survive.
down:
    @vm="mosaic-$(basename "$(pwd)")" && \
        php_v=$(yq -r '.php.version' mosaic.yaml) && \
        "{{home_dir}}/scripts/in-vm" "$vm" sudo systemctl stop nginx "php$php_v-fpm" && \
        "{{home_dir}}/scripts/in-vm" "$vm" \
            podman compose -f /srv/project/.devenv/services-compose.yaml down && \
        limactl stop "$vm"

# Reload nginx + php-fpm (after editing nginx.conf or php.ini in .devenv/).
reload-web:
    @vm="mosaic-$(basename "$(pwd)")" && \
        php_v=$(yq -r '.php.version' mosaic.yaml) && \
        "{{home_dir}}/scripts/in-vm" "$vm" sudo nginx -t && \
        "{{home_dir}}/scripts/in-vm" "$vm" sudo systemctl reload nginx && \
        "{{home_dir}}/scripts/in-vm" "$vm" sudo systemctl restart "php$php_v-fpm"

# Tail nginx + php-fpm logs (Ctrl-C to exit).
tail-web:
    @vm="mosaic-$(basename "$(pwd)")" && \
        php_v=$(yq -r '.php.version' mosaic.yaml) && \
        "{{home_dir}}/scripts/in-vm" "$vm" sudo journalctl -u nginx -u "php$php_v-fpm" -f

# One-screen summary: project, VM status, ports.
status:
    @"{{home_dir}}/scripts/status.sh"

# Destroy the VM (project files on disk survive).
nuke:
    @vm="mosaic-$(basename "$(pwd)")" && \
        (limactl stop "$vm" 2>/dev/null || true) && \
        limactl delete -f "$vm" && \
        "{{home_dir}}/scripts/reap-hostagents" "$vm"

# Diagnose Lima zombie hostagents holding ports against stopped VMs.
doctor:
    @vm="mosaic-$(basename "$(pwd)")" && "{{home_dir}}/scripts/reap-hostagents" "$vm"

# --- plugins ---------------------------------------------------------------

# List plugin entries from mosaic.yaml.
plugins:
    @"{{home_dir}}/scripts/plugins.sh"

# Re-apply plugin bind-mounts in the VM (after editing mosaic.yaml's plugins). Doesn't re-clone — use `mosaic build` for that.
apply-plugins:
    @vm="mosaic-$(basename "$(pwd)")" && \
        "{{home_dir}}/scripts/in-vm" "$vm" sudo systemctl restart apply-plugins.service

# --- moodle / workplace / totara -------------------------------------------

# Run admin/cli/install.php (creates DB schema + admin user + config.php).
install-moodle:
    @"{{home_dir}}/scripts/install-moodle.sh"

# Run admin/cli/upgrade.php (picks up plugin schemas, bumps versions).
upgrade-moodle:
    @"{{home_dir}}/scripts/upgrade-moodle.sh"

# composer install + phpunit init (set up the test database).
init-phpunit:
    @"{{home_dir}}/scripts/init-phpunit.sh"

# Run a Moodle CLI script. Example: mosaic cli admin/cli/cfg.php --name=debug
cli +ARGS:
    @vm="mosaic-$(basename "$(pwd)")" && \
        fw=$(yq -r '.framework' mosaic.yaml) && \
        "{{home_dir}}/scripts/in-vm" "$vm" sudo -u www-data php "/srv/$fw/{{ARGS}}"

# Purge Moodle caches.
purge:
    @vm="mosaic-$(basename "$(pwd)")" && \
        fw=$(yq -r '.framework' mosaic.yaml) && \
        "{{home_dir}}/scripts/in-vm" "$vm" sudo -u www-data php "/srv/$fw/admin/cli/purge_caches.php"

# Run Moodle cron once.
cron:
    @vm="mosaic-$(basename "$(pwd)")" && \
        fw=$(yq -r '.framework' mosaic.yaml) && \
        "{{home_dir}}/scripts/in-vm" "$vm" sudo -u www-data php "/srv/$fw/admin/cli/cron.php"

# Drop into the database shell (mariadb in v1).
db:
    @vm="mosaic-$(basename "$(pwd)")" && \
        proj=$(basename "$(pwd)") && \
        "{{home_dir}}/scripts/in-vm" "$vm" \
            podman exec -it "mosaic-$proj-db" mariadb -umoodle -pm@odl3ing moodle

# --- networking -------------------------------------------------------------

# Add a hostname → host-gateway entry to this VM's /etc/hosts.
add-host HOSTNAME:
    @vm="mosaic-$(basename "$(pwd)")" && \
        "{{home_dir}}/scripts/in-vm" "$vm" sudo /srv/mosaic/scripts/vm-host-add {{HOSTNAME}}

# Remove a hostname entry from this VM's /etc/hosts.
remove-host HOSTNAME:
    @vm="mosaic-$(basename "$(pwd)")" && \
        "{{home_dir}}/scripts/in-vm" "$vm" sudo /srv/mosaic/scripts/vm-host-remove {{HOSTNAME}}

# --- introspection (no project context required) ---------------------------

# Show the current port-offset (next `mosaic new` writes one above this).
port-offset:
    @"{{home_dir}}/scripts/port-offset.sh" show

# List available framework profiles (framework/version combinations).
frameworks:
    @find "{{home_dir}}/frameworks" -name '*.yaml' \
        | sed -e "s|{{home_dir}}/frameworks/||" -e 's|\.yaml$||' \
        | sort

# Print resolved cross-project defaults.
defaults:
    @cat "{{home_dir}}/defaults.yaml"

# Print MOSAIC_HOME (Mosaic's install location).
home:
    @echo "{{home_dir}}"
