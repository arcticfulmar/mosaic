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
