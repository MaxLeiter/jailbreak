# Clipboard sync: Linux desktop <-> iOS pasteboard

Copy in a Linux app, paste in an iOS app; copy in iOS, paste in Linux. Text,
images (PNG), URLs. Status 2026-07-01: wire protocol + both bridge halves
written and syntax-checked; XIOS_MSG_CLIPBOARD = 0x04 RATIFIED by the
record-space owner (iosc-protocols). The two integration patches below land
with their file owners: the iosc.c hooks are queued behind the monolith->
modules refactor freeze (iosc-protocols applies them; sequencing is the
lead's call — the ~150-line delete-and-extract here is itself refactor-
shaped, so landing with/just-after the split may be cleanest), and the
XScreen.swift pasteboard patch is with xios-app.

## Status update (2026-07-02)

- **App side LANDED (9470335):** `serviceIoscClipboard` was rewritten to the
  multi-item API on the 32-byte 'XMS1' typed envelope (`XIOS_MSG_CLIPBOARD`
  0x04); `lastSentPasteboard` and the transitional text-only wrappers are gone.
- **Compositor side NOT yet landed:** the `iosc-clipboard-bridge.{c,h}` files
  are committed (e83e216) but INERT — not added to the iosc compile line in
  `build-iosc.sh` and not `#include`d/called from `iosc.c`. iosc.c still runs
  the OLD inline text-only clipboard framing (`struct iosc_clip_msg {type,len}`,
  8-byte header). So there is a live WIRE-SKEW: the app speaks the 32-byte 0x04
  record, iosc speaks the old 8-byte framing, so cross-system sync is dead until
  the "iosc.c integration" step-list below lands.
- **wlr-data-control (009bbd8) is LANDED and complementary, not competing.** The
  `zwlr_data_control_manager_v1` protocol is implemented and compiled into iosc
  (iosc.c + build-iosc.sh). It shares the SAME `g_clip_items` selection store as
  `wl_data_device` via `clip_ingest_source()` (so wl-copy/wl-paste and clipboard
  managers work without keyboard focus, and `source_read_done` still feeds the
  iOS-pasteboard bridge). It does not replace this plan's iOS<->Wayland bridge;
  it feeds the same store the bridge would publish from.

## What already existed

iosc has held the desktop clipboard since the wl_data_device work: a copying
client's selection is snapshotted per-mime into `g_clip_items` (iosc.c
"clipboard / wl_data_device" section), and offers are minted from that store
for pasting clients. A side socket (`/var/jb/tmp/iosc-clipboard.sock`) already
bridged **text only** to the Xios app with an ad-hoc 8-byte `{type,len}`
framing, and XScreen.swift already polls `UIPasteboard.changeCount` each tick.
This work replaces the ad-hoc framing with the shared typed record, adds
PNG/URI/HTML, and makes big payloads safe.

## Wire protocol

One record grammar everywhere: the shared 32-byte `xios_msg` envelope
('XMS1'), same as the app/ddx socket's HELLO/DIRTY/CURSOR. New core type
**`XIOS_MSG_CLIPBOARD` (0x04)** — allocated from the iosc-protocols-owned
0x01-0x0f range; defined in `linux-build/patches/xios/xios_surface.h`
(canonical) and mirrored in `apps/iosc-host/Sources/iosc_native_proto.h`.

CLIPBOARD records ride the **dedicated clipboard socket only**, never the
app/ddx socket. Same call osk-plan.md made for TRAITS: the framing is shared,
the channel is not — the present stream's never-stall/drop-on-EAGAIN posture
would drop or delay multi-megabyte pasteboard payloads that must arrive whole,
and the typed app socket stays presentation-only.

```
window_id = 0
length    = item bytes (payload follows the header)
a         = kind:  0 NONE (clear; length must be 0)
                   1 TEXT  text/plain;charset=utf-8
                   2 URI   text/uri-list (CRLF-separated)
                   3 PNG   image/png
                   4 HTML  text/html
b         = generation (sender's copy-event counter, starts at 1, wraps past 0)
c, d      = 0 (c earmarked for chunked transfers if an item ever must
             stream; today one record = one whole item)
```

Records sharing a generation are representations of ONE logical clipboard
(text + html of the same copy). A record whose generation differs from the
receiver's last-seen replaces the clipboard; an equal one merges. Compare with
`!=` (not `<`). Receivers commit each record as it arrives — no end-of-set
marker, matching how iosc has always broadcast per-mime as pipe reads land.
Per-item cap `XIOS_CLIP_ITEM_MAX` = 16 MiB; oversize or bad magic/type is a
protocol violation and the receiver drops the connection (both ends
reconnect). Both ends are arm64 LE; structs go on the wire verbatim.

