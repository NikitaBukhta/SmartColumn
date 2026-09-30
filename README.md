# SmartColumn

A smart speaker running a custom Linux distribution built with the Yocto Project.

> **Work in progress.** Only this repository and
> [meta-smart-column](https://github.com/NikitaBukhta/meta-smart-column) are
> public — they show how the Yocto image is configured.

## Requirements

- x86-64 host with Ubuntu 22.04 or 24.04, 50 GB free disk space.
- Under WSL2, clone into the Linux filesystem (`/home/...`), not `/mnt/c`.

## Build the image

```bash
./utils/scripts/prepare_env.sh                   # Raspberry Pi 4 (default)
./utils/scripts/prepare_env.sh -m qemu-rpi4-64   # QEMU
```

Needs access to the private `smart-column-platform` repository; without it,
use the [prebuilt artifacts](#download-prebuilt-artifacts).

Installs host packages, sets up the build in `bitbake-builds/` and builds
`smart-column-image`. The first build takes hours; re-runs rebuild only what
changed. Defaults live in [`build-config/build.env`](build-config/build.env).

## Run in QEMU

```bash
./utils/scripts/run_qemu.sh                   # local build if present, else downloaded artifacts
./utils/scripts/run_qemu.sh --from artifacts  # force downloaded artifacts
```

Log in as `root` with an empty password. Exit with `Ctrl-A`, then `X`.

## Flash the Raspberry Pi 4

```bash
sudo bmaptool copy smart-column-image-raspberrypi4-64.rootfs.wic.bz2 /dev/sdX
```

## Download prebuilt artifacts

No build or credentials needed.

```bash
./utils/scripts/install_artifacts.sh           # everything
./utils/scripts/install_artifacts.sh --qemu    # QEMU image only
./utils/scripts/install_artifacts.sh --image   # Raspberry Pi 4 image only
./utils/scripts/install_artifacts.sh --sdk     # SDK only
```

Images go to `utils/artifacts/<machine>/`, the SDK to
`/opt/smart-column-sdk/rpi4-64/`. The release is set by `ARTIFACTS_RELEASE`.

## SDK

Use the SDK in a separate shell (not the one with the bitbake environment):

```bash
. /opt/smart-column-sdk/rpi4-64/environment-setup-*
```

To build it yourself:

```bash
./utils/scripts/build_sdk.sh
```

## Publish artifacts

Pack local build results into `utils/artifacts/` for a release:

```bash
./utils/scripts/get_artifacts.sh              # all machines
./utils/scripts/get_artifacts.sh --with-sdk   # plus the SDK
```

## Update layer revisions

Layers are pinned to exact commits in
[`build-config/smartcolumn-wrynose.conf.json`](build-config/smartcolumn-wrynose.conf.json).

```bash
./utils/scripts/update_pins.sh           # move pins to branch heads
./utils/scripts/update_pins.sh --check   # report only
```

## License

[MIT](LICENSE). Provided "as is", without warranty of any kind.
