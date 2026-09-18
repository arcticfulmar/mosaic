#!/usr/bin/env bash
# db: drop into the project's database shell. Dispatches on db.type
# and on framework (for the username/db).
#
# mariadb/mysql → `mariadb` client inside the db container.
# pgsql         → `psql` inside the db container.
#
# The container is named mosaic-<project>-db; the backend driver knows
# where the service stack runs (inside the Lima VM, or on the host
# podman for distrobox) and forwards to `podman exec` there.

set -euo pipefail
. "$(dirname "$0")/lib.sh"

require_project

PROJECT_NAME=$(basename "$(pwd)")
FRAMEWORK=$(project_yaml_get framework) || exit 1
DB_TYPE=$(project_yaml_get db.type) || exit 1
DRIVER=$(backend_driver) || exit 1

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
        exec "$DRIVER" services exec -it "$DB_CONTAINER" \
            mariadb -u"$DB_USER" -p"$DB_PASS" "$DB_NAME"
        ;;
    pgsql)
        # `psql` doesn't take password on CLI; the postgres image
        # accepts password via PGPASSWORD env.
        exec "$DRIVER" services exec -it -e "PGPASSWORD=$DB_PASS" "$DB_CONTAINER" \
            psql -U "$DB_USER" -d "$DB_NAME"
        ;;
    *) die "db: unsupported db.type '$DB_TYPE'" ;;
esac