Old/new skew: an old-format peer fails the magic check and gets dropped, then
retries. Harmless but clipboard-dead until both ends are redeployed —
**iosc and the Xios app ship together in the next device wave.**

## The pieces

| piece | file | state |
|---|---|---|
| wire contract | `linux-build/patches/xios/xios_surface.h` + mirror in `iosc_native_proto.h` | landed (0x04 needs iosc-protocols ratification) |
| compositor bridge | `wayland/iosc-clipboard-bridge.{h,c}` | written, cross-syntax-checked |
| app socket client | `apps/Xios/Sources/IoscClipboard.{h,c}` | rewritten, syntax-checked; transitional text-only wrappers keep the current XScreen.swift compiling and text sync alive |
| iosc.c hooks | `wayland/iosc.c` | patch below, lands with iosc-protocols |
| build line | `wayland/build-iosc.sh` | one line, lands with the iosc.c patch |
| pasteboard logic | `apps/Xios/Sources/XScreen.swift` | patch below, lands with xios-app |

### Compositor bridge (iosc-clipboard-bridge.c)

Owns the listening socket on the compositor's `wl_event_loop` (no threads),
speaks CLIPBOARD records both directions, and keeps the current set (one slot
per kind) so a host that (re)connects mid-session gets the session clipboard
replayed. Differences from the old inline code, all deliberate:

- **Buffered async sends.** Per-client outbound queue drained on
  `WL_EVENT_WRITABLE`. A suspended app never stalls the compositor, and a
  5 MB PNG is never dropped for hitting EAGAIN mid-write (the old code dropped
  the client, which with snapshot-on-connect would have looped forever).
  Clients are dropped only on hangup, protocol violation, or a >64 MiB
  backlog.
- **Publish dedupe.** Text alias mimes (text/plain, ;charset=utf-8,
  UTF8_STRING) snapshot identical bytes several times per selection; the
  bridge sends them once.
- **Never wipes on connect.** An empty store replays nothing, so starting the
  desktop doesn't clear the user's iOS pasteboard.
- **mobile:0660** on the socket like the ddx socket (0777 fallback), instead
  of the old 0777-always.

### iosc.c integration (owner: iosc-protocols)

Delete the inline clip-client machinery — `struct iosc_clip_msg`,
`struct iosc_clip_client`, `IOSC_CLIP_SET`, `g_clip_clients`,
`clip_client_drop`, `clip_send_set_to_client`, `clip_send_set_to_app`,
`clip_rx_reset`, `clip_client_readable`, `clip_listen_readable`,
`clipboard_socket_start` (keep `write_all_fd`: offers still use it; keep
`unix_listen_start` only if something else adopts it) — then:

1. `#include "iosc-clipboard-bridge.h"` and replace the
   `clipboard_socket_start(...)` call in main with:

```c
    if (ioscclip_start(wl_display_get_event_loop(g_display),
                       "/var/jb/tmp/iosc-clipboard.sock",
                       clipboard_from_app, NULL) != 0)
        /* same non-fatal warn as today */
```

2. The receive hook (new; the whole app->Wayland direction):

```c
/* iOS-side pasteboard changed: fold it into the selection store and offer it
 * to Wayland clients. first_of_set starts a new logical clipboard. Never
 * republish to the bridge from here — it already mirrored + relayed. */
static void clipboard_from_app(uint32_t kind, const void *data, size_t len,
                               int first_of_set, void *ud)
{ (void)ud;
    if (first_of_set) clip_clear_items();
    if (kind != XIOS_CLIP_KIND_NONE) {
        const char *mime = ioscclip_mime_for_kind(kind);
        if (!mime || clip_item_set(mime, data, len) != 0) return;
    }
    clipboard_selection_broadcast();
}
```

3. Publish points for the Linux->iOS direction:
   - `data_device_set_selection`, NULL-source branch: replace
     `clip_set_text("", 0, 1)` with
     `clip_clear_items(); ioscclip_selection_clear(); clipboard_selection_broadcast();`
   - `data_device_set_selection`, source branch: add
     `ioscclip_selection_begin();` right after its `clip_clear_items();`
   - `source_read_done`: replace the
     `if (is_text_mime(rd->mime)) clip_send_set_to_app(...)` line with

