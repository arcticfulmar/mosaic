#!/usr/bin/env bash
# Mosaic — scaffold a new project.
#
# Reads framework profile defaults, prompts for what's missing, allocates
# ports against the per-user offset counter, and writes
# ./<name>/mosaic.yaml. Does NOT provision a VM or clone any source —
# that's what `mosaic build` is for.
#
# Usage:
#   mosaic new <name> [--framework=X] [--version=Y] [--php=Z]
#                     [--db=W] [--db-version=V]
#                     [--source=URL] [--branch=B] [--destination=D]
#                     [--no-confirm]
#
# Flags pre-fill answers and skip the corresponding prompt. Plugins are
# always interactive (no flag form); add to mosaic.yaml by hand if you
# need scripted plugin entry.

set -euo pipefail
. "$(dirname "$0")/lib.sh"

HOME_DIR=$(mosaic_home)
DEFAULTS_YAML="$HOME_DIR/defaults.yaml"

# --- dependencies ------------------------------------------------------------
command -v yq >/dev/null 2>&1 || die "yq not found (brew install yq)"

# --- args --------------------------------------------------------------------
NAME=${1:-}
[[ -z $NAME ]] && die "usage: mosaic new <name> [flags]"
shift || true

# Project name validation — must be safe as both a directory name and a
# Lima VM name. Lima's own validator rejects dots, slashes, and most
# punctuation, so we mirror that here for an early, clear error.
if [[ ! $NAME =~ ^[a-z][a-z0-9-]*$ ]]; then
    die "project name must be lower-case letters/digits/hyphens, starting with a letter (got: '$NAME')"
fi

[[ -e $NAME ]] && die "./$NAME already exists; pick another name or remove it"

FRAMEWORK=''
VERSION=''
PHP=''
DB_TYPE=''
DB_VERSION=''
WWWROOT=''
PROJECT_SOURCE=''
PROJECT_BRANCH=''
PROJECT_DESTINATION=''
SKIP_CONFIRM=0

for arg in "$@"; do
    case $arg in
        --framework=*)   FRAMEWORK=${arg#*=} ;;
        --version=*)     VERSION=${arg#*=} ;;
        --php=*)         PHP=${arg#*=} ;;
        --db=*)          DB_TYPE=${arg#*=} ;;
        --db-version=*)  DB_VERSION=${arg#*=} ;;
        --wwwroot=*)     WWWROOT=${arg#*=} ;;
        --source=*)      PROJECT_SOURCE=${arg#*=} ;;
        --branch=*)      PROJECT_BRANCH=${arg#*=} ;;
        --destination=*) PROJECT_DESTINATION=${arg#*=} ;;
        --no-confirm)    SKIP_CONFIRM=1 ;;
        *) die "unknown flag: $arg" ;;
    esac
done

