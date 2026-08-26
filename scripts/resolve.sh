#!/usr/bin/env bash
# resolve: mosaic.yaml + framework profile (+ defaults) → resolved
# config JSON on stdout.
#
# This is the single place where profile inheritance (`extends`),
# git-ref patterns, plugins_root and the framework→flavour mapping are
# computed. Everything downstream — build.sh's orchestration and every
# flavour hook — consumes the JSON this emits and never reads
# mosaic.yaml or frameworks/*.yaml itself. That's the hook contract's
# data boundary (docs/flavour-architecture.md).
#
# Multi-target manifests resolve through the same path: the active
# target's fields shadow the top-level ones (lib.sh), so what this emits
# is always one concrete install — the notion of "several targets" stops
# at this boundary and nothing downstream has to know about it.
#
# Run from inside a project (or pipe to a hook):
#   scripts/resolve.sh | flavours/moodle/hooks/install
#
# The eventual flavour-owned `resolve` hook (flavour.yaml + versions/)
# will replace the body of this script; its stdout contract is already
# the one documented, so callers won't change.

set -euo pipefail
. "$(dirname "$0")/lib.sh"

require_project

# Resolve the active target once, up front: every project_yaml_get below
# is an overlay read (target value shadows top-level), and doing this
# here saves each of them a second yq invocation. Dies on an unknown or
# ambiguous target name — see lib.sh's project_target_init.
project_target_init
TARGET=$(project_active_target)

FRAMEWORK=$(project_yaml_get framework)
VERSION=$(project_yaml_get version)

# framework → flavour. Keep in sync with bin/mosaic's map until
# flavour.yaml lands.
flavour_for() {
    case $1 in
        moodle|workplace|totara) printf 'moodle' ;;
        laravel)                 printf 'laravel' ;;
        *) die "unknown framework '$1' (known: moodle, workplace, totara, laravel)" ;;
    esac
}

FLAVOUR=$(flavour_for "$FRAMEWORK") || exit 1

# Every target must land on the same flavour. The Lima template is
# chosen at VM creation and never re-rendered for an existing instance
# (render-lima.sh only passes .mosaic/lima.yaml to `limactl` for a
# brand-new VM), so a moodle→laravel switch inside one project would
# build a target the VM can't serve. Refuse now, with the escape hatch
# spelled out, rather than half-building it later.
if [[ -n $TARGET ]]; then
    while read -r _t_name _t_fw; do
        [[ -n $_t_name ]] || continue
        [[ -n $_t_fw ]] ||
            die "target '$_t_name' has no framework: — set one there or at the top level"
        _t_flavour=$(flavour_for "$_t_fw") || exit 1
        [[ $_t_flavour == "$FLAVOUR" ]] ||
            die "target '$_t_name' is $_t_fw (flavour: $_t_flavour) but '$TARGET' is $FRAMEWORK (flavour: $FLAVOUR)
       all targets in one project must share a flavour — the VM is built for one.
       For a different flavour, use a separate project (or 'mosaic nuke' and rebuild)."
    done < <(yq -r '.framework as $top | [.targets | to_entries[] | .key + " " + (.value.framework // $top // "")] | .[]' mosaic.yaml)
fi

MODE=$(profile_get "$FRAMEWORK" "$VERSION" 'mode')
[[ -n $MODE ]] || die "framework profile has no 'mode' field"

PLUGINS_ROOT=$(project_plugins_root "$FRAMEWORK" "$VERSION")
PHP_VERSION=$(project_yaml_get php.version)
WWWROOT=$(project_yaml_get_or wwwroot localhost)

# Source resolution differs by mode:
#   bake  → framework source: mosaic.yaml `source:` override, else the
#           profile's; ref computed from git_ref_pattern + version.
#   mount → the user's own app repo from `project.source` (may be empty
#           = scaffold fresh); ref is a plain branch name.
if [[ $MODE == "bake" ]]; then
    SOURCE_URL=$(project_yaml_get_or 'source' '')
    [[ -n $SOURCE_URL ]] || SOURCE_URL=$(profile_get "$FRAMEWORK" "$VERSION" 'source')
    [[ -n $SOURCE_URL ]] || die "no source URL — set 'source' in mosaic.yaml or in the framework profile"
    REF_PATTERN=$(profile_get "$FRAMEWORK" "$VERSION" 'git_ref_pattern')
    [[ -n $REF_PATTERN ]] || die "framework profile has no 'git_ref_pattern'"
    SOURCE_REF=$(resolve_git_ref "$REF_PATTERN" "$VERSION")
else
    SOURCE_URL=$(project_yaml_get_or project.source '')
    SOURCE_REF=$(project_yaml_get_or project.branch main)
fi

export FRAMEWORK VERSION FLAVOUR MODE PLUGINS_ROOT PHP_VERSION WWWROOT \
       SOURCE_URL SOURCE_REF TARGET
export PROJECT_NAME=$(basename "$(pwd)")
export PROJECT_DIR=$(pwd)
export VM_NAME=$(project_vm_name)

# Assemble the JSON. Scalars come in via strenv() (always strings —
# consumers are shell, so everything is text anyway); structured
# sections (ports, db, plugins, project_files) are lifted verbatim
# from mosaic.yaml so their native types survive.
#
# The structured lifts are target-aware where the schema allows it:
#
#   db        deep-merged, so a target overriding only `version:` keeps
#             the shared `type:`;
#   plugins   replaced wholesale — an empty `plugins: []` in a target
#             means "none", not "inherit" (yq's `//` only falls through
#             on null, and [] isn't null);
#   ports,
#   project_files
#             top-level only. Both are shared across targets by design
#             (see lib.sh's targets section); a target that sets either
#             is rejected before we get here.
#
# `target` is emitted so downstream consumers — and .mosaic/installed.json,
# which is this JSON — record *which* target produced this config. Empty
# string for a single-target manifest.
yq -n -o=json 'load("mosaic.yaml") as $m |
{
  "project": {
    "name": strenv(PROJECT_NAME),
    "dir":  strenv(PROJECT_DIR),
    "vm":   strenv(VM_NAME)
  },
  "target":       strenv(TARGET),
  "flavour":      strenv(FLAVOUR),
  "framework":    strenv(FRAMEWORK),
  "version":      strenv(VERSION),
  "mode":         strenv(MODE),
  "plugins_root": strenv(PLUGINS_ROOT),
  "wwwroot":      strenv(WWWROOT),
  "php":          { "version": strenv(PHP_VERSION) },
  "source":       { "url": strenv(SOURCE_URL), "ref": strenv(SOURCE_REF) },
  "db":            (($m.db // {}) * ($m.targets[strenv(TARGET)].db // {})),
  "ports":         ($m.ports // {}),
  "plugins":       ($m.targets[strenv(TARGET)].plugins // $m.plugins // []),
  "project_files": ($m.project_files // []),
  "vm_paths": {
    "framework": ("/srv/" + strenv(FRAMEWORK)),
    "project":   "/srv/project"
  }
}'