```c
        uint32_t k = ioscclip_kind_for_mime(rd->mime);
        if (k != XIOS_CLIP_KIND_NONE)
            ioscclip_publish(k, rd->buf ? rd->buf : "", rd->len);
```

   - `clip_set_text` keeps its signature; its `send_to_app` body becomes
     `ioscclip_selection_begin(); ioscclip_publish(XIOS_CLIP_KIND_TEXT, ...);`
     (after this the only send_to_app=1 caller is gone, so it can also just
     shrink to the store+broadcast core.)

4. Mime gate + caps: add `image/png` to `is_clip_mime()`, and raise
   `IOSC_CLIP_MAX` to `XIOS_CLIP_ITEM_MAX` (16 MiB) so a PNG survives the
   store. DnD and the offer paths are untouched.

5. `build-iosc.sh`: add `"$X11/wayland/iosc-clipboard-bridge.c"` to the iosc
   compile line (it already has `-I$X11/linux-build/patches/xios`).

### XScreen.swift integration (owner: xios-app)

Replaces `serviceIoscClipboard()` and the `lastSentPasteboard` field; keeps
`ioscClipboardSock` discovery and `pasteboardChangeCount` (still the
one-read-per-copy gate — reading pb *content* is what triggers the iOS 16
paste banner, so only read when changeCount moved; at most one banner per
copy). Sketch, compiles against the new IoscClipboard.h:

```swift
private let kClipText: UInt32 = 1, kClipURI: UInt32 = 2,
            kClipPNG: UInt32 = 3, kClipHTML: UInt32 = 4
private var clipRxGen: UInt32 = 0
private var clipRxItems: [UInt32: Data] = [:]
private var clipDeferredPushTicks = 0   // connect grace: desktop wins if it speaks
private var clipSuppressText: String?   // echo guards: what we last wrote/read
private var clipSuppressPNG: Data?

private func serviceIoscClipboard() {
    guard usingIosc, let sock = ioscClipboardSock else {
        if iosc_clipboard_is_open() { iosc_clipboard_close() }
        return
    }
    if !iosc_clipboard_is_open() {
        guard tickCount % 30 == 0, iosc_clipboard_open(sock) else { return }
        pasteboardChangeCount = UIPasteboard.general.changeCount
        // On (re)connect the compositor replays the session clipboard if it
        // has one. Push ours only if it stays silent for ~0.5 s — so a fresh
        // desktop inherits the iOS pasteboard, but an app relaunch mid-session
        // doesn't clobber the desktop clipboard with a stale one.
        clipDeferredPushTicks = 30
    }
    var gotAny = false
    while true {
        var kind: UInt32 = 0, gen: UInt32 = 0, len: UInt32 = 0
        var buf: UnsafeMutablePointer<UInt8>? = nil
        let r = iosc_clipboard_poll_item(&kind, &gen, &buf, &len)
        if r < 0 { clipDeferredPushTicks = 0; return }
        if r == 0 { break }
        clipDeferredPushTicks = 0
        if gen != clipRxGen { clipRxGen = gen; clipRxItems.removeAll() }
        if kind == 0 { free(buf); clipRxItems.removeAll() }
        else if let b = buf {
            clipRxItems[kind] = Data(bytesNoCopy: b, count: Int(len),
                                     deallocator: .free)
        }
        gotAny = true
    }
    if gotAny { commitReceivedClipboard() }
    if clipDeferredPushTicks > 0 {
        clipDeferredPushTicks -= 1
        if clipDeferredPushTicks == 0 { pushPasteboard(onConnect: true) }
    }
    if UIPasteboard.general.changeCount != pasteboardChangeCount {
        pushPasteboard(onConnect: false)
    }
}

private func commitReceivedClipboard() {
    let pb = UIPasteboard.general
    var item: [String: Any] = [:]
    if let t = clipRxItems[kClipText], let s = String(data: t, encoding: .utf8) {
        item["public.utf8-plain-text"] = s
        clipSuppressText = s
    } else { clipSuppressText = nil }
    if let png = clipRxItems[kClipPNG] {
        item["public.png"] = png
        clipSuppressPNG = png
    } else { clipSuppressPNG = nil }
    if let u = clipRxItems[kClipURI], let s = String(data: u, encoding: .utf8) {
        let uris = s.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
                    .filter { !$0.hasPrefix("#") }
        // A copied web link should paste as a link; file:// paths from Linux
        // mean nothing to iOS apps, so those only ride along as text.
        if uris.count == 1, let url = URL(string: String(uris[0])),
           url.scheme == "http" || url.scheme == "https" {
            item["public.url"] = url.absoluteString
        }
        if item["public.utf8-plain-text"] == nil {
            item["public.utf8-plain-text"] = s
        }
    }
    if let h = clipRxItems[kClipHTML], let s = String(data: h, encoding: .utf8) {
        item["public.html"] = s
    }
    pb.items = item.isEmpty ? [] : [item]
    pasteboardChangeCount = pb.changeCount   // our own write, not an iOS copy
}

private func pushPasteboard(onConnect: Bool) {
    let pb = UIPasteboard.general
    pasteboardChangeCount = pb.changeCount
    let text = pb.hasStrings ? pb.string : nil
    let png: Data? = pb.hasImages
        ? (pb.data(forPasteboardType: "public.png") ?? pb.image?.pngData())
        : nil
    let urls = pb.hasURLs ? (pb.urls ?? []) : []
    if text == nil && png == nil && urls.isEmpty {
        // Empty pasteboard: on connect that's "nothing to contribute", not
        // "clear the desktop clipboard".
        if !onConnect { _ = iosc_clipboard_send_clear() }
        clipSuppressText = nil; clipSuppressPNG = nil
        return
    }
    if !onConnect && text == clipSuppressText && png == clipSuppressPNG {
        return   // echo of our own commitReceivedClipboard write
    }
    iosc_clipboard_send_begin()
    if let t = text {
        _ = t.withCString { iosc_clipboard_send_item(kClipText, $0, strlen($0)) }
    }
    if let p = png {
        _ = p.withUnsafeBytes {
            iosc_clipboard_send_item(kClipPNG, $0.baseAddress, p.count)
        }
    }
    if !urls.isEmpty {
        let list = urls.map(\.absoluteString).joined(separator: "\r\n") + "\r\n"
        _ = list.withCString { iosc_clipboard_send_item(kClipURI, $0, strlen($0)) }
        if text == nil {
            _ = list.withCString { iosc_clipboard_send_item(kClipText, $0, strlen($0)) }
        }
    }
    clipSuppressText = text; clipSuppressPNG = png
}
```

