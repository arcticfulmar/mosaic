# Requirements: a `kassi` backend for mosaic

2026-10-25. Steve asked for these requirements, from the kassar web stack
thread. Nothing here has been built. The design behind them is kassar's
`docs/whatif/web-stack-recipes.md` (the two updates at the top), in the
kassar-build repo.

## Update 2026-10-27: review against mosaic's code

Where this update and the sections below disagree, this update wins.

**Done on branch `kassi-backend` (phase 0, the core seams):**

- R5.1 as written: a `web start|stop|restart|reload|logs` verb.
  Lima and distrobox share `systemd_web` in `scripts/lib.sh`; `up.sh`,
  `down.sh`, `build.sh`, `reload-web` and `tail-web` call it. Tested
  live on Lima; distrobox still needs a run.
- R5.2, changed: the switch is a new optional fact, `"sudo": false`,
  not an empty `service_user`. distrobox also has an empty
  `service_user`, so the R5.2 rule would have changed distrobox too.
  `root_prefix` in `scripts/lib.sh` gives `sudo` unless the fact is
  false. It covers the lines R5.2 lists, plus one R5.2 missed: the
  moodle `install` hook's `rm -f config.php`, which runs on every
  backend.
- New: the nginx templates had the php-fpm socket hard-coded
  (`/var/run/php/php<ver>-fpm.sock`). They now take `@@FPM_SOCKET@@`,
  from an optional `fpm_socket` fact. With the fact absent, the
  default is the old path, so Lima's and distrobox's rendered files
  are byte-identical.

**Corrections for phase 1 (the kassi driver):**

- *Constraints.* The moodle `install` hook changed (two `sudo` lines
  now take `root_prefix`). It still never names a backend. Read the
  constraint as "flavours never learn the backend's name".
- *R1.2.* `facts` adds
  `"fpm_socket":"/srv/run/php-fpm.sock","sudo":false`.
- *R1.3.* `create` also links `/srv/mosaic` to the mosaic checkout
  (`configure-phpunit` is called by that path) and `/srv/run` to the
  state directory's `run/`. It makes `/home/user/srv` if it is missing.
- *One project per kassi.* `/srv/project` is a single link. `create`
  refuses when it already points at another project.
- *Database bootstrap.* The install hook expects what the compose
  images set up. MariaDB: root with password `m@odl3ing`, the app user
  and database, and the server flags `utf8mb4`, `utf8mb4_bin` and
  `innodb_file_per_table`. Postgres: `app` as superuser and an `app`
  database. Read them from the rendered `.mosaic/services-compose.yaml`
  (`environment`, `command`, `ports`), so there is no third copy of the
  credentials. Do it on the first `services up`, not in `create`:
  `create` runs before rendering, and creating users needs the server
  running. `create` keeps the version check (R4.2).
- *`services exec`.* The hook's clients pass no host. Set
  `MYSQL_UNIX_PORT`, or `PGHOST` and `PGPORT`, to the project's socket.
  `services up` arrives with `--force-recreate`; ignore compose flags.
- *Lifecycle.* `services` covers the database and Mailpit, `web` covers
  nginx and php-fpm, and `start`/`stop` call both. All of them must be
  safe to call twice. Trust a pid file only when the process is alive
  and its `/proc/<pid>/comm` matches (stale pid files after
  `kassar down`).
- *Running without root.* nginx needs its own top-level config (pid
  file and every `*_temp_path` under the state directory) and must
  start with `-e <log>`, or it tries `/var/log/nginx` before it reads
  the config. Give php-fpm its own config, and pass the php.ini as
  `PHP_INI_SCAN_DIR=":<dir holding .mosaic/php.ini>"` to php-fpm,
  `exec` and `shell`. MariaDB needs `--defaults-file`, so
  `/etc/my.cnf.d` does not win, and `mariadbd` is in `/usr/libexec`.
  Start Mailpit with `setsid nohup`.
- *`shell`* gets the same PATH and environment as `exec`.

**For kassar:**

- Ship Composer as the phar (`#!/usr/bin/env php`). Fedora's RPM has
  `#!/usr/bin/php`, which bypasses the branch's `php` on PATH.
- Ship xdebug installed but off, as the distrobox image does. Remi
  enables it.
- Open question 1: make `/etc/hosts` a link into the home, as `/srv`
  is, and `add-host` works without root. Until then the driver reports
  "not supported in a kassi" and suggests `<name>.localhost`, which
  browsers and curl resolve to loopback.

**Deferred:** R7 as a whole, until kassi-ports exists. Open question 3:
`mosaic up` stays manual for now.

## Update 2026-10-30: the driver, tested in a stand-in

