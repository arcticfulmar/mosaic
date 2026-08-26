# Mosaic — shared bash helpers.
#
# Source from a script with:    . "$(dirname "$0")/lib.sh"
# Assumes the sourcing script set `set -euo pipefail`.
#
# Provides:
#   - colour-aware output  (say / info / ok / warn / die)
#   - interactive prompts  (ask / ask_default / ask_yn / ask_choice / confirm_tty)
#   - paths                (mosaic_state_dir, mosaic_home)
#   - project reads        (project_yaml_get & friends — target-overlay aware)
#   - flavour hooks        (run_hook / has_hook)

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

# Confirm a destructive action. Unlike ask_yn this reads from /dev/tty
# rather than stdin, because the callers that need it most are flavour
# hooks — whose stdin carries the config JSON and is already at EOF by
# the time anything wants to prompt.
#
# MOSAIC_ASSUME_YES=1 skips the prompt: that's what `--yes` sets, and
# what `mosaic switch` sets once it has asked its own combined
# "what dies + what gets built" question. With neither a tty nor
# MOSAIC_ASSUME_YES we refuse rather than assume consent — a teardown
# running unattended in a pipeline should say so, not guess.
confirm_tty() {
    local question=$1
    [[ ${MOSAIC_ASSUME_YES:-0} == 1 ]] && return 0
    # Test by opening, not with -e: the /dev/tty node exists even for a
    # process with no controlling terminal — it's the open that fails.
    ( : < /dev/tty ) 2>/dev/null ||
        die "no terminal to confirm on — re-run with --yes if you mean it"
    local answer
    printf '%s [y/N]: ' "$question" > /dev/tty
    IFS= read -r answer < /dev/tty || answer=''
    case $answer in
        y|Y|yes|Yes|YES) return 0 ;;
        *)               return 1 ;;
    esac
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

# --- targets -----------------------------------------------------------------
# A manifest may declare several named targets:
#
#   default_target: moodle-45
#   targets:
#     moodle-45: { framework: moodle, version: "4.5", plugins: [...] }
#     moodle-51: { framework: moodle, version: "5.1", plugins: [...] }
#
# Exactly one target is installed at a time. That is the load-bearing
# simplification: every singleton in Mosaic (one /srv/<framework> tree,
# one /srv/moodledata, one db volume, one `ports:` block, one VM) stays
# valid, and `mosaic switch` tears the installed target down before
# building the next one. Nothing is ever per-target on disk.
#
# A target may therefore only override the fields that describe the
# *content* of an install:
#
#     framework   version   php   db   source   plugins
#
# `ports`, `vm`, `wwwroot` and `project_files` are shared and stay
# top-level. The helpers here would happily honour a per-target value,
# but the Lima instance (rendered once, at VM creation) and the port
# allocator would not — so a target that sets one is a loud error rather
# than a half-applied setting. The allowlist is enforced in the resolver
# below, i.e. on every read path, not just in resolve.sh.
#
# Reads go through a per-field overlay — the target's value shadows the
# top-level one — so a manifest with no `targets:` key resolves exactly
# as it did before any of this existed.

# Resolved once per shell by project_target_init. Empty string is a
# meaningful value: it means "legacy manifest, no targets:", and every
# overlay read then falls straight through to the top-level field.
_MOSAIC_ACTIVE_TARGET=''
_MOSAIC_TARGET_RESOLVED=0

