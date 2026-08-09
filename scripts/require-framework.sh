#!/usr/bin/env bash
# require-framework: die unless cwd's mosaic.yaml's framework matches
# one of the allowed values.
#
# Usage: require-framework <allowed1> [<allowed2> ...]
#
# Used as a guard at the top of framework-specific just recipes —
# the listing in `mosaic` (no args) hides recipes for the wrong
# framework, but `just` doesn't refuse to RUN them. This guard
# turns "cd into laravel project, run `mosaic init-phpunit` by
# muscle memory" into a clear error rather than a confusing
# "/srv/moodle does not exist" downstream.

set -euo pipefail
. "$(dirname "$0")/lib.sh"

require_project

actual=$(project_yaml_get framework)
for allowed in "$@"; do
    [[ $actual == "$allowed" ]] && exit 0
done

die "this recipe requires framework: $* (project's framework is: $actual)"
