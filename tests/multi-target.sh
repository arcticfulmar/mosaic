#!/usr/bin/env bash
# VM-free tests for multi-target manifests.
#
# Run:  tests/multi-target.sh
#
# Covers the parts of the target machinery that can be exercised without
# a VM: resolution and its overlay rules, validation refusals, the
# desired-vs-installed split, and — the one that matters most — the
# teardown hook's work-loss guards and host wipe, rehearsed against real
# git repos in a scratch directory with no VM present.
#
# Everything runs in a temp dir; nothing here touches a real project.

set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export MOSAIC_HOME="$REPO"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/mosaic-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

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
    if [[ $rc -ne 0 ]]; then ok_ "$label"; else bad_ "$label" "expected non-zero exit; output: $err"; fi
}
assert_contains() {
    if [[ "$3" == *"$2"* ]]; then ok_ "$1"; else bad_ "$1" "expected to contain [$2], got [$3]"; fi
}

# --- fixtures -----------------------------------------------------------------

make_multi() {
    local dir=$1
    mkdir -p "$dir/.mosaic"
    cat > "$dir/mosaic.yaml" <<'YAML'
mosaic_version: "0.1"
default_target: m45
targets:
  m45:
    framework: moodle
    version: "4.5"
    php: { version: "8.2" }
    plugins:
      - { source: "git@example.com:t/theme_x.git", branch: "v1.0.0", destination: "theme/x" }
      - { source: "git@example.com:t/local_y.git", branch: "v1.1.0", destination: "local/y" }
  m51:
    framework: moodle
    version: "5.1"
    db: { version: "11.4" }
    plugins: []
php:
  version: "8.3"
db:
  type: mariadb
  version: "10.11"
wwwroot: test.mosaic
ports:
  web: 8099
  db: 3399
  mailpit_ui: 8098
  mailpit_smtp: 1098
  vite_dev: 5299
  ssh: 60099
vm:
  cpus: 4
  memory: 6GiB
  disk: 40GiB
YAML
}

make_legacy() {
    local dir=$1
    mkdir -p "$dir/.mosaic"
    cat > "$dir/mosaic.yaml" <<'YAML'
mosaic_version: "0.1"
framework: moodle
version: "4.5"
php:
  version: "8.2"
db:
  type: mariadb
  version: "10.11"
wwwroot: test.mosaic
ports:
  web: 8099
  db: 3399
  mailpit_ui: 8098
  mailpit_smtp: 1098
  vite_dev: 5299
  ssh: 60099
vm:
  cpus: 4
  memory: 6GiB
  disk: 40GiB
plugins:
  - { source: "git@example.com:t/theme_x.git", branch: "v1.0.0", destination: "theme/x" }
YAML
}

# ==============================================================================
head_ "1. Legacy manifests resolve exactly as before"
# ==============================================================================
# Strongest available check: run the PRE-CHANGE resolve.sh + lib.sh from
# git HEAD against the same fixture and diff. The only permitted
# difference is the new "target" key.

L="$WORK/legacy"; make_legacy "$L"

OLD="$WORK/old-home"
mkdir -p "$OLD/scripts"
ln -s "$REPO/frameworks" "$OLD/frameworks"
ln -s "$REPO/flavours"   "$OLD/flavours"
ln -s "$REPO/templates"  "$OLD/templates"
cp "$REPO/defaults.yaml" "$OLD/defaults.yaml"
if git -C "$REPO" show HEAD:scripts/lib.sh > "$OLD/scripts/lib.sh" 2>/dev/null &&
   git -C "$REPO" show HEAD:scripts/resolve.sh > "$OLD/scripts/resolve.sh" 2>/dev/null; then
    chmod +x "$OLD/scripts/resolve.sh"
    old_out=$(cd "$L" && MOSAIC_HOME="$OLD" "$OLD/scripts/resolve.sh" 2>/dev/null)
    new_out=$(cd "$L" && "$REPO/scripts/resolve.sh" 2>/dev/null | yq -p json -o=json 'del(.target)')
    if [[ "$old_out" == "$new_out" ]]; then
        ok_ "resolve.sh output for a legacy manifest is unchanged (modulo the new .target)"
    else
        bad_ "resolve.sh output for a legacy manifest changed" "$(diff <(echo "$old_out") <(echo "$new_out") | head -20)"
    fi
