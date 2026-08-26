#!/usr/bin/env bash
# get: print one resolved field of cwd's project manifest.
#
# Usage: get.sh [--installed] <field>
#   get.sh php.version
#   get.sh --installed framework
#
# Exists so justfile recipes stop reading mosaic.yaml with inline yq.
# A bare `yq -r '.framework' mosaic.yaml` sees only the top-level layer,
# which on a multi-target manifest is the shared *defaults*, not the
# target being worked on — so `mosaic cli` would run against the wrong
# framework tree. Every read goes through lib.sh's overlay instead.
#
# --installed prefers .mosaic/installed.json — the resolved config of the
# last successful build. Use it for recipes that act on what is *running*
# (`up`, `down`, `reload-web`, `cli`, `purge`, …) rather than on what the
# manifest currently asks for: the two differ between `mosaic switch`
# writing the desired target and the build that follows completing, and
# in that window it's the installed one you want to stop, restart or
# shell into. Falls back to the manifest when nothing is installed yet.
#
# Failure posture: dies only where resolve.sh would — i.e. when the field
# is absent from both the target and the top-level layer, or when the
# active target doesn't exist. Anything looser and a stale state file
# would silently return the wrong value, which is the whole failure mode
# this script exists to prevent.

set -euo pipefail
. "$(dirname "$0")/lib.sh"

require_project
command -v yq >/dev/null 2>&1 || die "yq not found"

INSTALLED=0
if [[ ${1:-} == "--installed" ]]; then
    INSTALLED=1
    shift
fi

[[ $# -eq 1 ]] || die "usage: get.sh [--installed] <field>   (e.g. php.version)"
FIELD=$1

if [[ $INSTALLED -eq 1 ]]; then
    project_installed_get "$FIELD"
else
    project_yaml_get "$FIELD"
fi
