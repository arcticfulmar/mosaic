#!/usr/bin/env bash
# render-services: render the nginx vhost, php.ini, and
# services-compose.yaml templates into ./.devenv/.
#
# Run from inside a Mosaic project. Pure templating — no VM
# interaction. The Lima template's provision step has already
# symlinked the renderer outputs into the right places (e.g.
# /etc/nginx/sites-enabled/moodle.conf → /srv/project/.devenv/nginx.conf),
# so simply writing the file makes it active. nginx still needs a
# reload to pick up changes (`mosaic reload-web`); podman compose
# doesn't auto-reload either (start fresh containers via `mosaic up`).

set -euo pipefail
. "$(dirname "$0")/lib.sh"

require_project
command -v yq >/dev/null 2>&1 || die "yq not found"

HOME_DIR=$(mosaic_home)
PROJECT_NAME=$(basename "$(pwd)")
FRAMEWORK=$(project_yaml_get framework)

case $FRAMEWORK in
    moodle|workplace|totara) ;;  # bake mode — has nginx/php to configure
    *) die "render-services only handles bake-mode frameworks (got: $FRAMEWORK)" ;;
esac

PHP_VERSION=$(project_yaml_get php.version)
DB_TYPE=$(project_yaml_get db.type)
DB_VERSION=$(project_yaml_get db.version)
WEB_PORT=$(project_yaml_get ports.web)
DB_PORT=$(project_yaml_get ports.db)
MAILPIT_UI_PORT=$(project_yaml_get ports.mailpit_ui)
MAILPIT_SMTP_PORT=$(project_yaml_get ports.mailpit_smtp)

# v1: mariadb only. mysql is interchangeable image-name-wise (the
# mariadb image accepts MYSQL_ env vars too) but we haven't tested it,
# so we error out loudly rather than silently succeed-then-fail.
case $DB_TYPE in
    mariadb) ;;
    *) die "Round C ships mariadb only; got db.type=$DB_TYPE (mysql/pgsql in a follow-up)" ;;
esac

mkdir -p .devenv

# Compact substitution helper. Each call renders one template.
render() {
    local src=$1 dst=$2
    sed \
        -e "s|@@PROJECT_NAME@@|$PROJECT_NAME|g" \
        -e "s|@@PHP_VERSION@@|$PHP_VERSION|g" \
        -e "s|@@DB_TYPE@@|$DB_TYPE|g" \
        -e "s|@@DB_VERSION@@|$DB_VERSION|g" \
        -e "s|@@WEB_PORT@@|$WEB_PORT|g" \
        -e "s|@@DB_PORT@@|$DB_PORT|g" \
        -e "s|@@MAILPIT_UI_PORT@@|$MAILPIT_UI_PORT|g" \
        -e "s|@@MAILPIT_SMTP_PORT@@|$MAILPIT_SMTP_PORT|g" \
        "$src" > "$dst"
    if grep -nE '@@[A-Z_]+@@' "$dst"; then
        die "$dst has unsubstituted placeholders (above)"
    fi
}

render "$HOME_DIR/templates/nginx-moodle.conf"      .devenv/nginx.conf
render "$HOME_DIR/templates/moodle-php.ini"          .devenv/php.ini
render "$HOME_DIR/templates/services-compose.yaml"   .devenv/services-compose.yaml

ok "rendered .devenv/{nginx.conf, php.ini, services-compose.yaml}"
