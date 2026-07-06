ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# libgdm.mk — the gdm CLIENT library only, for rootless iOS. gnome-shell statically imports
# gi://Gdm at boot in 5 files (dependencies.js, systemActions.js, unlockDialog.js,
# gdm/loginDialog.js, gdm/util.js), so the shell will NOT boot without the Gdm-1.0 typelib +
# libgdm dylib. The gdm daemon is Linux-only (PAM/udev/utmp/VT) and is dropped by
# ports/libgdm/patches, which replaces the top-level meson.build with a client-only
# one and compiles a single-session sd-login shim into libgdmcommon (the accountsservice
# pattern). The Gdm-1.0 typelib is generated ON-DEVICE, so the -dev package must ship.
# At runtime there is no display-manager daemon; Gdm.Client simply fails to connect and the
# shell's lock/login paths degrade, which is correct for a jailbreak session.

SUBPROJECTS   += libgdm
LIBGDM_VERSION := 46.0
DEB_LIBGDM_V  ?= $(LIBGDM_VERSION)+ios2

libgdm-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/gdm/$(shell echo $(LIBGDM_VERSION) | cut -f-1 -d.)/gdm-$(LIBGDM_VERSION).tar.xz)
	$(call EXTRACT_TAR,gdm-$(LIBGDM_VERSION).tar.xz,gdm-$(LIBGDM_VERSION),libgdm)
	$(call DO_PATCH,libgdm,libgdm,-p1)
	rm -rf $(BUILD_WORK)/libgdm/build && mkdir -p $(BUILD_WORK)/libgdm/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/libgdm/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/libgdm/.build_complete),)
libgdm:
	@echo "Using previously built libgdm."
else
libgdm: libgdm-setup
	cd $(BUILD_WORK)/libgdm/build && meson \
		--cross-file cross.txt \
		..
	+ninja -C $(BUILD_WORK)/libgdm/build
	+DESTDIR="$(BUILD_STAGE)/libgdm" ninja -C $(BUILD_WORK)/libgdm/build install
	$(call AFTER_BUILD,copy)
endif

libgdm-package: libgdm-stage
	rm -rf $(BUILD_DIST)/libgdm1 $(BUILD_DIST)/libgdm-dev
	mkdir -p $(BUILD_DIST)/libgdm1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libgdm-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# runtime: the versioned dylib
	cp -a $(BUILD_STAGE)/libgdm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgdm.*.dylib \
		$(BUILD_DIST)/libgdm1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/ 2>/dev/null || \
	cp -a $(BUILD_STAGE)/libgdm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgdm.dylib \
		$(BUILD_DIST)/libgdm1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/
	if [ -e "$(BUILD_WORK)/libgdm/data/org.gnome.login-screen.gschema.xml" ]; then \
		mkdir -p $(BUILD_DIST)/libgdm1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/glib-2.0/schemas; \
		cp -a "$(BUILD_WORK)/libgdm/data/org.gnome.login-screen.gschema.xml" \
			$(BUILD_DIST)/libgdm1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/glib-2.0/schemas/; \
	fi

	# dev: headers, pkgconfig, unversioned symlink — needed by the ON-DEVICE gir/typelib build
	cp -a $(BUILD_STAGE)/libgdm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libgdm-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/ 2>/dev/null || true
	cp -a $(BUILD_STAGE)/libgdm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/libgdm-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/ 2>/dev/null || true
	if [ -e "$(BUILD_STAGE)/libgdm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgdm.dylib" ]; then \
		cp -a $(BUILD_STAGE)/libgdm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgdm.dylib \
			$(BUILD_DIST)/libgdm-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/ 2>/dev/null || true; \
	fi

	$(call SIGN,libgdm1,general.xml)
	$(call PACK,libgdm1,DEB_LIBGDM_V)
	$(call PACK,libgdm-dev,DEB_LIBGDM_V)
	rm -rf $(BUILD_DIST)/libgdm1 $(BUILD_DIST)/libgdm-dev

.PHONY: libgdm libgdm-package
