#!/usr/bin/env bash
# targets: list the targets declared in cwd's mosaic.yaml, marking which
# is active (what the next build would build) and which is installed
# (what's on disk right now).
#
# Those two are usually the same. They differ exactly while a switch is
# in flight — or after one was interrupted — which is precisely when
# you'd want to look.

set -euo pipefail
. "$(dirname "$0")/lib.sh"

require_project
command -v yq >/dev/null 2>&1 || die "yq not found"

INSTALLED_JSON=.mosaic/installed.json

installed_target=''
installed_any=0
if [[ -f $INSTALLED_JSON ]]; then
    installed_any=1
    installed_target=$(yq -p json -r '.target // ""' "$INSTALLED_JSON")
fi

kind=$(yq -r '.targets | type' mosaic.yaml)

# --- single-target manifest ---------------------------------------------------
# Not an error: `targets:` is optional, and most projects never need it.
# Show what the project resolves to, and how to gain targets.
if [[ $kind != "!!map" ]]; then
    info "This project declares no targets:"
    kv "framework" "$(project_yaml_get framework) $(project_yaml_get version)"
    kv "php"       "$(project_yaml_get php.version)"
    kv "plugins"   "$(project_plugin_count)"
    kv "installed" "$( ((installed_any)) && echo yes || echo "no — run 'mosaic build'")"
    echo
    say "Add a 'targets:' map to mosaic.yaml to build several framework/plugin"
    say "combinations from this one project, one at a time:"
    say ""
    say "  default_target: moodle-45"
    say "  targets:"
    say "    moodle-45: { framework: moodle, version: \"4.5\", plugins: [ ... ] }"
    say "    moodle-51: { framework: moodle, version: \"5.1\", plugins: [ ... ] }"
    exit 0
fi

# The active target — validated, so a stale active-target reports itself
# here rather than at the next build.
active=$(project_active_target)

info "Targets in $(basename "$(pwd)")/mosaic.yaml"
echo

while IFS= read -r name; do
    [[ -n $name ]] || continue

    fw=$(T="$name" yq -r '.targets[strenv(T)].framework // .framework // "?"' mosaic.yaml)
    ver=$(T="$name" yq -r '.targets[strenv(T)].version // .version // "?"' mosaic.yaml)
    php=$(T="$name" yq -r '.targets[strenv(T)].php.version // .php.version // "?"' mosaic.yaml)
    n=$(T="$name" yq -r '(.targets[strenv(T)].plugins // .plugins // []) | length' mosaic.yaml)

    marks=''
    [[ $name == "$active" ]] && marks="active"
    if [[ $installed_any -eq 1 && $name == "$installed_target" ]]; then
        marks="${marks:+$marks, }installed"
    fi

    # A leading * on the line the eye should land on first.
    if [[ -n $marks ]]; then
        printf '  %s*%s %-16s %s%-22s%s %-9s %s%s%s\n' \
            "$_C_GREEN" "$_C_RESET" "$name" "$_C_CYAN" "$fw $ver" "$_C_RESET" \
            "php $php" "$_C_DIM" "$n plugin(s)  [$marks]" "$_C_RESET"
    else
        printf '    %-16s %s%-22s%s %-9s %s%s%s\n' \
            "$name" "$_C_CYAN" "$fw $ver" "$_C_RESET" \
            "php $php" "$_C_DIM" "$n plugin(s)" "$_C_RESET"
    fi
done < <(yq -r '.targets | keys | .[]' mosaic.yaml)

echo
if [[ $installed_any -eq 0 ]]; then
    say "Nothing is installed yet — 'mosaic build' builds '$active'."
elif [[ $installed_target != "$active" ]]; then
    warn "'$active' is active but '$installed_target' is what's installed."
    say  "A switch was interrupted. Re-run 'mosaic switch $active' to finish it."
else
    say "'mosaic switch <target>' tears this one down and builds another."
fi
