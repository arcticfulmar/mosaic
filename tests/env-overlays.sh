#!/usr/bin/env bash
# VM-free tests for env overlays (mosaic.<env>.yaml).
#
# Run:  tests/env-overlays.sh
#
# Covers the merge rules (scripts/manifest.sh), its refusals, env
# selection in bin/mosaic (--env in both positions, $MOSAIC_ENV, which
# wins), that the merged manifest is what resolve.sh and lib.sh's
# readers see, that no env leaves everything as it was, and the
# .gitignore helper behind `mosaic init`.
#
# Everything runs in a temp dir; nothing here touches a real project or
# a guest (the fixture pins the kassi backend, whose `facts` answer on
# any host).

set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export MOSAIC_HOME="$REPO"
unset MOSAIC_ENV MOSAIC_MANIFEST MOSAIC_BACKEND

WORK=$(mktemp -d "${TMPDIR:-/tmp}/mosaic-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
# reload-web below reaches the kassi driver, which finds no nginx; keep
# whatever state it looks for inside the scratch dir.
export XDG_STATE_HOME="$WORK/state"

pass=0; fail=0
ok_()   { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad_()  { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; [[ -n ${2:-} ]] && printf '       %s\n' "$2"; fail=$((fail+1)); }
head_() { printf '\n\033[0;36m%s\033[0m\n' "$1"; }

# assert_eq <label> <expected> <actual>
assert_eq() {
    if [[ "$2" == "$3" ]]; then ok_ "$1"; else bad_ "$1" "expected [$2], got [$3]"; fi
}
# assert_dies <label> <command...>   — non-zero exit AND something on stderr
assert_dies() {
    local label=$1; shift
    local err rc
    err=$("$@" 2>&1 >/dev/null); rc=$?
    if [[ $rc -ne 0 && -n $err ]]; then ok_ "$label"; else bad_ "$label" "expected non-zero exit with a message; rc=$rc output: $err"; fi
}
assert_contains() {
    if [[ "$3" == *"$2"* ]]; then ok_ "$1"; else bad_ "$1" "expected to contain [$2], got [$3]"; fi
}

# --- fixtures -----------------------------------------------------------------

make_project() {
    local dir=$1
    mkdir -p "$dir"
    cat > "$dir/mosaic.yaml" <<'YAML'
mosaic_version: "0.1"
backend: kassi
framework: laravel
version: "13"
php:
  version: "8.4"
db:
  type: pgsql
  version: "18"
wwwroot: connect-laravel.mosaic
ports:
  web:           8027
  db:            5459
  mailpit_ui:    8052
  mailpit_smtp:  1052
  vite_dev:      5200
vm:
  cpus:    4
  memory:  6GiB
  disk:    40GiB
plugins:
  - { source: "git@example.com:a.git", destination: "local/a" }
  - { source: "git@example.com:b.git", destination: "local/b" }
project:
  source: ""
  branch: main
YAML
}

P="$WORK/proj"
make_project "$P"
M="$REPO/scripts/manifest.sh"
mosaic() { (cd "$P" && "$REPO/bin/mosaic" "$@"); }
merged() { yq -r "$1" "$P/.mosaic/manifest.rules.yaml"; }
exists() { [[ -e $1 ]] && echo yes || echo no; }

# --- merge rules --------------------------------------------------------------

head_ "merge rules"
cat > "$P/mosaic.rules.yaml" <<'YAML'
listen: all
ports: { web: 80, extra: 9 }
db: { version: "17" }
plugins:
  - { source: "git@example.com:c.git", destination: "local/c" }
vm: { cpus: null }
wwwroot: null
project:
  branch: develop
new_key: [ null, 1 ]
YAML
out=$("$M" rules "$P"); rc=$?
assert_eq "manifest.sh succeeds"                       0 "$rc"
assert_eq "prints the merged file's absolute path"     "$(cd "$P" && pwd)/.mosaic/manifest.rules.yaml" "$out"
assert_eq "scalar replaces"                            all "$(merged .listen)"
assert_eq "map merges deeply: overlay key replaces"    80 "$(merged .ports.web)"
assert_eq "map merges deeply: base keys kept"          5459 "$(merged .ports.db)"
assert_eq "map merges deeply: new keys added"          9 "$(merged .ports.extra)"
assert_eq "nested map merge keeps sibling"             pgsql "$(merged .db.type)"
assert_eq "nested scalar replaced"                     17 "$(merged .db.version)"
assert_eq "list replaces wholesale (length)"           1 "$(merged '.plugins | length')"
assert_eq "list replaces wholesale (content)"          local/c "$(merged '.plugins[0].destination')"
assert_eq "null removes a top-level key"               false "$(merged 'has("wwwroot")')"
assert_eq "null removes a nested key"                  false "$(merged '.vm | has("cpus")')"
assert_eq "…and leaves its siblings"                   6GiB "$(merged .vm.memory)"
assert_eq "null inside a list is kept as an element"   2 "$(merged '.new_key | length')"
assert_eq "untouched keys pass through"                laravel "$(merged .framework)"
assert_eq "quoted strings stay strings"                '!!str' "$(merged '.version | tag')"
assert_eq "base file is not modified"                  connect-laravel.mosaic "$(yq -r .wwwroot "$P/mosaic.yaml")"

: > "$P/mosaic.empty.yaml"
"$M" empty "$P" >/dev/null
assert_eq "empty overlay changes nothing" \
    "$(yq -o=json . "$P/mosaic.yaml")" "$(yq -o=json . "$P/.mosaic/manifest.empty.yaml")"

# --- refusals -----------------------------------------------------------------

head_ "refusals"
assert_dies "missing overlay file"         "$M" nope "$P"
assert_dies "env name with a slash"        "$M" ../x "$P"
assert_dies "env name with a dot"          "$M" a.b "$P"
printf -- '- 1\n' > "$P/mosaic.seq.yaml"
assert_dies "overlay that is a list"       "$M" seq "$P"
printf 'just a string\n' > "$P/mosaic.str.yaml"
assert_dies "overlay that is a scalar"     "$M" str "$P"
printf 'a: [\n' > "$P/mosaic.broken.yaml"
assert_dies "overlay that is not YAML"     "$M" broken "$P"
printf 'listen: everywhere\n' > "$P/mosaic.badlisten.yaml"
assert_dies "merged file is validated like the base (listen)" mosaic config --env badlisten
printf 'framework: rails\n' > "$P/mosaic.badfw.yaml"
assert_dies "merged file is validated like the base (framework)" mosaic config --env badfw
printf 'php: { version: null }\n' > "$P/mosaic.nophp.yaml"
assert_dies "removing a required field fails like a base without it" mosaic config --env nophp

# --- selection ----------------------------------------------------------------

head_ "selection"
cat > "$P/mosaic.kassi.yaml" <<'YAML'
listen: all
ports: { web: 80 }
wwwroot: lab.kassi
YAML
cat > "$P/mosaic.other.yaml" <<'YAML'
wwwroot: other.test
YAML

base_json=$(mosaic config)
assert_eq "no env: base wwwroot"           connect-laravel.mosaic "$(printf '%s' "$base_json" | yq -r .wwwroot)"
assert_eq "no env: no merged file written" no "$(exists "$P/.mosaic/manifest.yaml")"

j=$(mosaic config --env kassi)
assert_eq "--env after the recipe"         lab.kassi "$(printf '%s' "$j" | yq -r .wwwroot)"
assert_eq "…listen from the overlay"       all "$(printf '%s' "$j" | yq -r .listen)"
assert_eq "…ports merged"                  "80 5459" "$(printf '%s' "$j" | yq -r '.ports.web') $(printf '%s' "$j" | yq -r '.ports.db')"
assert_eq "--env before the recipe"        lab.kassi "$(mosaic --env kassi config | yq -r .wwwroot)"
assert_eq "--env=<env> form"               lab.kassi "$(mosaic config --env=kassi | yq -r .wwwroot)"
assert_eq "MOSAIC_ENV selects"             lab.kassi "$(MOSAIC_ENV=kassi mosaic config | yq -r .wwwroot)"
assert_eq "the flag beats MOSAIC_ENV"      other.test "$(MOSAIC_ENV=kassi mosaic config --env other | yq -r .wwwroot)"
assert_eq "--env '' clears MOSAIC_ENV"     connect-laravel.mosaic "$(MOSAIC_ENV=kassi mosaic config --env '' | yq -r .wwwroot)"
(cd "$P" && MOSAIC_ENV=missing "$REPO/bin/mosaic" config >/dev/null 2>&1); rc=$?
assert_eq "…and stops the command"         1 "$rc"
assert_dies "--env without a name"         mosaic config --env

assert_eq "no-env run after env runs: same config as before" "$base_json" "$(mosaic config 2>/dev/null)"

# --- the guest's env ----------------------------------------------------------
# .mosaic/manifest.yaml (+ manifest.env) is what the guest was set up
# with. Only build, up and reload-web change it; reload-web is the one
# that runs here without a guest (its driver call fails afterwards,
# which doesn't matter: the shim has already done its part).

head_ "the guest's env"
rm -f "$P/.mosaic/manifest.yaml" "$P/.mosaic/manifest.env"
mosaic config --env kassi >/dev/null 2>&1
assert_eq "config --env writes the command's view" yes "$(exists "$P/.mosaic/manifest.kassi.yaml")"
assert_eq "…but not the guest's"           no "$(exists "$P/.mosaic/manifest.yaml")"
mosaic reload-web --env kassi >/dev/null 2>&1
assert_eq "reload-web --env sets the guest's manifest" all "$(yq -r .listen "$P/.mosaic/manifest.yaml" 2>/dev/null)"
assert_eq "…and names its env"             kassi "$(cat "$P/.mosaic/manifest.env" 2>/dev/null)"
err=$(mosaic config --env kassi 2>&1 >/dev/null)
assert_eq "same env: no warning"           "" "$err"
err=$(mosaic config 2>&1 >/dev/null)
assert_contains "no env: warns the guest has kassi" "set up with --env kassi; this command uses mosaic.yaml alone" "$err"
assert_eq "…and keeps the guest's manifest" kassi "$(cat "$P/.mosaic/manifest.env" 2>/dev/null)"
assert_eq "…while the command reads the base" 8027 "$(mosaic config 2>/dev/null | yq -r .ports.web)"
err=$(mosaic config --env other 2>&1 >/dev/null)
assert_contains "another env: warns too"   "this command uses --env other" "$err"
assert_eq "…and keeps the guest's manifest" kassi "$(cat "$P/.mosaic/manifest.env" 2>/dev/null)"
st=$(mosaic status 2>/dev/null)
assert_contains "status shows the env and the guest's" "none (mosaic.yaml alone); guest set up with kassi" "$st"
st=$(mosaic status --env kassi 2>/dev/null)
assert_contains "status --env shows the env" "kassi" "$(printf '%s\n' "$st" | grep -E '^ +env ')"
err=$(mosaic reload-web 2>&1 >/dev/null)
assert_contains "reload-web without an env warns it switches" "and switches the guest to it" "$err"
assert_eq "…and removes the guest's manifest" "no no" "$(exists "$P/.mosaic/manifest.yaml") $(exists "$P/.mosaic/manifest.env")"

# lib.sh readers (what build, up, status, the drivers use) see the merge.
lib_read() { (cd "$P" && bash -c '. "$MOSAIC_HOME/scripts/lib.sh"; project_yaml_get_or wwwroot localhost; echo; project_yaml_get ports.web; echo; project_plugin_count')
}
assert_eq "lib readers, no env"            "connect-laravel.mosaic
8027
2" "$(lib_read)"
assert_eq "lib readers, MOSAIC_ENV (no shim)" "lab.kassi
80
2" "$(MOSAIC_ENV=kassi lib_read)"
printf 'wwwroot: null\n' > "$P/mosaic.nullwww.yaml"
assert_eq "null falls back to the default" localhost "$(MOSAIC_ENV=nullwww lib_read | head -1)"

# Outside a project: the flag is an error, MOSAIC_ENV is ignored.
mkdir -p "$WORK/outside"
(cd "$WORK/outside" && "$REPO/bin/mosaic" home --env kassi >/dev/null 2>&1); rc=$?
assert_eq "--env outside a project is an error" 1 "$rc"
assert_eq "MOSAIC_ENV outside a project is ignored" "$REPO" \
    "$(cd "$WORK/outside" && MOSAIC_ENV=kassi "$REPO/bin/mosaic" home)"

# Only the two positions are the shim's; later arguments belong to the
# recipe. kassi's add-host refuses with a message naming its argument,
# which shows what the recipe was given.
err=$(mosaic add-host --env kassi 2>&1)
assert_contains "--env right after the recipe is taken by the shim" "add-host HOSTNAME" "$err"
err=$(mosaic --env kassi add-host --env 2>&1)
assert_contains "a later --env reaches the recipe verbatim" "wwwroot: --env.localhost" "$err"

# --- .gitignore ---------------------------------------------------------------

head_ "ignoring overlays (mosaic init)"
G="$WORK/gi"; mkdir -p "$G"
gi() { (cd "$G" && bash -c '. "$MOSAIC_HOME/scripts/lib.sh"; gitignore_overlays .' >/dev/null); }
gi
assert_eq "creates .gitignore"             'mosaic.*.yaml' "$(cat "$G/.gitignore")"
gi
assert_eq "idempotent"                     1 "$(grep -c 'mosaic' "$G/.gitignore")"
printf '/vendor' > "$G/.gitignore"          # no trailing newline
gi
assert_eq "appends on a fresh line"        "/vendor
mosaic.*.yaml" "$(cat "$G/.gitignore")"
printf '/mosaic.*.yaml\n' > "$G/.gitignore"
gi
assert_eq "an anchored entry counts"       '/mosaic.*.yaml' "$(cat "$G/.gitignore")"
make_project "$WORK/initp"
(cd "$WORK/initp" && "$REPO/bin/mosaic" init >/dev/null)
assert_eq "mosaic init writes it"          'mosaic.*.yaml' "$(cat "$WORK/initp/.gitignore")"
if command -v git >/dev/null 2>&1; then
    (cd "$WORK/initp" && git init -q . && : > mosaic.kassi.yaml)
    assert_eq "git ignores an overlay"     mosaic.kassi.yaml "$(cd "$WORK/initp" && git check-ignore mosaic.kassi.yaml)"
    assert_eq "…but not mosaic.yaml"       "" "$(cd "$WORK/initp" && git check-ignore mosaic.yaml)"

    # A cloned app: its committed .gitignore stays as it is.
    A="$WORK/app"; mkdir -p "$A"
    (cd "$A" && git init -q . && printf '/vendor\n' > .gitignore && : > mosaic.kassi.yaml)
    (cd "$A" && bash -c '. "$MOSAIC_HOME/scripts/lib.sh"; gitignore_overlays .' >/dev/null)
    assert_eq "in a repo: .gitignore untouched" /vendor "$(cat "$A/.gitignore")"
    assert_eq "…the line goes in .git/info/exclude" yes "$(grep -qxF 'mosaic.*.yaml' "$A/.git/info/exclude" && echo yes || echo no)"
    assert_eq "…and git ignores the overlay" mosaic.kassi.yaml "$(cd "$A" && git check-ignore mosaic.kassi.yaml)"
    (cd "$A" && bash -c '. "$MOSAIC_HOME/scripts/lib.sh"; gitignore_overlays .' >/dev/null)
    assert_eq "…idempotent"                1 "$(grep -c 'mosaic' "$A/.git/info/exclude")"
    mkdir -p "$A/sub"
    (cd "$A/sub" && bash -c '. "$MOSAIC_HOME/scripts/lib.sh"; gitignore_overlays .' >/dev/null)
    assert_eq "a subdir of a repo is not its root: .gitignore there" 'mosaic.*.yaml' "$(cat "$A/sub/.gitignore" 2>/dev/null)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
