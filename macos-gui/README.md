# Pikafish macOS GUI

A native AppKit interface for playing and analysing Chinese chess with the
Pikafish engine.

![Pikafish macOS GUI](./Screenshot.png)

## Features

- Red and black can independently be controlled by a human or the engine.
- Standard play, guidance mode and infinite analysis.
- Per-side chess clocks that stop when the game ends.
- Setup mode for mid-game and end-game practice positions.
- Undo one move or the complete move history.
- Board rotation, readable Chinese move records and last-move highlighting.
- Multi-line engine analysis with depth, nodes, position score and WDL.
- Guidance arrows based on the current engine principal variations.
- Wood board, gold markings, jade-style pieces and separate pickup, move and
  capture sounds.
- Optional per-side fast-win engine setting in this fork.

## Requirements

- macOS 13 or newer.
- Xcode Command Line Tools.
- Apple silicon by default. Set `ARCH` to another architecture listed by
  `make -C src help` when building for a different target.

## Build

From the repository root:

```bash
./macos-gui/build-app.sh
open ./build/macos-gui/Pikafish.app
```

The script downloads the default NNUE network when it is missing, builds the
engine from this repository, compiles the Swift GUI, embeds all required
resources and ad-hoc signs the application.

To use a locally compiled engine while running a standalone GUI binary, set:

```bash
PIKAFISH_ENGINE=/absolute/path/to/pikafish ./PikafishGUI
```

## Source layout

```text
macos-gui/
├── Sources/PikafishGUI/main.swift
├── Resources/
├── Info.plist
└── build-app.sh
```

The application intentionally uses AppKit directly and has no third-party GUI
runtime dependency.

## License and attribution

Pikafish and this GUI fork are distributed under GPL v3. See
[`Copying.txt`](../Copying.txt). Third-party sound attribution and generated
visual asset notes are in [`ASSET_CREDITS.md`](./ASSET_CREDITS.md).