`backends/kassi/driver` is written, with detection, docs
(`docs/kassi-backend.md`, README, CLAUDE.md, backends/README.md) and
the corrections above applied. Tested in a Fedora 44 Lima VM
provisioned like kassar's `web` runtime and used without root (see
"Testing without a kassi" in `docs/kassi-backend.md`). Against the
acceptance list:

1. Moodle 4.5 (PHP 8.3, MariaDB 10.11): `build`, the site answers on
   `http://localhost:8001/` with the login page. Pass.
2. A public plugin (`local_codechecker`) clones at its canonical path,
   `upgrade.php` installs it, `sync-graft` runs. `init-phpunit`, then
   `phpunit` on core (101 tests on 4.5, 102 on 5.1) and on the plugin
   (`--testsuite local_codechecker_testsuite`, or the test file; its 4
   failing cases are the plugin's own). Pass. A private plugin and Zed
   edits need a real kassi.
3. Moodle 5.1: plugin under `public/local/`, the site serves from
   `public/`. Pass. Two findings, both backend-independent: on 5.x a
   directory argument to `mosaic phpunit` runs nothing (PHPUnit 11;
   use the file or `--testsuite`); and the moodle `fetch` hook's
   "already laid down" marker was `version.php` at the root, which 5.x
   keeps under `public/`, so a rebuild on an existing 5.x tree refused
   to clone. Fixed on the branch (the marker follows `plugins_root`).
4. Laravel 13 (PHP 8.4, PostgreSQL 18): `build`, `migrate`, `test`,
   `dev` (Vite on `ports.vite_dev`). Pass.
5. `down`, then `up`: data intact. A simulated `kassar down` (every
   process killed with SIGKILL, pid files left behind), then `up`:
   recovers, data intact. Pass. `down` twice and `up` twice are no-ops.
6. `nuke` removes the state directory and the `/srv` links and keeps
   the tree. Pass.
7. `db.version: 11.8` in a 10.11 kassi refuses at `create`, before any
   state exists, with the version found and the recipe to add. Pass.
8. Lima: Moodle `build`, `init-phpunit`, `phpunit`; Laravel `build`,
   `test` (Steve, 2026-10-29). distrobox: `up`, `down`, `reload-web`,
   `tail-web`, `init-phpunit`, `phpunit`, `build` (Steve, 2026-10-30).
   Pass.

Also checked: `mosaic build` again on an existing tree (4.5 and 5.1),
`mosaic db` (both database types), `cli`, `purge`,
`cron`, `reload-web`, `tail-web`, `composer`, `shell`, `status`,
`doctor`; every process and file belongs to the user.

Still to run in a real kassi: everything above, plus a private plugin
over the split SSH agent (R6.2) and Zed's PHP wiring from `endpoint`.

## Goal

A project kassi, for example `titus-connect`, does the job of one mosaic
Lima VM. mosaic runs **inside** the kassi, and its guest is the kassi
itself. The project tree, its plugins and its data live in the kassi's
home and are served in place. The IDE runs in the kassi too: Zed first,
VS Code second.

A **kassi** is one of kassar's VMs on the Mac: a read-only Fedora root
shared with other kassis, plus a persistent ext4 home disk of its own.
Its windows appear on the Mac's desktop. It has one user (`user`, uid
1000), no sudo, no systemd (BusyBox init), and the network through a
netvm (for Titus, `sys-wg-titus`).

## Constraints

- **No nesting.** No podman, no containers and no VM inside the kassi.
  The database and Mailpit run as ordinary processes of the kassi's
  user.
- **No root at run time.** Everything the driver does runs as the
  kassi's user. Whatever needs root is in the kassi's template, which
  kassar provides (see "What kassar provides").
- **The flavours stay as they are.** `flavours/moodle`,
  `flavours/laravel` and the framework profiles need no change, which is
  the test `docs/flavour-architecture.md` sets for a new backend.
- **Lima and distrobox behave exactly as they do now.**
- **Native storage.** The served tree is the project tree on the kassi's
  home disk: no second clone, no grafts, no `config.php` symlink.

## R1. Selection and facts

- R1.1 The backend is chosen when `backend: kassi` is set in
  `mosaic.yaml`, or `MOSAIC_BACKEND=kassi`, or, with neither set, when
  `/etc/kassar/recipes` exists (the platform default is otherwise
  unchanged: Darwin is lima, Linux is distrobox).
- R1.2 `driver facts` prints
  `{"native_storage":true,"host_netns":true,"service_user":""}`.
