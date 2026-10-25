# Clipboard sync: Linux desktop and the iOS pasteboard

Copy in a Linux app, paste in an iOS app, and the other way round. Text, PNG
images, URLs and HTML.

**Status (2026-10-25): shipped.** Both halves are in the published packages
(`iosc`, `com.max.xios`, and Mutter's own bridge for GNOME). The Wayland side is
proven on device with `wl-copy`/`wl-paste`. The UIKit pasteboard leg (Notes to
`wl-paste` and back, PNGs, large payloads) has no recorded device run yet; use the
test recipe at the end. Current status lives in `handoff/polish.md`.

## The pieces

| Piece | File |
|---|---|
| Wire contract | `apps/shared/XiosProtocol.h` (`XIOS_MSG_CLIPBOARD` 0x04, `XIOS_CLIP_KIND_*`, `XIOS_CLIP_ITEM_MAX`) |
| iosc bridge | `wayland/iosc-clipboard-bridge.{c,h}`, built into iosc by `wayland/build-iosc.sh` |
| Mutter bridge | `wayland/meta-clipboard-ios.{c,h}` (strict v1, 2026-07-29) |
| App socket client | `apps/Xios/Sources/IoscClipboard.{c,h}` |
| Pasteboard logic | `apps/Xios/Sources/XScreen.swift`, on its own clipboard queue |

The native per-window host (`apps/iosc-host`) has no clipboard sync yet.
`IoscClipboard.{c,h}` is flavor-agnostic and should drop in unchanged.

iosc keeps the Wayland selection store (`g_clip_items`, fed by `wl_data_device`
and `zwlr_data_control_manager_v1`, so `wl-copy` works without keyboard focus).
The bridge never touches Wayland objects: iosc publishes each snapshotted mime to
it, and it hands iOS items back to iosc to offer.

## Socket

A dedicated AF_UNIX socket per display, never the present socket: the present
stream drops on EAGAIN, and a multi-megabyte pasteboard item has to arrive whole.
The default is `/var/jb/tmp/iosc-clipboard.sock`; a named slot gets its own
(`-clipboard-sock`), and the compositor advertises it as `clipboard_socket` in its
display config. The app requires that advertised path and does not guess. The
socket is mobile 0660 (owner-only 0600 if the chown fails, never world-writable).

## Wire protocol

Each connection starts with an exact v1 HELLO (`XIOS_PROTOCOL_VERSION`); a second
HELLO, another version or an unknown type is fatal. Then `XIOS_MSG_CLIPBOARD`
records in the 32-byte `xios_msg` envelope:

```
window_id = 0
length    = item bytes (payload follows the header)
a         = kind:  0 NONE (clear; length must be 0)
                   1 TEXT  text/plain;charset=utf-8
                   2 URI   text/uri-list (CRLF-separated)
                   3 PNG   image/png
                   4 HTML  text/html
b         = generation (sender's copy counter, starts at 1, wraps past 0)
c, d      = 0 (c is kept for chunking if an item ever has to stream)
```

Records that share a generation are representations of one copy (text plus html,
say). A different generation replaces the clipboard, an equal one merges; compare
with `!=`, not `<`. Receivers commit each record as it arrives, with no
end-of-set marker. Items over `XIOS_CLIP_ITEM_MAX` (16 MiB), bad magic or a bad
type drop the connection, and both ends reconnect.

## Behavior worth knowing
- **Buffered sends.** The bridge queues per client and drains on writable, so a
  suspended app never stalls the compositor and a 5 MB PNG is not dropped for
  backpressure. A client is dropped only on hangup, a protocol violation, or a
  backlog over 64 MiB.
- **Dedupe.** Text alias mimes (`text/plain`, `;charset=utf-8`, `UTF8_STRING`)
  carry identical bytes; the bridge sends them once.
- **Desktop wins on connect.** The compositor replays the session clipboard to a
  host that (re)connects. The app pushes the iOS pasteboard only if the desktop
  stays silent for about half a second, so a fresh desktop inherits the iOS
  pasteboard but an app relaunch does not clobber the desktop clipboard. An empty
  store replays nothing, so starting a desktop never wipes the iOS pasteboard.
- **One paste banner per copy.** The app reads pasteboard contents only when
  `UIPasteboard.changeCount` moved, since reading contents is what shows the iOS
  paste banner. Its own writes update the stored count so they do not echo back.

## Decisions and non-goals
- Primary selection stays Linux-only. iOS has no middle-click paste, and
  mirroring every selection would spam the pasteboard and the paste banner.
- Drag and drop is untouched; cross-system drag is its own project.
- `file://` URIs cross as text only. http(s) links paste as real links both ways
  (a URL-only iOS copy also sends a TEXT item for plain Linux apps).
- No chunking: 16 MiB single-record items cover realistic pasteboards.

## Test recipe (device)
1. App and compositor must be the same wire generation (install matching
   packages, restart the session).
2. Text Linux to iOS: `wl-copy hello`, or copy in Console; paste in Notes.
3. Text iOS to Linux: copy in Notes, bring Xios to the front; `wl-paste` or
   Ctrl+V in Console.
4. PNG Linux to iOS: `wl-copy -t image/png < x.png`; paste into Notes or Files.
5. PNG iOS to Linux: copy a photo; `wl-paste -t image/png > /tmp/x.png`.
6. Link round trip through Safari's share-sheet copy.
7. Reconnect: kill and relaunch the app mid-session. The desktop clipboard must
   survive, and a fresh desktop with an empty clipboard must not wipe iOS.
8. A full-screen screenshot PNG both ways while a video plays; the present stream
   must not hitch.
