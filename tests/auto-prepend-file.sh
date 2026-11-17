#!/usr/bin/env bash
# VM-free tests for php.auto_prepend_file in mosaic.yaml.
#
# Run:  tests/auto-prepend-file.sh
#
# Covers resolve.sh (absent, set, refusals, set from an env overlay)
# and render-services.sh (php.ini unchanged without the key, the line
# appended with it). Everything runs in a temp dir with the kassi
# backend pinned, whose `facts` answer on any host.

set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export MOSAIC_HOME="$REPO"
unset MOSAIC_ENV MOSAIC_MANIFEST MOSAIC_BACKEND

WORK=$(mktemp -d "${TMPDIR:-/tmp}/mosaic-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export XDG_STATE_HOME="$WORK/state"

pass=0; fail=0
ok_()   { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad_()  { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; [[ -n ${2:-} ]] && printf '       %s\n' "$2"; fail=$((fail+1)); }
head_() { printf '\n\033[0;36m%s\033[0m\n' "$1"; }
assert_eq() {
    if [[ "$2" == "$3" ]]; then ok_ "$1"; else bad_ "$1" "expected [$2], got [$3]"; fi
}
assert_dies() {
    local label=$1; shift
    local err rc
    err=$("$@" 2>&1 >/dev/null); rc=$?
    if [[ $rc -ne 0 && -n $err ]]; then ok_ "$label"; else bad_ "$label" "expected non-zero exit with a message; rc=$rc output: $err"; fi
}

P="$WORK/proj"
mkdir -p "$P"
write_manifest() {
    cat > "$P/mosaic.yaml" <<YAML
mosaic_version: "0.1"
backend: kassi
framework: laravel
version: "13"
php:
  version: "8.4"
$1
db:
  type: pgsql
  version: "18"
ports: { web: 8027, db: 5459, mailpit_ui: 8052, mailpit_smtp: 1052 }
project: { source: "", branch: main }
YAML
}
resolve() { (cd "$P" && "$REPO/scripts/resolve.sh"); }
render()  { (cd "$P" && "$REPO/scripts/render-services.sh" >/dev/null 2>&1); }

head_ "absent"
write_manifest ""
assert_eq "resolved php has only version" '{"version":"8.4"}' "$(resolve | yq -o=json -I0 .php)"
render; base_ini=$(cat "$P/.mosaic/php.ini")
assert_eq "php.ini is the template, rendered" "$(cat "$REPO/templates/moodle-php.ini")" "$base_ini"

head_ "set"
write_manifest "  auto_prepend_file: /srv/project/prepend.php"
assert_eq "resolved" /srv/project/prepend.php "$(resolve | yq -r .php.auto_prepend_file)"
render
assert_eq "php.ini = template + one setting" \
    "$base_ini"$'\n\n; php.auto_prepend_file in mosaic.yaml\nauto_prepend_file = "/srv/project/prepend.php"' \
    "$(cat "$P/.mosaic/php.ini")"
if command -v php >/dev/null; then
    assert_eq "host php parses it" /srv/project/prepend.php \
        "$(php -n -c "$P/.mosaic/php.ini" -r 'echo ini_get("auto_prepend_file");')"
fi

head_ "refusals"
write_manifest "  auto_prepend_file: prepend.php"
assert_dies "relative path refused" resolve
write_manifest "  auto_prepend_file: '/srv/a\"b.php'"
assert_dies "double quote refused" resolve

head_ "env overlay"
write_manifest ""
printf 'php: { auto_prepend_file: /home/me/xhprof.php }\n' > "$P/mosaic.prof.yaml"
assert_eq "overlay sets it" /home/me/xhprof.php \
    "$(cd "$P" && MOSAIC_ENV=prof "$REPO/bin/mosaic" config | yq -r .php.auto_prepend_file)"
assert_eq "overlay keeps php.version" 8.4 \
    "$(cd "$P" && MOSAIC_ENV=prof "$REPO/bin/mosaic" config | yq -r .php.version)"
assert_eq "without the env it's absent" null "$(resolve | yq -r .php.auto_prepend_file)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
