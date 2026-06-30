ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# nautilus.mk — GNOME Files, the GTK4/libadwaita file manager. GNOME 45 = 45.0.
#
# Optional-feature trims (verified against nautilus 45.0 meson.build) to keep the dep tree
# minimal:
#   -Dextensions=false   → drops gexiv2 + gstreamer-tag/pbutils + explicit gdk-pixbuf
#   -Dcloudproviders=false → drops libcloudproviders
#   -Dpackagekit=false   → drops the PackageKit handler-install path
#   -Dintrospection=false → typelibs can't be cross-generated for Mach-O (see gnome-plan.md #2)
#   -Dtests=none
# Required (unconditional) deps remain: gnome-autoar, gnome-desktop-4, libportal(+gtk4),
# tracker-sparql-3.0, gtk4, libadwaita, libxml2.
#
# DRAFT — Phase 1, NOT built/verified. Mirrors recipes/pango.mk style.

SUBPROJECTS       += nautilus
NAUTILUS_MAJOR_V  := 46
NAUTILUS_VERSION  := $(NAUTILUS_MAJOR_V).4
DEB_NAUTILUS_V    ?= $(NAUTILUS_VERSION)

nautilus-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/nautilus/$(NAUTILUS_MAJOR_V)/nautilus-$(NAUTILUS_VERSION).tar.xz)
	$(call EXTRACT_TAR,nautilus-$(NAUTILUS_VERSION).tar.xz,nautilus-$(NAUTILUS_VERSION),nautilus)
	mkdir -p $(BUILD_WORK)/nautilus/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/nautilus/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/nautilus/.build_complete),)
nautilus:
	@echo "Using previously built nautilus."
else
nautilus: nautilus-setup gtk4 libadwaita gnome-desktop gnome-autoar libportal tracker libxml2
	cd $(BUILD_WORK)/nautilus/build && meson \
		--cross-file cross.txt \
		-Dextensions=false \
		-Dcloudproviders=false \
		-Dpackagekit=false \
		-Dselinux=false \
		-Dintrospection=false \
		-Dtests=none \
		..
	+ninja -C $(BUILD_WORK)/nautilus/build
	+DESTDIR="$(BUILD_STAGE)/nautilus" ninja -C $(BUILD_WORK)/nautilus/build install
	$(call AFTER_BUILD,copy)
endif

nautilus-package: nautilus-stage
	rm -rf $(BUILD_DIST)/nautilus
	mkdir -p $(BUILD_DIST)/nautilus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	# app: bin/nautilus + lib (libnautilus-extension dylib + lib/nautilus modules) + share
	cp -a $(BUILD_STAGE)/nautilus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/nautilus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	if [ -d "$(BUILD_STAGE)/nautilus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec" ]; then \
		cp -a $(BUILD_STAGE)/nautilus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec $(BUILD_DIST)/nautilus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi
	# ship the extension dylib + modules dir, but not the -dev cruft
	mkdir -p $(BUILD_DIST)/nautilus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	if compgen -G "$(BUILD_STAGE)/nautilus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libnautilus-extension*.dylib" >/dev/null; then \
		cp -a $(BUILD_STAGE)/nautilus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libnautilus-extension*.dylib $(BUILD_DIST)/nautilus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib; \
	fi
	if [ -d "$(BUILD_STAGE)/nautilus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/nautilus" ]; then \
		cp -a $(BUILD_STAGE)/nautilus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/nautilus $(BUILD_DIST)/nautilus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib; \
	fi
	cp -a $(BUILD_STAGE)/nautilus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/nautilus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,nautilus,general.xml)
	$(call PACK,nautilus,DEB_NAUTILUS_V)
	rm -rf $(BUILD_DIST)/nautilus

.PHONY: nautilus nautilus-package