else
    bad_ "could not read HEAD's resolve.sh/lib.sh for comparison"
fi

assert_eq "legacy .target is empty" "" \
    "$(cd "$L" && "$REPO/scripts/resolve.sh" | yq -p json -r '.target')"

# ==============================================================================
head_ "2. Per-target resolution + overlay rules"
# ==============================================================================
M="$WORK/multi"; make_multi "$M"

r() { (cd "$M" && "$REPO/scripts/resolve.sh"); }

assert_eq "default_target picks m45"          "m45"   "$(r | yq -p json -r '.target')"
assert_eq "m45 version from the target"       "4.5"   "$(r | yq -p json -r '.version')"
assert_eq "m45 php from the target"           "8.2"   "$(r | yq -p json -r '.php.version')"
assert_eq "m45 plugins from the target"       "2"     "$(r | yq -p json -r '.plugins | length')"
assert_eq "m45 plugins_root (4.x profile)"    "."     "$(r | yq -p json -r '.plugins_root')"
assert_eq "shared ports still resolve"        "8099"  "$(r | yq -p json -r '.ports.web')"
assert_eq "shared wwwroot still resolves"     "test.mosaic" "$(r | yq -p json -r '.wwwroot')"

echo "m51" > "$M/.mosaic/active-target"
assert_eq "active-target overrides default"   "m51"   "$(r | yq -p json -r '.target')"
assert_eq "m51 version from the target"       "5.1"   "$(r | yq -p json -r '.version')"
assert_eq "m51 php falls through to shared"   "8.3"   "$(r | yq -p json -r '.php.version')"
assert_eq "m51 plugins_root (5.x profile)"    "public" "$(r | yq -p json -r '.plugins_root')"
assert_eq "empty plugins: [] overrides, not inherits" "0" "$(r | yq -p json -r '.plugins | length')"
assert_eq "db deep-merge keeps shared type"   "mariadb" "$(r | yq -p json -r '.db.type')"
assert_eq "db deep-merge takes target version" "11.4"  "$(r | yq -p json -r '.db.version')"

echo "m45" > "$M/.mosaic/active-target"
assert_eq "db without a target override"      "10.11" "$(r | yq -p json -r '.db.version')"

# ==============================================================================
head_ "3. Validation refusals"
# ==============================================================================
B="$WORK/bogus"; make_multi "$B"
echo "nope" > "$B/.mosaic/active-target"
assert_dies "unknown active-target dies" bash -c "cd '$B' && '$REPO/scripts/resolve.sh'"
err=$(cd "$B" && "$REPO/scripts/resolve.sh" 2>&1 >/dev/null || true)
assert_contains "…and names the state file" ".mosaic/active-target" "$err"

E="$WORK/empty-name"; make_multi "$E"
: > "$E/.mosaic/active-target"
python3 - "$E/mosaic.yaml" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
open(p,'w').write(s.replace("default_target: m45\n",""))
PY
assert_dies "no default_target + empty state file dies" bash -c "cd '$E' && '$REPO/scripts/resolve.sh'"

K="$WORK/badkey"; make_multi "$K"
python3 - "$K/mosaic.yaml" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
open(p,'w').write(s.replace('    php: { version: "8.2" }\n',
                            '    php: { version: "8.2" }\n    ports: { web: 9999 }\n'))
PY
assert_dies "a disallowed key inside a target dies" bash -c "cd '$K' && '$REPO/scripts/resolve.sh'"
err=$(cd "$K" && "$REPO/scripts/resolve.sh" 2>&1 >/dev/null || true)
assert_contains "…and names the offending key" "ports" "$err"

