ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# The zathura executable is the shell; rendering is a dlopen'd backend
# plugin (zathura-pdf-poppler, built separately).
#
# ports/zathura/patches:
#   1. Darwin-ectomy: meson.build's `if system() == 'darwin'` blocks pull in
#      gtk-mac-integration-gtk3 and AppKit/Quartz code. Neutralized: this is
#      an X11 GTK3 build, not GtkOSX, even though cross.txt sets
#      system='darwin' for Mach-O.
#   2. Magic-ectomy: 0.5.12 made `dependency('libmagic')` unconditional.
#      libmagic isn't in the tree, so the patch drops it from meson.build
#      and swaps content-type.c for a libmagic-free version using GLib's
#      g_content_type_guess.

SUBPROJECTS      += zathura
ZATHURA_VERSION  := 0.5.12
DEB_ZATHURA_V    ?= $(ZATHURA_VERSION)+ios1

zathura-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://pwmt.org/projects/zathura/download/zathura-$(ZATHURA_VERSION).tar.xz)
	$(call EXTRACT_TAR,zathura-$(ZATHURA_VERSION).tar.xz,zathura-$(ZATHURA_VERSION),zathura)
	$(call DO_PATCH,zathura,zathura,-p1)
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
