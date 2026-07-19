ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# wayland-protocols — the extension protocol XML (xdg-shell, linux-dmabuf, viewporter,
# presentation-time, ...) plus wayland-protocols.pc. Architecture-independent *data*:
# clients run wayland-scanner over these XMLs at *their* build time, so nothing here is
# compiled or cross-built. No cross file needed (the meson project declares no language).
#
# BUILT/PUBLISHED — wayland-protocols 1.44+ios1. Recipe integration:
#   recipe        -> Procursus/makefiles/wayland-protocols.mk
#   control file  -> Procursus/build_info/wayland-protocols.control

SUBPROJECTS            += wayland-protocols
# Bumped 1.38 -> 1.44 for foot 1.27, whose meson hard-requires wayland-protocols >= 1.41 and
# references color-management-v1 (added 1.41) + xdg-toplevel-tag-v1 (>=1.43 gate). Pure data,
# backward compatible; only foot/imv consume it in the wayland volume.
WAYLANDPROTOCOLS_VERSION := 1.44
DEB_WAYLANDPROTOCOLS_V ?= $(WAYLANDPROTOCOLS_VERSION)+ios1

wayland-protocols-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://gitlab.freedesktop.org/wayland/wayland-protocols/-/releases/$(WAYLANDPROTOCOLS_VERSION)/downloads/wayland-protocols-$(WAYLANDPROTOCOLS_VERSION).tar.xz)
	$(call EXTRACT_TAR,wayland-protocols-$(WAYLANDPROTOCOLS_VERSION).tar.xz,wayland-protocols-$(WAYLANDPROTOCOLS_VERSION),wayland-protocols)
	mkdir -p $(BUILD_WORK)/wayland-protocols/build

ifneq ($(wildcard $(BUILD_WORK)/wayland-protocols/.build_complete),)
wayland-protocols:
	@echo "Using previously built wayland-protocols."
else
# Data-only (no compilation, host-arch-independent), but meson.build unconditionally resolves
# dependency('wayland-scanner', native:true, fallback:'wayland') at configure time. We don't ship
# the wayland subproject, so point a native file's pkg_config_path at the version-matched native
# scanner that the `wayland` build left in WAYLAND_NATIVE_ROOT (hence the `wayland` prerequisite).
# tests stay off (the scanner is only *executed* by the tests, which we don't need).
wayland-protocols: wayland-protocols-setup wayland
	cd $(BUILD_WORK)/wayland-protocols/build && \
		printf "[binaries]\npkgconfig = 'pkg-config'\n[built-in options]\npkg_config_path = ['$(WAYLAND_NATIVE_ROOT)/lib/pkgconfig']\n" > native.txt && \
		PATH="$(WAYLAND_NATIVE_ROOT)/bin:$$PATH" meson \
		--native-file native.txt \
		-Dtests=false \
		--prefix=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) \
		..
	+DESTDIR="$(BUILD_STAGE)/wayland-protocols" ninja -C $(BUILD_WORK)/wayland-protocols/build install
	$(call AFTER_BUILD,copy)
endif

wayland-protocols-package: wayland-protocols-stage
	# wayland-protocols.mk Package Structure (pure data)
	rm -rf $(BUILD_DIST)/wayland-protocols
	mkdir -p $(BUILD_DIST)/wayland-protocols/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	# wayland-protocols.mk Prep (share/wayland-protocols/*.xml + share/pkgconfig + any lib/pkgconfig)
	cp -a $(BUILD_STAGE)/wayland-protocols/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share \
		$(BUILD_DIST)/wayland-protocols/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	if [ -d "$(BUILD_STAGE)/wayland-protocols/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib" ]; then \
		cp -a $(BUILD_STAGE)/wayland-protocols/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
			$(BUILD_DIST)/wayland-protocols/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi

	# wayland-protocols.mk Make .deb (no binaries -> no SIGN)
	$(call PACK,wayland-protocols,DEB_WAYLANDPROTOCOLS_V)

	# wayland-protocols.mk Build cleanup
	rm -rf $(BUILD_DIST)/wayland-protocols

.PHONY: wayland-protocols wayland-protocols-package
