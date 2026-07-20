/*
 * iosc_input.c — see iosc_input.h. Wraps libxkbcommon: compile the "us" keymap,
 * expose its text form for wl_keyboard.keymap, and precompute a keysym→(evdev
 * keycode, shift-level) table by walking every key/level so the app can keep
 * sending plain X keysyms.
 */
#include "iosc_input.h"

#include <xkbcommon/xkbcommon.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char    *s_keymap_str;
static uint32_t s_keymap_size;

static uint32_t s_mod_shift, s_mod_ctrl, s_mod_alt, s_mod_super, s_mod_caps, s_mod_num;

/* keysym -> (evdev keycode, needs_shift). Small (a few hundred entries); linear
 * scan on key events is fine. First (lowest-keycode, lowest-level) wins. */
struct keymap_entry { uint32_t sym; uint32_t evdev; uint8_t shift; };
static struct keymap_entry *s_rev;
static int s_nrev;

static void rev_add(uint32_t sym, uint32_t evdev, int shift, int cap)
{
    if (sym == 0 || sym == XKB_KEY_NoSymbol) return;
    for (int i = 0; i < s_nrev; i++)
        if (s_rev[i].sym == sym) return;          /* keep the first mapping */
    if (s_nrev >= cap) return;
    s_rev[s_nrev].sym = sym;
    s_rev[s_nrev].evdev = evdev;
    s_rev[s_nrev].shift = (uint8_t)(shift ? 1 : 0);
    s_nrev++;
}

/* Modifier MASK (1<<index) for a named modifier, or 0 if the keymap lacks it. */
static uint32_t mod_mask(struct xkb_keymap *km, const char *name)
{
    xkb_mod_index_t mi = xkb_keymap_mod_get_index(km, name);
    return (mi == XKB_MOD_INVALID) ? 0 : (1u << mi);
}

int iosc_input_init(void)
{
    /* libxkbcommon's compiled-in default config root may not match a rootless
     * jailbreak; point it at the on-device xkb data explicitly (no-override so a
     * caller's env still wins). */
    setenv("XKB_CONFIG_ROOT", "/var/jb/usr/share/X11/xkb", 0);

    struct xkb_context *ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    if (!ctx) { fprintf(stderr, "iosc_input: xkb_context_new failed\n"); return -1; }

    struct xkb_rule_names names = {
        .rules = "evdev", .model = "pc105", .layout = "us", .variant = "", .options = ""
    };
    struct xkb_keymap *km = xkb_keymap_new_from_names(ctx, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
    if (!km) {
        fprintf(stderr, "iosc_input: keymap compile failed (xkb data at "
                        "/var/jb/usr/share/X11/xkb?)\n");
        xkb_context_unref(ctx);
        return -1;
    }

    s_keymap_str = xkb_keymap_get_as_string(km, XKB_KEYMAP_FORMAT_TEXT_V1);
    if (!s_keymap_str) {
        fprintf(stderr, "iosc_input: keymap_get_as_string failed\n");
        xkb_keymap_unref(km); xkb_context_unref(ctx); return -1;
    }
    s_keymap_size = (uint32_t)strlen(s_keymap_str) + 1;   /* include the NUL */

    /* Modifier masks (1<<index) for this keymap. */
    s_mod_shift = mod_mask(km, XKB_MOD_NAME_SHIFT);
    s_mod_ctrl  = mod_mask(km, XKB_MOD_NAME_CTRL);
    s_mod_alt   = mod_mask(km, XKB_MOD_NAME_ALT);
    s_mod_super = mod_mask(km, XKB_MOD_NAME_LOGO);
    s_mod_caps  = mod_mask(km, XKB_MOD_NAME_CAPS);
    s_mod_num   = mod_mask(km, XKB_MOD_NAME_NUM);

    /* Build the keysym -> (evdev, shift) reverse table. Walk layout 0, levels 0
     * (unshifted) and 1 (shifted) for every key; xkb keycode − 8 = evdev keycode. */
    xkb_keycode_t kc_min = xkb_keymap_min_keycode(km);
    xkb_keycode_t kc_max = xkb_keymap_max_keycode(km);
    int cap = (int)(kc_max - kc_min + 1) * 2 + 16;
    s_rev = calloc((size_t)cap, sizeof(*s_rev));
    if (!s_rev) { xkb_keymap_unref(km); xkb_context_unref(ctx); return -1; }

    for (xkb_keycode_t kc = kc_min; kc <= kc_max; kc++) {
        if (kc < 8) continue;                     /* no valid evdev code */
        xkb_layout_index_t nlev = xkb_keymap_num_levels_for_key(km, kc, 0);
        for (xkb_level_index_t lev = 0; lev < nlev && lev < 2; lev++) {
            const xkb_keysym_t *syms = NULL;
            int n = xkb_keymap_key_get_syms_by_level(km, kc, 0, lev, &syms);
            for (int i = 0; i < n; i++)
                rev_add((uint32_t)syms[i], (uint32_t)(kc - 8), (int)lev, cap);
        }
    }
    fprintf(stderr, "iosc_input: us keymap ready (%u bytes, %d keysyms, "
                    "mods shift=0x%x ctrl=0x%x alt=0x%x super=0x%x caps=0x%x num=0x%x)\n",
            s_keymap_size, s_nrev, s_mod_shift, s_mod_ctrl, s_mod_alt,
            s_mod_super, s_mod_caps, s_mod_num);

    /* The keymap string + reverse table are retained; drop the compile objects. */
    xkb_keymap_unref(km);
    xkb_context_unref(ctx);
    return 0;
}

const char *iosc_input_keymap_string(void) { return s_keymap_str; }
uint32_t    iosc_input_keymap_size(void)   { return s_keymap_size; }
uint32_t    iosc_input_mod_shift(void)     { return s_mod_shift; }
uint32_t    iosc_input_mod_ctrl(void)      { return s_mod_ctrl; }
uint32_t    iosc_input_mod_alt(void)       { return s_mod_alt; }
uint32_t    iosc_input_mod_super(void)     { return s_mod_super; }
uint32_t    iosc_input_mod_caps(void)      { return s_mod_caps; }
uint32_t    iosc_input_mod_num(void)       { return s_mod_num; }

int iosc_input_lookup(uint32_t keysym, uint32_t *evdev_keycode, int *needs_shift)
{
    for (int i = 0; i < s_nrev; i++) {
        if (s_rev[i].sym == keysym) {
            if (evdev_keycode) *evdev_keycode = s_rev[i].evdev;
            if (needs_shift)   *needs_shift   = s_rev[i].shift;
            return 0;
        }
    }
    return -1;
}
