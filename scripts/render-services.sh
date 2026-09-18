#!/usr/bin/env bash
# render-services: render the nginx vhost, php.ini, and services-compose
# templates into ./.mosaic/. Picks the right templates based on
# framework + db.type.
#
# Run from inside a Mosaic project. Pure templating — no guest
# interaction. Guest provisioning has already symlinked the renderer
# outputs into the right places (e.g. /etc/nginx/sites-enabled/*.conf
# → /srv/project/.mosaic/nginx.conf), so simply writing the file makes
# it active. nginx still needs a
# reload to pick up changes (`mosaic reload-web`); podman compose
# doesn't auto-reload either (start fresh containers via `mosaic up`).

set -euo pipefail
. "$(dirname "$0")/lib.sh"

require_project
command -v yq >/dev/null 2>&1 || die "yq not found"

HOME_DIR=$(mosaic_home)
load_config
PROJECT_NAME=$(cfg .project.name)
FRAMEWORK=$(cfg .framework)
VERSION=$(cfg .version)

PHP_VERSION=$(cfg .php.version)
DB_TYPE=$(cfg .db.type)
DB_VERSION=$(cfg .db.version)
WEB_PORT=$(cfg .ports.web)
DB_PORT=$(cfg .ports.db)
MAILPIT_UI_PORT=$(cfg .ports.mailpit_ui)
MAILPIT_SMTP_PORT=$(cfg .ports.mailpit_smtp)
FW_ROOT=$(cfg .vm_paths.framework)
HOST_NETNS=$(cfg .backend.host_netns)

# Webroot path nginx serves from. Moodle 4.x serves from the framework
# root; Moodle 5.x serves from a public/ subdirectory. The profile's
# plugins_root value is what drives the difference (4.x: ".", 5.x:
# "public"). The framework root itself comes from the resolved config
# (/srv/<framework> for a baked tree, /srv/project on native-storage
# backends). For non-Moodle frameworks the webroot path is unused
# (Laravel's nginx template hardcodes /srv/project/public).
PLUGINS_ROOT=$(cfg .plugins_root)
if [[ $PLUGINS_ROOT == "." ]]; then
    WEBROOT="$FW_ROOT"
else
    WEBROOT="$FW_ROOT/$PLUGINS_ROOT"
fi

# nginx listen addresses. Inside a VM, bind everything: the VM's port
# forward is what exposes it, and only to 127.0.0.1 on the host. On a
# backend that shares the host network namespace the guest's bind IS
# the host's, so restrict to loopback there — a dev site must not
# appear on the LAN.
if [[ $HOST_NETNS == "true" ]]; then
    LISTEN4="127.0.0.1:$WEB_PORT"
    LISTEN6="[::1]:$WEB_PORT"
else
    LISTEN4="$WEB_PORT"
    LISTEN6="[::]:$WEB_PORT"
fi

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

mkdir -p .mosaic

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
        -e "s|@@WEBROOT@@|$WEBROOT|g" \
        -e "s|@@LISTEN4@@|$LISTEN4|g" \
        -e "s|@@LISTEN6@@|$LISTEN6|g" \
        "$src" > "$dst"
    if grep -nE '@@[A-Z_]+@@' "$dst"; then
        die "$dst has unsubstituted placeholders (above)"
    fi
}

render "$HOME_DIR/templates/$NGINX_TEMPLATE"     .mosaic/nginx.conf
render "$HOME_DIR/templates/$PHP_INI_TEMPLATE"   .mosaic/php.ini
render "$HOME_DIR/templates/$SERVICES_TEMPLATE"  .mosaic/services-compose.yaml

ok "rendered .mosaic/{nginx.conf, php.ini, services-compose.yaml}"
