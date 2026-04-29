#!/usr/bin/env bash
# Mosaic — manage the per-user port offset counter.
#
# State lives at $XDG_STATE_HOME/mosaic/port-offset (typically
# ~/.local/state/mosaic/port-offset). One file shared across every Mosaic
# project on this machine, so newly-scaffolded projects don't clash with
# already-running ones by accident.
#
# Usage:
#   port-offset.sh show         # print current value (or "0" if no file yet)
#   port-offset.sh next         # increment, write back, print new value
#
# Mosaic does NOT free offsets when a project is destroyed — over time
# the counter grows monotonically. To override, pin ports explicitly in
# mosaic.yaml.

set -euo pipefail

. "$(dirname "$0")/lib.sh"

state_file="$(mosaic_state_dir)/port-offset"

cmd=${1:-show}

case $cmd in
    show)
        if [[ -f $state_file ]]; then
            cat "$state_file"
        else
            # No file yet means the next `next` will produce 1. We print 0
            # so callers can read this as the current high-water mark.
            echo 0
        fi
        ;;
    next)
        mkdir -p "$(dirname "$state_file")"
        current=0
        [[ -f $state_file ]] && current=$(cat "$state_file")
        next=$((current + 1))
        echo "$next" > "$state_file"
        echo "$next"
        ;;
    *)
        die "port-offset.sh: unknown command '$cmd' (expected: show, next)"
        ;;
esac
