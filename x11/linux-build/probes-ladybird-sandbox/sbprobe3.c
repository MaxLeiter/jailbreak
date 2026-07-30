/*
 * sbprobe3 — does CoreText still work in a CONFINED process?
 *
 * This port renders text through SkFontMgr_New_CoreText (patches-m0 0008), and
 * Gfx::font_manager() is lazy: it is first constructed during layout, which is AFTER
 * the point where WebContent would be confined. CoreText normally reaches fontd over
 * XPC, and the profile denies new sockets, so this needs measuring. A failure here is
 * the worst kind: pages would render with no text and nothing would say why.
 *
 * cold  = confine, THEN touch CoreText for the first time  (what WebContent would do)
 * warm  = touch CoreText, THEN confine, then touch it again (does caching save us?)
 * none  = baseline
 *
 * usage: sbprobe3 <none|cold|warm> [profile-name]
 */
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreText/CoreText.h>

extern int sandbox_init_with_parameters(const char *profile, uint64_t flags,
                                        const char *const parameters[], char **errorbuf);
#define SANDBOX_NAMED 0x1ULL

static void confine(const char *profile)
{
    char *err = NULL;
    int rc = sandbox_init_with_parameters(profile, SANDBOX_NAMED, NULL, &err);
    printf("  confine(%s): rc=%d err=%s\n", profile, rc, err ? err : "(none)");
    fflush(stdout);
}

/* The three things the text path actually needs. */
static void exercise_coretext(const char *tag)
{
    /* 1. Family enumeration — the call most likely to need fontd. */
    CFArrayRef families = CTFontManagerCopyAvailableFontFamilyNames();
    long n = families ? CFArrayGetCount(families) : -1;
    printf("  [%s] CTFontManagerCopyAvailableFontFamilyNames -> %ld families\n", tag, n);
    if (families) CFRelease(families);

    /* 2. Create a concrete font by name. */
    CFStringRef name = CFSTR("Helvetica");
    CTFontRef font = CTFontCreateWithName(name, 16.0, NULL);
    printf("  [%s] CTFontCreateWithName(Helvetica, 16) -> %s\n", tag, font ? "OK" : "NULL");

    /* 3. Shape-ish: map characters to glyphs, which forces the font data to load. */
    if (font) {
        UniChar chars[3] = { 'A', 'b', 'c' };
        CGGlyph glyphs[3] = { 0, 0, 0 };
        bool got = CTFontGetGlyphsForCharacters(font, chars, glyphs, 3);
        printf("  [%s] CTFontGetGlyphsForCharacters -> %s (glyphs %u,%u,%u)\n",
               tag, got ? "OK" : "FAILED", glyphs[0], glyphs[1], glyphs[2]);

        CFStringRef psname = CTFontCopyPostScriptName(font);
        if (psname) {
            char buf[128] = { 0 };
            CFStringGetCString(psname, buf, sizeof(buf), kCFStringEncodingUTF8);
            printf("  [%s] resolved PostScript name = %s\n", tag, buf);
            CFRelease(psname);
        }
        CFRelease(font);
    }
    fflush(stdout);
}

int main(int argc, char **argv)
{
    const char *mode = argc >= 2 ? argv[1] : "none";
    const char *profile = argc >= 3 ? argv[2] : "com.apple.WebKit.WebContent";
    printf("[sbprobe3 pid=%d mode=%s profile=%s]\n", getpid(), mode, profile);

    if (!strcmp(mode, "warm"))
        exercise_coretext("warm-before");

    if (!strcmp(mode, "cold") || !strcmp(mode, "warm"))
        confine(profile);

    exercise_coretext(!strcmp(mode, "none") ? "baseline" : "after-confine");
    return 0;
}