- R1.3 `resolve.sh` then serves from `/srv/project`, as it already does
  for native storage. kassar's template makes `/srv` a link into the
  home (`/home/user/srv`). The driver's `create` makes
  `/srv/project` a link to the project directory, and
  `/srv/moodledata` and `/srv/phpunitdata` links into the project's
  state directory (R3.1).

## R2. The driver contract (`backends/kassi/driver`)

Every command in `backends/README.md`, implemented in place:

| Command | Requirement |
|---|---|
| `facts` | as R1.2 |
| `create` | Idempotent. Makes the state directory (R3.1). Renders user-mode nginx and php-fpm configs, with pid files, sockets and logs under the state directory and nginx on `127.0.0.1:<ports.web>`. Initialises the database directory once (`mariadb-install-db --user=$USER --datadir=…`, or `initdb`). Checks the PHP branch and the database version against R4, and refuses if they don't match |
| `exists` | the state directory exists |
| `status` | `Running` when the project's nginx pid is alive, `Stopped` when the state directory exists, else `(not created)` |
| `start`, `stop` | start or stop the database, Mailpit, php-fpm and nginx for this project, through their pid files. Starting twice and stopping twice are no-ops |
| `destroy` | `stop`, then delete the state directory, the database included. The project tree stays, as with `mosaic nuke` on the other backends |
| `exec <guest> <cmd…>` | `cd /srv/project` (with the `direnv` export the Lima driver does), then `exec` the command, argv kept exactly. `MOSAIC_FORWARD_AGENT` needs nothing: the kassi's `SSH_AUTH_SOCK` is already kassar's split SSH agent |
| `shell` | `$SHELL` in `/srv/project` |
| `endpoint` | `url<TAB>http://localhost:<ports.web>/` and `php<TAB><path of the php binary>`, for Zed and VS Code. No ssh lines |
| `services up\|down` | the database and Mailpit, as in `start` and `stop` |
| `services exec [-it] [-e K=V] <container> <cmd…>` | ignores the container name, applies `-e`, and runs the command in place. `mosaic db` therefore opens the `mariadb` or `psql` client against the project's socket with the credentials `render-services.sh` defines |
| `add-host`, `remove-host` | a user can't write `/etc/hosts` in a kassi. Keep a hosts file in the state directory that nginx and PHP use, or report "not supported in a kassi" clearly. To be settled with kassar's kassi-ports work (R7) |
| `doctor` | `just`, `yq` (mikefarah's), `git`, the PHP branch, the database server, the state directory, and nginx's port free |

## R3. Where things live

- R3.1 The state directory is
  `~/.local/state/mosaic/projects/<project>/`, with `run/`, `log/`,
  `moodledata/`, `phpunitdata/` and `db/`. This matches the distrobox
  backend's dataroots.
- R3.2 The project tree is wherever `mosaic new` put it, normally
  `~/projects/<name>`.
- R3.3 mosaic itself is a git checkout in the home, with `bin/mosaic`
  linked into `~/.local/bin`. kassar's `mosaic` recipe will do that.

## R4. Versions

- R4.1 **PHP:** `php.version` in `mosaic.yaml` picks the branch. The kassi
  has PHP 8.1 to 8.5 installed side by side from Remi's repository, as
  software collections. The driver finds the branch's `php-fpm` and
  `php` binaries. Remi's collections install under `/opt/remi/phpXY/`,
  with `phpXY` commands on PATH; confirm the exact paths once kassar's
  runtime is built. The driver puts the right `php` first on PATH for
  `exec`, so Composer, `artisan` and Moodle's CLI scripts use it.
- R4.2 **Database:** one MariaDB server per kassi (Fedora installs only
  one), plus Postgres 18. kassar's template carries MariaDB 10.11 and
  Postgres 18, which match mosaic's defaults (Moodle 4.x: MariaDB 10.11;
  Laravel 13: Postgres 18). A kassi set up for MariaDB 11.8 has 11.8
  instead. `create` compares `db.type` and `db.version` with the server
  it finds (by major.minor), and refuses with a message that names the
  version found and the kassar recipe to add.
