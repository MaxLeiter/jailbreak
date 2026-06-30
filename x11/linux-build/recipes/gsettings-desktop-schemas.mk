ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# gsettings-desktop-schemas.mk — the shared GSettings schemas the GNOME stack reads
# (org.gnome.desktop.*, org.gnome.system.*). Data-only: .gschema.xml files + translations,
# no compiled code, no target-binary execution at build → fully tractable to cross "build".
# Independent of GTK/dbus/introspection. See docs/gnome-plan.md, Stage A.
#
# DRAFT — authored Phase 1 (research), NOT yet built/verified. Mirrors recipes/pango.mk style.

SUBPROJECTS  += gsettings-desktop-schemas
GSDS_MAJOR_V := 46
GSDS_VERSION := $(GSDS_MAJOR_V).1
DEB_GSDS_V   ?= $(GSDS_VERSION)

gsettings-desktop-schemas-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/gsettings-desktop-schemas/$(GSDS_MAJOR_V)/gsettings-desktop-schemas-$(GSDS_VERSION).tar.xz)
	$(call EXTRACT_TAR,gsettings-desktop-schemas-$(GSDS_VERSION).tar.xz,gsettings-desktop-schemas-$(GSDS_VERSION),gsettings-desktop-schemas)
	mkdir -p $(BUILD_WORK)/gsettings-desktop-schemas/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/gsettings-desktop-schemas/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/gsettings-desktop-schemas/.build_complete),)
gsettings-desktop-schemas:
	@echo "Using previously built gsettings-desktop-schemas."
else
gsettings-desktop-schemas: gsettings-desktop-schemas-setup glib2.0
	cd $(BUILD_WORK)/gsettings-desktop-schemas/build && meson \
		--cross-file cross.txt \
		-Dintrospection=false \
		..
	+ninja -C $(BUILD_WORK)/gsettings-desktop-schemas/build
	+DESTDIR="$(BUILD_STAGE)/gsettings-desktop-schemas" ninja -C $(BUILD_WORK)/gsettings-desktop-schemas/build install
	$(call AFTER_BUILD,copy)
endif

gsettings-desktop-schemas-package: gsettings-desktop-schemas-stage
	# gsettings-desktop-schemas.mk Package Structure — data-only (schemas + locale)
	rm -rf $(BUILD_DIST)/gsettings-desktop-schemas
	mkdir -p $(BUILD_DIST)/gsettings-desktop-schemas/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/gsettings-desktop-schemas/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/gsettings-desktop-schemas/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	# NOTE: installs $(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/glib-2.0/schemas/*.gschema.xml.
	# A postinst (or dpkg trigger from libglib2.0-bin) must run `glib-compile-schemas` on that
	# dir on-device to produce gschemas.compiled. Wire a build_info/*.postinst when shipping.

	$(call SIGN,gsettings-desktop-schemas,general.xml)
	$(call PACK,gsettings-desktop-schemas,DEB_GSDS_V)
	rm -rf $(BUILD_DIST)/gsettings-desktop-schemas

.PHONY: gsettings-desktop-schemas gsettings-desktop-schemas-package
