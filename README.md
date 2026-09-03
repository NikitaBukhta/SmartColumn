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

## Status

Documentation phase. The requirement set is at v1.0.0, status `DRAFT`;
implementation has not started — see
`SmartColumnSpec/en/15-roadmap-milestones.md` for the milestone plan.