Then delete the transitional `iosc_clipboard_set_text` / `iosc_clipboard_poll`
wrappers from IoscClipboard.{h,c} and the `lastSentPasteboard` property.
Line 1562's copy-debug helper keeps working (it writes pb; the changeCount
path picks it up like any iOS copy).

## Decisions and non-goals

- **Primary selection stays Linux-only.** iOS has no middle-click-paste
  concept, and mirroring every mouse-select into UIPasteboard would spam the
  store (and the paste banner). zwp_primary_selection keeps working
  compositor-internally, untouched.
- **DnD untouched.** Drag sources are live grabs, not snapshots; cross-system
  drag is its own project.
- **file:// URIs cross systems as text only.** Linux paths mean nothing to
  iOS and vice versa. http(s) links paste as real links both ways (URL-only
  iOS copies also emit a TEXT item so plain Linux apps can paste them).
- **iosc-host (native flavor) later.** The new IoscClipboard.{h,c} is
  flavor-agnostic and drops into apps/iosc-host unchanged when that host
  grows pasteboard sync; the compositor side needs nothing extra.
- **Connect policy: desktop wins.** See the deferred-push comment above.
- **Chunking deferred.** 16 MiB single-record items cover realistic
  pasteboards; field `c` is reserved if streaming ever matters.

## Test recipe (device)

1. Rebuild iosc (build-iosc.sh) + redeploy; rebuild + redeploy Xios.app
   (both ends must move together — the wire format changed).
2. Text L->i: `wl-copy hello` or copy in kgx; paste in iOS Notes.
3. Text i->L: copy in Notes, app foreground; `wl-paste` or Ctrl+V in kgx.
4. PNG L->i: copy an image in a GTK4 app (or
   `wl-copy -t image/png < x.png`); paste into Notes/Files.
5. PNG i->L: copy a photo in Photos; `wl-paste -t image/png > /tmp/x.png`.
6. Link i->L->i round trip via Safari share-sheet copy.
7. Reconnect: kill + relaunch the app mid-session; the desktop clipboard
   must survive and replay (and the iOS pasteboard must NOT be wiped by a
   fresh desktop start with an empty clipboard).
8. Big paste: a full-screen screenshot PNG both directions while a video
   plays in the desktop (present stream must not hitch — sends are buffered).
