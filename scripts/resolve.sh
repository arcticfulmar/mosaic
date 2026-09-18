#!/usr/bin/env bash
# resolve: mosaic.yaml + framework profile (+ defaults + backend facts)
# → resolved config JSON on stdout.
#
# This is the single place where profile inheritance (`extends`),
# git-ref patterns, plugins_root, the framework→flavour mapping and the
# backend choice are computed. Everything downstream — build.sh's
# orchestration and every flavour hook — consumes the JSON this emits
# and never reads mosaic.yaml or frameworks/*.yaml itself. That's the
# hook contract's data boundary (docs/flavour-architecture.md).
#
# Run from inside a project (or pipe to a hook):
#   scripts/resolve.sh | flavours/moodle/hooks/install
#
# Backend facts (backends/<name>/driver facts) are folded in under
# `.backend` so flavours can branch on *properties* of the runtime
# (native_storage, service_user) without ever naming the runtime.

set -euo pipefail
. "$(dirname "$0")/lib.sh"

require_project

FRAMEWORK=$(project_yaml_get framework) || exit 1
VERSION=$(project_yaml_get version) || exit 1

# framework → flavour. Keep in sync with bin/mosaic's map until
# flavour.yaml lands.
case $FRAMEWORK in
    moodle|workplace|totara) FLAVOUR=moodle ;;
    laravel)                 FLAVOUR=laravel ;;
    *) die "unknown framework '$FRAMEWORK' (known: moodle, workplace, totara, laravel)" ;;
esac

MODE=$(profile_get "$FRAMEWORK" "$VERSION" 'mode') || exit 1
[[ -n $MODE ]] || die "framework profile has no 'mode' field"

PLUGINS_ROOT=$(project_plugins_root "$FRAMEWORK" "$VERSION") || exit 1
PHP_VERSION=$(project_yaml_get php.version) || exit 1
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
    SOURCE_REF=$(resolve_git_ref "$REF_PATTERN" "$VERSION") || exit 1
else
    SOURCE_URL=$(project_yaml_get_or project.source '')
    SOURCE_REF=$(project_yaml_get_or project.branch main)
fi

# Backend + its facts. The driver answers `facts` without a project.
BACKEND=$(project_backend) || exit 1
DRIVER=$(backend_driver "$BACKEND") || exit 1
BACKEND_FACTS=$("$DRIVER" facts) || die "backend '$BACKEND' failed to report facts"

# Where the served framework tree lives inside the guest. Bake-mode
# flavours on a virtiofs backend keep a guest-native copy at
# /srv/<framework>; on a native-storage backend the host tree IS the
# served tree, so the framework root is the project mount itself.
NATIVE=$(printf '%s' "$BACKEND_FACTS" | yq -r '.native_storage // false')
if [[ $MODE == "bake" && $NATIVE != "true" ]]; then
    GUEST_FRAMEWORK="/srv/$FRAMEWORK"
else
    GUEST_FRAMEWORK="/srv/project"
fi

export FRAMEWORK VERSION FLAVOUR MODE PLUGINS_ROOT PHP_VERSION WWWROOT \
       SOURCE_URL SOURCE_REF BACKEND BACKEND_FACTS GUEST_FRAMEWORK
export PROJECT_NAME=$(basename "$(pwd)")
export PROJECT_DIR=$(pwd)
export VM_NAME=$(project_vm_name)
export STATE_DIR=$(project_state_dir)

# Assemble the JSON. Scalars come in via strenv() (always strings —
# consumers are shell, so everything is text anyway); structured
# sections (ports, db, plugins, project_files) are lifted verbatim
# from mosaic.yaml so their native types survive.
yq -n -o=json '
{
  "project": {
    "name":      strenv(PROJECT_NAME),
    "dir":       strenv(PROJECT_DIR),
    "vm":        strenv(VM_NAME),
    "state_dir": strenv(STATE_DIR)
  },
  "flavour":      strenv(FLAVOUR),
  "framework":    strenv(FRAMEWORK),
  "version":      strenv(VERSION),
  "mode":         strenv(MODE),
  "plugins_root": strenv(PLUGINS_ROOT),
  "wwwroot":      strenv(WWWROOT),
  "php":          { "version": strenv(PHP_VERSION) },
  "source":       { "url": strenv(SOURCE_URL), "ref": strenv(SOURCE_REF) },
  "db":            (load("mosaic.yaml") | .db // {}),
  "ports":         (load("mosaic.yaml") | .ports // {}),
  "vm":            (load("mosaic.yaml") | .vm // {}),
  "plugins":       (load("mosaic.yaml") | .plugins // []),
  "project_files": (load("mosaic.yaml") | .project_files // []),
  "backend":       ({"name": strenv(BACKEND)} * (strenv(BACKEND_FACTS) | fromjson)),
  "vm_paths": {
    "framework": strenv(GUEST_FRAMEWORK),
    "project":   "/srv/project"
  }
}'