X="$WORK/xflavour"; make_multi "$X"
python3 - "$X/mosaic.yaml" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
open(p,'w').write(s.replace("  m51:\n    framework: moodle\n","  m51:\n    framework: laravel\n"))
PY
assert_dies "targets on different flavours die" bash -c "cd '$X' && '$REPO/scripts/resolve.sh'"
err=$(cd "$X" && "$REPO/scripts/resolve.sh" 2>&1 >/dev/null || true)
assert_contains "…and explains the VM constraint" "flavour" "$err"

S="$WORK/seq"; make_multi "$S"
python3 - "$S/mosaic.yaml" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
i=s.index("targets:"); j=s.index("php:\n  version")
open(p,'w').write(s[:i]+"targets: [a, b]\n"+s[j:])
PY
assert_dies "targets: as a sequence dies" bash -c "cd '$S' && '$REPO/scripts/resolve.sh'"

# ==============================================================================
head_ "4. get.sh, installed.json and the generated justfile"
# ==============================================================================
G="$WORK/get"; make_multi "$G"

assert_eq "get.sh reads the active target"  "8.2" "$(cd "$G" && "$REPO/scripts/get.sh" php.version)"
echo "m51" > "$G/.mosaic/active-target"
assert_eq "get.sh follows active-target"    "8.3" "$(cd "$G" && "$REPO/scripts/get.sh" php.version)"

# Pretend m45 is installed while m51 is desired — the interrupted-switch state.
cat > "$G/.mosaic/installed.json" <<'JSON'
{"target":"m45","framework":"moodle","version":"4.5","php":{"version":"8.2"},"plugins":[],"flavour":"moodle"}
JSON
assert_eq "get.sh --installed reads installed.json" "8.2" \
    "$(cd "$G" && "$REPO/scripts/get.sh" --installed php.version)"
assert_eq "get.sh (no flag) still reads the manifest" "8.3" \
    "$(cd "$G" && "$REPO/scripts/get.sh" php.version)"
rm "$G/.mosaic/installed.json"
assert_eq "get.sh --installed falls back with nothing installed" "8.3" \
    "$(cd "$G" && "$REPO/scripts/get.sh" --installed php.version)"

# bin/mosaic writes the flavour import from the ACTIVE target's framework.
(cd "$G" && "$REPO/bin/mosaic" --summary >/dev/null 2>&1 || true)
assert_contains "generated justfile imports the moodle flavour" \
    "flavours/moodle/recipes.just" "$(cat "$G/.mosaic/justfile" 2>/dev/null || echo MISSING)"

# ==============================================================================
head_ "5. render-services.sh per target"
# ==============================================================================
R="$WORK/render"; make_multi "$R"
(cd "$R" && "$REPO/scripts/render-services.sh" >/dev/null 2>&1)
assert_contains "4.x nginx uses the target's php socket" "php8.2-fpm.sock" "$(cat "$R/.mosaic/nginx.conf")"
assert_contains "4.x webroot is the framework root" "root /srv/moodle;" "$(cat "$R/.mosaic/nginx.conf")"

echo "m51" > "$R/.mosaic/active-target"
(cd "$R" && "$REPO/scripts/render-services.sh" >/dev/null 2>&1)
assert_contains "5.x nginx uses the shared php socket" "php8.3-fpm.sock" "$(cat "$R/.mosaic/nginx.conf")"
assert_contains "5.x webroot moves under public/" "root /srv/moodle/public;" "$(cat "$R/.mosaic/nginx.conf")"
assert_contains "compose picks up the target's db version" "mariadb:11.4" "$(cat "$R/.mosaic/services-compose.yaml")"

# ==============================================================================
head_ "6. Teardown guards (real git repos, no VM)"
# ==============================================================================
# One scratch project per plugin state. The hook is fed installed.json on
# stdin exactly as core does it, with MOSAIC_ASSUME_YES set and a VM name
# that doesn't exist (so the VM leg is skipped, loudly).

HOOK="$REPO/flavours/moodle/hooks/teardown"

