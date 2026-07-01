ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# d-spy.mk — D-Spy, GNOME's GTK4/libadwaita D-Bus explorer (browse names/objects/interfaces on
# the session & system bus; call methods; watch signals). Pure C, and one of the shallowest GTK4
# apps there is: its only library deps are gtk4 + libadwaita-1 + gio — all prebuilt — so it adds
# zero new sub-deps (like gnome-font-viewer). Binary is `d-spy`.
#
# Version 1.10.0 (its own symbolic_version is "46.0"): the LAST pre-rewrite release. d-spy 47+
# was rewritten on libdex (a new fiber/async dep) and needs gtk4 >=4.15 — neither of which we
# have — so 1.10.0 is the right match for our gtk4 4.14.5 / libadwaita 1.5 foundation.
# Its tarball lives under the two-component dir (sources/d-spy/1.10/...).
#
# DEPENDS (target): gtk4 + libadwaita (+ gio/glib, prebuilt). Needs a running D-Bus session
# at runtime (we ship dbus).

SUBPROJECTS       += d-spy
D-SPY_MAJOR_V     := 1.10
D-SPY_VERSION     := $(D-SPY_MAJOR_V).0
DEB_D-SPY_V       ?= $(D-SPY_VERSION)

d-spy-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/d-spy/$(D-SPY_MAJOR_V)/d-spy-$(D-SPY_VERSION).tar.xz)
	$(call EXTRACT_TAR,d-spy-$(D-SPY_VERSION).tar.xz,d-spy-$(D-SPY_VERSION),d-spy)
	mkdir -p $(BUILD_WORK)/d-spy/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/d-spy/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/d-spy/.build_complete),)
d-spy:
	@echo "Using previously built d-spy."
else
d-spy: d-spy-setup gtk4 libadwaita
	cd $(BUILD_WORK)/d-spy/build && meson \
		--cross-file cross.txt \
		-Ddevelopment=false \
		..
	+ninja -C $(BUILD_WORK)/d-spy/build
	+DESTDIR="$(BUILD_STAGE)/d-spy" ninja -C $(BUILD_WORK)/d-spy/build install
	$(call AFTER_BUILD,copy)
endif

d-spy-package: d-spy-stage
	rm -rf $(BUILD_DIST)/d-spy
	mkdir -p $(BUILD_DIST)/d-spy/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	# app: bin/d-spy + lib (libdspy private shared lib) + share (desktop, icons, gresource)
	cp -a $(BUILD_STAGE)/d-spy/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/d-spy/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	if [ -d "$(BUILD_STAGE)/d-spy/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib" ]; then \
		cp -a $(BUILD_STAGE)/d-spy/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib $(BUILD_DIST)/d-spy/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi
	cp -a $(BUILD_STAGE)/d-spy/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/d-spy/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,d-spy,general.xml)
	$(call PACK,d-spy,DEB_D-SPY_V)
	rm -rf $(BUILD_DIST)/d-spy

.PHONY: d-spy d-spy-package
