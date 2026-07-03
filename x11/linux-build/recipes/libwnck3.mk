ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# libwnck 3.x — window-navigator construction kit (EWMH client-window list / WM hints).
# Hard dep of xfwm4; used by xfce4-panel (tasklist/pager), xfce4-session, xfdesktop.
# Not in Procursus. GTK3-era libwnck (3.x) builds with meson. Blocked on the GTK3 stack.
SUBPROJECTS     += libwnck3
LIBWNCK3_MAJOR_V := 3.36
LIBWNCK3_VERSION := $(LIBWNCK3_MAJOR_V).0
DEB_LIBWNCK3_V   ?= $(LIBWNCK3_VERSION)+ios1

libwnck3-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://ftp.gnome.org/pub/gnome/sources/libwnck/$(LIBWNCK3_MAJOR_V)/libwnck-$(LIBWNCK3_VERSION).tar.xz)
	$(call EXTRACT_TAR,libwnck-$(LIBWNCK3_VERSION).tar.xz,libwnck-$(LIBWNCK3_VERSION),libwnck3)
	rm -rf $(BUILD_WORK)/libwnck3/build
	mkdir -p $(BUILD_WORK)/libwnck3/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/libwnck3/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/libwnck3/.build_complete),)
libwnck3:
	@echo "Using previously built libwnck3."
else
libwnck3: libwnck3-setup glib2.0 gtk+3.0 gdk-pixbuf cairo libx11 libxres startup-notification
	cd $(BUILD_WORK)/libwnck3/build && meson \
		--cross-file cross.txt \
		-Dintrospection=disabled \
		-Dstartup_notification=enabled \
		-Dgtk_doc=false \
		..
	+ninja -C $(BUILD_WORK)/libwnck3/build
	+DESTDIR="$(BUILD_STAGE)/libwnck3" ninja -C $(BUILD_WORK)/libwnck3/build install
	$(call AFTER_BUILD,copy)
endif

libwnck3-package: libwnck3-stage
	rm -rf $(BUILD_DIST)/libwnck-3-0
	mkdir -p $(BUILD_DIST)/libwnck-3-0
	cp -a $(BUILD_STAGE)/libwnck3/$(MEMO_PREFIX) $(BUILD_DIST)/libwnck-3-0/

	rm -rf $(BUILD_DIST)/libwnck-3-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libwnck-3-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/libwnck-3-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/*.a \
		$(BUILD_DIST)/libwnck-3-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/gtk-doc

	$(call SIGN,libwnck-3-0,general.xml)
	$(call PACK,libwnck-3-0,DEB_LIBWNCK3_V)
	rm -rf $(BUILD_DIST)/libwnck-3-0

.PHONY: libwnck3 libwnck3-package