# A bare "remote" plus a clone checked out at a tag = the pristine state
# of every plugin in a target.
setup_teardown_project() {
    local dir=$1
    mkdir -p "$dir/.mosaic"
    printf 'version.php\nlib\ntheme\nlocal\n' > "$dir/.mosaic/bake-manifest"
    : > "$dir/version.php"
    mkdir -p "$dir/lib" "$dir/theme" "$dir/local"
    : > "$dir/lib/setup.php"
    : > "$dir/config.php"
    printf 'my own file\n' > "$dir/NOTES.md"

    local remote="$WORK/remotes/$(basename "$dir")-theme_x.git"
    mkdir -p "$remote"
    git init -q --bare "$remote"

    local seed="$WORK/seed-$(basename "$dir")"
    rm -rf "$seed"
    git init -q "$seed"
    git -C "$seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    : > "$seed/plugin.php"
    git -C "$seed" add -A
    git -C "$seed" -c user.email=t@t -c user.name=t commit -q -m content
    git -C "$seed" tag v1.0.0
    git -C "$seed" push -q "$remote" HEAD:refs/heads/main --tags

    git clone -q --depth 1 --branch v1.0.0 "$remote" "$dir/theme/x" 2>/dev/null
}

installed_json_for() {
    cat <<JSON
{"project":{"name":"p","dir":"$1","vm":"mosaic-does-not-exist-$$"},
 "target":"m45","flavour":"moodle","framework":"moodle","version":"4.5","mode":"bake",
 "plugins_root":".","wwwroot":"t","php":{"version":"8.2"},
 "source":{"url":"x","ref":"y"},"db":{},"ports":{},
 "plugins":[{"source":"x","branch":"v1.0.0","destination":"theme/x"}],
 "project_files":[],
 "vm_paths":{"framework":"/srv/moodle","project":"/srv/project"}}
JSON
}

run_teardown() {   # <project-dir> → exit code, output on stdout
    local d=$1
    installed_json_for "$d" > "$d/.mosaic/installed.json"
    (cd "$d" && MOSAIC_ASSUME_YES=1 "$HOOK" < "$d/.mosaic/installed.json" 2>&1)
}

# 6a. clean at the tag (detached HEAD) — must PASS
D="$WORK/td-clean"; setup_teardown_project "$D"
out=$(run_teardown "$D"); rc=$?
if [[ $rc -eq 0 ]]; then ok_ "clean clone at its tag (detached HEAD) is torn down"
else bad_ "clean clone at its tag was refused" "$(echo "$out" | tail -3)"; fi
[[ ! -e "$D/theme/x" ]]      && ok_ "…plugin clone removed"        || bad_ "…plugin clone survived"
[[ ! -e "$D/lib" ]]          && ok_ "…manifest entry 'lib' removed" || bad_ "…manifest entry 'lib' survived"
[[ ! -e "$D/version.php" ]]  && ok_ "…version.php removed"          || bad_ "…version.php survived"
[[ ! -e "$D/config.php" ]]   && ok_ "…config.php removed"           || bad_ "…config.php survived"
[[ -e "$D/NOTES.md" ]]       && ok_ "…the user's own file untouched" || bad_ "…the user's own file was deleted"
[[ ! -e "$D/.mosaic/installed.json" ]] && ok_ "…installed.json removed last" || bad_ "…installed.json survived"
[[ ! -e "$D/.mosaic/bake-manifest" ]]  && ok_ "…bake-manifest removed"       || bad_ "…bake-manifest survived"

# 6b. dirty working tree — must REFUSE
D="$WORK/td-dirty"; setup_teardown_project "$D"
echo "edit" >> "$D/theme/x/plugin.php"
out=$(run_teardown "$D"); rc=$?
[[ $rc -ne 0 ]] && ok_ "uncommitted changes refuse" || bad_ "uncommitted changes were NOT refused"
[[ -e "$D/theme/x/plugin.php" ]] && ok_ "…and nothing was deleted" || bad_ "…but files were deleted anyway"

# 6c. untracked file — must REFUSE
D="$WORK/td-untracked"; setup_teardown_project "$D"
echo "scratch" > "$D/theme/x/notes.txt"
out=$(run_teardown "$D"); rc=$?
[[ $rc -ne 0 ]] && ok_ "untracked files refuse" || bad_ "untracked files were NOT refused"

