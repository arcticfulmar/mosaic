#!/usr/bin/env bash
# plugins: list the active target's plugin entries from cwd's mosaic.yaml.
#
# Single source of truth: the yaml. No filesystem walk, no separate
# manifest — `mosaic plugins` is a thin renderer over what's declared.

set -euo pipefail
. "$(dirname "$0")/lib.sh"

require_project
command -v yq >/dev/null 2>&1 || die "yq not found"

# Lists the ACTIVE target's plugins on a multi-target manifest — the
# same list `mosaic build` would clone. `mosaic targets` shows the
# per-target counts.
project_target_init
target=$(project_active_target)

count=$(project_plugin_count)
if [[ $count -eq 0 ]]; then
    say "(no plugins declared in mosaic.yaml${target:+ for target '$target'})"
    exit 0
fi

framework=$(project_yaml_get framework)
version=$(project_yaml_get version)
plugin_base=$(project_host_plugin_base "$framework" "$version")

PLUGINS_JSON=$(project_plugins_json)
plug() { printf '%s' "$PLUGINS_JSON" | yq -p json -r "$1"; }

info "$count plugin(s)${target:+ in target '$target'}:"
for ((i=0; i<count; i++)); do
    p_source=$(plug ".[$i].source")
    p_branch=$(plug ".[$i].branch // \"main\"")
    p_dest=$(plug ".[$i].destination")
    if [[ $plugin_base == "." ]]; then
        host_path="./$p_dest"
    else
        host_path="./$plugin_base/$p_dest"
    fi
    say  ""
    kv "destination" "$p_dest"
    kv "source"      "$p_source"
    kv "branch"      "$p_branch"
    kv "host path"   "$host_path"
done
