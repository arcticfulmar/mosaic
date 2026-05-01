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

FRAMEWORK=$(project_yaml_get framework)
VERSION=$(project_yaml_get version)

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

info "==> admin/tool/phpunit/cli/init.php (drop + rebuild phpu_ tables)"
"$HOME_DIR/scripts/in-vm" "$VM_NAME" \
    sudo -u www-data php "/srv/$FRAMEWORK/admin/tool/phpunit/cli/init.php"

ok "PHPUnit ready — vendor/bin/phpunit will find the test infrastructure"
