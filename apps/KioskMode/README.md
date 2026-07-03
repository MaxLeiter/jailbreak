# KioskMode

Lock the iPad to a single app. Two halves:

- **`apps/KioskMode`** — a SwiftUI companion app: a pleasant paged onboarding
  (welcome → pick the app → choose an escape shortcut → enable) and a dashboard
  to change those later. It writes the shared config plist.
- **`tweaks/KioskMode`** — a SpringBoard tweak that reads that config and enforces
  it: keeps the chosen app frontmost, relaunching it if you leave. The device
  still sleeps and auto-locks normally; enforcement pauses on the Lock Screen so
  it never wakes the panel.

## Shared config

`/var/mobile/Library/Preferences/com.max.kioskmode.plist` — both processes run as
`mobile`, so the app writes it and the tweak reads it directly.

| Key | Type | Meaning |
|---|---|---|
| `enabled` | Bool | Master switch — kiosk armed |
| `targetBundleID` | String | App to lock to |
| `targetName` | String | Display name (cached for the UI) |
| `escapeMethod` | String | `off` \| `volumeUpTriple` \| `volumeDownTriple` |
| `paused` | Bool | Runtime pause; the escape gesture flips this |
| `configured` | Bool | Set once onboarding is done |

Default (no file) = disarmed, so it never traps you until you opt in.

## Escape

There is no reliable way for a SpringBoard tweak to intercept touches over
another app's fullscreen window, so escape is a **hardware volume pattern**:
triple-press Volume Up (or Down) within ~1.4s toggles `paused`. A short haptic
confirms. `off` means it stays locked until you flip the master switch in the app.

## Build & install

```bash
bin/install.sh     tweaks/KioskMode    # tweak → SpringBoard (resprings)
bin/install-app.sh apps/KioskMode      # companion app
```

The app links two private classes (`LSApplicationWorkspace`, `LSApplicationProxy`)
for the app picker; they have no SDK link stub, so `project.yml` weak-links them
(`-Wl,-U,...`) and dyld resolves them from the shared cache at load. The app also
carries `no-container` / `platform-application` entitlements so it can write the
shared plist under `/var/mobile`.
