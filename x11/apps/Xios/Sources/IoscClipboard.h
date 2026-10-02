#ifndef XIOS_IOSCCLIPBOARD_H
#define XIOS_IOSCCLIPBOARD_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "../../shared/XiosProtocol.h"

// Bridge between UIPasteboard and iosc's wl_data_device selection, over the
// dedicated clipboard socket (iosc-clipboard.sock). Wire format is the shared
// 32-byte xios_msg records. Both sides require an exact v1 HELLO before any
// XIOS_MSG_CLIPBOARD record: a=kind, b=generation, payload=item data.
// Records sharing a generation are
// representations of ONE copy event (e.g. text + png); a generation change
// replaces the clipboard. Contract lives in
// apps/shared/XiosProtocol.h.

// Connecting is split so the blocking part can run off the main thread:
// iosc_clipboard_connect() does connect() plus the HELLO exchange (up to 2 s
// waiting on the reply) and touches no module state; the main thread then
// hands the fd to iosc_clipboard_adopt(), which takes ownership (it closes
// the fd and returns false if a connection is already open).
int iosc_clipboard_connect(const char *sock_path);   // connected fd, or -1
bool iosc_clipboard_adopt(int fd);
void iosc_clipboard_close(void);
bool iosc_clipboard_is_open(void);

// Sending one iOS copy event: send_begin starts a new generation and returns
// it, then each representation is one whole record from write_item;
// write_clear announces an emptied pasteboard. Writes block (SO_SNDTIMEO is
// 2 s per write() call, and an item can be ITEM_MAX bytes), so they belong on
// a writer thread, against that thread's own dup of the connection from
// writer_fd (the writer closes it). They touch no module state, so the main
// thread can keep polling, or close and replace the connection, meanwhile.
uint32_t iosc_clipboard_send_begin(void);
int iosc_clipboard_writer_fd(void);   // dup of the open connection, or -1
// 1 written; 0 refused (bad kind, or over ITEM_MAX), nothing sent; -1 the
// write failed and may have cut the record short: drop that connection.
int iosc_clipboard_write_item(int fd, uint32_t generation, uint32_t kind,
                              const void *data, size_t len);
int iosc_clipboard_write_clear(int fd, uint32_t generation);

// Drain one received item per call (non-blocking). Returns 1 with *kind,
// *generation, *data (malloc'd, len+1 bytes with a trailing NUL — caller
// frees), *len filled; 0 when no complete record is pending; -1 when the
// connection dropped (caller reconnects). A KIND_NONE clear arrives as an
// item with len 0.
int iosc_clipboard_poll_item(uint32_t *kind, uint32_t *generation,
                             uint8_t **data, uint32_t *len);

#endif
