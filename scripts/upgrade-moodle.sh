#!/usr/bin/env bash
# upgrade-moodle: run admin/cli/upgrade.php inside the guest. Triggers
# Moodle's standard upgrade pipeline — picks up new plugins (creates
# their tables, runs db_install.php / db_upgrade.php), bumps existing
# plugins to their current version, runs core upgrades.
#
# Cheap to re-run when nothing changed (Moodle short-circuits if all
# components are at their declared version). Build calls this after
# install.php so plugins added via mosaic.yaml become functional with
# no further action.

set -euo pipefail
. "$(dirname "$0")/lib.sh"

require_project
HOME_DIR=$(mosaic_home)

FRAMEWORK=$(project_yaml_get framework) || exit 1
case $FRAMEWORK in
    moodle|workplace|totara) ;;
    *) die "upgrade-moodle: framework $FRAMEWORK not supported" ;;
esac

info "==> Running Moodle upgrade (picks up plugin schemas)"
"$HOME_DIR/scripts/in-project.sh" php admin/cli/upgrade.php --non-interactive
ok "Upgrade complete"
