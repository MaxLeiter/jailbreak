/* libgtkintl: maps GTK's bundled proxy-libintl symbol names (g_libintl_*) onto
   the real GNU gettext libintl_* in libintl.8.
 *
 * GTK's meson links an internal copy of proxy-libintl whose exports are renamed
 * g_libintl_*. Upstream that resolves to GTK's bundled @rpath/libintl.dylib,
 * which we can't ship (gettext owns that path on Procursus). Relinking GTK onto
 * the system libintl.8 alone fails: libintl.8 has libintl_*, not g_libintl_*, so
 * dyld aborts ("Symbol not found: _g_libintl_gettext"). This shim bridges the gap.
 *
 * It REEXPORTS libintl.8 (so any real libintl_* still resolve) and adds the
 * g_libintl_* wrappers. It also exposes the unprefixed GNU API for foreign
 * bindings such as gettext-rs, which declare gettext() directly instead of
 * following libintl.h's preprocessor aliases to libintl_gettext().
 *
 * Build (on device, or any env with libintl):
 *   clang -dynamiclib -fno-common -install_name @rpath/libgtkintl.dylib \
 *       gtkintl_shim.c -L<prefix>/lib -Wl,-reexport-lintl -o libgtkintl.dylib
 *   ldid -S libgtkintl.dylib
 */
extern char *libintl_gettext(const char *);
extern char *libintl_dgettext(const char *, const char *);
extern char *libintl_dcgettext(const char *, const char *, int);
extern char *libintl_ngettext(const char *, const char *, unsigned long);
extern char *libintl_dngettext(const char *, const char *, const char *, unsigned long);
extern char *libintl_dcngettext(const char *, const char *, const char *, unsigned long, int);
extern char *libintl_textdomain(const char *);
extern char *libintl_bindtextdomain(const char *, const char *);
extern char *libintl_bind_textdomain_codeset(const char *, const char *);

char *g_libintl_gettext(const char *m) { return libintl_gettext(m); }
char *g_libintl_dgettext(const char *d, const char *m) { return libintl_dgettext(d, m); }
char *g_libintl_dcgettext(const char *d, const char *m, int c) { return libintl_dcgettext(d, m, c); }
char *g_libintl_ngettext(const char *s, const char *p, unsigned long n) { return libintl_ngettext(s, p, n); }
char *g_libintl_dngettext(const char *d, const char *s, const char *p, unsigned long n) { return libintl_dngettext(d, s, p, n); }
char *g_libintl_dcngettext(const char *d, const char *s, const char *p, unsigned long n, int c) { return libintl_dcngettext(d, s, p, n, c); }
char *g_libintl_textdomain(const char *d) { return libintl_textdomain(d); }
char *g_libintl_bindtextdomain(const char *d, const char *dir) { return libintl_bindtextdomain(d, dir); }
char *g_libintl_bind_textdomain_codeset(const char *d, const char *c) { return libintl_bind_textdomain_codeset(d, c); }

char *gettext(const char *m) { return libintl_gettext(m); }
char *dgettext(const char *d, const char *m) { return libintl_dgettext(d, m); }
char *dcgettext(const char *d, const char *m, int c) { return libintl_dcgettext(d, m, c); }
char *ngettext(const char *s, const char *p, unsigned long n) { return libintl_ngettext(s, p, n); }
char *dngettext(const char *d, const char *s, const char *p, unsigned long n) { return libintl_dngettext(d, s, p, n); }
char *dcngettext(const char *d, const char *s, const char *p, unsigned long n, int c) { return libintl_dcngettext(d, s, p, n, c); }
char *textdomain(const char *d) { return libintl_textdomain(d); }
char *bindtextdomain(const char *d, const char *dir) { return libintl_bindtextdomain(d, dir); }
char *bind_textdomain_codeset(const char *d, const char *c) { return libintl_bind_textdomain_codeset(d, c); }
