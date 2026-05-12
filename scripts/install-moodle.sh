#!/usr/bin/env bash
# install-moodle: run admin/cli/install.php inside the VM, then move
# the resulting config.php to the host so it's editable.
#
# Run from inside a Mosaic project. Assumes:
#   - VM is running (Round A)
#   - Plugins are bind-mounted (Round B — install.php doesn't install
#     plugin schemas, but plugin code being on disk is fine)
#   - render-services.sh has written .devenv/services-compose.yaml AND
#     `podman compose up -d` has been run (db must be reachable)
#
# Idempotent on re-run: removes any existing config.php first so
# install.php's "config exists" guard doesn't trip.

set -euo pipefail
. "$(dirname "$0")/lib.sh"

require_project
HOME_DIR=$(mosaic_home)
VM_NAME=$(project_vm_name)
PROJECT_NAME=$(basename "$(pwd)")

FRAMEWORK=$(project_yaml_get framework)
WWWROOT=$(project_yaml_get_or wwwroot localhost)
WEB_PORT=$(project_yaml_get ports.web)
DB_PORT=$(project_yaml_get ports.db)

case $FRAMEWORK in
    moodle|workplace|totara) ;;
    *) die "install-moodle: framework $FRAMEWORK not supported" ;;
esac

# Default install credentials. Fixed for v1 to match
# services-compose.yaml's database setup. The user can change these
# via Moodle's admin UI after install.
ADMIN_USER=${MOSAIC_ADMIN_USER:-admin}
ADMIN_PASS=${MOSAIC_ADMIN_PASS:-Password1!}
ADMIN_EMAIL=${MOSAIC_ADMIN_EMAIL:-dev@example.com}

WWWROOT_URL="http://${WWWROOT}:${WEB_PORT}"
DB_CONTAINER="mosaic-${PROJECT_NAME}-db"

# --- wait for db -----------------------------------------------------------
# install.php hits the db immediately. mariadb takes ~10s on first
# start to initialise its data dir. A naive `sleep 5` was sometimes
# too short — proper readiness loop instead. Bounded at 60s so we
# don't hang the build forever on a genuinely broken db.
#
# `bash -c` (NOT `bash -lc`): a login shell sources ~/.bash_logout on
# exit, which on Ubuntu contains `[ -x /usr/bin/clear_console ]`. With
# `set -e` active during shell teardown that test's non-zero exit (the
# binary doesn't exist) overwrites whatever the script's own `exit`
# said. Symptom: `exit 0` becomes ssh exit 1 mysteriously. Don't use
# -l for non-interactive remote scripts.
info "==> Waiting for db ($DB_CONTAINER)"
"$HOME_DIR/scripts/in-vm" "$VM_NAME" bash -c "
set -e
for i in \$(seq 1 60); do
    if podman exec '$DB_CONTAINER' mariadb-admin ping -uroot -pm@odl3ing 2>/dev/null | grep -q alive; then
        echo 'db is ready'
        exit 0
    fi
    sleep 1
done
echo 'db never became ready (60s timeout)' >&2
exit 1
"

# --- install ---------------------------------------------------------------

info "==> Installing $FRAMEWORK"
say  "    wwwroot:    $WWWROOT_URL"
say  "    admin user: $ADMIN_USER (password: $ADMIN_PASS)"

# Clear any prior config.php at both ends. install.php refuses to
# overwrite an existing one, and a stale host-side config.php from a
# previous install would otherwise survive into the new VM via the
# symlink dance below.
"$HOME_DIR/scripts/in-vm" "$VM_NAME" \
    sudo rm -f "/srv/$FRAMEWORK/config.php" "/srv/project/config.php"

# Drop+recreate the database. install.php refuses to install over an
# existing schema ("Database tables already present; CLI installation
# cannot continue."). Mosaic's design says rebuild = clean slate, so
# we don't try to preserve content. Re-creating in the same statement
# with the same charset/collation matches what services-compose.yaml
# initialised the db with on first start.
"$HOME_DIR/scripts/in-vm" "$VM_NAME" \
    podman exec "$DB_CONTAINER" mariadb -uroot -pm@odl3ing -e \
    "DROP DATABASE IF EXISTS moodle; CREATE DATABASE moodle CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;"

# Run install.php. Each flag is a separate arg — in-vm.sh's %q
# quoting handles spaces/special chars in the password and email
# without needing intermediate shell escaping.
"$HOME_DIR/scripts/in-vm" "$VM_NAME" \
    sudo -u www-data php "/srv/$FRAMEWORK/admin/cli/install.php" \
    --non-interactive \
    --agree-license \
    --wwwroot="$WWWROOT_URL" \
    --dataroot=/srv/moodledata \
    --dbtype=mariadb \
    --dbhost=127.0.0.1 \
    --dbport="$DB_PORT" \
    --dbname=moodle \
    --dbuser=moodle \
    --dbpass=m@odl3ing \
    --fullname="Mosaic Dev" \
    --shortname=dev \
    --adminuser="$ADMIN_USER" \
    --adminpass="$ADMIN_PASS" \
    --adminemail="$ADMIN_EMAIL"

# --- pin require_once to the baked tree ------------------------------------
# install.php writes `require_once(__DIR__ . '/lib/setup.php')`. After
# we host-link config.php, __DIR__ resolves through the symlink to the
# host clone — making setup.php's `$CFG->dirroot = dirname(__DIR__)`
# point Moodle entirely at the host clone via virtiofs. That defeats
# the bake (slow file IO over virtiofs) AND breaks plugin bind-mounts
# (Moodle no longer looks for plugins under /srv/<framework>/).
#
# Patch the require to an absolute path before moving the file. Now
# wherever config.php physically lives, setup.php is always loaded
# from the baked /srv/<framework>/lib/setup.php, and dirroot is
# /srv/<framework> as intended.
BAKED_CONFIG="/srv/$FRAMEWORK/config.php"
HOST_CONFIG="/srv/project/config.php"

info "==> Pinning config.php's setup.php require to /srv/$FRAMEWORK"
"$HOME_DIR/scripts/in-vm" "$VM_NAME" sudo sed -i \
    "s|require_once(__DIR__ \. '/lib/setup\.php')|require_once('/srv/$FRAMEWORK/lib/setup.php')|" \
    "$BAKED_CONFIG"

# --- host-link config.php --------------------------------------------------
# Move config.php to the project root and symlink the baked path back
# to it. After this, ./config.php on the host is editable; PHP inside
# the VM reads it via the symlink, and (thanks to the absolute require
# above) still uses the baked /srv/<framework> tree for everything else.
#
# Permissions: 0644 so php-fpm (www-data) can read via the symlink.
info "==> Linking config.php to host (./config.php)"
"$HOME_DIR/scripts/in-vm" "$VM_NAME" sudo mv "$BAKED_CONFIG" "$HOST_CONFIG"
"$HOME_DIR/scripts/in-vm" "$VM_NAME" sudo chmod 0644 "$HOST_CONFIG"
"$HOME_DIR/scripts/in-vm" "$VM_NAME" sudo ln -sfn "$HOST_CONFIG" "$BAKED_CONFIG"

ok "Moodle installed; config.php is host-editable at ./config.php"
