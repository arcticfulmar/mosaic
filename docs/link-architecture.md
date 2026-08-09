# Linking architecture

Replaces v1's `apply-graft`. The job is unchanged: host-owned directories
and files must appear at canonical positions inside a framework tree that
lives on fast guest-native storage, without breaking the path semantics
PHP relies on.

## What v1 does, and why it needs replacing

`scripts/apply-graft` is a 242-line script that runs **inside** the guest
as root, on every boot via a systemd oneshot, reading `mosaic.yaml`
through `yq`. Each run: unmounts everything currently bound under the
framework tree, reaps symlinks recorded in
`/var/lib/mosaic/grafted-files`, re-reads the manifest, `rm -rf`s each
destination, re-creates it, bind-mounts the host path over it, then
restarts php-fpm to clear `realpath_cache`.

It works. The problems are structural:

1. **Imperative and stateful.** Idempotent by cleanup rather than by
   construction: it has to reverse the previous run before it can perform
   the current one, which is why the state file exists.
2. **The mechanism leaks into the semantics.** "Directories get bind
   mounts, files get symlinks" reads like a design rule but is an
   artifact of what was easy. Testing shows single-file mounts work fine
   (see [runtime-findings.md](runtime-findings.md)), so the rule was
   never load-bearing.
3. **Framework knowledge in the wrong place.** `plugins_root` — a Moodle
   5.x concern — is consumed by `apply-graft`, `sync-graft.sh`,
   `bake.sh`, `render-services.sh` and the nginx template. Five places
   know about `public/`.
4. **Failures are silent.** A missing source directory prints to stderr
   and continues, so a typo in `destination:` produces a running site
   with a quietly absent plugin.
5. **Undebuggable from outside.** Answering "what is actually grafted
   right now?" means `mosaic shell` and reading `/proc/self/mountinfo`.
6. **Side effects.** It restarts php-fpm, which is nothing to do with
   linking.

## The v2 model: the plan is data

One idea: **compute the link plan on the host, and let the runtime apply
it.** Both backends already accept a mount list at creation time —
`container`'s `--volume`, Lima's `mounts:`. Nothing needs to run inside
the guest.

```
mosaic.yaml ──▶ flavour hook ──▶ link plan ──▶ backend driver ──▶ runtime mounts
 (intent)        (expansion)     (.mosaic/     (rendering)
                                  links.json)
```

The plan is a build artifact, inspectable on the host, diffable between
runs, and identical across backends. It is also the only state: there is
no `/var/lib/mosaic/grafted-files`, because the plan *is* the record of
what should exist.

### Link modes

Chosen by what the guest does with the path, not by whether the source is
a file or a directory:

| Mode | Semantics | Use when |
|---|---|---|
| `graft` | Source appears at the target path, carrying the target's identity. `__DIR__`, `realpath()`, `pwd -P` and autoloaders all resolve canonically. | Content the framework treats as a path anchor — plugins, themes, any PHP that does `__DIR__/../../config.php`. **Default for code.** |
| `alias` | Target is a symlink to the source. Resolves *through* to the source path. | Content that is read but never anchors a path — `.env`, config fragments. Survives without runtime support. |
| `seed` | One-time copy at create; no live link. | Files the framework rewrites where you don't want the change written back to the host. |

`graft` is a runtime mount. `alias` is a symlink created once. The v1
dir/file split disappears; `.env` can be either, and you choose on
meaning.

### Plan schema

`.mosaic/links.json`, generated on the host:

```json
{
  "version": 1,
  "base": "/srv/moodle",
  "entries": [
    { "source": "local/codechecker",
      "target": "local/codechecker",
      "mode": "graft",
      "on_conflict": "shadow",
      "origin": "plugins[0]" },

    { "source": ".env",
      "target": ".env",
      "mode": "alias",
      "on_conflict": "require-absent",
      "origin": "project_files[0]" }
  ]
}
```

- `source` — relative to the project root on the host.
- `target` — relative to `base`, already resolved through `plugins_root`.
  The `public/` layer for Moodle 5.x is applied **once**, at plan time, by
  the flavour. Nothing downstream knows about it.
- `origin` — the manifest key this came from, so errors can point at what
  the user wrote rather than at a derived path.

### Conflict policy, made explicit

| Policy | Behaviour if the base tree already has content at `target` |
|---|---|
| `shadow` | Allowed; the graft hides it. Default for `graft`. |
| `require-absent` | Hard error. Default for `alias` — matches v1's refusal to shadow a real file, but now uniform and declared. |
| `require-present` | Hard error if the base tree *lacks* the path. Catches typo'd destinations at plan time. |

