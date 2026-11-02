# mosaic as a kassar recipe

[kassar](https://github.com/arcticfulmar/kassar) runs apps in small Linux
VMs on a Mac ("kassis"). mosaic's `kassi` backend runs a project inside
one. This folder is the kassar recipe that puts mosaic into a kassi: a
home part that checks out this repository at a release tag into
`~/src/mosaic` and links `~/.local/bin/mosaic`.

It lives here, not in kassar's recipe library, so a mosaic release never
waits on a kassar release.

## Using it

Copy both files into kassar's folder for your own recipes, beside
`kassar.toml`:

```sh
mkdir -p ~/.config/kassar/recipes
cp kassar/recipes/mosaic.toml kassar/recipes/mosaic.home.sh ~/.config/kassar/recipes/
```

Then list it on a kassi with kassar's `web` recipe and the database your
`mosaic.yaml` asks for, e.g. `recipes = ["web", "mariadb", "mosaic"]`, or
put `web` and `mosaic` in a template's recipes. The home part runs at the
kassi's first `up`; `kassar recipe apply <kassi> --force` moves an
existing kassi to the tag in a newer copy.

Every kassar 1.x reads recipes from `~/.config/kassar/recipes/`; the
`web` recipe it pairs with is in kassar v1.25.0 and later. A kassar
whose library still ships a `mosaic` recipe (v1.25.0 to v1.25.2) uses
this one instead; `kassar doctor` notes the override.

## Releases

`mosaic.home.sh` pins `ref=vX.Y.Z`, the release it ships with, and the
`description` in `mosaic.toml` names it. Each release bumps both to the
new tag (CLAUDE.md, "Release flow"), then copy them again.
