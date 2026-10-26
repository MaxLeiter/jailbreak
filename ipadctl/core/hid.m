#import "hid.h"
#import "spi.h"

#include <ctype.h>
#include <mach/mach_time.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

// Synthetic sender ID stamped on every event. backboardd routes events by
// sender; a fixed, made-up built-in-looking ID is accepted on iOS 14..17 (the
// value TrollVNC uses). ZXTouch instead sniffs the real digitizer's ID from a
// live touch, which needs the user to touch the screen once per boot.
static const uint64_t kSenderID = 0x8000000817319371ULL;

// Finger identity/index used for single-touch gestures.
static const uint32_t kFinger = 2;

// HID usage pages / usages.
enum { kPageKeyboard = 0x07, kPageConsumer = 0x0C };
enum {
    kUsageReturn = 0x28, kUsageEscape = 0x29, kUsageBackspace = 0x2A, kUsageTab = 0x2B,
    kUsageSpace = 0x2C, kUsageDeleteForward = 0x4C,
    kUsageHome = 0x4A, kUsagePageUp = 0x4B, kUsageEnd = 0x4D, kUsagePageDown = 0x4E,
    kUsageRight = 0x4F, kUsageLeft = 0x50, kUsageDown = 0x51, kUsageUp = 0x52,
    kUsageLCtrl = 0xE0, kUsageLShift = 0xE1, kUsageLAlt = 0xE2, kUsageLGUI = 0xE3,
};
enum { kConsumerMenu = 0x40, kConsumerVolUp = 0xE9, kConsumerVolDown = 0xEA };

static IOHIDEventSystemClientRef gClient;

bool ipc_hid_init(void) {
    if (gClient) return true;
    if (!spi_load()) return false;
    gClient = SPI.IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    return gClient != NULL;
}

static void sleep_ms(int ms) {
    if (ms > 0) usleep((useconds_t)ms * 1000);
}

static void dispatch_event(IOHIDEventRef e) {
    SPI.IOHIDEventSetSenderID(e, kSenderID);
    SPI.IOHIDEventSystemClientDispatchEvent(gClient, e);
}

// ---- touch

typedef enum { PH_DOWN, PH_MOVE, PH_UP } phase_t;

// One hand event with one finger child, following the shape UIKit's own
// HID event recorder produces (WebKit's HIDEventGenerator documents it):
// the parent "hand" carries the touch/identity mask, the child finger carries
// normalized panel coordinates.
static void send_touch(phase_t ph, CGPoint unit) {
    uint64_t ts = mach_absolute_time();
    bool touching = (ph != PH_UP);

    uint32_t mask;
    if (ph == PH_MOVE) mask = kIPCDigPosition | kIPCDigAttribute;
    else mask = kIPCDigTouch | kIPCDigIdentity;

    IOHIDEventRef hand = SPI.IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault, ts, kIPCHIDTransducerHand,
                                                            0, 0, mask, 0, 0, 0, 0, 0, 0, false, touching, 0);
    SPI.IOHIDEventSetIntegerValue(hand, kIPCFieldIsBuiltIn, 1);
    SPI.IOHIDEventSetIntegerValue(hand, kIPCFieldDigIsDisplayIntegrated, 1);

    uint32_t childMask = mask;
    if (ph != PH_MOVE) childMask |= kIPCDigRange;
    IOHIDEventRef finger = SPI.IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault, ts, kFinger, kFinger, childMask, unit.x, unit.y, 0, touching ? 0.5 : 0, 0,
        touching, touching, 0);
    double radius = touching ? 5.0 : 0.0;
    SPI.IOHIDEventSetFloatValue(finger, kIPCFieldDigMajorRadius, radius);
    SPI.IOHIDEventSetFloatValue(finger, kIPCFieldDigMinorRadius, radius);

    SPI.IOHIDEventAppendEvent(hand, finger, 0);
    dispatch_event(hand);
    CFRelease(finger);
    CFRelease(hand);
}

