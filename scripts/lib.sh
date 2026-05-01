# Mosaic — shared bash helpers.
#
# Source from a script with:    . "$(dirname "$0")/lib.sh"
# Assumes the sourcing script set `set -euo pipefail`.
#
# Provides:
#   - colour-aware output  (say / info / ok / warn / die)
#   - interactive prompts  (ask / ask_default / ask_yn / ask_choice)
#   - paths                (mosaic_state_dir, mosaic_home)

# --- output ------------------------------------------------------------------
# Colour escapes are emitted only when stdout is a TTY. Piping `mosaic …` into
# another command therefore yields clean output free of escape sequences.

if [[ -t 1 ]]; then
    _C_RED=$'\033[0;31m'
    _C_GREEN=$'\033[0;32m'
    _C_YELLOW=$'\033[0;33m'
    _C_CYAN=$'\033[0;36m'
    _C_DIM=$'\033[0;90m'
    _C_RESET=$'\033[0m'
else
    _C_RED=''; _C_GREEN=''; _C_YELLOW=''; _C_CYAN=''; _C_DIM=''; _C_RESET=''
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s%s%s\n' "$_C_CYAN" "$*" "$_C_RESET"; }
ok()   { printf '%s%s%s\n' "$_C_GREEN" "$*" "$_C_RESET"; }
warn() { printf '%sWARNING:%s %s\n' "$_C_YELLOW" "$_C_RESET" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$_C_RED" "$_C_RESET" "$*" >&2; exit 1; }

# Print a key/value pair, colourising the value. Used by `mosaic new`'s
# confirmation summary.
kv() {
    printf '  %-18s %s%s%s\n' "$1" "$_C_CYAN" "$2" "$_C_RESET"
}

# --- prompts -----------------------------------------------------------------
# Returning values via stdout (not via a global) so callers can do:
#   foo=$(ask "Question?")
# This keeps each prompt self-contained and free of shared mutable state.

# Ask for a value with no default. Re-prompts until the user enters something
# non-empty. Reads from /dev/tty so the prompt works even if stdin has been
# redirected (e.g. `mosaic new < answers.txt` for non-interactive testing —
# /dev/tty would still need to be available there; the redirect form is for
# straight-through piping).
ask() {
    local question=$1
    local answer=''
    while [[ -z $answer ]]; do
        # `< /dev/tty` is omitted: read from current stdin so test scripts
        # can pipe answers in. Interactive use (where stdin is a TTY) is
        # unaffected.
        printf '%s: ' "$question" >&2
        IFS= read -r answer || die "input stream closed before answering: $question"
    done
    printf '%s' "$answer"
}

# Ask with a default shown in [brackets]. Empty input picks the default.
ask_default() {
    local question=$1
    local default=$2
    local answer
    printf '%s [%s%s%s]: ' "$question" "$_C_CYAN" "$default" "$_C_RESET" >&2
    IFS= read -r answer || die "input stream closed before answering: $question"
    printf '%s' "${answer:-$default}"
}

# Yes/no prompt. $2 is the default ('y' or 'n'); empty input picks it.
# Returns 0 for yes, 1 for no.
ask_yn() {
    local question=$1
    local default=${2:-y}
    local hint
    case $default in
        y|Y) hint="Y/n" ;;
        n|N) hint="y/N" ;;
        *)   die "ask_yn: bad default '$default'" ;;
    esac
    local answer
    printf '%s [%s]: ' "$question" "$hint" >&2
    IFS= read -r answer || die "input stream closed before answering: $question"
    answer=${answer:-$default}
    case $answer in
        y|Y|yes|Yes|YES) return 0 ;;
        *)               return 1 ;;
    esac
}

# Pick one of a fixed set of choices. Re-prompts on bad input.
# Args: <question> <default> <choice1> <choice2> ...
# The default must be one of the choices but is passed separately so the
# caller can express it independently of choice ordering.
ask_choice() {
    local question=$1; shift
    local default=$1;  shift
    local choices="$*"
    local answer
    while true; do
        printf '%s (%s) [%s%s%s]: ' "$question" "$choices" "$_C_CYAN" "$default" "$_C_RESET" >&2
        IFS= read -r answer || die "input stream closed before answering: $question"
        answer=${answer:-$default}
        for c in $choices; do
            if [[ $c == "$answer" ]]; then
                printf '%s' "$answer"
                return
            fi
        done
        warn "not one of: $choices"
    done
}

