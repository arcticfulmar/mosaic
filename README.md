# Mosaic

A local development environment builder for **Moodle**, **Workplace**,
and (coming soon) **Laravel** projects on macOS. Each project gets its
own Lima VM, its own ports, its own database, and its own framework
build — but they all share a single declarative manifest
(`mosaic.yaml`) and a small set of `mosaic <verb>` recipes.

```
$ mosaic new myproj
$ cd myproj
$ mosaic build
$ open http://localhost:8001/   # logged in as admin / Password1!
```

## Status

**v0.1.0**:
- Moodle 4.x and Workplace 4.x — full bake, install, plugins, mixins,
  PHPUnit infrastructure, plugin bind-mounts.
- Per-project Lima VMs with nginx, php-fpm, podman (mariadb +
  mailpit), all parameterised on `mosaic.yaml`.
- Plugin-state warnings on rebuild so uncommitted work isn't silently
  lost.
- Verb-first recipe surface: `new`, `build`, `up`, `down`, `shell`,
  `status`, `nuke`, `apply-graft`, `init-phpunit`, …

**Coming soon:**
- v0.2 — Laravel (mount-mode, no bake).
- v0.3 — Moodle 5.x (`/public` layout).
- Later — Totara, Linux host support, recipe catalogues, and image
  baking. See [Mosaic.md](Mosaic.md)'s **Future** section.

## Requirements

- macOS (Apple Silicon or Intel; both work via Lima).
- Homebrew.
- An SSH agent with whatever keys you'll need for any private repos
  your projects clone (e.g. Workplace, your client plugins).

Mosaic itself is `bash` + [`just`](https://just.systems) +
[`yq`](https://github.com/mikefarah/yq) + [Lima](https://lima-vm.io/).
Everything else (PHP, nginx, podman, MariaDB) lives inside the
per-project VM.

## Install

```sh
brew tap arcticfulmar/mosaic
brew install mosaic
```

The tap pulls Mosaic's dependencies (Lima, just, yq, coreutils)
automatically. First boot of any VM also installs ~500 MB of Ubuntu
packages inside the guest — first build of a project takes 5-10 min;
subsequent ones take 2-3.

## Quickstart

Scaffold a Moodle 4.5 project on PHP 8.3:

```sh
mosaic new mylms
cd mylms
mosaic build
```

`mosaic new` is interactive by default. It walks you through
framework, version, PHP, database, plugins, and mixins, writes a
`mosaic.yaml` to the project directory, and shows the resolved config
before you commit. Pass `--no-confirm` and individual `--field=value`
flags to script it.

Once `mosaic build` finishes you can:

```sh
mosaic status        # one-screen summary
mosaic shell         # ssh into the VM at /srv/project
mosaic init-phpunit  # set up PHPUnit's test database
mosaic plugins       # list plugin entries from mosaic.yaml
mosaic down          # stop services without losing state
mosaic up            # start them again
mosaic nuke          # destroy the VM (project files survive)
```

Run `mosaic` with no arguments for the full recipe list.

## Adding plugins

Edit `mosaic.yaml`:

```yaml
plugins:
  - source: git@github.com:moodlehq/moodle-local_codechecker.git
    branch: master
    destination: local/codechecker

  - source: git@bitbucket.org:titus-learning/local_titusconnect.git
    branch: main
    destination: local/titusconnect
```

Then `mosaic build` (full clean rebuild) or `mosaic apply-graft`
(re-mount without re-cloning the framework). Plugins live as their
own git repos at canonical Moodle paths inside `./moodle/`, so your
IDE sees them right where they should be.

## Project files

Files that live in your project root but which the framework expects
to find relative to its own root — a `.env` read via `$CFG->dirroot`,
say — go in `project_files:`:

```yaml
project_files:
  - .env
```

Each is symlinked into the framework tree, so host edits are live and
no copy drifts out of date. Re-apply with `mosaic apply-graft`.

## Multiple projects

Each project gets a separate Lima VM and a separate set of ports.
Mosaic auto-allocates ports from a per-user counter at scaffold time
and writes them into `mosaic.yaml` so they're stable across rebuilds.
Two projects on the same machine never collide on `localhost:8001`
because Mosaic never assigns the same offset twice.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
