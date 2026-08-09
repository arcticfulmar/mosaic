# Laravel flavour recipes.
#
# Imported by the generated root justfile only when mosaic.yaml's
# framework is laravel — no runtime guards needed (see the moodle
# flavour header).
#
# All Laravel recipes run inside the project root (= /srv/project in
# the VM). The host project is virtiofs-mounted there; the Laravel app
# sits at the root of the mount (no subdirectory). scripts/in-vm already
# cd's to /srv/project before running its command, so recipes pass the
# command + "$@" straight through — no `sh -c "cd … && …"` wrapper, which
# is what used to re-split quoted args like `--filter='a b c'`.

# Run an artisan subcommand (e.g. `mosaic artisan migrate:status`).
[group('laravel')]
artisan +ARGS:
    @vm="mosaic-$(basename "$(pwd)")" && \
        "{{home_dir}}/scripts/in-vm" "$vm" php artisan "$@"

# Open `php artisan tinker`.
[group('laravel')]
tinker:
    @vm="mosaic-$(basename "$(pwd)")" && \
        "{{home_dir}}/scripts/in-vm" "$vm" php artisan tinker

# Process the queue (Ctrl-C to exit).
[group('laravel')]
queue:
    @vm="mosaic-$(basename "$(pwd)")" && \
        "{{home_dir}}/scripts/in-vm" "$vm" php artisan queue:work

# Run scheduled tasks once (the equivalent of one cron tick).
[group('laravel')]
schedule-run:
    @vm="mosaic-$(basename "$(pwd)")" && \
        "{{home_dir}}/scripts/in-vm" "$vm" php artisan schedule:run

# Run pending migrations.
[group('laravel')]
migrate:
    @vm="mosaic-$(basename "$(pwd)")" && \
        "{{home_dir}}/scripts/in-vm" "$vm" php artisan migrate

# Drop everything and re-migrate from scratch (optionally with --seed).
[group('laravel')]
migrate-fresh *FLAGS:
    @vm="mosaic-$(basename "$(pwd)")" && \
        "{{home_dir}}/scripts/in-vm" "$vm" php artisan migrate:fresh "$@"

# Run the Laravel test suite (`php artisan test`).
[group('laravel')]
test *ARGS:
    @vm="mosaic-$(basename "$(pwd)")" && \
        "{{home_dir}}/scripts/in-vm" "$vm" php artisan test "$@"

# Run pestphp directly (`./vendor/bin/pest`).
[group('laravel')]
pest *ARGS:
    @vm="mosaic-$(basename "$(pwd)")" && \
        "{{home_dir}}/scripts/in-vm" "$vm" ./vendor/bin/pest "$@"

# Run the dev frontend bundler (Vite). Ctrl-C to exit.
[group('laravel')]
dev:
    @vm="mosaic-$(basename "$(pwd)")" && \
        port=$(yq -r '.ports.vite_dev // 5173' mosaic.yaml) && \
        "{{home_dir}}/scripts/in-vm" "$vm" npm run dev -- --host localhost --port "$port"
# `--host localhost` (NOT bare `--host`): bare `--host` makes Vite bind on
# all interfaces incl. IPv6 `[::]`, and Laravel's Vite plugin then writes
# `http://[::]:<port>` into public/hot. Browsers (Safari, content-blockers)
# refuse to load resources from the IPv6 unspecified address. Pinning the
# bind to `localhost` makes the hot-file URL `http://localhost:<port>`,
# which every browser will accept. Lima's port forward catches the
# 127.0.0.1 binding fine.
