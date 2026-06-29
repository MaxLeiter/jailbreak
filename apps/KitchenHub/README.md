# KitchenHub

A full-screen, tiling **dashboard app** for the wall-mounted kitchen iPad. The
screen is a 12×8 grid; each panel (clock, timer, …) snaps to whole cells and can
be moved/resized in edit mode. Layout persists to `Documents/layout.json`.

This is the *front-end* half of the kitchen project. The always-on / kiosk
behaviour (auto-launch, no-sleep, dock detection) lives in a separate Theos tweak
(`tweaks/KitchenKiosk`, later phase). See the repo root README for device details.

## Status

| Phase | What | State |
|---|---|---|
| 1 | Project scaffold + unsigned install pipeline | ✅ |
| 2 | Grid engine (move/resize/snap, persistence) + Clock + Timer panels | ✅ |
| 3 | Weather + Recipe panels | placeholder |
| 4 | Remotes (Sonos → LG webOS → Apple TV) | todo |
| 5 | KitchenKiosk tweak | todo |

## Build & install

The app is built **unsigned** and run on the jailbroken iPad via AppSync Unified
(installed once from Sileo), so there's no 7-day re-sign dance.

```bash
# from repo root — builds, pseudo-signs, pushes over SSH, registers with uicache
bin/install-app.sh
```

Prereqs: `brew install xcodegen ldid`, Xcode, and **AppSync Unified** on the iPad
(add the repo `https://cydia.akemi.ai/` in Sileo, install AppSync Unified).

## Develop in the Simulator (no device)

```bash
xcodegen generate
open KitchenHub.xcodeproj      # pick an iPad simulator, run
```

The grid + panels work fully in the Simulator; only the device install path needs
the jailbreak.

## Layout / architecture

```
Sources/
  KitchenHubApp.swift     @main App
  Theme.swift             colors, corner radius, gutter
  Models/
    Board.swift           grid dimensions (12×8) + min sizes
    PanelKind.swift       enum of panel types (add a case to add a type)
    PanelLayout.swift     one panel's grid placement (Codable)
  Store/
    BoardStore.swift      panels + edit mode + JSON load/save + placement
  Views/
    BoardView.swift       grid host
    PanelChrome.swift     per-panel positioning + drag/resize/delete in edit mode
    PanelContent.swift    kind -> view switch
    GridGuides.swift      faint grid overlay (edit mode)
    EditHandle.swift      long-press corner control to enter edit mode
    EditToolbar.swift     add-panel / done bar
    ButtonStyles.swift    shared button styles
    Panels/
      ClockPanel.swift
      TimerPanel.swift
      PlaceholderPanel.swift
```

### Edit mode

Long-press the **slider icon** in the top-right corner to enter edit mode. Then
drag panels to move, drag the amber bottom-right handle to resize, tap the red ✕
to delete, and use **Add Panel** to add more. Tap **Done** to lock it again. It's
long-press-gated so cooking never rearranges the board.

## Adding a panel type

1. Add a case to `PanelKind` (+ `title`, `symbol`, `defaultSize`, `isImplemented`).
2. Add its view under `Views/Panels/`.
3. Wire it into the `switch` in `PanelContent.swift`.

It then appears in the Add Panel menu automatically.