# List available frameworks (subdirs of frameworks/), one per line, sorted.
# Single source of truth for both flag validation and the interactive
# prompt's choice list — adding a new profile directory is enough to
# expose it everywhere.
list_frameworks() {
    local d
    for d in "$HOME_DIR"/frameworks/*/; do
        [[ -d $d ]] && basename "$d"
    done | sort
}

# Early validation of --framework so we fail BEFORE prompting for any
# follow-up values. Without this, the user types a version, then a php,
# then watches the script die because the profile lookup couldn't find
# their bogus framework name.
if [[ -n $FRAMEWORK ]]; then
    if ! list_frameworks | grep -qFx "$FRAMEWORK"; then
        avail=$(list_frameworks | tr '\n' ' ')
        die "unknown framework '$FRAMEWORK' (available: ${avail% })"
    fi
fi

# Profile resolution (profile_file, profile_get, profile_caps) lives in
# lib.sh — also used by `mosaic build` so the resolution rules stay in one
# place.

# --- prompts -----------------------------------------------------------------

if [[ -z $FRAMEWORK ]]; then
    default_fw=$(yq -r '.defaults.framework // "moodle"' "$DEFAULTS_YAML")
    # Drive the choice list from the framework profile directory rather
    # than hardcoding — keeps prompt and flag-validation in lockstep.
    # Plain `while read` rather than `mapfile -t`: macOS ships bash 3.2
    # which lacks mapfile. Mosaic shouldn't force users to install
    # bash 4 just to run the scaffolder.
    available_frameworks=()
    while IFS= read -r line; do
        available_frameworks+=("$line")
    done < <(list_frameworks)
    FRAMEWORK=$(ask_choice "framework?" "$default_fw" "${available_frameworks[@]}")
fi

if [[ -z $VERSION ]]; then
    case $FRAMEWORK in
        moodle|workplace) default_ver="4.5" ;;
        laravel)          default_ver="13"  ;;
        *)                default_ver=""    ;;
    esac
    VERSION=$(ask_default "version?" "$default_ver")
fi

# Verify a profile resolves; die early with a clear error rather than
# producing a half-formed mosaic.yaml that fails at build time.
PROF_FILE=$(profile_file "$FRAMEWORK" "$VERSION")
info "using framework profile: ${PROF_FILE#$HOME_DIR/}"
MODE=$(profile_get "$FRAMEWORK" "$VERSION" "mode")
[[ -z $MODE ]] && die "framework profile '$PROF_FILE' is missing the required 'mode' field"

if [[ -z $PHP ]]; then
    default_php=$(profile_get "$FRAMEWORK" "$VERSION" "default_php")
    PHP=$(ask_default "php version?" "${default_php:-8.2}")
fi

if [[ -z $DB_TYPE ]]; then
    default_db=$(profile_get "$FRAMEWORK" "$VERSION" "default_db_type")
    DB_TYPE=$(ask_choice "database type?" "${default_db:-mariadb}" mariadb mysql pgsql)
fi

if [[ -z $DB_VERSION ]]; then
    default_db_ver=$(profile_get "$FRAMEWORK" "$VERSION" "default_db_version")
    DB_VERSION=$(ask_default "database version?" "${default_db_ver:-10.11}")
fi

# wwwroot — what hostname goes into config.php and what the browser uses.
# `localhost` is the lowest-friction default (no host /etc/hosts edit). A
# custom name like `moodle.test` requires the user to add a host-side
# /etc/hosts entry; `mosaic build` reminds them at the end.
if [[ -z $WWWROOT ]]; then
    WWWROOT=$(ask_default "web hostname?" "localhost")
fi

# Plugins (bake mode) or single-project source (mount mode). The two are
# mutually exclusive — bake mode never has a `project:` block, mount mode
# never has a `plugins:` block.
PLUGINS_YAML=''
if [[ $MODE == "bake" ]]; then
    echo
    info "Add plugins. Press enter on a blank source URL to finish."
    while true; do
        plugin_src=$(ask_default "  plugin source URL (blank = done)" "")
        [[ -z $plugin_src ]] && break
        plugin_branch=$(ask_default "  branch?" "main")
        plugin_dest=$(ask "  destination (e.g. local/myplugin)")
        PLUGINS_YAML+="  - source: $plugin_src"$'\n'
        PLUGINS_YAML+="    branch: $plugin_branch"$'\n'
        PLUGINS_YAML+="    destination: $plugin_dest"$'\n'
    done

    # Mixins: only offered if the active profile lists them as a capability.
    # Refuses early on profiles where mixins make no sense (future Laravel
    # / WordPress) rather than letting the user write a yaml that fails
    # at build.
    if profile_caps "$FRAMEWORK" "$VERSION" | grep -qFx 'mixins'; then
        if ask_yn "include mixins?" y; then
            mixins_src=$(ask "  mixins repo source URL")
            mixins_branch=$(ask_default "  branch?" "main")
            PLUGINS_YAML+="  - source: $mixins_src"$'\n'
            PLUGINS_YAML+="    branch: $mixins_branch"$'\n'
            PLUGINS_YAML+="    destination: mixins"$'\n'
        fi
    fi
fi

PROJECT_YAML=''
if [[ $MODE == "mount" ]]; then
    [[ -z $PROJECT_SOURCE      ]] && PROJECT_SOURCE=$(ask "project source URL")
    [[ -z $PROJECT_BRANCH      ]] && PROJECT_BRANCH=$(ask_default "branch?" "main")
    [[ -z $PROJECT_DESTINATION ]] && PROJECT_DESTINATION=$(ask_default "destination?" "$FRAMEWORK")
    PROJECT_YAML+="project:"$'\n'
    PROJECT_YAML+="  source: $PROJECT_SOURCE"$'\n'
    PROJECT_YAML+="  branch: $PROJECT_BRANCH"$'\n'
    PROJECT_YAML+="  destination: $PROJECT_DESTINATION"$'\n'
fi

# --- port allocation ---------------------------------------------------------
# Increment the per-user offset counter, then derive each port from its
# base. Counter state lives at ~/.local/state/mosaic/port-offset and is
# shared across every project this user has scaffolded — so two projects
# in a row never collide on default ports.

OFFSET=$("$HOME_DIR/scripts/port-offset.sh" next)

WEB_BASE=$(yq -r '.ports.web_base'          "$DEFAULTS_YAML")
MAILPIT_UI_BASE=$(yq -r '.ports.mailpit_ui_base'   "$DEFAULTS_YAML")
MAILPIT_SMTP_BASE=$(yq -r '.ports.mailpit_smtp_base' "$DEFAULTS_YAML")
case $DB_TYPE in
    mariadb) DB_BASE=$(yq -r '.ports.db_mariadb_base' "$DEFAULTS_YAML") ;;
    mysql)   DB_BASE=$(yq -r '.ports.db_mysql_base'   "$DEFAULTS_YAML") ;;
    pgsql)   DB_BASE=$(yq -r '.ports.db_pgsql_base'   "$DEFAULTS_YAML") ;;
esac
WEB_PORT=$((WEB_BASE + OFFSET))
DB_PORT=$((DB_BASE + OFFSET))
MAILPIT_UI_PORT=$((MAILPIT_UI_BASE + OFFSET))
MAILPIT_SMTP_PORT=$((MAILPIT_SMTP_BASE + OFFSET))

# --- vm sizing ---------------------------------------------------------------

VM_CPUS=$(yq -r '.vm.cpus'   "$DEFAULTS_YAML")
VM_MEMORY=$(yq -r '.vm.memory' "$DEFAULTS_YAML")
VM_DISK=$(yq -r '.vm.disk'   "$DEFAULTS_YAML")

# --- summary + confirm -------------------------------------------------------

echo
info "Project summary"
kv "name"        "$NAME"
kv "framework"   "$FRAMEWORK"
kv "version"     "$VERSION"
kv "mode"        "$MODE"
kv "php"         "$PHP"
kv "db"          "$DB_TYPE $DB_VERSION"
kv "wwwroot"     "$WWWROOT"
[[ $MODE == "bake" && -n $PROJECT_SOURCE ]] && kv "source override" "$PROJECT_SOURCE"
kv "ports"       "web=$WEB_PORT db=$DB_PORT mailpit=$MAILPIT_UI_PORT/$MAILPIT_SMTP_PORT"
kv "vm"          "cpus=$VM_CPUS memory=$VM_MEMORY disk=$VM_DISK"
if [[ $MODE == "bake" ]]; then
    if [[ -n $PLUGINS_YAML ]]; then
        echo "  plugins:"
        printf '%s' "$PLUGINS_YAML" | sed "s/^/    /; s/^    /  /"
    else
        kv "plugins"    "(none)"
    fi
elif [[ $MODE == "mount" ]]; then
    kv "project src" "$PROJECT_SOURCE@$PROJECT_BRANCH → ./$PROJECT_DESTINATION"
fi
echo

if [[ $SKIP_CONFIRM -eq 0 ]]; then
    if ! ask_yn "create project ./$NAME?" y; then
        warn "aborted; port-offset has been bumped to $OFFSET — pin ports in mosaic.yaml or accept the gap"
        exit 1
    fi
fi

# --- write project -----------------------------------------------------------
#
# `mosaic new` writes ONLY the manifest. Everything else (./.devenv/ with
# nginx.conf etc., the host clone of the framework, plugin directories) is
# produced by `mosaic build`. Creating empty placeholder directories here
# would imply content that isn't there yet.

mkdir -p "$NAME"
yaml="$NAME/mosaic.yaml"

# Heredoc for the invariant header; plugins/project blocks are appended
# afterwards because their length and presence depend on the mode.
{
    cat <<EOF
# Mosaic project manifest. Edit this file to reconfigure; run \`mosaic build\`
# to apply. Generated by \`mosaic new\` at $(date -u +%Y-%m-%dT%H:%M:%SZ).

mosaic_version: "0.1"

framework: $FRAMEWORK
version: "$VERSION"

php:
  version: "$PHP"

db:
  type: $DB_TYPE
  version: "$DB_VERSION"

# Hostname Moodle bakes into wwwroot. \`localhost\` is friction-free; any
# custom name (e.g. moodle.test) needs an /etc/hosts entry on the host.
wwwroot: $WWWROOT
EOF
    if [[ $MODE == "bake" && -n $PROJECT_SOURCE ]]; then
        cat <<EOF

# Source URL override. Wins over the framework profile's default
# (typically used when the dev's ssh config aliases the upstream host
# — e.g. \`titus-bitbucket:...\` instead of \`git@bitbucket.org:...\`).
source: $PROJECT_SOURCE
EOF
    fi
    cat <<EOF

ports:
  web:           $WEB_PORT
  db:            $DB_PORT
  mailpit_ui:    $MAILPIT_UI_PORT
  mailpit_smtp:  $MAILPIT_SMTP_PORT

vm:
  cpus:    $VM_CPUS
  memory:  $VM_MEMORY
  disk:    $VM_DISK

EOF

    if [[ $MODE == "bake" ]]; then
        if [[ -n $PLUGINS_YAML ]]; then
            echo "plugins:"
            printf '%s' "$PLUGINS_YAML"
        else
            echo "plugins: []"
        fi
    elif [[ $MODE == "mount" ]]; then
        printf '%s' "$PROJECT_YAML"
    fi
} > "$yaml"

ok "wrote $yaml"
echo
info "Next steps:"
say "  cd $NAME"
say "  mosaic build         # provision the VM and install the framework"