void ipc_hid_tap(const ipc_geometry *g, CGPoint p) {
    CGPoint u = ipc_view_to_panel_unit(g, p);
    send_touch(PH_DOWN, u);
    sleep_ms(60);
    send_touch(PH_UP, u);
}

void ipc_hid_longpress(const ipc_geometry *g, CGPoint p, int hold_ms) {
    CGPoint u = ipc_view_to_panel_unit(g, p);
    send_touch(PH_DOWN, u);
    // Feed stationary position updates so the hold looks like a resting finger.
    for (int t = 0; t < hold_ms; t += 50) {
        sleep_ms(50);
        send_touch(PH_MOVE, u);
    }
    send_touch(PH_UP, u);
}

void ipc_hid_swipe(const ipc_geometry *g, CGPoint a, CGPoint b, int dur_ms) {
    const int step_ms = 16;  // ~60 Hz, like a real digitizer
    int steps = dur_ms / step_ms;
    if (steps < 2) steps = 2;
    send_touch(PH_DOWN, ipc_view_to_panel_unit(g, a));
    for (int i = 1; i <= steps; i++) {
        sleep_ms(step_ms);
        double t = (double)i / steps;
        CGPoint p = CGPointMake(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t);
        send_touch(PH_MOVE, ipc_view_to_panel_unit(g, p));
    }
    // A short rest before lifting keeps the gesture a drag rather than a fling.
    sleep_ms(step_ms);
    send_touch(PH_UP, ipc_view_to_panel_unit(g, b));
}

// ---- keyboard

static void send_key(uint32_t page, uint32_t usage, bool down) {
    IOHIDEventRef e =
        SPI.IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(), page, usage, down, 0);
    dispatch_event(e);
    CFRelease(e);
}

// ASCII -> (usage, needs shift). Returns false for unsupported characters.
static bool ascii_usage(char ch, uint32_t *usage, bool *shift) {
    static const char *unshifted = "-=[]\\;',./`";
    static const char *shifted = "_+{}|:\"<>?~";
    static const uint8_t punct[] = {0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x33, 0x34, 0x36, 0x37, 0x38, 0x35};
    static const char *shiftedDigits = ")!@#$%^&*(";  // index = digit
    *shift = false;
    if (ch >= 'a' && ch <= 'z') { *usage = 0x04 + (ch - 'a'); return true; }
    if (ch >= 'A' && ch <= 'Z') { *usage = 0x04 + (ch - 'A'); *shift = true; return true; }
    if (ch >= '1' && ch <= '9') { *usage = 0x1E + (ch - '1'); return true; }
    if (ch == '0') { *usage = 0x27; return true; }
    if (ch == ' ') { *usage = kUsageSpace; return true; }
    if (ch == '\n') { *usage = kUsageReturn; return true; }
    if (ch == '\t') { *usage = kUsageTab; return true; }
    const char *hit;
    if (ch && (hit = strchr(unshifted, ch))) { *usage = punct[hit - unshifted]; return true; }
    if (ch && (hit = strchr(shifted, ch))) { *usage = punct[hit - shifted]; *shift = true; return true; }
    if (ch && (hit = strchr(shiftedDigits, ch))) {
        long d = hit - shiftedDigits;
        *usage = d == 0 ? 0x27 : 0x1E + (uint32_t)(d - 1);
        *shift = true;
        return true;
    }
    return false;
}

static void press(uint32_t usage, const uint32_t *mods, int nmods) {
    for (int i = 0; i < nmods; i++) { send_key(kPageKeyboard, mods[i], true); sleep_ms(8); }
    send_key(kPageKeyboard, usage, true);
    sleep_ms(25);
    send_key(kPageKeyboard, usage, false);
    for (int i = nmods - 1; i >= 0; i--) { sleep_ms(8); send_key(kPageKeyboard, mods[i], false); }
}

