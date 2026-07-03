ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# libportal.mk — GIO-style wrappers around the XDG Desktop Portal D-Bus APIs. Required by
# nautilus (libportal + libportal-gtk4). One build emits the core lib + the gtk4 backend.
# NOTE: on iOS there is no xdg-desktop-portal *service*, so portal calls are inert at runtime
# (file chooser etc. fall back to GTK's own dialogs) — fine; nautilus only needs to LINK it.
#
# DEPENDS (target): glib + gtk4 (gtk-builder; for the -gtk4 backend).
#
# DRAFT — Phase 1, NOT built/verified. Mirrors recipes/pango.mk style.

SUBPROJECTS        += libportal
LIBPORTAL_VERSION  := 0.7.1
DEB_LIBPORTAL_V    ?= $(LIBPORTAL_VERSION)+ios1

libportal-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/flatpak/libportal/releases/download/$(LIBPORTAL_VERSION)/libportal-$(LIBPORTAL_VERSION).tar.xz)
	$(call EXTRACT_TAR,libportal-$(LIBPORTAL_VERSION).tar.xz,libportal-$(LIBPORTAL_VERSION),libportal)
	mkdir -p $(BUILD_WORK)/libportal/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/libportal/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/libportal/.build_complete),)
libportal:
	@echo "Using previously built libportal."
else
libportal: libportal-setup glib2.0 gtk4
	cd $(BUILD_WORK)/libportal/build && meson \
		--cross-file cross.txt \
		-Dbackend-gtk4=enabled \
		-Dbackend-gtk3=disabled \
		-Dbackend-qt5=disabled \
		-Dintrospection=false \
		-Dvapi=false \
		-Ddocs=false \
		-Dtests=false \
		..
	+ninja -C $(BUILD_WORK)/libportal/build
	+DESTDIR="$(BUILD_STAGE)/libportal" ninja -C $(BUILD_WORK)/libportal/build install
	$(call AFTER_BUILD,copy)
endif

libportal-package: libportal-stage
	rm -rf $(BUILD_DIST)/libportal1 $(BUILD_DIST)/libportal-gtk4-1 $(BUILD_DIST)/libportal-dev
	mkdir -p $(BUILD_DIST)/libportal1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libportal-gtk4-1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libportal-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libportal1 (core runtime dylib)
	cp -a $(BUILD_STAGE)/libportal/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libportal.1.dylib $(BUILD_DIST)/libportal1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libportal-gtk4-1 (gtk4 backend runtime dylib)
	cp -a $(BUILD_STAGE)/libportal/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libportal-gtk4.1.dylib $(BUILD_DIST)/libportal-gtk4-1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libportal-dev (headers, symlinks, .pc for both)
	cp -a $(BUILD_STAGE)/libportal/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libportal.1.dylib|libportal-gtk4.1.dylib) $(BUILD_DIST)/libportal-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libportal/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libportal-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,libportal1,general.xml)
	$(call SIGN,libportal-gtk4-1,general.xml)
	$(call PACK,libportal1,DEB_LIBPORTAL_V)
	$(call PACK,libportal-gtk4-1,DEB_LIBPORTAL_V)
	$(call PACK,libportal-dev,DEB_LIBPORTAL_V)
	rm -rf $(BUILD_DIST)/libportal1 $(BUILD_DIST)/libportal-gtk4-1 $(BUILD_DIST)/libportal-dev

.PHONY: libportal libportal-package