All conflict and missing-source checks run **on the host, before the
runtime is touched**. v1's silent-skip-and-continue becomes a refusal to
build.

### Stubs

A `graft` target must exist before the runtime can mount onto it. Since
the plan is known on the host, stub creation is deterministic:

- **container**: stubs are baked into the image (they are a function of
  the plan, so the image build emits `mkdir -p` for each target).
- **Lima**: stubs are created by the post-bake step.

Testing confirmed a mount over a populated image path shadows it cleanly,
so a stub that accidentally contains content is harmless rather than a
corruption risk.

## Backend drivers

Flavours never see the backend. A driver implements:

```
create(spec, links)   start()   stop()   exec(argv)   apply_links(plan)   destroy()
```

**lima driver (macOS, primary).** `apply_links` renders `graft` entries
into `mounts:` in `lima.yaml`, applied at boot. For re-linking without a
VM restart, a small in-guest reconciler reads the same `links.json`,
diffs it against `/proc/self/mountinfo`, and mounts or unmounts only the
difference. Stateless — it derives everything from the plan and the
kernel, holds no state file, and is idempotent by construction rather
than by cleanup; roughly 40 lines against v1's 242. Provisioning moves
from cloud-init to Mosaic-published prebuilt VM images, so the 5-10
minute first boot collapses to an image download shared across projects.
Chosen as primary because Lima's hostagent-routed networking survives
leak-protection VPNs that kill vmnet NAT — see
[runtime-findings.md](runtime-findings.md).

**distrobox/podman driver (Linux).** Same contract, same plan. `create`
maps to `distrobox create --image <img> --name mosaic-<proj> --init`
plus one `--volume` per `graft` entry; `shell` is `distrobox enter`;
`apply_links` is rm + re-create — cheap with no VM in the way, so no
reconciler is needed. The two backends consume different image formats
(VM disk image vs OCI), but both are built from the same provisioning
definition — that, not a shared binary artifact, is the deliverable of
moving provisioning out of boot-time scripts. Linux-specific driver
concerns, kept out of flavours:

- **UID mapping.** Rootless podman enforces mount permissions through
  the userns. The design already never chowns mounts, so the only
  consequence is that the service user (`www-data` vs keep-id-mapped
  host user) is chosen by the driver.
- **Networking.** Distrobox shares the host network namespace: no port
  publishing exists or is needed; the per-project port counter is the
  whole story.
- **SELinux.** The driver appends `:Z` to volume specs on
  SELinux-enforcing hosts.

**apple/container driver (deferred).** Every mechanism verified 2026-08
(see [runtime-findings.md](runtime-findings.md)): create-time `-v`
grafts give the exact bind-mount semantics with 0.49s re-create, so
`apply_links` would need no reconciler at all — the cleanest possible
rendering of the plan. Deferred because its vmnet NAT egress dies under
leak-protection VPNs (Mullvad, tested exhaustively). Revisit if Apple
ships user-mode networking.

## What this removes

| v1 | v2 |
|---|---|
| `scripts/apply-graft` (242 lines) | plan renderer on the host + ~40-line Lima-only reconciler |
| `apply-graft.service` systemd unit | nothing — the runtime restores mounts |
| `/var/lib/mosaic/grafted-files` | nothing — the plan is the state |
| `sync-graft.sh` special-casing | `mosaic link` re-renders and re-applies |
| php-fpm restart as a side effect | explicit core step after `apply_links` |
| `plugins_root` in 5 places | resolved once, at plan time, by the flavour |
| Silent skip on missing source | hard error before the runtime starts |
| `mosaic shell` + read `/proc/self/mountinfo` | `mosaic links` prints plan + live status |

## `mosaic links`

```
$ mosaic links
base  /srv/moodle  (container: mosaic-mylms)

MODE   TARGET                      SOURCE                    STATUS
graft  local/codechecker           ./local/codechecker       ok
graft  local/titusconnect          ./local/titusconnect      ok
graft  mod/customcert              ./mod/customcert          STALE (plan changed, not applied)
alias  .env                        ./.env                    ok
graft  local/typo                  ./local/typo              MISSING SOURCE

2 problems. Run `mosaic link` to re-apply.
```

Being able to answer "what is grafted, and does it match the manifest?"
from the host, without a shell, is most of the debuggability win.
