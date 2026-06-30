#ifndef XIOS_XINPUT_H
#define XIOS_XINPUT_H
#include <stdbool.h>

// Thin C bridge over Xlib + the XTEST extension, so Swift can inject pointer/key
// events into the X server (as if from hardware). Connects as an X client.
bool xinput_open(const char *display);          // e.g. ":3"; true on success
void xinput_close(void);
bool xinput_is_open(void);
void xinput_motion(int x, int y);               // absolute, in X screen pixels
void xinput_button(int button, bool down);      // 1=left 2=mid 3=right 4/5=scroll
void xinput_key(int keycode, bool down);        // raw X keycode
int  xinput_keycode_for_keysym(unsigned long keysym);
bool xinput_type_keysym(unsigned long keysym);  // press+release, auto-Shift; true if typed
bool xinput_type_keysym_mods(unsigned long keysym, bool ctrl, bool alt,
                             bool shift, bool super);   // same, holding modifiers
void xinput_flush(void);

#endif