bool ipc_hid_type(const char *text, int *bad_index) {
    // Validate first so a bad string types nothing rather than half of itself.
    for (int i = 0; text[i]; i++) {
        uint32_t u; bool s;
        if (!ascii_usage(text[i], &u, &s)) {
            if (bad_index) *bad_index = i;
            return false;
        }
    }
    const uint32_t shift = kUsageLShift;
    for (int i = 0; text[i]; i++) {
        uint32_t u; bool s;
        ascii_usage(text[i], &u, &s);
        press(u, &shift, s ? 1 : 0);
        sleep_ms(20);
    }
    return true;
}

static bool named_usage(const char *name, uint32_t *usage) {
    static const struct { const char *name; uint32_t usage; } table[] = {
        {"return", kUsageReturn}, {"enter", kUsageReturn}, {"escape", kUsageEscape}, {"esc", kUsageEscape},
        {"tab", kUsageTab}, {"backspace", kUsageBackspace}, {"delete", kUsageBackspace},
        {"forwarddelete", kUsageDeleteForward}, {"space", kUsageSpace},
        {"left", kUsageLeft}, {"right", kUsageRight}, {"up", kUsageUp}, {"down", kUsageDown},
        {"home", kUsageHome}, {"end", kUsageEnd}, {"pageup", kUsagePageUp}, {"pagedown", kUsagePageDown},
    };
    for (size_t i = 0; i < sizeof(table) / sizeof(table[0]); i++)
        if (!strcasecmp(name, table[i].name)) { *usage = table[i].usage; return true; }
    if (name[0] && !name[1]) {  // single character, e.g. "a" or "/"
        bool s;
        char ch = (char)tolower((unsigned char)name[0]);
        return ascii_usage(ch, usage, &s) && !s;
    }
    if ((name[0] == 'f' || name[0] == 'F') && isdigit((unsigned char)name[1])) {
        int n = atoi(name + 1);
        if (n >= 1 && n <= 12) { *usage = 0x3A + (uint32_t)(n - 1); return true; }
    }
    return false;
}

static bool modifier_usage(const char *name, uint32_t *usage) {
    if (!strcasecmp(name, "cmd") || !strcasecmp(name, "command") || !strcasecmp(name, "meta")) *usage = kUsageLGUI;
    else if (!strcasecmp(name, "shift")) *usage = kUsageLShift;
    else if (!strcasecmp(name, "ctrl") || !strcasecmp(name, "control")) *usage = kUsageLCtrl;
    else if (!strcasecmp(name, "alt") || !strcasecmp(name, "opt") || !strcasecmp(name, "option")) *usage = kUsageLAlt;
    else return false;
    return true;
}

bool ipc_hid_key(const char *combo) {
    char buf[128];
    strlcpy(buf, combo, sizeof(buf));
    uint32_t mods[4];
    int nmods = 0;
    char *parts[8];
    int nparts = 0;
    for (char *save = NULL, *tok = strtok_r(buf, "+", &save); tok && nparts < 8; tok = strtok_r(NULL, "+", &save))
        parts[nparts++] = tok;
    if (nparts == 0) return false;
    for (int i = 0; i < nparts - 1; i++) {
        if (nmods >= 4 || !modifier_usage(parts[i], &mods[nmods])) return false;
        nmods++;
    }
    uint32_t usage;
    if (!named_usage(parts[nparts - 1], &usage)) return false;
    press(usage, mods, nmods);
    return true;
}

// ---- consumer buttons

void ipc_hid_button(ipc_button b) {
    uint32_t usage;
    switch (b) {
    case IPC_BUTTON_HOME: usage = kConsumerMenu; break;
    case IPC_BUTTON_VOLUP: usage = kConsumerVolUp; break;
    case IPC_BUTTON_VOLDOWN: usage = kConsumerVolDown; break;
    default: return;
    }
    // Deliberately no lock/power: sleeping the screen needs the passcode to undo.
    send_key(kPageConsumer, usage, true);
    sleep_ms(60);
    send_key(kPageConsumer, usage, false);
}
