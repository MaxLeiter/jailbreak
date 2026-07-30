# KitchenHub

A full-screen **dashboard app** for the wall-mounted kitchen iPad. It idles as a
standby/lock screen (big clock, ambient album-art glow, weather chip, running
timer), unlocks on tap into a card dashboard, and each card opens a full-screen
detail view: timers, weather, recipes, music, and an Apple TV remote.

This is the *front-end* half of the kitchen project. The kiosk behaviour (lock the
iPad to one app, auto-relaunch) lives in the generic **KioskMode** tweak + app
([`tweaks/KioskMode`](../../tweaks/KioskMode), [`apps/KioskMode`](../KioskMode)),
which can lock to KitchenHub or anything else. See the repo root README for device
details.

## The screens

| Screen | What it does | Backend |
|---|---|---|
| Standby / lock | Clock, greeting, weather chip, now-playing bar, running-timer pill. Tap to unlock. | — |
| Dashboard | Clock / Weather / Timer / Music / Recipe cards in one of three layouts (Grid, Hero, Mosaic). | — |
| Timers | Multiple named timers with quick-add presets (Eggs 6, Pasta 10, Tea 3, Bread 30) and an alarm sound. | local |
| Weather | Current conditions, feels-like, hi/lo. | Open-Meteo (no API key) + CoreLocation |
| Recipes | Ingredients scaled by serving count, steps that can start a named timer, plus an editor and URL import. | schema.org Recipe JSON-LD scraped from the page |
| Music | Album art, transport, room selection, volume, up-next. | Sonos over SSDP discovery + UPnP (`ZoneGroupTopology`) |
| Apple TV | Glass trackpad (swipe to move focus, tap to select), menu / home / play-pause, volume rocker. | Companion protocol, implemented natively in Swift |

Theme (light/dark) and dashboard layout persist to `Documents/kh-prefs.json`.

## Apple TV setup (one-time, credentials are gitignored)

The Companion client is hand-rolled (`Services/AppleTV/`: TLV8, OPACK, the
crypto handshake, the connection, and a HID command surface). There's no in-app
pairing yet, so pair once with pyatv and paste the credentials in:

```bash
cp Sources/Services/AppleTV/AppleTVConfig.swift.example \
   Sources/Services/AppleTV/AppleTVConfig.swift
# pip install atvremote; atvremote --id <ATV_ID> --protocol companion pair
```

Fill in the device name, LAN IP (static lease recommended until Bonjour discovery
lands), port, and the `ltpk:ltsk:atv_id:client_id` credentials string.
`AppleTVConfig.swift` is gitignored — never commit real credentials.

## Build & install

The app is built **unsigned** and run on the jailbroken iPad via AppSync Unified
(installed once from Sileo), so there's no 7-day re-sign dance.

```bash
# from repo root — builds, pseudo-signs, pushes over SSH, registers with uicache
bin/install-app.sh apps/KitchenHub

# or package it as a .deb for the apt repo instead
bin/package-app.sh apps/KitchenHub
```

Prereqs: `brew install xcodegen ldid`, Xcode, and **AppSync Unified** on the iPad
(add the repo `https://cydia.akemi.ai/` in Sileo, install AppSync Unified).

## Develop in the Simulator (no device)

```bash
xcodegen generate
open KitchenHub.xcodeproj      # pick an iPad simulator, run
```

Everything but the device install path works in the Simulator. `DEBUG` builds also
honour `KitchenScreenshotScenario`, which loads fixture data for the standby,
dashboard, timers, and recipe screens so screenshots don't depend on live network
state.

## Layout / architecture

```
Sources/
  KitchenHubApp.swift        @main App
  Design/KH.swift            design tokens: colors, type, gaps, background
  Shell/
    AppRoot.swift            owns the shared models, routes lock ↔ dashboard ↔ detail
    LockView.swift           the standby screen
    DashboardView.swift      top bar + the Grid / Hero / Mosaic layouts
    Cards.swift              the five dashboard cards
  Models/
    KHModel.swift            theme, lock, layout, route; persists kh-prefs.json
    TimersModel.swift        multiple named timers + ticker
    WeatherModel.swift       location + fetch + refresh loop
    RecipeModel.swift        Recipe / Ingredient / RecipeStep, scaling, persistence
    ScreenshotFixtures.swift DEBUG-only fixture data per screenshot scenario
  Screens/                   full-screen detail views (Timers, Weather, Recipe,
                             RecipeEditor, NewTimerSheet, Music, AppleTV)
  Services/
    WeatherService.swift     Open-Meteo current + daily hi/lo
    LocationManager.swift    CoreLocation, for the weather query
    RecipeImporter.swift     JSON-LD recipe scrape, Foundation only
    SonosService.swift       SSDP discovery + UPnP control
    AlarmPlayer.swift        timer-finished sound
    AppleTV/                 Companion protocol client (TLV8, OPACK, crypto, HID)
```

## Adding a screen

1. Add a case to `KHModel.Route`.
2. Add the view under `Screens/` and route it in `AppRoot.routed`.
3. If it belongs on the dashboard, add a card in `Shell/Cards.swift` and place it
   in the three layouts in `DashboardView.swift`.
