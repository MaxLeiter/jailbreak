ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# libnotify.mk — desktop notifications client library (libnotify4). GLib + GdkPixbuf only
# (libnotify 0.8 dropped its GTK dependency; the notify-send tool is the only GTK user and
# we skip it). Needed by gnome-settings-daemon's housekeeping plugin and useful to GNOME
# apps generally. Introspection off (typelib not needed for the C link).

SUBPROJECTS      += libnotify
LIBNOTIFY_VERSION := 0.8.3
DEB_LIBNOTIFY_V  ?= $(LIBNOTIFY_VERSION)

libnotify-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/libnotify/$(shell echo $(LIBNOTIFY_VERSION) | cut -f-2 -d.)/libnotify-$(LIBNOTIFY_VERSION).tar.xz)
	$(call EXTRACT_TAR,libnotify-$(LIBNOTIFY_VERSION).tar.xz,libnotify-$(LIBNOTIFY_VERSION),libnotify)
	rm -rf $(BUILD_WORK)/libnotify/build && mkdir -p $(BUILD_WORK)/libnotify/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/libnotify/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/libnotify/.build_complete),)
libnotify:
	@echo "Using previously built libnotify."
else
libnotify: libnotify-setup gdk-pixbuf
	cd $(BUILD_WORK)/libnotify/build && meson \
		--cross-file cross.txt \
		-Dtests=false \
		-Dintrospection=disabled \
		-Dman=false \
		-Dgtk_doc=false \
		-Ddocbook_docs=disabled \
		..
	+ninja -C $(BUILD_WORK)/libnotify/build
	+DESTDIR="$(BUILD_STAGE)/libnotify" ninja -C $(BUILD_WORK)/libnotify/build install
	$(call AFTER_BUILD,copy)
endif

libnotify-package: libnotify-stage
	rm -rf $(BUILD_DIST)/libnotify4 $(BUILD_DIST)/libnotify-dev
	mkdir -p $(BUILD_DIST)/libnotify4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libnotify-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# runtime: the versioned dylib
	cp -a $(BUILD_STAGE)/libnotify/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libnotify.*.dylib \
		$(BUILD_DIST)/libnotify4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/ 2>/dev/null || \
	cp -a $(BUILD_STAGE)/libnotify/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libnotify.dylib \
		$(BUILD_DIST)/libnotify4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/

	# dev: unversioned symlink, headers, pkgconfig
	cp -a $(BUILD_STAGE)/libnotify/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/libnotify-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/ 2>/dev/null || true
	cp -a $(BUILD_STAGE)/libnotify/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libnotify-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/ 2>/dev/null || true
	if [ -e "$(BUILD_STAGE)/libnotify/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libnotify.dylib" ]; then \
		cp -a $(BUILD_STAGE)/libnotify/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libnotify.dylib \
			$(BUILD_DIST)/libnotify-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/ 2>/dev/null || true; \
	fi

	$(call SIGN,libnotify4,general.xml)
	$(call PACK,libnotify4,DEB_LIBNOTIFY_V)
	$(call PACK,libnotify-dev,DEB_LIBNOTIFY_V)
	rm -rf $(BUILD_DIST)/libnotify4 $(BUILD_DIST)/libnotify-dev

.PHONY: libnotify libnotify-package
