# Moodle / Workplace / Totara flavour recipes.
#
# Imported by the generated root justfile only when mosaic.yaml's
# framework maps to the moodle flavour — so unlike v1 there are no
# require-framework.sh guards: these recipes simply don't exist in a
# Laravel project.
#
# Everything that runs PHP goes through scripts/in-project.sh, which
# picks the framework root and the service user from the resolved
# config — /srv/<framework> as www-data on Lima, /srv/project as you on
# distrobox. Recipes stay ignorant of both.

# Run admin/cli/install.php (creates DB schema + admin user + config.php).
[group('moodle')]
install-moodle:
    @"{{home_dir}}/scripts/resolve.sh" | "{{home_dir}}/flavours/moodle/hooks/install"

# Run admin/cli/upgrade.php (picks up plugin schemas, bumps versions).
[group('moodle')]
upgrade-moodle:
    @"{{home_dir}}/scripts/upgrade-moodle.sh"

# composer install + phpunit init (set up the test database).
[group('moodle')]
init-phpunit:
    @"{{home_dir}}/scripts/init-phpunit.sh"

# Run a Moodle CLI script from the framework root. Example: mosaic cli admin/cli/cfg.php --name=debug
[group('moodle')]
cli +ARGS:
    @"{{home_dir}}/scripts/in-project.sh" php "$@"

# Purge Moodle caches.
[group('moodle')]
purge:
    @"{{home_dir}}/scripts/in-project.sh" php admin/cli/purge_caches.php

# Run Moodle cron once.
[group('moodle')]
cron:
    @"{{home_dir}}/scripts/in-project.sh" php admin/cli/cron.php

# List plugin entries from mosaic.yaml.
[group('moodle')]
plugins:
    @"{{home_dir}}/scripts/plugins.sh"

# Run PHPUnit tests inside the guest, from the framework root as the service user (so require_once paths resolve in the served tree and /srv/phpunitdata is writable). Pass test paths relative to the framework root, e.g. `mosaic phpunit local/foo/tests/bar_test.php`.
[group('moodle')]
phpunit *ARGS:
    @"{{home_dir}}/scripts/in-project.sh" ./vendor/bin/phpunit "$@"

# Re-graft plugins + project_files onto the framework tree (after editing mosaic.yaml). Doesn't re-clone — use `mosaic sync-graft` for that.
[group('moodle')]
apply-graft:
    @"{{home_dir}}/scripts/apply-graft.sh"

# Clone missing plugins from mosaic.yaml, re-graft, run upgrade-moodle. Safe alternative to `mosaic build`.
[group('moodle')]
sync-graft:
    @"{{home_dir}}/scripts/sync-graft.sh"
