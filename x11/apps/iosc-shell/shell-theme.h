/*
 * shell-theme.h — the iosc shell's design tokens, in ONE place.
 *
 * Palette, radii, spacing, and type scale shared by every shell surface
 * (panel, quick settings, overview) so the desktop reads as one design, not
 * three programs. Layout headers (panel-layout.h, overview-layout.h) consume
 * these; they never define their own colors.
 *
 * Color model: straight-alpha 0xAARRGGBB (cairo premultiplies on our behalf —
 * see panel-render.h). RGB-only defines (no alpha byte) are bases that take a
 * runtime opacity via pl_with_alpha().
 */
#ifndef SHELL_THEME_H
#define SHELL_THEME_H

/* ------------------------------------------------------------- palette ---- */
/* Dark, cohesive, ONE blue accent. Derived from iOS system colors so the shell
 * sits naturally next to native iPadOS. */
#define TH_BASE_TOP    0x26262Au        /* bar gradient, top edge            */
#define TH_BASE_BOT    0x1C1C1Eu        /* iOS systemGray6 dark              */
#define TH_CARD        0xF22C2C2Eu      /* cards/popovers (systemGray5 dark) */
#define TH_CARD_INNER  0x3A3A3Cu        /* nested fills (gauge tracks, rows) */
#define TH_HILITE      0x14FFFFFFu      /* 1px inner top highlight   (~8%)   */
#define TH_SHADOW      0x40000000u      /* 1px bottom hairline       (~25%)  */
#define TH_BORDER      0x1FFFFFFFu      /* hairline card border      (~12%)  */
#define TH_SEP         0x1AFFFFFFu      /* separators                (~10%)  */
#define TH_FG          0xFFF5F5F7u      /* primary text                      */
#define TH_FG_DIM      0xA6EBEBF5u      /* secondary text            (~65%)  */
#define TH_FG_FAINT    0x59EBEBF5u      /* tertiary/hint text        (~35%)  */
#define TH_ACCENT      0xFF0A84FFu      /* iOS systemBlue                    */
#define TH_ACCENT_BG   0x4C0A84FFu      /* active pill fill          (~30%)  */
#define TH_ACCENT_DIM  0x330A84FFu      /* accent-tinted button fill (~20%)  */
#define TH_HOVER       0x1FFFFFFFu      /* hover backplate           (~12%)  */
#define TH_PRESS       0x33FFFFFFu      /* pressed backplate         (~20%)  */
#define TH_TILE        0x24FFFFFFu      /* monogram backplate        (~14%)  */
#define TH_GREEN       0xFF30D158u      /* charging / positive               */
#define TH_SCRIM       0xB3000000u      /* overview dim over the blur (~70%) */

/* Wallpaper fallback gradient (also the preview backdrop). */
#define TH_WALL_TOP    0xFF141824u
#define TH_WALL_BOT    0xFF241832u

/* --------------------------------------------------------- logical units --- */
/* All shell dimensions are LOGICAL px. The default effective scale on device
 * is 1.5 (iPad 7: 2160x1620 physical = 1440x1080 logical), so 1 logical px =
 * 0.75 iOS pt. Apple's 44pt minimum touch target is therefore 59 logical px —
 * TH_TOUCH is the floor every tappable region must meet. NOTHING here assumes
 * a specific output: layouts take W/H from the compositor's configure and the
 * scale may be any DPI factor (fractional included). */
#define TH_TOUCH       60       /* min touch target (44+ iOS pt at 1.5x) */

/* ---------------------------------------------------------------- radii --- */
#define TH_R_CARD      24       /* quick settings / popovers   */
#define TH_R_TILE      20       /* overview app-tile backplate */
#define TH_R_BUTTON    16       /* card buttons                */
#define TH_R_PILL      14       /* taskbar pills               */
#define TH_R_HOVER     12       /* panel hover backplates      */
#define TH_R_MONO      9        /* monogram tiles              */

/* -------------------------------------------------------------- spacing --- */
#define TH_PAD         14       /* panel edge padding             */
#define TH_GAP         12       /* sibling gap                    */
#define TH_CARD_PAD    22       /* card interior padding          */

/* ----------------------------------------------------------- type scale --- */
/* Pango descriptions; generic "Sans" resolves to Apple SF via the on-device
 * x11-fonts-sf fontconfig rule (and the preview container mirrors it).
 * Sizes are tuned for 1 logical px = 0.75 iOS pt (17 here reads as iOS body). */
#define TH_FONT_LABEL       "Sans 17"
#define TH_FONT_LABEL_MED   "Sans Medium 17"
#define TH_FONT_CLOCK       "Sans Medium 19"
#define TH_FONT_MONO        "Sans 20"
#define TH_FONT_TITLE       "Sans Semi-Bold 20"
#define TH_FONT_SECTION     "Sans Semi-Bold 17"
#define TH_FONT_SMALL       "Sans 15"
#define TH_FONT_SEARCH      "Sans 20"
#define TH_FONT_TILE        "Sans 15"

#endif /* SHELL_THEME_H */
