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
| [`scripts/`](scripts) | Build host setup, first image build, QEMU launcher, revision pinning. |
| [`build-config/`](build-config) | Build configuration, and the layer revisions it resolves to. |

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

| Variable | Default | Purpose |
|---|---|---|
| `BB_TARGET` | `core-image-minimal` | Image to build |
| `BB_INIT_ARGS` | `poky-wrynose poky distro/poky machine/qemux86-64` | Configuration id, its options and fragments, passed to `bitbake-setup init` |
| `BB_FRAGMENTS` | `core/yocto/sstate-mirror-cdn` | Fragments enabled before the build |
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

## Status

Documentation phase. The requirement set is at v1.0.0, status `DRAFT`.
The build environment is scripted and `core-image-minimal` builds and boots
for `qemux86-64`; the project's own layers have not been started — see
`SmartColumnSpec/en/15-roadmap-milestones.md` for the milestone plan.
