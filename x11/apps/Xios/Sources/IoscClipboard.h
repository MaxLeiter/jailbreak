#ifndef XIOS_IOSCCLIPBOARD_H
#define XIOS_IOSCCLIPBOARD_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Bridge between UIPasteboard and iosc's wl_data_device selection, over the
// dedicated clipboard socket (iosc-clipboard.sock). Wire format is the shared
// 32-byte xios_msg record with type XIOS_MSG_CLIPBOARD (0x04): a=kind,
// b=generation, payload=item data. Records sharing a generation are
// representations of ONE copy event (e.g. text + png); a generation change
// replaces the clipboard. Contract lives in
// linux-build/patches/xios/xios_surface.h — these constants must match it.
#define IOSC_CLIP_KIND_NONE 0u  // clear (no payload)
#define IOSC_CLIP_KIND_TEXT 1u  // text/plain;charset=utf-8
#define IOSC_CLIP_KIND_URI  2u  // text/uri-list (CRLF-separated)
#define IOSC_CLIP_KIND_PNG  3u  // image/png
#define IOSC_CLIP_KIND_HTML 4u  // text/html
#define IOSC_CLIP_ITEM_MAX  (16u * 1024u * 1024u)

bool iosc_clipboard_open(const char *sock_path);
void iosc_clipboard_close(void);
bool iosc_clipboard_is_open(void);

// Sending one iOS copy event: begin (starts a new generation), then one
// send_item per representation. send_clear announces an emptied pasteboard.
// Sends block briefly (2s timeout) — payloads are at most ITEM_MAX and the
// compositor drains asynchronously, so this returns in milliseconds.
void iosc_clipboard_send_begin(void);
bool iosc_clipboard_send_item(uint32_t kind, const void *data, size_t len);
bool iosc_clipboard_send_clear(void);

// Drain one received item per call (non-blocking). Returns 1 with *kind,
// *generation, *data (malloc'd, len+1 bytes with a trailing NUL — caller
// frees), *len filled; 0 when no complete record is pending; -1 when the
// connection dropped (caller reconnects). A KIND_NONE clear arrives as an
// item with len 0.
int iosc_clipboard_poll_item(uint32_t *kind, uint32_t *generation,
                             uint8_t **data, uint32_t *len);

// TRANSITIONAL text-only wrappers keeping the pre-multi-mime XScreen.swift
// call sites compiling (and text sync working) until the full pasteboard
// patch in docs/clipboard-plan.md lands. New code uses the item API above.
bool iosc_clipboard_set_text(const char *utf8);
bool iosc_clipboard_poll(char *out, int out_cap, int *out_len);

#endif
