# ipadctld HTTP API (v1)

Contract between `ipad-mcp` (Mac) and `ipadctld` (iPad root daemon). The fake daemon in `mcp/fake-daemon/server.ts` implements it.

- Base: `http://<host>:8790/v1/...`, JSON unless noted.
- Auth: `Authorization: Bearer <token>` on every request. Wrong or missing token gives `401`, decided from the headers alone before any body is read. Bodies are capped at 1 MiB, and a body shorter than its `Content-Length` is `400 invalid`.
- All coordinates are in **point space** of the current orientation, origin top-left. A screenshot is also in point space (1080x810 in landscape on this iPad), so a pixel in a screenshot is the tap coordinate. No scaling.
- Errors: HTTP 4xx/5xx with `{"error": {"code", "message", "details"?}}`. Codes: `locked`, `app_mismatch`, `target_mismatch`, `app_blocked`, `invalid`, `unauthorized`, `internal`.

## GET /v1/info

```json
{
  "screen": {"width": 1080, "height": 810, "scale": 2, "orientation": "landscape_left"},
  "frontmost": {"bundle_id": "com.apple.MobileSMS", "name": "Messages"},
  "locked": false, "asleep": false, "daemon_version": "0.1",
  "selftest": {"capture_ok": true, "screen_on": true, "detail": "captured a non-black frame while the screen is on"}
}
```
`orientation`: `portrait`, `portrait_upside_down`, `landscape_left`, `landscape_right`. `frontmost` is null on the lock screen.

`selftest` reports whether capture actually works, because a missing capture entitlement fails silently with an all-black frame rather than an error. The daemon runs it at startup and on every `/v1/info`. `capture_ok` is `true` if a non-black frame was captured while the screen was on, `false` if the frame was black while the screen was on (capture is probably denied), and `null` when it could not be judged (screen off, so a black frame is expected). `screen_on` is the screen-power state (or `null` if unknown), and `detail` is a human-readable note.

## GET /v1/apps

`{"apps": [{"bundle_id": "com.apple.MobileSMS", "name": "Messages"}, ...]}`

## POST /v1/screenshot

Request (all optional): `{"quality": 70, "region": {"x": 0, "y": 0, "w": 1080, "h": 810}}`

- `quality`: JPEG quality 10 to 95, default 70.
- `region` (added for the `zoom` tool): crop in point space. The daemon returns the crop at native device resolution (points x `scale`), so text is sharper than a plain screenshot. The fake daemon returns point resolution. Without `region` the full screen is returned in point space.

Response: raw `image/jpeg` body with metadata headers (chosen over base64 JSON to avoid a 33% size hit):
`X-Ipad-Width`, `X-Ipad-Height` (image pixels), `X-Ipad-Scale`, `X-Ipad-Orientation`, `X-Ipad-Frontmost` (bundle id), `X-Ipad-Locked` (`true`/`false`).

There is no `max_edge`: downscaling would break the "pixel = point" rule.

## POST /v1/actions

Request: `{"actions": [Action, ...], "screenshot": {"quality"?: 70}}`. `screenshot` is optional; when present the daemon takes a screenshot after the last executed action (after a short settle delay) and returns it.

Actions run in order and stop at the first failure. The daemon enforces its own bounds whatever the client sends: `duration_ms` is clamped to 0 to 10000, `amount` to 1 to 50, `wait` to 10000 ms, and `type` text over 4000 characters is `invalid`.

| type | fields |
| --- | --- |
| `tap`, `double_tap` | `x`, `y` |
| `long_press` | `x`, `y`, `duration_ms?` (default 800) |
| `swipe` | `x`, `y`, `x2`, `y2`, `duration_ms?` (default 300) |
| `scroll` | `x`, `y`, `direction` (`up\|down\|left\|right`, direction content moves like a wheel), `amount?` ticks (default 5, about 120pt each) |
| `type` | `text` |
| `key` | `key`: `return`, `escape`, `tab`, `delete`, arrows, or chords like `cmd+a` |
| `button` | `name`: `home`, `volume_up`, `volume_down`. No lock button, by design. |
| `open_app` | `bundle_id` |
| `open_url` | `url` |
| `wait` | `ms` |

Every action except `wait` also carries:

- `app`: expected frontmost app (bundle id or name). The daemon compares it with the real frontmost app and refuses with `app_mismatch` on difference. For `open_app` it is the app on screen before the switch.
- `target`: short description of what is touched or typed into, e.g. "Send button". Today it is recorded and logged; later the daemon will check it against OCR at (x, y) and refuse with `target_mismatch`.
- `why`: one line of intent. Logged.

A missing or empty `app`, `target` or `why` is `invalid`.

Response (HTTP 200 whenever the request was well formed, even if an action failed):

```json
{
  "ok": false,
  "results": [
    {"index": 0, "status": "ok"},
    {"index": 1, "status": "failed", "error": {"code": "app_mismatch", "message": "...", "details": {"expected": "...", "actual": "..."}}},
    {"index": 2, "status": "skipped"}
  ],
  "frontmost": "com.apple.MobileSMS",
  "screenshot": {"jpeg_base64": "...", "width": 1080, "height": 810, "scale": 2, "orientation": "landscape_left", "frontmost": "...", "locked": false}
}
```
A malformed request (bad JSON, empty `actions`) is HTTP 400 `invalid`.

## Error codes

| code | meaning |
| --- | --- |
| `locked` | Device is locked or asleep. Never retried or bypassed. |
| `app_mismatch` | `app` does not match the real frontmost app. |
| `target_mismatch` | OCR at (x, y) does not match `target`. Reserved; not enforced until phase 2. |
| `app_blocked` | Policy tier forbids driving this app (checked against the real frontmost app, and the destination of `open_app`). Reserved; phase 1 blocks nothing. |
| `invalid` | Malformed request, missing fields, out-of-range coordinates, unknown action or app. |
| `unauthorized` | Bad bearer token (HTTP 401). |
| `internal` | Daemon fault. |
