#!/usr/bin/env bash
# db: drop into the project's database shell. Dispatches on db.type
# and on framework (for the username/db).
#
# mariadb/mysql → `mariadb` client (CLI-equivalent of mysql, ships
#                 with mariadb-client which we install in the VM).
# pgsql         → `psql` (postgresql-client installed in VM).
#
# The container is named mosaic-<project>-db and reachable from
# inside the VM via `podman exec -it`. From the host we'd use the
# Lima-forwarded port and the same credentials, but staying inside
# the VM avoids a second auth hop.

set -euo pipefail
. "$(dirname "$0")/lib.sh"

require_project

HOME_DIR=$(mosaic_home)
VM_NAME=$(project_vm_name)
PROJECT_NAME=$(basename "$(pwd)")
# Installed, not desired: this opens a shell on the container that is
# running, whose credentials and engine came from the build that made it.
FRAMEWORK=$(project_installed_get framework)
DB_TYPE=$(project_installed_get db.type)

# Credentials — must match what render-services.sh set the container
# up with. Keep this case statement in lockstep with that one.
case $FRAMEWORK in
    moodle|workplace|totara) DB_USER=moodle; DB_PASS=m@odl3ing; DB_NAME=moodle ;;
    laravel)                 DB_USER=app;    DB_PASS=app;       DB_NAME=app    ;;
    *) die "db: unknown framework '$FRAMEWORK'" ;;
esac

DB_CONTAINER="mosaic-${PROJECT_NAME}-db"

case $DB_TYPE in
    mariadb|mysql)
        exec "$HOME_DIR/scripts/in-vm" "$VM_NAME" \
            podman exec -it "$DB_CONTAINER" \
            mariadb -u"$DB_USER" -p"$DB_PASS" "$DB_NAME"
        ;;
    pgsql)
        # `psql` doesn't take password on CLI; the postgres image
        # accepts password via PGPASSWORD env. -e propagates it from
        # the local shell into the container.
        exec "$HOME_DIR/scripts/in-vm" "$VM_NAME" \
            podman exec -it -e "PGPASSWORD=$DB_PASS" "$DB_CONTAINER" \
            psql -U "$DB_USER" -d "$DB_NAME"
        ;;
    *) die "db: unsupported db.type '$DB_TYPE'" ;;
esac
