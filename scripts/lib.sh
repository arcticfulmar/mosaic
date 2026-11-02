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
# user might also run (ad-hoc machines, client tooling, etc.).
project_vm_name() {
    printf 'mosaic-%s' "$(basename "$(pwd)")"
}

# The ssh Host alias in Lima's generated ssh.config for <vm>. Lima
# sanitizes the instance name (dots become dashes, so mosaic-foo-5.3 is
# `lima-mosaic-foo-5-3`); read it from the file rather than guessing.
lima_ssh_host() {
    local cfgf="$HOME/.lima/$1/ssh.config" h=
    [[ -f $cfgf ]] && h=$(awk '$1=="Host"{print $2; exit}' "$cfgf")
    printf '%s' "${h:-lima-$1}"
}

# The manifest every reader uses: mosaic.yaml, or with an env selected
# (`--env <env>` / $MOSAIC_ENV) mosaic.yaml merged with mosaic.<env>.yaml
# (scripts/manifest.sh). bin/mosaic merges once per invocation and
# exports the result as $MOSAIC_MANIFEST; a script run without the shim
# merges here. "Read mosaic.yaml" in the comments below means this file.
manifest_file() {
    if [[ -n ${MOSAIC_MANIFEST:-} ]]; then
        printf '%s' "$MOSAIC_MANIFEST"
    elif [[ -n ${MOSAIC_ENV:-} ]]; then
        "$(mosaic_home)/scripts/manifest.sh" "$MOSAIC_ENV" .
    else
        printf 'mosaic.yaml'
    fi
}

# Read a scalar field from cwd's mosaic.yaml. Dies if the field is
# missing — we want loud failures on a project that's been hand-edited
# into an inconsistent state, not silent skips with confusing downstream
# errors.
project_yaml_get() {
    local field=$1
    local val m
    m=$(manifest_file) || exit 1
    val=$(yq -r ".${field} // \"\"" "$m")
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
    local val m
    m=$(manifest_file) || exit 1
    val=$(yq -r ".${field} // \"\"" "$m")
    if [[ -z $val || $val == "null" ]]; then
        printf '%s' "$fallback"
    else
        printf '%s' "$val"
    fi
}

