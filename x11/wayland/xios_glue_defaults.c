/*
 * xios_glue_defaults.c — default weak symbols so libxios_glue.dylib links
 * standalone.
 *
 * xios_surface.c references an EXTERNAL `char *display` — the X display-number
 * string, written only cosmetically into the xios.json handshake
 * ("display":":<n>"). In the X server that symbol comes from dix; in iosc from
 * iosc.c (`char *display = "9"`). A consumer with no X display (Mutter's
 * MetaBackendIOS) has nothing to provide it, so the shared dylib carries this
 * WEAK default. A consumer that does define `display` (the X server, or a linker
 * that pulls iosc.c) overrides it; iosc itself compiles the glue sources directly
 * and never links this dylib, so there is no conflict there.
 */
__attribute__((weak)) char *display = "0";
