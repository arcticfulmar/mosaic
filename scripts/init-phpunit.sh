#!/usr/bin/env bash
# init-phpunit: install Moodle's PHPUnit test database and dev deps.
#
# Two steps:
#   1. composer install in /srv/$framework — pulls phpunit/behat/mocks
#      into vendor/. Required for vendor/bin/phpunit and for the test
#      bootstrap to find Moodle's testing infrastructure.
#   2. admin/tool/phpunit/cli/init.php — drops + rebuilds the phpu_
#      tables. Required after first install AND after any plugin
#      version.php bump (so the new tables are present).
#
# Both steps run as www-data so file ownership stays consistent with
# the rest of the install. Cheap to re-run; phpunit init is the
# slowest bit (~30s on 4.x) but doesn't redo work that's already
# done.
#
# Profile capability gate: if `phpunit` isn't in the active profile's
# capabilities, refuse rather than producing a confusing failure
# downstream.

set -euo pipefail
. "$(dirname "$0")/lib.sh"

require_project
HOME_DIR=$(mosaic_home)
VM_NAME=$(project_vm_name)

# Installed, not desired — phpunit is initialised against the tree at
# /srv/<framework>, and plugins_root/capabilities have to match the
# version that produced it.
FRAMEWORK=$(project_installed_get framework)
VERSION=$(project_installed_get version)

if ! profile_caps "$FRAMEWORK" "$VERSION" | grep -qFx 'phpunit'; then
    die "framework profile '$FRAMEWORK $VERSION' doesn't list 'phpunit' capability"
fi

info "==> composer install (in /srv/$FRAMEWORK — pulls phpunit/behat dev deps)"
"$HOME_DIR/scripts/in-vm" "$VM_NAME" \
    sudo -u www-data -H sh -c "cd /srv/$FRAMEWORK && composer install --no-interaction"

# Patch config.php to add phpunit_dataroot + phpunit_prefix. install.php
# doesn't write these, so phpunit's bootstrap aborts without them.
# Idempotent: configure-phpunit is a no-op if the lines are already
# present, so this stays cheap on re-run.
info "==> Adding phpunit settings to config.php"
"$HOME_DIR/scripts/in-vm" "$VM_NAME" \
    sudo /srv/mosaic/scripts/configure-phpunit "/srv/$FRAMEWORK/config.php"

# admin/tool/phpunit is a *plugin* (admin tool), not a core CLI script —
# it lives under the framework's plugins_root. Moodle 4.x: directly at
# /srv/<framework>/admin/tool/phpunit/. Moodle 5.x: under public/ (along
# with every other plugin), so /srv/<framework>/public/admin/tool/phpunit/.
# Core CLI scripts at /srv/<framework>/admin/cli/ (install, upgrade, cron,
# purge_caches…) stayed at the framework root in 5.x and don't need this
# adjustment.
PLUGINS_ROOT=$(project_plugins_root "$FRAMEWORK" "$VERSION")
if [[ $PLUGINS_ROOT == "." ]]; then
    PHPUNIT_INIT="/srv/$FRAMEWORK/admin/tool/phpunit/cli/init.php"
else
    PHPUNIT_INIT="/srv/$FRAMEWORK/$PLUGINS_ROOT/admin/tool/phpunit/cli/init.php"
fi

info "==> $PHPUNIT_INIT (drop + rebuild phpu_ tables)"
"$HOME_DIR/scripts/in-vm" "$VM_NAME" \
    sudo -u www-data php "$PHPUNIT_INIT"

# Normalise /srv/phpunitdata to 0777 so any caller can write — the
# lima user (shell, PhpStorm SSH remote interpreter), www-data
# (`mosaic phpunit` recipe), or Moodle itself. init.php may have
# created internal subdirs with restrictive perms; the recursive
# chmod fixes the whole tree. World-writable is appropriate for a
# single-user dev VM.
info "==> Normalising /srv/phpunitdata permissions"
"$HOME_DIR/scripts/in-vm" "$VM_NAME" \
    sudo chmod -R 0777 /srv/phpunitdata

ok "PHPUnit ready — vendor/bin/phpunit will find the test infrastructure"