# One yq pass emitting four facts, one per line:
#   1. the type of `.targets`     (!!map = multi-target, !!null = legacy)
#   2. the effective target name  ($D = state file, else default_target)
#   3. whether that name exists under `.targets`
#   4. targets carrying keys outside the allowlist, as "name/key+key"
#
# Fact 3 exists because yq's `//` fallthrough is silent by design: a
# bogus or empty target name would otherwise resolve every field to the
# top-level layer and cheerfully build the wrong thing. The realistic
# trigger is a stale .mosaic/active-target after a target was renamed.
_MOSAIC_TARGET_FACTS_YQ='
((.targets | select(type == "!!map")) // {}) as $tg |
([strenv(D), (.default_target // "")] | map(select(. != "")) | .[0] // "") as $t |
[
  (.targets | type),
  $t,
  ($tg | has($t)),
  ([$tg | to_entries[] | .key as $k
      | ((.value // {}) | keys) - ["framework", "version", "php", "db", "source", "plugins"]
      | select(length > 0)
      | ($k + "/" + join("+"))] | join(" "))
] | .[]
'

# Resolve + validate the active target, caching it in this shell.
#
# Callers that read many fields should call this once at the top: each
# `x=$(project_yaml_get …)` runs in a subshell, so a cache populated
# inside one never reaches the next. Calling it up front populates the
# cache in the caller's own shell, which the subshells then inherit —
# turning two yq invocations per field read into one. Purely an
# optimisation; correctness never depends on it.
project_target_init() {
    [[ $_MOSAIC_TARGET_RESOLVED == 1 ]] && return 0

    # Desired target: written by `mosaic switch`, after teardown of the
    # previous one succeeded (see scripts/switch.sh for why that order).
    local desired='' from='default_target:'
    if [[ -f .mosaic/active-target ]]; then
        desired=$(tr -d '[:space:]' < .mosaic/active-target)
        [[ -n $desired ]] && from='.mosaic/active-target'
    fi

    local facts line
    facts=$(D="$desired" yq -r "$_MOSAIC_TARGET_FACTS_YQ" mosaic.yaml) ||
        die "could not read 'targets:' from mosaic.yaml — is it valid YAML?"

    local f=()
    while IFS= read -r line; do f+=("$line"); done <<< "$facts"
    local kind=${f[0]:-} name=${f[1]:-} known=${f[2]:-} bad=${f[3]:-}

    case $kind in
        '!!null')
            # No targets: block — legacy manifest, no overlay anywhere.
            name=''
            ;;
        '!!map')
            if [[ -n $bad ]]; then
                die "mosaic.yaml: keys not allowed inside a target: $bad
       a target may set only: framework, version, php, db, source, plugins
       ports/vm/wwwroot/project_files are shared — keep them top-level"
            fi
            [[ -n $name ]] ||
                die "mosaic.yaml has 'targets:' but no active target — add 'default_target: <name>' or run 'mosaic switch <name>' (see 'mosaic targets')"
            [[ $known == "true" ]] ||
                die "$from names target '$name', which is not in 'targets:' — run 'mosaic targets' to see what is, then 'mosaic switch <name>'"
            ;;
        *)
            die "mosaic.yaml: 'targets:' must be a map of name → settings (got $kind)"
            ;;
    esac

    _MOSAIC_ACTIVE_TARGET=$name
    _MOSAIC_TARGET_RESOLVED=1
}

# The active target's name; empty for a legacy (single-target) manifest.
project_active_target() {
    project_target_init
    printf '%s' "$_MOSAIC_ACTIVE_TARGET"
}

# Overlay read: the active target's value for <field>, else the
# top-level one, else empty. Empty target name (legacy manifest) indexes
# a missing map and falls through — which is exactly the behaviour we
# want, and why the name is validated up front rather than here.
#
# `|| exit 1` rather than a bare call, here and below: bash unsets
# errexit inside command substitutions (there's no inherit_errexit on
# macOS's bash 3.2), so a `die` in a nested $(…) prints its message and
# then lets the caller carry on with an empty value. For a target that
# failed validation that would mean silently resolving every field to
# the top-level layer and building the wrong thing — the exact failure
# the validation exists to prevent. The inner die has already printed;
# exit 1 just makes it stick.
_project_overlay_read() {
    local field=$1 t
    t=$(project_active_target) || exit 1
    T="$t" yq -r ".targets[strenv(T)].${field} // .${field} // \"\"" mosaic.yaml
}

# Read a scalar field from cwd's mosaic.yaml. Dies if the field is
# missing — we want loud failures on a project that's been hand-edited
# into an inconsistent state, not silent skips with confusing downstream
# errors. "Missing" means absent from both the active target and the
# top-level layer.
project_yaml_get() {
    local field=$1
    local val
    val=$(_project_overlay_read "$field") || exit 1
    if [[ -z $val || $val == "null" ]]; then
        local t
        t=$(project_active_target) || exit 1
        die "mosaic.yaml is missing required field: ${field}${t:+ (target: $t)}"
    fi
    printf '%s' "$val"
}

# Read a scalar field from cwd's mosaic.yaml, returning a fallback if
# the field is absent. Use for optional fields like `wwwroot` whose
# default is well-defined.
project_yaml_get_or() {
    local field=$1 fallback=$2
    local val
    val=$(_project_overlay_read "$field") || exit 1
    if [[ -z $val || $val == "null" ]]; then
        printf '%s' "$fallback"
    else
        printf '%s' "$val"
    fi
}

# --- flavour hooks -----------------------------------------------------------
# The hook contract (docs/flavour-architecture.md): resolved config JSON
# on stdin, human progress on stderr, JSON result on stdout, non-zero
# exit aborts. Lives here rather than in build.sh because teardown.sh
# needs the same dispatch — and because "core sequences, flavours fill
# in the steps" is a core-wide rule, not a build-time one.

# Run a flavour hook. A missing hook is not an error: a flavour with
# nothing to do at that step simply doesn't ship one. The hook's stdout
# (its JSON result) is passed through to ours, so callers can capture it
# — or redirect it to /dev/null when they have no use for it yet.
#
# Usage: run_hook <flavour> <hook-name> <config-json>
run_hook() {
    local flavour=$1 name=$2 json=$3
    local exe
    exe="$(mosaic_home)/flavours/$flavour/hooks/$name"
    [[ -e $exe ]] || return 0
    [[ -x $exe ]] || die "hook exists but is not executable: $exe"
    printf '%s' "$json" | "$exe"
}

# Whether a flavour ships a given hook. Lets a caller tell "the flavour
# had nothing to do" apart from "the step ran" — which matters for
# teardown, where a silently-skipped hook must not be reported (or acted
# on) as a completed tear-down.
has_hook() {
    [[ -x "$(mosaic_home)/flavours/$1/hooks/$2" ]]
}

# Read a field from the last successful build's resolved config
# (.mosaic/installed.json), falling back to the manifest overlay when
# nothing is installed yet.
#
# Use this wherever a script addresses what is RUNNING — the tree at
# /srv/<framework>, the php-fpm unit, the db container — rather than what
# the next build will create. The two differ between `mosaic switch`
# recording a new desired target and the build that follows finishing,
# and in that window it's the installed one you need to talk to.
project_installed_get() {
    local field=$1 val
    if [[ -f .mosaic/installed.json ]]; then
        val=$(yq -p json -r ".${field} // \"\"" .mosaic/installed.json 2>/dev/null || true)
        if [[ -n $val && $val != "null" ]]; then
            printf '%s' "$val"
            return
        fi
    fi
    project_yaml_get "$field"
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
    file=$(profile_file "$fw" "$ver") || exit 1
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
    file=$(profile_file "$fw" "$ver") || exit 1
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

# The active target's plugin list as compact JSON — the single reader
# every host-side consumer of `plugins:` goes through, so a switched
# project can never clone the top-level list into the target's tree.
#
# An empty `plugins: []` inside a target *overrides* the top-level list
# rather than inheriting it: yq's `//` only falls through on null, and
# an empty array isn't null. Omit the key to inherit; write `[]` to
# declare "this target has none".
project_plugins_json() {
    local t
    t=$(project_active_target) || exit 1
    T="$t" yq -o=json -I=0 '(.targets[strenv(T)].plugins // .plugins // [])' mosaic.yaml
}

# Number of plugin entries for the active target. 0 if `plugins:` is
# absent, an empty array, or null.
project_plugin_count() {
    local t
    t=$(project_active_target) || exit 1
    local n
    n=$(T="$t" yq -r '(.targets[strenv(T)].plugins // .plugins // []) | length' mosaic.yaml 2>/dev/null || echo 0)
    [[ -z $n || $n == "null" ]] && n=0
    printf '%s' "$n"
}

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
