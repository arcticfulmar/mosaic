#!/bin/sh
# The mosaic recipe's home part: run once per kassi as the user by kassar
# (`kassar recipe apply <kassi> --force` runs it again: it then checks
# out that tag).
set -eu
dir=$HOME/src/mosaic
# The mosaic release this recipe ships with; each release bumps it (the
# release checklist in CLAUDE.md), as it does the Homebrew formula.
ref=v2.5.0
if [ -d "$dir/.git" ]; then
	{ git -C "$dir" fetch -q --tags && git -C "$dir" -c advice.detachedHead=false checkout -q "$ref"; } ||
		echo "mosaic: $dir has changes of its own; left as it is" >&2
else
	mkdir -p "$HOME/src"
	git -c advice.detachedHead=false clone -q --branch "$ref" https://github.com/arcticfulmar/mosaic.git "$dir"
fi
mkdir -p "$HOME/.local/bin"
ln -sf "$dir/bin/mosaic" "$HOME/.local/bin/mosaic"
