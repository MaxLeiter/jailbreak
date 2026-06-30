ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# libxfce4util — XFCE base utility library (no GTK dep; only glib). First XFCE brick;
# GTK-independent, so it can be built/validated ahead of the GTK3 stack.
SUBPROJECTS         += libxfce4util
LIBXFCE4UTIL_MAJOR_V := 4.16
LIBXFCE4UTIL_VERSION := $(LIBXFCE4UTIL_MAJOR_V).0
DEB_LIBXFCE4UTIL_V   ?= $(LIBXFCE4UTIL_VERSION)

libxfce4util-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://archive.xfce.org/src/xfce/libxfce4util/$(LIBXFCE4UTIL_MAJOR_V)/libxfce4util-$(LIBXFCE4UTIL_VERSION).tar.bz2)
	$(call EXTRACT_TAR,libxfce4util-$(LIBXFCE4UTIL_VERSION).tar.bz2,libxfce4util-$(LIBXFCE4UTIL_VERSION),libxfce4util)

ifneq ($(wildcard $(BUILD_WORK)/libxfce4util/.build_complete),)
libxfce4util:
	@echo "Using previously built libxfce4util."
else
libxfce4util: libxfce4util-setup glib2.0
	cd $(BUILD_WORK)/libxfce4util && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--disable-static \
		--disable-gtk-doc \
		--disable-introspection \
		--disable-debug
	+$(MAKE) -C $(BUILD_WORK)/libxfce4util
	+$(MAKE) -C $(BUILD_WORK)/libxfce4util install DESTDIR=$(BUILD_STAGE)/libxfce4util
	$(call AFTER_BUILD,copy)
endif

libxfce4util-package: libxfce4util-stage
	rm -rf $(BUILD_DIST)/libxfce4util7
	mkdir -p $(BUILD_DIST)/libxfce4util7
	cp -a $(BUILD_STAGE)/libxfce4util/$(MEMO_PREFIX) $(BUILD_DIST)/libxfce4util7/

	rm -rf $(BUILD_DIST)/libxfce4util7/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libxfce4util7/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/libxfce4util7/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/*.a \
		$(BUILD_DIST)/libxfce4util7/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/gtk-doc

	$(call SIGN,libxfce4util7,general.xml)
	$(call PACK,libxfce4util7,DEB_LIBXFCE4UTIL_V)
	rm -rf $(BUILD_DIST)/libxfce4util7

.PHONY: libxfce4util libxfce4util-package