# 6d. unpushed commit on a branch — must REFUSE
D="$WORK/td-unpushed"; setup_teardown_project "$D"
git -C "$D/theme/x" checkout -q -b work
echo x >> "$D/theme/x/plugin.php"
git -C "$D/theme/x" add -A
git -C "$D/theme/x" -c user.email=t@t -c user.name=t commit -q -m "local work"
out=$(run_teardown "$D"); rc=$?
[[ $rc -ne 0 ]] && ok_ "unpushed commits refuse" || bad_ "unpushed commits were NOT refused"

# 6e. stash — must REFUSE
D="$WORK/td-stash"; setup_teardown_project "$D"
echo y >> "$D/theme/x/plugin.php"
git -C "$D/theme/x" -c user.email=t@t -c user.name=t stash -q
out=$(run_teardown "$D"); rc=$?
[[ $rc -ne 0 ]] && ok_ "a non-empty stash refuses" || bad_ "a non-empty stash was NOT refused"

# 6f. detached at the WRONG commit — must REFUSE
D="$WORK/td-wrongcommit"; setup_teardown_project "$D"
git -C "$D/theme/x" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "detached work"
out=$(run_teardown "$D"); rc=$?
[[ $rc -ne 0 ]] && ok_ "detached HEAD away from the declared ref refuses" \
                || bad_ "detached HEAD at the wrong commit was NOT refused"
assert_contains "…and says which ref it expected" "v1.0.0" "$out"

# 6g. not a git repo at all — must REFUSE
D="$WORK/td-notrepo"; setup_teardown_project "$D"
rm -rf "$D/theme/x/.git"
out=$(run_teardown "$D"); rc=$?
[[ $rc -ne 0 ]] && ok_ "a plugin dir that isn't a git repo refuses" || bad_ "a non-repo plugin dir was NOT refused"

# 6h. installed.json is authoritative even after mosaic.yaml changes
D="$WORK/td-edited"; setup_teardown_project "$D"
make_multi "$D"                       # manifest now says m45/m51, plugins theme/x + local/y
python3 - "$D/mosaic.yaml" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
open(p,'w').write(s.replace('default_target: m45','default_target: m51'))
PY
out=$(run_teardown "$D"); rc=$?
[[ $rc -eq 0 ]] && ok_ "teardown ignores an edited manifest and uses installed.json" \
               || bad_ "teardown failed after the manifest was edited" "$(echo "$out" | tail -3)"

# 6h2. a plugin destination that escapes the project must refuse
D="$WORK/td-escape"; setup_teardown_project "$D"
installed_json_for "$D" | sed 's|"destination":"theme/x"|"destination":"../../etc/x"|' \
    > "$D/.mosaic/installed.json"
