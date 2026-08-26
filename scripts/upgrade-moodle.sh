#!/usr/bin/env bash
# upgrade-moodle: run admin/cli/upgrade.php inside the VM. Triggers
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
VM_NAME=$(project_vm_name)

# Installed, not desired: upgrade.php has to run against the tree that
# is actually at /srv/<framework>.
FRAMEWORK=$(project_installed_get framework)

case $FRAMEWORK in
    moodle|workplace|totara) ;;
    *) die "upgrade-moodle: framework $FRAMEWORK not supported" ;;
esac

info "==> Running Moodle upgrade (picks up plugin schemas)"

"$HOME_DIR/scripts/in-vm" "$VM_NAME" \
    sudo -u www-data php "/srv/$FRAMEWORK/admin/cli/upgrade.php" --non-interactive

ok "Upgrade complete"