- R4.3 Mailpit is a single binary on PATH (from kassar's runtime).
- R4.4 Exact patch versions of a database are out of scope. This is the
  one thing given up against the Lima backend.

## R5. Core changes outside the driver

- R5.1 A new driver verb, `web start|stop|restart|reload|logs`, replaces
  the direct `in-vm … sudo systemctl … nginx php<ver>-fpm` calls in
  `scripts/up.sh`, `scripts/down.sh` and `scripts/build.sh`, and in the
  `reload-web` and `tail-web` recipes in `core/core.just`. The Lima and
  distrobox drivers implement it with the `systemctl` and `journalctl`
  lines they run today, so nothing changes there. The kassi driver uses
  pid files, `nginx -t` and the log directory.
- R5.2 The `sudo` lines that run on the native-storage path
  (`scripts/init-phpunit.sh`: `configure-phpunit` and the `phpunitdata`
  chmod; the moodle `install` hook's `configure-phpunit` call) run
  without `sudo` when `service_user` is empty, as `scripts/in-project.sh`
  already does. The bake-path `sudo` lines stay, because native storage
  never runs them.
- R5.3 `README.md`, `CLAUDE.md` and `backends/README.md` list the third
  backend. A short `docs/kassi-backend.md` gives the rationale, in the
  style of `docs/linux-backend.md`.

## R6. Behaviour to keep

- R6.1 Moodle 4.x and 5.x, including 5.x's `public/` layer and
  `project_files` symlinks, through the existing native-storage code
  paths.
- R6.2 Workplace from its private Bitbucket repository, and private
  plugins, over the kassi's split SSH agent.
- R6.3 `mosaic down` then `up` keeps everything. So does a kassi restart
  (`kassar down`, then `kassar up`) followed by `mosaic up`.
- R6.4 `phpunit`, `init-phpunit`, `cli`, `purge`, `cron`, `plugins` and
  `sync-graft` for Moodle; `artisan`, `tinker`, `queue`, `migrate`,
  `test`, `pest` and `dev` (Vite on `ports.vite_dev`) for Laravel.
- R6.5 Bash 3.2 compatibility stays a repo-wide rule, though the driver
  only ever runs inside a kassi (bash 5).

## R7. With kassar's kassi-ports (Titus Connect)

Titus Connect has Moodle in one kassi and Laravel in another, with
Laravel calling Moodle over HTTP. kassar's kassi-ports design (planned)
lets one kassi serve listed ports to named kassis on the same netvm,
under a fixed name such as `titus-moodle.kassi`.

- R7.1 Moodle's `wwwroot` must be the name and port the other kassi
  uses, for example `http://titus-moodle.kassi:<ports.web>`. Moodle
  redirects to its `wwwroot`, so the serving kassi's own browser must
  reach that name too.
- R7.2 **Open on the kassar side:** a kassi never learns its own name
  (kassar's identity rule), so the serving kassi can't simply resolve
  its own service name. kassi-ports has to settle this, for example with
  a neutral alias such as `self.kassi`, or by giving the serving kassi
  its service name through the cmdline. Until then, use `localhost` for
  single-kassi work.
- R7.3 nginx binds the address kassi-ports forwards to (the kassi's link
  address as well as 127.0.0.1), and only when the project opts in, for
  example with a `listen:` key in `mosaic.yaml`.

## What kassar provides (not mosaic's work)

- The `web` runtime in Steve's Fedora `dev` template: nginx, Remi PHP
  8.1 to 8.5 with the extensions in `backends/distrobox/Containerfile`
  (mysql, pgsql, mbstring, xml, gd, intl, zip, curl, bcmath, soap, redis,
  sqlite3, opcache, xdebug), Composer, Node 22, git, just, yq, the
  MariaDB and Postgres clients and servers, Mailpit, and the `/srv`
  link.
- `mariadb@11.8` for a kassi that needs it.
- The `mosaic` recipe (R3.3).
- Optionally, services at boot, so a project comes up when its kassi
  starts.
- kassi-ports (R7).

## Acceptance

1. In a fresh dev kassi:
   `mosaic new lms --framework=moodle --version=4.5`, then `mosaic build`.
   The site answers on `http://localhost:<port>/` in the kassi's browser,
   with admin and `Password1!`.
2. Two plugins declared in `mosaic.yaml`, one public and one private,
   clone at canonical paths. A change in Zed shows after `mosaic purge`.
   `mosaic init-phpunit` then `mosaic phpunit` passes a plugin's tests.
3. The same with Moodle 5.1 (the `public/` layer).
4. Laravel 13 on Postgres 18: `mosaic build`, `mosaic migrate`,
   `mosaic test` and `mosaic dev` (Vite) all work.
5. `mosaic down`, `kassar down`, `kassar up`, `mosaic up`: everything is
   back, with the data intact.
6. `mosaic nuke` removes the state and keeps the tree.
7. `mosaic.yaml` asking for MariaDB 11.8 in a 10.11 kassi refuses with
   R4.2's message.
8. Lima and distrobox projects build exactly as before (`mosaic build` on
   an existing project of each).

## Open questions

1. `add-host` in a kassi: a mosaic-side hosts file, or not supported
   (R2)?
2. The serving kassi's own name for kassi-ports (R7.2), with kassar.
3. Whether `mosaic up` should run by itself when the kassi boots, through
   kassar's services, or stay manual.
