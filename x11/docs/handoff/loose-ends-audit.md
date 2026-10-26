# Loose ends: intentional shims and remaining port work

This started as the 2026-07-18 closure sweep, done while the iPad was offline. Everything in
its package queue (iosc 0.9.18 to 0.9.27, `xios-session 1.0.55`, `xios-launcher-tools 0.1.2`,
`libmutter 46.0+ios3` to `+ios5`, `kwin +ios5`, Milou, `plasma-mobile +ios21`, libgtop,
`xios-desktop-stublibs`, Ladybird 0.1.25+ios1) has since been superseded by newer published
versions, so that ledger is gone; git history has it. What is still worth keeping:

## Intentional shims, not loose ends

Do not turn every occurrence of "stub" into a replacement project. Several shims are the
correct iOS implementation of a Linux API whose kernel or service does not exist here.

- login1 and polkit model a single-user iOS session; there is no systemd or logind.
  AccountsService is a persistent single-user bridge, not an all-users placeholder.
- udev/gudev, DRM/KMS, dma-buf and libei links are inert where IOSurface, UIKit input or iOS
  frameworks replace the Linux subsystem.
- gsound bridges event sounds without pulling in a Linux audio daemon.
- Plasma's generated QML compatibility providers are audited against the imports that really
  ship. They expose iOS capabilities and reject unsupported mutations; a real package takes
  over when one exists (Milou did).
- BlueZ is a D-Bus bridge backed by iOS BluetoothManager, not an unfinished bluetoothd port.

The domain docs list their own stubs and why: `gnome-session.md`, `kde-kf6.md`, `polish.md`.

## Remaining port work (status lives in the domain docs)

- XFCE: only Thunar and its libraries ship; there is no session. See `xfce.md`.
- GNOME Terminal: needs the GTK3 VTE flavor built first. GNOME Console is the published
  terminal.
- Xwayland WM polish: `WM_NORMAL_HINTS`, client-requested `_NET_WM_STATE` and activation,
  `_NET_WM_MOVERESIZE`, an X11 clipboard bridge. See `iosc-compositor.md`.
- Geary/WebKitGTK: published; the multiprocess WebKit device smoke is still open. See
  `geary-webkitgtk.md`.
- Ladybird: published (`ladybird-app 0.1.25+ios1`, rootless; a rootful profile was published
  too and dropped on 2026-10-25, with no physical rootful run ever recorded). See
  `docs/ladybird-plan.md`.

Resolved from the old list and published on 2026-07-30: mako/basu, nwg-look, Papers.

## Physical checks no one has recorded

These need hands on the iPad, and no device run of them is written down anywhere:

1. The full physical input matrix in `xios-app.md` (held and repeated keys, shortcuts,
   Caps/Num, five-button chords, discrete wheel versus trackpad scroll and stop, pointer lock
   and confinement, custom cursor hotspots) in iosc, nested KDE, GNOME and the native host.
2. VoiceOver action, adjust and scroll gestures (`polish.md`, `docs/a11y-plan.md`).
3. GNOME user name, icon and language persistence; BlueZ discovery, alias, trust and agent
   behavior; pwquality feedback.
