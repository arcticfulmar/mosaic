#!/usr/bin/env bash
# render-services: render the nginx vhost, php.ini, and services-compose
# templates into ./.devenv/. Picks the right templates based on
# framework + db.type.
#
# Run from inside a Mosaic project. Pure templating — no VM
# interaction. The Lima template's provision step has already
# symlinked the renderer outputs into the right places (e.g.
# /etc/nginx/sites-enabled/site.conf → /srv/project/.devenv/nginx.conf),
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

PHP_VERSION=$(project_yaml_get php.version)
DB_TYPE=$(project_yaml_get db.type)
DB_VERSION=$(project_yaml_get db.version)
WEB_PORT=$(project_yaml_get ports.web)
DB_PORT=$(project_yaml_get ports.db)
MAILPIT_UI_PORT=$(project_yaml_get ports.mailpit_ui)
MAILPIT_SMTP_PORT=$(project_yaml_get ports.mailpit_smtp)

# --- pick templates -------------------------------------------------------

# nginx vhost: per-framework (Moodle's slasharguments rewrite is unique;
# Laravel's vhost is much simpler).
case $FRAMEWORK in
    moodle|workplace|totara) NGINX_TEMPLATE=nginx-moodle.conf ;;
    laravel)                 NGINX_TEMPLATE=nginx-laravel.conf ;;
    *) die "no nginx template for framework: $FRAMEWORK" ;;
esac

# php.ini: shared across all PHP frameworks for now (Moodle's tunings
# are reasonable defaults for Laravel too).
PHP_INI_TEMPLATE=moodle-php.ini

# services compose: per db.type. Each template parameterises creds via
# @@DB_USER/PASS/NAME@@ so this script can set them based on framework.
case $DB_TYPE in
    mariadb|mysql) SERVICES_TEMPLATE=services-mariadb.yaml ;;
    pgsql)         SERVICES_TEMPLATE=services-pgsql.yaml ;;
    *) die "no services compose template for db.type: $DB_TYPE" ;;
esac

# --- pick credentials ------------------------------------------------------
# Moodle's install.php is hardcoded to user=moodle/pass=m@odl3ing/db=moodle —
# changing this would mean parameterising install-moodle.sh too. For
# Laravel, the app reads its own .env, so we use a generic app/app/app
# triple that's easy to remember and matches no real-world data.

case $FRAMEWORK in
    moodle|workplace|totara)
        DB_USER=moodle
        DB_PASS=m@odl3ing
        DB_NAME=moodle
        ;;
    laravel)
        DB_USER=app
        DB_PASS=app
        DB_NAME=app
        ;;
esac

# --- substitute -----------------------------------------------------------

mkdir -p .devenv

# Compact substitution helper. Each call renders one template.
render() {
    local src=$1 dst=$2
    sed \
        -e "s|@@FRAMEWORK@@|$FRAMEWORK|g" \
        -e "s|@@PROJECT_NAME@@|$PROJECT_NAME|g" \
        -e "s|@@PHP_VERSION@@|$PHP_VERSION|g" \
        -e "s|@@DB_TYPE@@|$DB_TYPE|g" \
        -e "s|@@DB_VERSION@@|$DB_VERSION|g" \
        -e "s|@@DB_USER@@|$DB_USER|g" \
        -e "s|@@DB_PASS@@|$DB_PASS|g" \
        -e "s|@@DB_NAME@@|$DB_NAME|g" \
        -e "s|@@WEB_PORT@@|$WEB_PORT|g" \
        -e "s|@@DB_PORT@@|$DB_PORT|g" \
        -e "s|@@MAILPIT_UI_PORT@@|$MAILPIT_UI_PORT|g" \
        -e "s|@@MAILPIT_SMTP_PORT@@|$MAILPIT_SMTP_PORT|g" \
        "$src" > "$dst"
    if grep -nE '@@[A-Z_]+@@' "$dst"; then
        die "$dst has unsubstituted placeholders (above)"
    fi
}

render "$HOME_DIR/templates/$NGINX_TEMPLATE"     .devenv/nginx.conf
render "$HOME_DIR/templates/$PHP_INI_TEMPLATE"   .devenv/php.ini
render "$HOME_DIR/templates/$SERVICES_TEMPLATE"  .devenv/services-compose.yaml

ok "rendered .devenv/{nginx.conf, php.ini, services-compose.yaml}"
