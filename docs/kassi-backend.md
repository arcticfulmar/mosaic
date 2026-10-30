# kassi backend: mosaic inside a kassar VM

Status: **implemented, tested in a stand-in** (2026-10-30): a Fedora 44
Lima VM provisioned like kassar's `web` runtime (Remi PHP 8.3 and 8.4,
MariaDB 10.11, PostgreSQL 18, nginx, Mailpit, `/srv` linked into the
home, `/etc/kassar/recipes` present), used without root. Not yet run in
a real kassi. The brief is
[kassi-backend-requirements.md](kassi-backend-requirements.md).

This is the third backend behind the driver seam
([link-architecture.md](link-architecture.md)). The flavours are
unchanged; two of their `sudo` lines now go through `root_prefix`,
which is the one addition to core the kassi needed (see "What core
gained").

## What a kassi is, for mosaic's purposes

A kassi is one of kassar's VMs on the Mac: a read-only Fedora root
shared with other kassis, a persistent ext4 home disk of its own, one
user (`user`, uid 1000), no sudo, no systemd (BusyBox init), its
windows on the Mac's desktop, and the network through a netvm. Its ssh
agent is kassar's split agent, already in `SSH_AUTH_SOCK`.

mosaic runs **inside** the kassi, and the guest is the kassi itself.
The project tree, its plugins, its data and the IDE all live in the
kassi's home. Nothing is nested: no VM, no container, no ssh hop.

## What is different from the other backends, and why

### The guest is the machine mosaic runs on

`exec` is `cd /srv/project` plus `exec`, with the same `direnv` export
the Lima driver does. `shell` is `$SHELL` there. `MOSAIC_FORWARD_AGENT`
needs nothing. `endpoint` prints the URL for the kassi's own browser
and the path of the branch's `php` for Zed or VS Code; there are no
ssh lines.

### Native storage, as on distrobox

The home disk is native ext4, so there is no bake: the driver reports
`native_storage: true` and the flavours take the code paths
[linux-backend.md](linux-backend.md) describes. `/srv` is a link into
the home, made by kassar's template; `create` makes `/srv/project`,
`/srv/mosaic`, `/srv/moodledata`, `/srv/phpunitdata`, `/srv/run` and
`/srv/<framework>` links under it. `/srv/project` is one link, so a
kassi holds one project; `create` refuses a second and names the first.

### No root at run time

A kassi user has no sudo and there is no systemd, so nginx, php-fpm,
the database and Mailpit are ordinary processes of the user, tracked
through pid files under the state directory
(`~/.local/state/mosaic/projects/<project>/{run,log,db,moodledata,phpunitdata}`).

- **nginx** gets a top-level config of its own (`run/nginx.conf`) with
  the pid file, logs and every `*_temp_path` under the state directory,
  and includes the project's rendered `.mosaic/nginx.conf` as its server
  block. It starts with `-p <state> -c <conf> -e <log>`: without `-e`
  nginx tries `/var/log/nginx` before it reads the config. `include
  fastcgi_params` in the server block resolves relative to the wrapper's
  directory, hence a link `run/fastcgi_params → /etc/nginx/fastcgi_params`.
- **php-fpm** gets `run/php-fpm.conf`: pid file, log and a socket at
  `run/php-fpm.sock`. The driver's `fpm_socket` fact names it as
  `/srv/run/php-fpm.sock`, which `render-services.sh` writes into the
  `fastcgi_pass` line. `.mosaic/php.ini` reaches php-fpm and the CLI
  alike through `PHP_INI_SCAN_DIR=":/srv/project/.mosaic"`; the
  leading `:` keeps the branch's own `php.d`.
- **MariaDB** runs with `--defaults-file=run/mariadb.cnf`, so Fedora's
  `/etc/my.cnf.d` (socket and datadir under `/var`) does not win. The
  server flags come from the compose template's `command:`, so the
  charset and collation match the other backends. `mariadbd` is in
  `/usr/libexec` on Fedora.
- **PostgreSQL** is driven by `pg_ctl`, with the socket in `run/`.
- **Mailpit** does not daemonise; `setsid nohup` detaches it from the
  terminal mosaic ran in.
- A pid file is trusted only when the process is alive **and**
  `/proc/<pid>/comm` is the expected program: after `kassar down` the
  files are stale and the pids may be reused.

The `sudo` fact is `false`. Core's `root_prefix` (lib.sh) then runs
plain what it would run under `sudo` elsewhere.

### The database is the distro's own server

There is no podman, so no `mariadb:<tag>` image. The kassi has one
MariaDB (10.11 by default; 11.8 if its template says so) and one
PostgreSQL (18). `create` compares `db.type` and `db.version` with what
it finds (MariaDB by major.minor, PostgreSQL by major) and refuses with
the version found and the kassar recipe to add. Exact patch versions
are the one thing given up against the Lima backend.

The first `services up` initialises the data directory
(`mariadb-install-db` or `initdb`) and creates what the compose image
would have created from its environment: root's password, the app user
and the database, read from the rendered `.mosaic/services-compose.yaml`
so there is no third copy of the credentials. This happens on
`services up`, not `create`, because `create` runs before the render
and creating users needs the server running. The install hooks then
find what they find elsewhere: `mariadb-admin ping -uroot -p…` answers,
`DROP DATABASE moodle; CREATE DATABASE moodle` works, and the app
user's grants on the name survive the drop.

`services exec` drops the container name, applies `-e`, and runs the
command in place with `MYSQL_UNIX_PORT` (or `PGHOST` + `PGPORT`)
pointing at the project's server. `mosaic db` therefore opens the
client against the project's socket with the usual credentials.

### Host network namespace

nginx binds `127.0.0.1:<ports.web>` (`host_netns: true`), and that is
the address the kassi's browser uses. The database and Mailpit bind
loopback too.

## What core gained

- `driver web start|stop|restart|reload|logs`: core no longer runs
  `systemctl` in the guest. Lima and distrobox share `systemd_web` in
  `lib.sh`, running the lines they ran before.
- The `fpm_socket` fact and the `@@FPM_SOCKET@@` placeholder in the
  nginx templates. Absent the fact, the old path is rendered.
- The `sudo` fact and `root_prefix`, for the few guest commands that
  run on every backend and need root where there is one.

## Selection

`backend: kassi` in `mosaic.yaml`, `MOSAIC_BACKEND=kassi`, or, with
neither set, the presence of `/etc/kassar/recipes` on Linux (the marker
kassar's template writes). The platform defaults are otherwise
unchanged.

## Not supported, and open

- `add-host` / `remove-host`: `/etc/hosts` is read-only for a kassi
  user. The driver says so and suggests `wwwroot: <name>.localhost`,
  which browsers and curl resolve to loopback. If kassar links
  `/etc/hosts` into the home, as it does `/srv`, the verb can be
  implemented without any mosaic-side hosts file.
- kassi-ports (Laravel in one kassi calling Moodle in another): waits
  for kassar's design. Until then `wwwroot` is `localhost`.
- Bringing a project up when its kassi boots: `mosaic up` is manual.
  kassar's services could run it once the pid handling has had real use.
- For kassar's `web` recipe: ship Composer as the phar (Fedora's RPM has
  a `#!/usr/bin/php` shebang that bypasses the branch's `php` on PATH)
  and xdebug installed but off, as the distrobox image does.

## Testing without a kassi

A Fedora 44 Lima VM provisioned as root once (Remi's `php83`/`php84`
collections with mosaic's extension list, `mariadb10.11-server`,
`postgresql-server`, nginx, Mailpit, Composer's phar, `just`, `yq`,
`git-core`, `nodejs`; `/srv → ~/srv`; `echo web > /etc/kassar/recipes`)
and then used without sudo behaves like a kassi for everything but the
acceptance tests. The mosaic checkout can be the host's, mounted
read-only: mosaic never writes under `MOSAIC_HOME`.
