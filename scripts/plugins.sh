#!/usr/bin/env bash
# plugins: list plugin entries from cwd's mosaic.yaml.
#
# Single source of truth: the yaml. No filesystem walk, no separate
# manifest — `mosaic plugins` is a thin renderer over what's declared.

set -euo pipefail
. "$(dirname "$0")/lib.sh"

require_project
command -v yq >/dev/null 2>&1 || die "yq not found"

count=$(project_plugin_count)
if [[ $count -eq 0 ]]; then
    say "(no plugins declared in mosaic.yaml)"
    exit 0
fi

framework=$(project_yaml_get framework)
version=$(project_yaml_get version)
plugin_base=$(project_host_plugin_base "$framework" "$version")

info "$count plugin(s):"
for ((i=0; i<count; i++)); do
    p_source=$(yq -r ".plugins[$i].source" mosaic.yaml)
    p_branch=$(yq -r ".plugins[$i].branch // \"main\"" mosaic.yaml)
    p_dest=$(yq -r ".plugins[$i].destination" mosaic.yaml)
    say  ""
    kv "destination" "$p_dest"
    kv "source"      "$p_source"
    kv "branch"      "$p_branch"
    kv "host path"   "./$plugin_base/$p_dest"
done
