#ifndef XIOS_IOSCCLIPBOARD_H
#define XIOS_IOSCCLIPBOARD_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "../../shared/XiosProtocol.h"

// Bridge between UIPasteboard and iosc's wl_data_device selection, over the
// dedicated clipboard socket (iosc-clipboard.sock). Wire format is the shared
// 32-byte xios_msg record with type XIOS_MSG_CLIPBOARD (0x04): a=kind,
// b=generation, payload=item data. Records sharing a generation are
// representations of ONE copy event (e.g. text + png); a generation change
// replaces the clipboard. Contract lives in
// apps/shared/XiosProtocol.h.

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

#endif
