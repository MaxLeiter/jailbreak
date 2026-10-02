// hid.h - synthesize touch, keyboard and consumer-button events through the
// IOHID event system (the same path a real digitizer/keyboard takes into
// backboardd), from an ordinary process.
//
// All touch coordinates are view-space points (see display.h); the module
// maps them to the panel's normalized digitizer space itself.
#pragma once

#import <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include "display.h"

bool ipc_hid_init(void);

void ipc_hid_tap(const ipc_geometry *g, CGPoint p);
void ipc_hid_longpress(const ipc_geometry *g, CGPoint p, int hold_ms);
void ipc_hid_swipe(const ipc_geometry *g, CGPoint a, CGPoint b, int dur_ms);

// Types printable ASCII (0x20..0x7E) plus \n and \t. Returns false and stops at
// the first unsupported character.
bool ipc_hid_type(const char *text, int *bad_index);

// "return", "escape", "tab", "backspace", "left", ..., "a", "cmd+a",
// "cmd+shift+z", "ctrl+c". Returns false if the name is unknown.
bool ipc_hid_key(const char *combo);

typedef enum {
    IPC_BUTTON_HOME,
    IPC_BUTTON_VOLUP,
    IPC_BUTTON_VOLDOWN,
} ipc_button;

void ipc_hid_button(ipc_button b);
