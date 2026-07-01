#include "XInput.h"
#include <TargetConditionals.h>

#if TARGET_OS_SIMULATOR

bool xinput_open(const char *display) {
    (void)display;
    return false;
}

void xinput_close(void) {}
bool xinput_is_open(void) { return false; }
void xinput_motion(int x, int y) { (void)x; (void)y; }
void xinput_button(int button, bool down) { (void)button; (void)down; }
void xinput_key(int keycode, bool down) { (void)keycode; (void)down; }
int xinput_keycode_for_keysym(unsigned long keysym) { (void)keysym; return 0; }
bool xinput_type_keysym_mods(unsigned long keysym, bool ctrl, bool alt,
                             bool shift, bool super) {
    (void)keysym; (void)ctrl; (void)alt; (void)shift; (void)super;
    return false;
}
bool xinput_type_keysym(unsigned long keysym) { (void)keysym; return false; }
void xinput_flush(void) {}

#else

#include <X11/Xlib.h>
#include <X11/XKBlib.h>
#include <X11/keysym.h>
#include <X11/extensions/XTest.h>
#include <setjmp.h>

static Display *dpy = NULL;

/* If the X server dies, Xlib's default fatal-I/O handler calls exit(), which would
 * kill the whole app (the IOSurface display path is independent and could keep
 * running). Instead, longjmp out of the failing Xlib call, mark the connection
 * dead, and let the app retry later. All Xlib access below is wrapped in a guard. */
static jmp_buf s_recover;
static volatile int s_guarded = 0;

static int xinput_io_error(Display *d) {
    (void) d;
    dpy = NULL;                 /* the connection is gone; never touch it again */
    if (s_guarded) longjmp(s_recover, 1);
    return 0;
}

bool xinput_open(const char *display) {
    if (dpy) return true;
    dpy = XOpenDisplay(display);
    if (!dpy) return false;
    XSetIOErrorHandler(xinput_io_error);
    if (setjmp(s_recover)) { s_guarded = 0; return false; }
    s_guarded = 1;
    int ev = 0, er = 0, mj = 0, mn = 0;
    Bool ok = XTestQueryExtension(dpy, &ev, &er, &mj, &mn);   // XTEST must be present
    s_guarded = 0;
    if (!ok) {
        if (dpy) { XCloseDisplay(dpy); dpy = NULL; }
        return false;
    }
    return true;
}

void xinput_close(void) {
    if (dpy) { XCloseDisplay(dpy); dpy = NULL; }
}

bool xinput_is_open(void) { return dpy != NULL; }

void xinput_motion(int x, int y) {
    if (!dpy) return;
    if (setjmp(s_recover)) { s_guarded = 0; return; }
    s_guarded = 1;
    XTestFakeMotionEvent(dpy, -1, x, y, 0);   // -1 = default screen, 0 = no delay
    XFlush(dpy);
    s_guarded = 0;
}

void xinput_button(int button, bool down) {
    if (!dpy) return;
    if (setjmp(s_recover)) { s_guarded = 0; return; }
    s_guarded = 1;
    XTestFakeButtonEvent(dpy, (unsigned int)button, down ? True : False, 0);
    XFlush(dpy);
    s_guarded = 0;
}

void xinput_key(int keycode, bool down) {
    if (!dpy) return;
    if (setjmp(s_recover)) { s_guarded = 0; return; }
    s_guarded = 1;
    XTestFakeKeyEvent(dpy, (unsigned int)keycode, down ? True : False, 0);
    XFlush(dpy);
    s_guarded = 0;
}

int xinput_keycode_for_keysym(unsigned long keysym) {
    if (!dpy) return 0;
    if (setjmp(s_recover)) { s_guarded = 0; return 0; }
    s_guarded = 1;
    int kc = (int)XKeysymToKeycode(dpy, (KeySym)keysym);
    s_guarded = 0;
    return kc;
}

static void mod_event(KeyCode kc, Bool down) {
    if (kc) XTestFakeKeyEvent(dpy, kc, down, 0);
}

/* Type one keysym as a full press+release while holding the requested modifiers.
 * Shift is auto-added when the keysym is the shifted (level-1) glyph on its key, so
 * "A"/"!"/etc. come through correctly regardless of the server's layout (the auto
 * and explicit shift are merged into a single Shift press). false if no key for it. */
bool xinput_type_keysym_mods(unsigned long keysym, bool ctrl, bool alt,
                             bool shift, bool super) {
    if (!dpy) return false;
    if (setjmp(s_recover)) { s_guarded = 0; return false; }
    s_guarded = 1;
    KeyCode kc = XKeysymToKeycode(dpy, (KeySym)keysym);
    if (kc == 0) { s_guarded = 0; return false; }
    KeySym lvl0 = XkbKeycodeToKeysym(dpy, kc, 0, 0);
    KeySym lvl1 = XkbKeycodeToKeysym(dpy, kc, 0, 1);
    Bool needShift = shift || (lvl0 != (KeySym)keysym && lvl1 == (KeySym)keysym);

    KeyCode ctrlKc  = ctrl     ? XKeysymToKeycode(dpy, XK_Control_L) : 0;
    KeyCode altKc   = alt      ? XKeysymToKeycode(dpy, XK_Alt_L)     : 0;
    KeyCode superKc = super    ? XKeysymToKeycode(dpy, XK_Super_L)   : 0;
    KeyCode shiftKc = needShift ? XKeysymToKeycode(dpy, XK_Shift_L)  : 0;

    mod_event(ctrlKc, True); mod_event(altKc, True);
    mod_event(superKc, True); mod_event(shiftKc, True);
    XTestFakeKeyEvent(dpy, kc, True, 0);
    XTestFakeKeyEvent(dpy, kc, False, 0);
    mod_event(shiftKc, False); mod_event(superKc, False);
    mod_event(altKc, False); mod_event(ctrlKc, False);
    XFlush(dpy);
    s_guarded = 0;
    return true;
}

/* Convenience: type a keysym with no modifiers (auto-Shift still applies). */
bool xinput_type_keysym(unsigned long keysym) {
    return xinput_type_keysym_mods(keysym, false, false, false, false);
}

void xinput_flush(void) {
    if (!dpy) return;
    if (setjmp(s_recover)) { s_guarded = 0; return; }
    s_guarded = 1;
    XFlush(dpy);
    s_guarded = 0;
}

#endif
