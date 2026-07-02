ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# zathura.mk — zathura, the keyboard-driven, plugin-based document viewer
# (git.pwmt.org/pwmt/zathura). Pure C, meson, GTK3 via girara. This is the pragmatic PDF app for
# the Xios desktop (GNOME Papers is Rust-blocked). The zathura executable is the shell; the
# actual rendering is a dlopen'd backend plugin (zathura-pdf-poppler, built separately).
#
# iOS PORTING PATCHES (recipes/zathura-ios-fixes.sh, applied at setup):
#   1. Darwin-ectomy: zathura 0.5.12's meson.build has `if host_machine.system() == 'darwin'`
#      blocks that (a) require gtk-mac-integration-gtk3 and (b) define -DGTKOSXAPPLICATION, which
#      drags in <gtkosxapplication.h> + AppKit/Quartz code in main.c. Our cross.txt sets
#      system='darwin' (Mach-O), but this is an X11 GTK3 build with no GtkOSX. The fix neutralises
#      both darwin conditionals so neither path is taken.
#   2. Magic-ectomy: 0.5.12 removed the old -Dmagic option and made `dependency('libmagic')`
#      unconditional. libmagic (the `file` lib + its .mgc database) is not in our tree and would
#      add a runtime dep, so the patch drops it from meson.build and swaps zathura/content-type.c
#      for a libmagic-free version. zathura already carries a full GLib content-type fallback
#      (g_content_type_guess), which is more than enough to route .pdf -> the poppler plugin.
#
# DISABLED at configure: -Dseccomp (Linux sandbox, will not compile on iOS), -Dlandlock (Linux
# LSM), -Dsynctex (TeX source sync, needs libsynctex), -Dmanpages (needs sphinx), -Dtests,
# -Dconvert-icon (rsvg-convert host tool). ENABLED implicitly (hard deps, all present on the
# volume): sqlite3 (bookmark/history DB -> libsqlite3-1) and json-glib (config).
#
# App deb `zathura`: ships bin/ + share/ only (the static libzathura is linked into the exe;
# headers + zathura.pc are consumed from build_base by the plugin build, not shipped in the app).

SUBPROJECTS      += zathura
ZATHURA_VERSION  := 0.5.12
DEB_ZATHURA_V    ?= $(ZATHURA_VERSION)

zathura-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://pwmt.org/projects/zathura/download/zathura-$(ZATHURA_VERSION).tar.xz)
	$(call EXTRACT_TAR,zathura-$(ZATHURA_VERSION).tar.xz,zathura-$(ZATHURA_VERSION),zathura)
	bash /work/recipes/zathura-ios-fixes.sh $(BUILD_WORK)/zathura
	mkdir -p $(BUILD_WORK)/zathura/build
	echo -e "[host_machine]\n \
	system = 'darwin'\n \
	cpu_family = '$(shell echo $(GNU_HOST_TRIPLE) | cut -d- -f1)'\n \
	cpu = '$(MEMO_ARCH)'\n \
	endian = 'little'\n \
	[properties]\n \
	root = '$(BUILD_BASE)'\n \
	needs_exe_wrapper = true\n \
	[built-in options]\n \
	prefix ='$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)'\n \
	[binaries]\n \
	c = '$(CC)'\n \
	cpp = '$(CXX)'\n \
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/zathura/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/zathura/.build_complete),)
zathura:
	@echo "Using previously built zathura."
else
zathura: zathura-setup girara gtk+3.0
	cd $(BUILD_WORK)/zathura/build && meson \
		--cross-file cross.txt \
		-Dseccomp=disabled \
		-Dlandlock=disabled \
		-Dsynctex=disabled \
		-Dmanpages=disabled \
		-Dtests=disabled \
		-Dconvert-icon=disabled \
		..
	+ninja -C $(BUILD_WORK)/zathura/build
	+DESTDIR="$(BUILD_STAGE)/zathura" ninja -C $(BUILD_WORK)/zathura/build install
	$(call AFTER_BUILD,copy)
endif

zathura-package: zathura-stage
	rm -rf $(BUILD_DIST)/zathura
	mkdir -p $(BUILD_DIST)/zathura/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	# app: bin/zathura + share (desktop, appdata, icon, dbus interface, completions, locale)
	cp -a $(BUILD_STAGE)/zathura/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/zathura/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/zathura/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/zathura/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,zathura,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,zathura,DEB_ZATHURA_V)
	rm -rf $(BUILD_DIST)/zathura

.PHONY: zathura zathura-package
