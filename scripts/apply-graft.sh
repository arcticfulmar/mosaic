#!/usr/bin/env bash
# apply-graft.sh (host side): make the plugins + project_files declared
# in mosaic.yaml appear at their canonical places in the served tree.
#
# What that means depends on the backend's storage model:
#
#   virtiofs backend (Lima) — the served tree is a separate guest-native
#   clone at /srv/<framework>; plugins live on the host and are bind-
#   mounted over it by scripts/apply-graft, a systemd oneshot inside
#   the guest. This script just (re)starts that unit.
#
#   native-storage backend (distrobox) — the host tree IS the served
#   tree. Plugins already sit at their canonical paths (fetch clones
#   them there), so there is nothing to bind. Only project_files need
#   help, and only on Moodle 5.x: they are declared relative to the
#   project root but the framework reads them relative to $CFG->dirroot,
#   which is <root>/public/. A relative symlink <root>/public/<file> →
#   ../<file> bridges that, on the host, once, and survives everything.
#   On 4.x dirroot == project root and the file is already in place.

set -euo pipefail
. "$(dirname "$0")/lib.sh"

require_project
HOME_DIR=$(mosaic_home)
load_config
VM_NAME=$(cfg .project.vm)
NATIVE=$(cfg .backend.native_storage)
PLUGINS_ROOT=$(cfg .plugins_root)
PROJECT_DIR=$(cfg .project.dir)

if [[ $NATIVE != "true" ]]; then
    info "==> Re-applying the graft in the guest (apply-graft.service)"
    exec "$HOME_DIR/scripts/in-vm" "$VM_NAME" sudo systemctl restart apply-graft.service
fi

count=$(cfg '.project_files | length')
if [[ $PLUGINS_ROOT == "." || $count -eq 0 ]]; then
    say "apply-graft: native storage — plugins are served in place; nothing to graft"
    exit 0
fi

# `../` for each directory level of "<plugins_root>/<rel>" — the hops
# from the symlink's directory back up to the project root.
updirs() {
    local dir=${1%/*}
    [[ $dir == "$1" ]] && { printf ''; return; }   # no slash: file at root
    local n=1 rest=$dir
    while [[ $rest == */* ]]; do n=$((n+1)); rest=${rest#*/}; done
    local i out=''
    for ((i=0; i<n; i++)); do out+='../'; done
    printf '%s' "$out"
}

info "==> Linking $count project file(s) into $PLUGINS_ROOT/ (native storage, Moodle 5.x layout)"
for ((i=0; i<count; i++)); do
    rel=$(cfg ".project_files[$i]")
    case $rel in
        ""|null|/*|*..*) warn "invalid project_files entry '$rel' — skipping"; continue ;;
    esac
    src="$PROJECT_DIR/$rel"
    dst="$PROJECT_DIR/$PLUGINS_ROOT/$rel"
    [[ -e $src ]] || { warn "project file missing: ./$rel — skipping"; continue; }
    if [[ -e $dst && ! -L $dst ]]; then
        warn "./$PLUGINS_ROOT/$rel exists in the framework tree — refusing to shadow it"
        continue
    fi
    install -d "$(dirname "$dst")"
    target="$(updirs "$PLUGINS_ROOT/$rel")$rel"
    ln -sfn "$target" "$dst"
    say "  + $PLUGINS_ROOT/$rel  → $target"
done
ok "Graft applied"
