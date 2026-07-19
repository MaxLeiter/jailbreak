ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# libxkbcommon — keymap compilation for the compositor's wl_keyboard (xkb_keymap_new_*),
# the Wayland analogue of the X server's XKB. Built with the X11 helper library
# (`libxkbcommon-x11`) for Xwayland-backed apps such as imv, but no wayland helper
# tool, docs, or CLI tools. xkbregistry IS enabled
# (adds only a libxml2 dep, already prebuilt in Procursus): this is the ONE canonical
# libxkbcommon shared with gnome-track, whose Files (gnome-desktop-4 / GnomeXkbInfo) needs
# libxkbregistry — Wayland is unaffected by the extra symbol. Keymap *data* comes from
# Procursus's xkeyboard-config at runtime, so we point xkb-config-root at its install path.
#
# Host build-dep: bison (libxkbcommon generates its keymap parser at build time). Ensure
# the build container has it (apt-get install -y bison) — documented, not auto-installed.
#
# BUILT/PUBLISHED — libxkbcommon0 1.7.0+ios2. Recipe integration:
#   recipe        -> Procursus/makefiles/libxkbcommon.mk
#   control files -> Procursus/build_info/libxkbcommon0.control, libxkbcommon-dev.control

SUBPROJECTS        += libxkbcommon
LIBXKBCOMMON_VERSION := 1.7.0
DEB_LIBXKBCOMMON_V ?= $(LIBXKBCOMMON_VERSION)+ios2

libxkbcommon-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://xkbcommon.org/download/libxkbcommon-$(LIBXKBCOMMON_VERSION).tar.xz)
	$(call EXTRACT_TAR,libxkbcommon-$(LIBXKBCOMMON_VERSION).tar.xz,libxkbcommon-$(LIBXKBCOMMON_VERSION),libxkbcommon)
	mkdir -p $(BUILD_WORK)/libxkbcommon/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/libxkbcommon/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/libxkbcommon/.build_complete),)
libxkbcommon:
	@echo "Using previously built libxkbcommon."
else
libxkbcommon: libxkbcommon-setup libxml2 libxcb
	cd $(BUILD_WORK)/libxkbcommon/build && meson \
		--cross-file cross.txt \
		-Denable-docs=false \
		-Denable-wayland=false \
		-Denable-x11=true \
		-Denable-xkbregistry=true \
		-Denable-tools=false \
		-Dxkb-config-root=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/X11/xkb \
		-Dx-locale-root=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/X11/locale \
		..
	+ninja -C $(BUILD_WORK)/libxkbcommon/build
	+DESTDIR="$(BUILD_STAGE)/libxkbcommon" ninja -C $(BUILD_WORK)/libxkbcommon/build install
	$(call AFTER_BUILD,copy)
endif

libxkbcommon-package: libxkbcommon-stage
	# libxkbcommon.mk Package Structure
	rm -rf $(BUILD_DIST)/libxkbcommon{0,-dev}
	mkdir -p $(BUILD_DIST)/libxkbcommon0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libxkbcommon-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libxkbcommon.mk Prep libxkbcommon0 (runtime dylibs: libxkbcommon + libxkbregistry)
	cp -a $(BUILD_STAGE)/libxkbcommon/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libxkbcommon.*.dylib \
		$(BUILD_STAGE)/libxkbcommon/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libxkbcommon-x11.*.dylib \
		$(BUILD_STAGE)/libxkbcommon/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libxkbregistry.*.dylib \
		$(BUILD_DIST)/libxkbcommon0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libxkbcommon.mk Prep libxkbcommon-dev (headers, .pc, unversioned symlinks)
	cp -a $(BUILD_STAGE)/libxkbcommon/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libxkbcommon-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/libxkbcommon/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libxkbcommon.*.dylib|libxkbcommon-x11.*.dylib|libxkbregistry.*.dylib) \
		$(BUILD_DIST)/libxkbcommon-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libxkbcommon.mk Sign
	$(call SIGN,libxkbcommon0,general.xml)

	# libxkbcommon.mk Make .debs
	$(call PACK,libxkbcommon0,DEB_LIBXKBCOMMON_V)
	$(call PACK,libxkbcommon-dev,DEB_LIBXKBCOMMON_V)

	# libxkbcommon.mk Build cleanup
	rm -rf $(BUILD_DIST)/libxkbcommon{0,-dev}

.PHONY: libxkbcommon libxkbcommon-package
