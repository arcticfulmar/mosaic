# Mosaic — top-level recipes.
#
# Invoked via the `mosaic` shim (which sets MOSAIC_HOME and execs `just`
# against this file with --working-directory=<user's cwd>). Every recipe
# carries a one-line comment immediately above it — this is what `mosaic`
# (no args) prints for that recipe. Longer explanation, when needed,
# follows the recipe body.
#
# Recipes that operate on a Mosaic project (build, up, down, ...) read
# the project's mosaic.yaml from {{invocation_directory()}} and use it
# to drive what they do. There is no per-project justfile — the whole
# tool surface lives here.

# Print this list of recipes.
default:
    @just --list --unsorted --justfile "{{justfile_directory()}}/justfile"

# Scaffold a new Mosaic project under cwd.
new NAME *FLAGS='':
    @"{{justfile_directory()}}/scripts/new.sh" "{{NAME}}" {{FLAGS}}
# Examples:
#   mosaic new myproj                                 # interactive
#   mosaic new myproj --framework=moodle --version=4.5
#   mosaic new myproj --framework=laravel --source=git@…:repo.git --no-confirm

# Show the current port-offset (next `mosaic new` writes one above this).
port-offset:
    @"{{justfile_directory()}}/scripts/port-offset.sh" show

# List available framework profiles (framework/version combinations).
frameworks:
    @find "{{justfile_directory()}}/frameworks" -name '*.yaml' \
        | sed -e "s|{{justfile_directory()}}/frameworks/||" -e 's|\.yaml$||' \
        | sort

# Print resolved cross-project defaults.
defaults:
    @cat "{{justfile_directory()}}/defaults.yaml"

# Print MOSAIC_HOME (Mosaic's install location).
home:
    @echo "{{justfile_directory()}}"

# Provision the VM, fetch source, install the framework. (NOT YET IMPLEMENTED.)
[no-exit-message]
build:
    @echo "mosaic build: not yet implemented." >&2
    @echo "" >&2
    @echo "This recipe will eventually:" >&2
    @echo "  1. Read mosaic.yaml from the current directory" >&2
    @echo "  2. Provision a Lima VM" >&2
    @echo "  3. Fetch framework source (bake mode) or clone the project (mount mode)" >&2
    @echo "  4. Clone plugins + mixins, wire up bind-mounts" >&2
    @echo "  5. Run framework install" >&2
    @echo "" >&2
    @echo "For now: scaffold a project with \`mosaic new\` and inspect mosaic.yaml." >&2
    @exit 1
