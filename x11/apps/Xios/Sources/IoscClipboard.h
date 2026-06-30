#ifndef XIOS_IOSCCLIPBOARD_H
#define XIOS_IOSCCLIPBOARD_H
#include <stdbool.h>

// Bridge between UIPasteboard and iosc's wl_data_device selection.
// Text is UTF-8. A zero-length text message clears the selection.
bool iosc_clipboard_open(const char *sock_path);
void iosc_clipboard_close(void);
bool iosc_clipboard_is_open(void);
bool iosc_clipboard_set_text(const char *utf8);
bool iosc_clipboard_poll(char *out, int out_cap, int *out_len);

#endif