# Make git ignore env overlays (mosaic.<env>.yaml) in <dir>, which hold
# one machine's settings. In a git repo rooted at <dir> (a cloned app)
# the line goes in .git/info/exclude, so the app's committed .gitignore
# is left alone; otherwise (a new project, a Moodle tree) in .gitignore.
# Idempotent. Committing an overlay anyway is fine: `git add -f` it.
gitignore_overlays() {
    local dir=${1:-.} line='mosaic.*.yaml' f top
    f="$dir/.gitignore"
    if [[ -e $dir/.git ]] && command -v git >/dev/null 2>&1 &&
       top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) &&
       [[ $top == "$(cd "$dir" && pwd -P)" ]]; then
        f=$(git -C "$dir" rev-parse --git-path info/exclude)
        [[ $f == /* ]] || f="$dir/$f"
        mkdir -p "$(dirname "$f")"
    fi
    if [[ -f $f ]] && grep -qxF -e "$line" -e "/$line" "$f"; then
        return 0
    fi
    # Start on a fresh line if the file doesn't end with one.
    if [[ -s $f && -n $(tail -c 1 "$f") ]]; then
        printf '\n' >> "$f"
    fi
    printf '%s\n' "$line" >> "$f"
    info "added $line to $f (env overlays stay local)"
}

# A site's URL for a host and port: `http://host:port`, or `http://host`
# on port 80, so a project served on 80 has the URL a browser shows
# (Moodle compares its wwwroot with the request).
site_url() {
    if [[ $2 == 80 ]]; then
        printf 'http://%s' "$1"
    else
        printf 'http://%s:%s' "$1" "$2"
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
# the framework root to where plugins are layered. Defaults to "."
# (Moodle 4.x: plugins at ./local/foo). Moodle 5.x sets it to "public"
# so plugins land at ./public/local/foo.
project_plugins_root() {
    local fw=$1 ver=$2
    local pr
    pr=$(profile_get "$fw" "$ver" 'plugins_root')
    [[ -z $pr ]] && pr="."
    printf '%s' "$pr"
}

# Resolve the directory under which plugin clones live on the host —
# Returns the host directory (relative to project root) where plugin
# clones live. With bake mode now laying the framework directly at
# the project root, this just mirrors `plugins_root` — kept as a
# helper because callers reading "plugin base on host" stays clearer
# than calling the underlying `project_plugins_root` directly.
#
# Examples:
#   moodle 4.x → "."                 (plugins under ./<destination>)
#   moodle 5.x → "public"            (plugins under ./public/<destination>)
project_host_plugin_base() {
    local fw=$1 ver=$2
    project_plugins_root "$fw" "$ver"
}

# Number of plugin entries in cwd's mosaic.yaml. 0 if `plugins:` is
# absent, an empty array, or null.
project_plugin_count() {
    local n m
    m=$(manifest_file) || exit 1
    n=$(yq -r '.plugins | length // 0' "$m" 2>/dev/null || echo 0)
    [[ -z $n || $n == "null" ]] && n=0
    printf '%s' "$n"
}

# Which git ref plugin entry $2 pins, as "<branch|tag> <ref>". $1 is a
# yq-style reader taking an expression (`cfg`, or `manifest_get` for the
# raw mosaic.yaml). `tag:` and `branch:` are mutually exclusive; neither
# means branch main. Both go to `git clone --branch`, which takes either.
plugin_ref() {
    local reader=$1 i=$2 tag branch
    tag=$("$reader" ".plugins[$i].tag // \"\"")
    branch=$("$reader" ".plugins[$i].branch // \"\"")
    if [[ -n $tag && -n $branch ]]; then
        die "plugins[$i]: set either tag: or branch:, not both"
    elif [[ -n $tag ]]; then
        printf 'tag %s' "$tag"
    else
        printf 'branch %s' "${branch:-main}"
    fi
}

manifest_get() { local m; m=$(manifest_file) || exit 1; yq -r "$1" "$m"; }

# Resolve a profile's `git_ref_pattern` against a project version string.
# Substitutes {major}, {minor}, {minor:02} (zero-padded), {patch} placeholders.
#
# Refuses to leave any placeholder unsubstituted — a 2-part version
# against a pattern that requires {patch} would otherwise yield
# `WORKPLACE_405_` (trailing underscore), which fails opaquely at clone
# time. Better to fail loudly here with a clear "pattern needs a
# 3-part version" message.
#
# Examples:
#   resolve_git_ref 'MOODLE_{major}{minor:02}_STABLE' '4.5'   → MOODLE_405_STABLE
#   resolve_git_ref 'WORKPLACE_{major}{minor:02}_{patch}' '4.5.11' → WORKPLACE_405_11
#   resolve_git_ref 'WORKPLACE_{major}{minor:02}_{patch}' '4.5'    → die
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

    # Refuse the substitution if the pattern references something we
    # don't have a value for. {minor} and {minor:02} share `minor`; if
    # `minor` is empty and either is referenced, fail.
    if [[ $pattern == *'{patch}'* && -z $patch ]]; then
        die "git_ref_pattern '$pattern' requires a {patch} value but version '$version' has none — pin a 3-part version (e.g. 4.5.11)"
    fi
    if [[ ( $pattern == *'{minor}'* || $pattern == *'{minor:02}'* ) && -z $minor ]]; then
        die "git_ref_pattern '$pattern' requires a {minor} value but version '$version' has none — pin at least a 2-part version (e.g. 4.5)"
    fi

    local result=$pattern
    result=${result//\{major\}/$major}
    result=${result//\{minor:02\}/$minor_02}
    result=${result//\{minor\}/$minor}
    result=${result//\{patch\}/$patch}
    printf '%s' "$result"
}

# --- backends ----------------------------------------------------------------
# A backend is the runtime that hosts the guest: Lima on macOS, distrobox/
# podman on Linux. Each lives at backends/<name>/driver — one executable
# with subcommands (facts, create, start, stop, exec, shell, services, …;
# see backends/README.md for the contract). Flavours never name a backend;
# they call scripts/in-vm, which dispatches to the active driver.
#
# Resolution: `backend:` in mosaic.yaml, else $MOSAIC_BACKEND, else the
# platform default. Callers capture this in $( ) — remember that `die`
# inside a command substitution doesn't stop the caller (bash drops
# errexit there, and macOS bash 3.2 has no inherit_errexit), so capture
# sites append `|| exit 1`.
project_backend() {
    local b='' m
    if [[ -f mosaic.yaml ]]; then
        m=$(manifest_file) || exit 1
        b=$(yq -r '.backend // ""' "$m" 2>/dev/null || true)
        [[ $b == "null" ]] && b=''
    fi
    [[ -n $b ]] || b=${MOSAIC_BACKEND:-}
    if [[ -z $b ]]; then
        case $(uname -s) in
            Darwin) b=lima ;;
            # Inside a kassar VM (the marker its template writes) mosaic
            # is its own guest; elsewhere on Linux, distrobox.
            Linux)  [[ -f /etc/kassar/recipes ]] && b=kassi || b=distrobox ;;
            *) die "no default backend for $(uname -s) — set 'backend:' in mosaic.yaml" ;;
        esac
    fi
    printf '%s' "$b"
}

# Absolute path to the active backend's driver executable.
backend_driver() {
    local b
    b=${1:-$(project_backend)} || exit 1
    local d
    d="$(mosaic_home)/backends/$b/driver"
    [[ -x $d ]] || die "unknown backend '$b' (expected an executable at $d)"
    printf '%s' "$d"
}

# `driver web <sub>` for backends whose guest runs nginx and
# php<ver>-fpm as systemd units (lima, distrobox). $1 is the driver
# itself, whose `exec` is the transport; $2 the guest; $3 the PHP
# version; $4 the subcommand.
systemd_web() {
    local drv=$1 guest=$2 php=$3 sub=${4:-}
    local fpm="php${php}-fpm"
    case $sub in
        start)   "$drv" exec "$guest" sudo systemctl start "$fpm" nginx ;;
        stop)    "$drv" exec "$guest" sudo systemctl stop nginx "$fpm" ;;
        restart) "$drv" exec "$guest" sudo systemctl restart "$fpm" nginx ;;
        reload)  "$drv" exec "$guest" sudo nginx -t &&
                 "$drv" exec "$guest" sudo systemctl reload nginx &&
                 "$drv" exec "$guest" sudo systemctl restart "$fpm" ;;
        logs)    exec "$drv" exec "$guest" sudo journalctl -u nginx -u "$fpm" -f ;;
        *) die "driver web: unknown subcommand '$sub' (start, stop, restart, reload, logs)" ;;
    esac
}

# Per-project host-side state that must NOT live in the project tree
# (dataroots for native-storage backends, for instance). XDG-conformant.
project_state_dir() {
    printf '%s/projects/%s' "$(mosaic_state_dir)" "$(basename "$(pwd)")"
}

# --- resolved config ---------------------------------------------------------
# Scripts that need more than one or two manifest fields load the
# resolved config once (resolve.sh: manifest + profile + backend facts)
# and read it with cfg(). Cheaper and more consistent than N yq calls
# against mosaic.yaml, and the only way to get backend facts.
load_config() {
    CONFIG_JSON=$("$(mosaic_home)/scripts/resolve.sh") || exit 1
}
cfg() { printf '%s' "$CONFIG_JSON" | yq -r "$1"; }

# Populate SVC with the sudo prefix that runs a command as the guest's
# service user (the owner of the served tree: www-data on Lima, nothing
# on distrobox where the tree is the host user's own). Use as
#   in-vm "$VM" ${SVC[@]+"${SVC[@]}"} php …
# — the bash-3.2-safe expansion of a possibly-empty array under set -u.
svc_prefix() {
    local u
    u=$(cfg .backend.service_user)
    if [[ -n $u && $u != "null" ]]; then
        SVC=(sudo -u "$u" -H)
    else
        SVC=()
    fi
}

# Populate ROOT with the prefix for guest commands that run on every
# backend and use root where there is one: `sudo`, unless the backend's
# `sudo` fact is false (a guest without root, where the exec user owns
# everything those commands touch). Use as
#   in-vm "$VM" ${ROOT[@]+"${ROOT[@]}"} rm -f …
# Commands that only run on the bake path (virtiofs backends) keep a
# literal `sudo`: native storage never reaches them.
root_prefix() {
    if [[ $(cfg .backend.sudo) == "false" ]]; then
        ROOT=()
    else
        ROOT=(sudo)
    fi
}
