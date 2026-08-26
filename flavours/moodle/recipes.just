# Moodle / Workplace / Totara flavour recipes.
#
# Imported by the generated root justfile only when mosaic.yaml's
# framework maps to the moodle flavour — so unlike v1 there are no
# require-framework.sh guards: these recipes simply don't exist in a
# Laravel project.

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

# `get.sh --installed framework` rather than inline yq: on a multi-target
# manifest the top-level `framework:` is only the shared default, and
# these recipes must address the tree that is actually installed at
# /srv/<framework> (which is what installed.json records).
#
# The inner `sh -c '…' _ "$fw" "$@"` passes the framework name + the
# user's args as positional params (single-quoted script, no string
# interpolation) so a script arg containing spaces survives intact. $1
# is the framework; after `shift` the remaining "$@" is the user's
# `<script.php> [args…]`, run from the framework root.
#
# Run a Moodle CLI script. Example: mosaic cli admin/cli/cfg.php --name=debug
[group('moodle')]
cli +ARGS:
    @vm="mosaic-$(basename "$(pwd)")" && \
        fw=$("{{home_dir}}/scripts/get.sh" --installed framework) && \
        "{{home_dir}}/scripts/in-vm" "$vm" sudo -u www-data sh -c 'cd "/srv/$1" && shift && exec php "$@"' _ "$fw" "$@"

# Purge Moodle caches.
[group('moodle')]
purge:
    @vm="mosaic-$(basename "$(pwd)")" && \
        fw=$("{{home_dir}}/scripts/get.sh" --installed framework) && \
        "{{home_dir}}/scripts/in-vm" "$vm" sudo -u www-data php "/srv/$fw/admin/cli/purge_caches.php"

# Run Moodle cron once.
[group('moodle')]
cron:
    @vm="mosaic-$(basename "$(pwd)")" && \
        fw=$("{{home_dir}}/scripts/get.sh" --installed framework) && \
        "{{home_dir}}/scripts/in-vm" "$vm" sudo -u www-data php "/srv/$fw/admin/cli/cron.php"

# List the active target's plugin entries from mosaic.yaml.
[group('moodle')]
plugins:
    @"{{home_dir}}/scripts/plugins.sh"

# Run PHPUnit tests inside the VM. Executes from /srv/<framework> as www-data so require_once paths resolve in the baked tree (avoids redeclare fatals from the dual-clone architecture) and writes to /srv/phpunitdata succeed without permission gymnastics. Pass test file paths relative to the framework root, e.g. `mosaic phpunit local/foo/tests/bar_test.php`.
[group('moodle')]
phpunit *ARGS:
    @vm="mosaic-$(basename "$(pwd)")" && \
        fw=$("{{home_dir}}/scripts/get.sh" --installed framework) && \
        "{{home_dir}}/scripts/in-vm" "$vm" sudo -u www-data sh -c 'cd "/srv/$1" && shift && exec ./vendor/bin/phpunit "$@"' _ "$fw" "$@"

# Re-graft plugins + project_files onto the framework tree in the VM (after editing mosaic.yaml). Doesn't re-clone — use `mosaic sync-graft` for that.
[group('moodle')]
apply-graft:
    @vm="mosaic-$(basename "$(pwd)")" && \
        "{{home_dir}}/scripts/vm-sync-tools" "$vm" && \
        "{{home_dir}}/scripts/in-vm" "$vm" sudo systemctl restart apply-graft.service

# Clone missing plugins from mosaic.yaml, re-graft, run upgrade-moodle. Safe alternative to `mosaic build`.
[group('moodle')]
sync-graft:
    @"{{home_dir}}/scripts/sync-graft.sh"