# --- paths -------------------------------------------------------------------

# Directory for Mosaic's per-user state (port offset counter, future cache).
# Honours XDG_STATE_HOME so it lives in the conventional location on Linux
# and a sensible fallback on macOS.
mosaic_state_dir() {
    printf '%s/mosaic' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

# Mosaic's install root. Set by bin/mosaic before invoking `just`. Scripts
# that source lib.sh outside of a `mosaic …` invocation (e.g. running
# `scripts/new.sh` directly during development) fall back to walking up
# from this file's location.
mosaic_home() {
    if [[ -n ${MOSAIC_HOME:-} ]]; then
        printf '%s' "$MOSAIC_HOME"
        return
    fi
    local self
    self=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
    printf '%s' "$self"
}

# --- project context ---------------------------------------------------------
# Helpers used by recipes that operate on a project (build, up, shell, …).
# A "project" is any directory containing a mosaic.yaml at its root.

# Die unless cwd contains a mosaic.yaml. Use as the first call in any
# recipe that expects to be run from inside a project directory.
require_project() {
    if [[ ! -f mosaic.yaml ]]; then
        die "no mosaic.yaml in $(pwd) — run \`mosaic new <name>\` to scaffold a project, or cd into one"
    fi
}

# The Lima VM name for the project rooted at cwd. Mosaic VMs are named
# mosaic-<dirname> so they don't collide with non-Mosaic Lima VMs the
# user might also run (titus-devenv, ad-hoc machines, etc.).
project_vm_name() {
    printf 'mosaic-%s' "$(basename "$(pwd)")"
}

# Read a scalar field from cwd's mosaic.yaml. Dies if the field is
# missing — we want loud failures on a project that's been hand-edited
# into an inconsistent state, not silent skips with confusing downstream
# errors.
project_yaml_get() {
    local field=$1
    local val
    val=$(yq -r ".${field} // \"\"" mosaic.yaml)
    if [[ -z $val || $val == "null" ]]; then
        die "mosaic.yaml is missing required field: ${field}"
    fi
    printf '%s' "$val"
}

# Read a scalar field from cwd's mosaic.yaml, returning a fallback if
# the field is absent. Use for optional fields like `wwwroot` whose
# default is well-defined.
project_yaml_get_or() {
    local field=$1 fallback=$2
    local val
    val=$(yq -r ".${field} // \"\"" mosaic.yaml)
    if [[ -z $val || $val == "null" ]]; then
        printf '%s' "$fallback"
    else
        printf '%s' "$val"
    fi
}

# --- framework profiles ------------------------------------------------------
# These are referenced by `mosaic new` (defaults at scaffold time) AND
# `mosaic build` (resolution at provision time), so they live here rather
# than in either script's body.

# Locate the framework profile file. Walks <version>.yaml → <major>.x.yaml
# → x.yaml so a project that says `version: 4.5` matches frameworks/moodle/4.x.yaml.
profile_file() {
    local fw=$1 ver=$2
    local home
    home=$(mosaic_home)
    local candidates=("$home/frameworks/$fw/$ver.yaml")
    if [[ $ver == *.* ]]; then
        local major=${ver%%.*}
        candidates+=("$home/frameworks/$fw/${major}.x.yaml")
    fi
    candidates+=("$home/frameworks/$fw/x.yaml")
    for f in "${candidates[@]}"; do
        [[ -f $f ]] && { echo "$f"; return; }
    done
    die "no profile for framework='$fw' version='$ver' (looked under $home/frameworks/$fw/)"
}

# Read a scalar field from a profile, recursing into `extends` if the
# field is absent. Returns empty string if not found anywhere up the
# chain. Use `profile_caps` for the (currently single) array field
# `capabilities` — its semantics differ.
profile_get() {
    local fw=$1 ver=$2 field=$3
    local file
    file=$(profile_file "$fw" "$ver")
    local val
    val=$(yq -r ".${field} // \"\"" "$file")
    if [[ -n $val && $val != "null" ]]; then
        echo "$val"
        return
    fi
    local ext
    ext=$(yq -r '.extends // ""' "$file")
    if [[ -n $ext && $ext != "null" ]]; then
        local ext_fw=${ext%%/*}
        local ext_ver=${ext##*/}
        profile_get "$ext_fw" "$ext_ver" "$field"
    fi
}

# Resolve the capabilities array for a (framework, version), walking
# `extends` if the local profile doesn't define one. Returns one
# capability per line (empty stdout if none anywhere up the chain).
#
# Capabilities don't merge across the inheritance chain — the closest
# `capabilities:` declaration wins outright. A child profile that wants
# to extend its parent's caps should respell the full list.
profile_caps() {
    local fw=$1 ver=$2
    local file
    file=$(profile_file "$fw" "$ver")
    local kind
    kind=$(yq -r '.capabilities | type' "$file")
    if [[ $kind == "!!seq" ]]; then
        yq -r '.capabilities[]' "$file"
        return
    fi
    local ext
    ext=$(yq -r '.extends // ""' "$file")
    if [[ -n $ext && $ext != "null" ]]; then
        local ext_fw=${ext%%/*}
        local ext_ver=${ext##*/}
        profile_caps "$ext_fw" "$ext_ver"
    fi
}

# Resolve the `plugins_root` for a project — the relative path from
# `./<framework>/` to where plugins are layered. Defaults to "." (e.g.
# Moodle 4.x: `./moodle/local/foo`). Moodle 5.x will set it to "public"
# so plugins land at `./moodle/public/local/foo`.
project_plugins_root() {
    local fw=$1 ver=$2
    local pr
    pr=$(profile_get "$fw" "$ver" 'plugins_root')
    [[ -z $pr ]] && pr="."
    printf '%s' "$pr"
}

# Resolve the directory under which plugin clones live on the host —
# combines the framework directory with `plugins_root`. Returns a path
# relative to the project root (no leading `./`, no trailing slash).
#
# Examples:
#   moodle 4.x → "moodle"            (plugins under ./moodle/<destination>)
#   moodle 5.x → "moodle/public"     (plugins under ./moodle/public/<destination>)
project_host_plugin_base() {
    local fw=$1 ver=$2
    local root
    root=$(project_plugins_root "$fw" "$ver")
    if [[ $root == "." ]]; then
        printf '%s' "$fw"
    else
        printf '%s/%s' "$fw" "$root"
    fi
}

# Number of plugin entries in cwd's mosaic.yaml. 0 if `plugins:` is
# absent, an empty array, or null.
project_plugin_count() {
    local n
    n=$(yq -r '.plugins | length // 0' mosaic.yaml 2>/dev/null || echo 0)
    [[ -z $n || $n == "null" ]] && n=0
    printf '%s' "$n"
}

# Resolve a profile's `git_ref_pattern` against a project version string.
# Substitutes {major}, {minor}, {minor:02} (zero-padded), {patch} placeholders.
#
# Examples:
#   resolve_git_ref 'MOODLE_{major}{minor:02}_STABLE' '4.5'   → MOODLE_405_STABLE
#   resolve_git_ref 'WORKPLACE_{major}{minor:02}_{patch}' '4.5.11' → WORKPLACE_405_11
resolve_git_ref() {
    local pattern=$1 version=$2

    # Decompose the version into major[.minor[.patch]]. Bash parameter
    # expansion is sufficient for our cases; we don't need a full SemVer
    # parser yet.
    local major minor patch rest
    major=${version%%.*}
    rest=${version#*.}
    if [[ $rest == "$version" ]]; then
        minor=""
        patch=""
    else
        minor=${rest%%.*}
        patch=${rest#*.}
        [[ $patch == "$minor" ]] && patch=""
    fi

    local minor_02=""
    if [[ -n $minor ]]; then
        printf -v minor_02 '%02d' "$minor"
    fi

    local result=$pattern
    result=${result//\{major\}/$major}
    result=${result//\{minor:02\}/$minor_02}
    result=${result//\{minor\}/$minor}
    result=${result//\{patch\}/$patch}
    printf '%s' "$result"
}
