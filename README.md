# SmartColumn

A smart speaker running a purpose-built Linux distribution assembled with the
**Yocto Project**. It combines a voice AI assistant with a multimedia player
(AirPlay, Internet radio, local files, Bluetooth) and a web interface on the
local network.

Unlike off-the-shelf smart speakers, the whole software stack is built from
source and under the owner's control — including where voice data is processed.

The device supports two AI topologies, chosen at build time:

- **Profile A — local.** Speech recognition, the language model and speech
  synthesis all run on the device. Voice data never leaves it.
- **Profile B — hybrid.** Only wake word detection is local; the rest goes to
  an external service. Runs on an order of magnitude cheaper hardware.

## Repository layout

| Path | Contents |
|---|---|
| [`SmartColumnSpec/`](https://github.com/NikitaBukhta/SmartColumnSpec) | Product documentation — requirements, architecture decisions, verification plan. Git submodule. |
| [`scripts/`](scripts) | Build host setup, first image build, SDK build and install, QEMU launcher, revision pinning. |
| [`build-config/`](build-config) | Build configuration: the defaults every script reads ([`build.env`](build-config/build.env)), and the layer revisions they resolve to. |

Yocto layers, recipes and application source will live in separate
repositories; see `SmartColumnSpec/en/11-yocto-layer-plan.md`.

## Getting started

```bash
git clone --recurse-submodules git@github.com:NikitaBukhta/SmartColumn.git
```

Already cloned without submodules:

```bash
git submodule update --init --recursive
```

Then start from [`SmartColumnSpec/README.md`](SmartColumnSpec/README.md). The
English edition is canonical, a Russian translation is kept in step with it,
and `SmartColumnSpec/dist/` holds the whole set as PDF and DOCX.

## Building the image

The build needs an x86-64 host running **Ubuntu 22.04 or 24.04** and at least
50 GB of free space. Under WSL2 the checkout **must** live in the Linux
filesystem (`/home/...`): a build directory on a mounted Windows drive breaks
permissions, symlinks and case sensitivity, so the script refuses to run
there.

```bash
./scripts/prepare_env.sh
```

It takes the host from nothing to a booting image:

1. checks the build directory — filesystem type and free space;
2. installs the host packages BitBake needs;
3. generates the `en_US.UTF-8` locale;
4. caps `BB_NUMBER_THREADS` and `PARALLEL_MAKE` at 2 GB of RAM per thread, so
   a link task cannot exhaust memory;
5. installs `bitbake-setup` into `bitbake-setup-venv/` and initialises the
   setup under `bitbake-builds/`;
6. enables the `sstate-mirror-cdn` fragment and builds the image.

A first build from scratch takes hours. Prebuilt artefacts from the Yocto
sstate CDN reduce what has to be compiled, which is what step 6 turns on.
Re-running the script reuses the existing setup and rebuilds only what
changed.

Every variable below takes its default from
[`build-config/build.env`](build-config/build.env), which every script that
touches the build sources. Setting one in the environment wins over the file,
so a one-off change needs no edit:

```bash
BB_TARGET=core-image-base ./scripts/prepare_env.sh
```

| Variable | Default | Purpose |
|---|---|---|
| `BB_TARGET` | `core-image-minimal` | Image to build |
| `BB_INIT_ARGS` | `poky-wrynose poky distro/poky machine/qemux86-64` | Configuration id, its options and fragments, passed to `bitbake-setup init` |
| `BB_FRAGMENTS` | `core/yocto/sstate-mirror-cdn` | Fragments enabled before the build; empty enables none, for a build without the sstate mirror |
| `BB_MIN_FREE_GB` | `50` | Free space the disk check demands |
| `BB_ROOT_LOGIN` | `1` | Root logs in with an empty password; set to `0` for an image that leaves the workstation |
| `BB_SOURCE_OVERRIDES` | `build-config/source-overrides.json` | Layer revision pins; ignored when the file is missing |
| `BB_TOP_DIR_NAME` | `bitbake-builds` | Top directory for setups and caches |
| `BB_SETUP_DIR` | `poky-wrynose` | Setup directory inside it |

Everything the build produces stays in `bitbake-builds/`, which git ignores.
`DL_DIR` and `SSTATE_DIR` sit outside `build/`, so deleting `build/tmp/` for a
clean rebuild does not throw away the downloads or the cache.

## Layer revisions

The configuration registry hands out **branch names** — `openembedded-core` at
`wrynose`, `bitbake` at `2.18`. Branches move, so two people running the same
command a week apart would build different code. `NFR-MNT-010` forbids that.

[`build-config/source-overrides.json`](build-config/source-overrides.json)
fixes every layer at an exact commit. `prepare_env.sh` hands it to
`bitbake-setup init` through `--source-overrides`, so a fresh checkout
reproduces the same tree. The pins are only read at `init`; afterwards they
live in the setup's own `config/config-upstream.json`.

To move the pins to the current head of each recorded branch:

```bash
./scripts/update_pins.sh          # rewrite the revisions
./scripts/update_pins.sh --check  # report only, non-zero exit if behind
```

It reads revisions over the network and clones nothing, so it is quick and
touches no build. `--check` suits CI. A branch that has disappeared upstream is
an error rather than a silent no-op.

This only follows the branches already in the file. Moving to a newer Yocto
release means changing the configuration id in `BB_INIT_ARGS`, not the pins.

After updating, rebuild to verify and commit the file as a change of its own
(`NFR-MNT-010` item 3). An existing setup takes the new revisions with:

```bash
./bitbake-setup-venv/bin/bitbake-setup update --setup-dir bitbake-builds/poky-wrynose --update-bb-conf no
```

`--update-bb-conf no` is not optional. The default prompts, which hangs a
non-interactive shell, and accepting the prompt regenerates `build/conf/` from
upstream — dropping any fragment enabled locally, `sstate-mirror-cdn`
included.

## Running the image in QEMU

```bash
./scripts/run_qemu.sh
```

Leave the console with `Ctrl-A`, then `X`.

The script locates the built machine and its `.qemuboot.conf` on its own, so
the build environment does not have to be sourced first. It boots headless
(`nographic`), with user-mode networking (`slirp`, needs no `sudo`) and from a
throwaway copy of the rootfs (`snapshot`, also required because the image is
compressed). KVM is added when the host and the target architecture match.

| Variable | Default | Purpose |
|---|---|---|
| `QEMU_MACHINE` | the one built machine | Which machine to boot |
| `BB_TARGET` | `core-image-minimal` | Which image to boot |
| `RUNQEMU_OPTS` | `nographic slirp snapshot` | Replaces the whole default option set |

Any extra arguments are passed through to `runqemu`.

### Logging in

Log in as `root` with an empty password — just press Enter.

That comes from the `root-login-with-empty-password` fragment, which
`prepare_env.sh` enables by default. Upstream ships the image locked instead —
no `/etc/shadow`, and root listed as `root:*` — which leaves no way into a QEMU
console at all, so the default here is flipped.

For an image that leaves the workstation, turn it off:

```bash
BB_ROOT_LOGIN=0 ./scripts/prepare_env.sh
```

The variable toggles in both directions, so switching it off really removes the
fragment instead of leaving it enabled from an earlier build. Either way only
the rootfs is regenerated — minutes, not another full build.

## Cross-compilation SDK

Applications are cross-compiled against an SDK generated **from the image**, so
its target sysroot holds every package the image installs plus their `-dev`,
`-dbg` and `-src` counterparts. The bare `meta-toolchain` recipe gives a
compiler and libc only, and is not enough.

### Building it

```bash
./scripts/build_sdk.sh
```

The installer and the metadata bitbake deploys next to it — manifests, SBOM,
test data — are packed into one archive under `sdk/`:

```
sdk/sdk-qemux86-64-64bit-6.0.3.tar.gz
```

Machine, the target's word size and the distro version come from the SDK's own
metadata, so a change of machine or tune renames the archive instead of
mislabelling it. The host architecture the installer runs on — it refuses to
run on any other — is part of the installer's name inside. `sdk/` is not
tracked by git: a 240 MiB installer never comes out of history again.

| Variable | Default | Purpose |
|---|---|---|
| `BB_TARGET` | `core-image-minimal` | Image whose sysroot the SDK carries |
| `SDK_TASK` | `populate_sdk` | `populate_sdk_ext` builds the extensible SDK instead |
| `SDK_DIR` | `sdk` | Where the archive is written |

`do_populate_sdk` is an ordinary sstate task, so running the script again after
a build that changed nothing costs a parse and no rebuild, while anything that
changes the image — a package added, a recipe bumped — invalidates it and
the SDK is regenerated. Deleting the installer from `build/tmp/deploy/sdk/`
by hand does not: the stamp stays valid, and forcing it takes
`bitbake <image> -c populate_sdk -f`.

Rebuild and republish whenever the image changes: a library added to the image
does not appear in an SDK built before it. The archive is published as an asset
of a GitHub release, which is where the next script fetches it from.

### Installing it

```bash
gh auth login                 # once per machine
./scripts/install_sdk.sh      # optional architecture argument, default: x86
```

It downloads the archive for that architecture, unpacks it and runs the
installer into `/opt/smart-column-sdk/<arch>`, discarding the download once the
SDK is in place. The installer escalates with `sudo` by itself when the
destination is not writable.

| Variable | Default | Purpose |
|---|---|---|
| `SDK_REPO` | `NikitaBukhta/SmartColumn` | Repository holding the release |
| `SDK_RELEASE` | `dummy` | Release tag to download from — a placeholder until the first real release |
| `SDK_INSTALL_ROOT` | `/opt/smart-column-sdk` | Parent of the per-architecture directory |

These come from the script itself rather than `build.env`, so it stays runnable
on a machine that has never built anything. A further architecture is one line
in `SDK_ASSETS` at the top of it, mapping the name to the asset file.

Then, in a shell of its own — sourcing the SDK environment and
`init-build-env` in the same shell confuses bitbake:

```bash
. /opt/smart-column-sdk/x86/environment-setup-x86-64-v3-poky-linux
```

### SDK credentials

The repository is private, so the download is authenticated — and that is the
whole access control: read access to the repository is what limits the SDK to
contributors.

`gh auth login` is the way to hold those credentials. It keeps them in the
system keyring, nothing has to be typed again, and revoking someone's
repository access revokes their access to the SDK with it.

Without `gh` the script falls back to `GITHUB_TOKEN`. Create it under
**Settings → Developer settings → Personal access tokens → Fine-grained
tokens**, with exactly these parameters:

| Setting | Value |
|---|---|
| Resource owner | `NikitaBukhta` — the account owning the repository |
| Repository access | Only select repositories → `SmartColumn` |
| Repository permissions → Contents | **Read-only** |
| Any other permission | none |
| Expiration | a finite date |

`Contents` is what governs releases and their assets — GitHub has no separate
permission for them — and reading is all the script does. A classic token
would need the whole `repo` scope instead, which grants write access to every
repository you own.

A token without that permission gets **404, not 403**: GitHub will not reveal
that a private resource exists. A missing release looks identical, so suspect
the token first.

The token is handed to the script through the environment, under the name
`GITHUB_TOKEN`. Prompting for it is the form that leaves no trace — `-s` keeps
it off the screen, and nothing reaches `~/.bash_history`:

```bash
read -rsp 'GitHub token: ' GITHUB_TOKEN && export GITHUB_TOKEN
./scripts/install_sdk.sh
```

`export` is what makes the variable visible to the script; without it the value
stays in the shell and the script stops with the credentials error. For a single
run the inline form does the same in one line, at the cost of a history entry:

```bash
GITHUB_TOKEN=github_pat_... ./scripts/install_sdk.sh
```

To keep it across sessions, store it outside the checkout and read it back,
rather than writing the token itself into a shell profile:

```bash
install -D -m 600 /dev/null ~/.config/smartcolumn/token
"${EDITOR:-nano}" ~/.config/smartcolumn/token
echo 'export GITHUB_TOKEN="$(cat ~/.config/smartcolumn/token)"' >>~/.bashrc
```

`gh`, when installed, reads `GITHUB_TOKEN` too, so setting the variable works
whether or not the CLI is present and logged in. In CI the value comes from
`secrets.GITHUB_TOKEN`, which already reads releases of its own repository.

**Never put the token in `build-config/build.env`**, or in any other tracked
file: it would reach everyone through git history, and a leaked token has to be
revoked on GitHub rather than deleted in a commit. The script deliberately
takes no `--token` option either — command lines are visible to every user of
the machine through `ps`, environment variables are not.

### Installing by hand

Only the `.sh` inside the archive is needed; the rest is the record of what the
SDK contains.

```bash
tar -xzf sdk-qemux86-64-64bit-6.0.3.tar.gz
./poky-glibc-x86_64-core-image-minimal-x86-64-v3-qemux86-64-toolchain-6.0.3.sh -y -d ~/sdk/poky-wrynose
```

The install directory **must** be in the Linux filesystem for the same reason
the build is: relocation rewrites the ELF interpreter of every binary. The
installer rejects paths with spaces and paths over 1024 characters, but it does
not check the filesystem type, so a `/mnt/c` target fails later and quietly.

## Status

Documentation phase. The requirement set is at v1.0.0, status `DRAFT`.
The build environment is scripted, `core-image-minimal` builds and boots for
`qemux86-64`, and a cross-compilation SDK is built and installed by script;
the project's own layers have not been started — see
`SmartColumnSpec/en/15-roadmap-milestones.md` for the milestone plan.
