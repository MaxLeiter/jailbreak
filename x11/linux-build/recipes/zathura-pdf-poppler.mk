ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# zathura-pdf-poppler.mk — the PDF backend plugin for zathura, using Poppler's GLib bindings
# (git.pwmt.org/pwmt/zathura-pdf-poppler). A single shared_module (libpdf-poppler.dylib) that
# zathura dlopens at runtime. Deps: zathura (headers + plugindir from zathura.pc), girara,
# glib, poppler-glib — all already staged on the volume. ZERO new sub-deps.
#
# Install path: the plugin reads `plugindir` from zathura.pc, which is ${libdir}/zathura, i.e.
# $(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/zathura — exactly the ZATHURA_PLUGINDIR the zathura
# executable was compiled with. meson links the module with -undefined dynamic_lookup (macOS
# default for shared_module), so the plugin's undefined zathura_* symbols resolve against the
# export_dynamic zathura executable at dlopen time.

SUBPROJECTS       += zathura-pdf-poppler
ZPP_VERSION       := 0.3.3
DEB_ZPP_V         ?= $(ZPP_VERSION)

zathura-pdf-poppler-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://pwmt.org/projects/zathura-pdf-poppler/download/zathura-pdf-poppler-$(ZPP_VERSION).tar.xz)
	$(call EXTRACT_TAR,zathura-pdf-poppler-$(ZPP_VERSION).tar.xz,zathura-pdf-poppler-$(ZPP_VERSION),zathura-pdf-poppler)
	mkdir -p $(BUILD_WORK)/zathura-pdf-poppler/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/zathura-pdf-poppler/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/zathura-pdf-poppler/.build_complete),)
zathura-pdf-poppler:
	@echo "Using previously built zathura-pdf-poppler."
else
zathura-pdf-poppler: zathura-pdf-poppler-setup zathura poppler
	# -Dplugindir is set explicitly: left unset, the plugin reads it from zathura.pc's
	# `plugindir=${libdir}/zathura`, and cross-pkg-config expands ${libdir} to the ABSOLUTE
	# build_base sysroot path — installing the dylib to the wrong staged location. Pin it to the
	# real on-device dir, which is also exactly zathura's compiled-in ZATHURA_PLUGINDIR.
	cd $(BUILD_WORK)/zathura-pdf-poppler/build && meson \
		--cross-file cross.txt \
		-Dtests=disabled \
		-Dplugindir=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/zathura \
		..
	+ninja -C $(BUILD_WORK)/zathura-pdf-poppler/build
	+DESTDIR="$(BUILD_STAGE)/zathura-pdf-poppler" ninja -C $(BUILD_WORK)/zathura-pdf-poppler/build install
	$(call AFTER_BUILD,copy)
endif

zathura-pdf-poppler-package: zathura-pdf-poppler-stage
	rm -rf $(BUILD_DIST)/zathura-pdf-poppler
	mkdir -p $(BUILD_DIST)/zathura-pdf-poppler/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	# the plugin dylib (in lib/zathura/) ...
	cp -a $(BUILD_STAGE)/zathura-pdf-poppler/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/zathura \
		$(BUILD_DIST)/zathura-pdf-poppler/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	# ... plus the metainfo + .desktop it ships under share.
	if [ -d "$(BUILD_STAGE)/zathura-pdf-poppler/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share" ]; then \
		cp -a $(BUILD_STAGE)/zathura-pdf-poppler/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share \
			$(BUILD_DIST)/zathura-pdf-poppler/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi

	$(call SIGN,zathura-pdf-poppler,general.xml)
	$(call PACK,zathura-pdf-poppler,DEB_ZPP_V)
	rm -rf $(BUILD_DIST)/zathura-pdf-poppler

.PHONY: zathura-pdf-poppler zathura-pdf-poppler-package
