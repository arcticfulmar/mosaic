#!/usr/bin/env bash
# composer-autoload: merge mosaic.yaml's `composer.autoload` into the
# served tree's composer.json, before the install hook's `composer
# install` writes vendor/autoload.php from it.
#
#   composer:
#     autoload:
#       psr-4:
#         "titus\\": titus/
#
# For code a project adds to a tree it doesn't own, such as a site-root
# module beside a fetched Moodle (`../titus/toolkit`), whose classes
# Composer must load. Each type is merged into the file's own: a map
# (psr-4, psr-0) entry by entry, mosaic.yaml's value winning for the
# same namespace; a list (classmap, files) as a union. Entries already
# there are left as they are, so a second build changes nothing, and
# without the key composer.json is never opened.
#
# Runs in the guest at the served tree's root (in-project.sh), so on a
# baked tree (Lima) it edits the copy that is served, on every backend.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

require_project
HOME_DIR=$(mosaic_home)
load_config

spec=$(printf '%s' "$CONFIG_JSON" | yq -o=json -I=0 '.composer.autoload // {}')
[[ $spec == "{}" ]] && exit 0
info "==> Composer autoload entries from mosaic.yaml"

# Objects stay objects (json_decode without assoc), so an empty {} in
# composer.json isn't rewritten as []; the file is written only when an
# entry is new or different.
read -r -d '' merge <<'PHP' || true
$f = 'composer.json';
if (!is_file($f)) { fwrite(STDERR, "composer.json not found in " . getcwd() . "\n"); exit(1); }
$flags = JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE;
$j = json_decode(file_get_contents($f), false, 512, JSON_THROW_ON_ERROR);
$add = json_decode($argv[1], false, 512, JSON_THROW_ON_ERROR);
$before = json_encode($j, $flags);
if (!isset($j->autoload) || !is_object($j->autoload)) { $j->autoload = new stdClass(); }
foreach ($add as $type => $entries) {
    if (is_array($entries)) {
        $cur = isset($j->autoload->$type) ? (array) $j->autoload->$type : [];
        $j->autoload->$type = array_values(array_unique(array_merge($cur, $entries)));
    } else {
        if (!isset($j->autoload->$type) || !is_object($j->autoload->$type)) { $j->autoload->$type = new stdClass(); }
        foreach ($entries as $k => $v) { $j->autoload->$type->$k = $v; }
    }
}
$after = json_encode($j, $flags);
if ($after === $before) { echo "    composer.json: already has them\n"; exit(0); }
file_put_contents($f, $after . "\n");
echo "    composer.json: autoload updated\n";
PHP
"$HOME_DIR/scripts/in-project.sh" php -r "$merge" "$spec"