out=$(cd "$D" && MOSAIC_ASSUME_YES=1 "$HOOK" < "$D/.mosaic/installed.json" 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok_ "a plugin destination containing .. refuses" || bad_ "a .. destination was NOT refused"
[[ -e "$D/lib" ]] && ok_ "…and deletes nothing" || bad_ "…but deleted files anyway"

# 6i. a framework tree with no bake-manifest must refuse rather than guess
D="$WORK/td-nomanifest"; setup_teardown_project "$D"
rm "$D/.mosaic/bake-manifest"
out=$(run_teardown "$D"); rc=$?
[[ $rc -ne 0 ]] && ok_ "a host tree with no bake-manifest refuses" || bad_ "missing bake-manifest did NOT refuse"
[[ -e "$D/lib" ]] && ok_ "…and deletes nothing" || bad_ "…but deleted files anyway"

# 6j. backstop: a repo installed.json does NOT declare, holding work that
# exists nowhere else (no remote at all), inside a manifest entry — must
# REFUSE. This is the sync-graft-under-an-older-Mosaic / hand-cloned case.
D="$WORK/td-undeclared-work"; setup_teardown_project "$D"
mkdir -p "$D/local/undeclared"
git init -q "$D/local/undeclared"
echo work > "$D/local/undeclared/lib.php"
git -C "$D/local/undeclared" add -A
git -C "$D/local/undeclared" -c user.email=t@t -c user.name=t commit -q -m "only here"
out=$(run_teardown "$D"); rc=$?
[[ $rc -ne 0 ]] && ok_ "an undeclared repo with unpushed work refuses" \
                || bad_ "an undeclared repo with unpushed work was NOT refused"
assert_contains "…and says it isn't declared" "not declared" "$out"
[[ -e "$D/local/undeclared/lib.php" ]] && ok_ "…and nothing was deleted" || bad_ "…but files were deleted anyway"

# 6k. backstop: an undeclared repo that's a clean clone at a tag — every
# commit is on the remote, so teardown must PASS and remove it.
D="$WORK/td-undeclared-clean"; setup_teardown_project "$D"
git clone -q --depth 1 --branch v1.0.0 "$WORK/remotes/td-undeclared-clean-theme_x.git" "$D/local/extra" 2>/dev/null
out=$(run_teardown "$D"); rc=$?
[[ $rc -eq 0 ]] && ok_ "an undeclared clean clone at a tag is torn down" \
                || bad_ "an undeclared clean clone was refused" "$(echo "$out" | tail -3)"
[[ ! -e "$D/local/extra" ]] && ok_ "…and removed with its manifest entry" || bad_ "…but it survived"

# ==============================================================================
head_ "7. Core teardown.sh dispatch"
# ==============================================================================
N="$WORK/td-nothing"; make_multi "$N"
out=$(cd "$N" && "$REPO/scripts/teardown.sh" --yes 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok_ "teardown on a never-built project is a no-op" || bad_ "teardown on a never-built project failed" "$out"
assert_contains "…and says so" "nothing to tear down" "$out"

out=$(cd "$N" && "$REPO/scripts/teardown.sh" --bogus 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok_ "teardown rejects unknown flags" || bad_ "teardown accepted an unknown flag"

# A baked tree whose .mosaic state was lost entirely (version.php is the
# only trace): must reach the hook's manifest refusal, not "nothing to
# tear down".
V="$WORK/td-marker-only"; make_multi "$V"
: > "$V/version.php"
out=$(cd "$V" && MOSAIC_ASSUME_YES=1 "$REPO/scripts/teardown.sh" --yes 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok_ "a baked tree with only version.php refuses (not a no-op)" \
                || bad_ "version.php-only tree was treated as nothing installed" "$out"
assert_contains "…with the migration message" "bake-manifest" "$out"

# ==============================================================================
head_ "8. switch.sh validation"
# ==============================================================================
W="$WORK/sw"; make_multi "$W"
assert_dies "switch to an unknown target dies" bash -c "cd '$W' && '$REPO/scripts/switch.sh' nope --yes"
err=$(cd "$W" && "$REPO/scripts/switch.sh" nope --yes 2>&1 || true)
assert_contains "…and lists the known targets" "m45" "$err"

WL="$WORK/sw-legacy"; make_legacy "$WL"
assert_dies "switch in a project with no targets: dies" bash -c "cd '$WL' && '$REPO/scripts/switch.sh' m45 --yes"

cat > "$W/.mosaic/installed.json" <<'JSON'
{"target":"m45","framework":"moodle","version":"4.5","php":{"version":"8.2"},"plugins":[],"flavour":"moodle"}
JSON
out=$(cd "$W" && "$REPO/scripts/switch.sh" m45 --yes 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok_ "switch to the already-installed target is a no-op" || bad_ "switch to the installed target failed" "$out"
assert_contains "…and points at build for a rebuild" "mosaic build" "$out"

# A tree built before installed.json existed: switch must refuse and
# route through teardown, never build over it (fetch would skip the host
# clone and leave the old install's files under the new target).
WF="$WORK/sw-prefeature"; make_multi "$WF"
: > "$WF/version.php"
printf 'PLUGINS_ROOT=.\n' > "$WF/.mosaic/plugin-context"
out=$(cd "$WF" && "$REPO/scripts/switch.sh" m51 --yes 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok_ "switch on a pre-installed.json build refuses" \
                || bad_ "switch built over a pre-installed.json tree" "$out"
assert_contains "…and points at teardown" "mosaic teardown" "$out"

# ==============================================================================
head_ "8b. sync-graft records its clones into installed.json"
# ==============================================================================
# A plugin added to the manifest and cloned by sync-graft AFTER the build
# must appear in installed.json's plugin list — that list is what the
# teardown guard vouches refs with. The VM leg fails (no such VM), and
# the record must already be on disk by then.

SG="$WORK/sync-rec"; mkdir -p "$SG/.mosaic"
sg_remote="$WORK/remotes/sync-rec-local_z.git"
mkdir -p "$sg_remote"; git init -q --bare "$sg_remote"
sg_seed="$WORK/seed-sync-rec"
git init -q "$sg_seed"
: > "$sg_seed/lib.php"
git -C "$sg_seed" add -A
git -C "$sg_seed" -c user.email=t@t -c user.name=t commit -q -m content
git -C "$sg_seed" tag v1.0.0
git -C "$sg_seed" push -q "$sg_remote" HEAD:refs/heads/main --tags
cat > "$SG/mosaic.yaml" <<YAML
mosaic_version: "0.1"
default_target: m45
targets:
  m45:
    framework: moodle
    version: "4.5"
    php: { version: "8.2" }
    plugins:
      - { source: "$sg_remote", branch: "v1.0.0", destination: "local/z" }
db: { type: mariadb, version: "10.11" }
YAML
cat > "$SG/.mosaic/installed.json" <<'JSON'
{"target":"m45","framework":"moodle","version":"4.5","php":{"version":"8.2"},"plugins":[],"flavour":"moodle"}
JSON
out=$(cd "$SG" && "$REPO/scripts/sync-graft.sh" 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok_ "sync-graft still fails loudly at the VM leg (no VM here)" \
                || bad_ "sync-graft unexpectedly succeeded with no VM"
[[ -d "$SG/local/z/.git" ]] && ok_ "…the plugin was cloned first" || bad_ "…the plugin was not cloned"
assert_eq "…and installed.json now lists it" "local/z" \
    "$(yq -p json -r '.plugins[0].destination // ""' "$SG/.mosaic/installed.json" 2>/dev/null)"
assert_eq "…with the ref it was cloned at" "v1.0.0" \
    "$(yq -p json -r '.plugins[0].branch // ""' "$SG/.mosaic/installed.json" 2>/dev/null)"

# ==============================================================================
head_ "9. build.sh refuses to build over a different installed target"
# ==============================================================================
BB="$WORK/build-guard"; make_multi "$BB"
cat > "$BB/.mosaic/installed.json" <<'JSON'
{"target":"m51","framework":"moodle","version":"5.1","php":{"version":"8.3"},"plugins":[],"flavour":"moodle"}
JSON
err=$(cd "$BB" && "$REPO/scripts/build.sh" 2>&1 >/dev/null); rc=$?
[[ $rc -ne 0 ]] && ok_ "build over a different installed target dies" || bad_ "build over a different target was allowed"
assert_contains "…and points at switch" "mosaic switch" "$err"

# ==============================================================================
head_ "10. up on an unbuilt VM offers/points at build"
# ==============================================================================
# The `mosaic nuke && mosaic up` trap: with no VM, up must not reach
# limactl start. Non-interactively (stdin a pipe) the prompt is skipped
# and it dies pointing at build; the interactive offer itself needs a
# tty and stays a manual test.

if command -v limactl >/dev/null 2>&1; then
    U="$WORK/up-unbuilt"; make_multi "$U"    # basename → VM mosaic-up-unbuilt: never exists
    out=$(cd "$U" && "$REPO/scripts/up.sh" </dev/null 2>&1); rc=$?
    [[ $rc -ne 0 ]] && ok_ "up with no VM refuses non-interactively" \
                    || bad_ "up with no VM did not fail" "$out"
    assert_contains "…and points at build"        "mosaic build"   "$out"
    assert_contains "…and says the VM is missing" "does not exist" "$out"
else
    ok_ "SKIP: limactl not installed here"
fi

# ==============================================================================
printf '\n\033[0;36mSummary\033[0m\n  %d passed, %d failed\n\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
