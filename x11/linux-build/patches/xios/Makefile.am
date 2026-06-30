SUBDIRS = man

bin_PROGRAMS = Xvfb

AM_CFLAGS = -DHAVE_DIX_CONFIG_H \
            $(XVFBMODULES_CFLAGS) \
	    $(DIX_CFLAGS)

SRCS =	InitInput.c \
	InitOutput.c \
	xios_surface.c \
	$(top_srcdir)/mi/miinitext.c

Xvfb_SOURCES = $(SRCS)

XVFB_LIBS = \
        @XVFB_LIBS@ \
	$(MAIN_LIB) \
	$(XSERVER_LIBS) \
	$(top_builddir)/Xi/libXistubs.la

Xvfb_LDADD = $(XVFB_LIBS) $(XVFB_SYS_LIBS) $(XSERVER_SYS_LIBS)
Xvfb_DEPENDENCIES = $(XVFB_LIBS)
# IOSurface + CoreFoundation back the zero-copy shared framebuffer (xios_surface.c);
# the mach_* APIs come from libSystem. -framework is understood by the cctools ld64.
Xvfb_LDFLAGS = $(LD_EXPORT_SYMBOLS_FLAG) \
	-Wl,-framework,IOSurface -Wl,-framework,CoreFoundation

relink:
	$(AM_V_at)rm -f Xvfb$(EXEEXT) && $(MAKE) Xvfb$(EXEEXT)
