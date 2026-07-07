ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# libsigc++ 2.x: C++ signal/slot base used by the gtkmm3 stack.
# Procursus already carries this target name; keep it so existing dependency
# names still work, but mark our iOS rebuild on the deb version seam.

SUBPROJECTS             += libsigcplusplus
LIBSIGCPLUSPLUS_VERSION := 2.10.3
DEB_LIBSIGCPLUSPLUS_V   ?= $(LIBSIGCPLUSPLUS_VERSION)+ios1

libsigcplusplus-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/libsigc++/2.10/libsigc++-$(LIBSIGCPLUSPLUS_VERSION).tar.xz)
	$(call EXTRACT_TAR,libsigc++-$(LIBSIGCPLUSPLUS_VERSION).tar.xz,libsigc++-$(LIBSIGCPLUSPLUS_VERSION),libsigcplusplus)
	sed -i 's/-keep_private_externs -nostdlib/-keep_private_externs $(PLATFORM_VERSION_MIN) -arch $(MEMO_ARCH) -nostdlib/g' $(BUILD_WORK)/libsigcplusplus/configure

ifneq ($(wildcard $(BUILD_WORK)/libsigcplusplus/.build_complete),)
libsigcplusplus:
	@echo "Using previously built libsigcplusplus."
else
libsigcplusplus: libsigcplusplus-setup
	cd $(BUILD_WORK)/libsigcplusplus && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--disable-dependency-tracking \
		--disable-static \
		--enable-shared
	+$(MAKE) -C $(BUILD_WORK)/libsigcplusplus
	+$(MAKE) -C $(BUILD_WORK)/libsigcplusplus install DESTDIR=$(BUILD_STAGE)/libsigcplusplus
	$(call AFTER_BUILD,copy)
endif

libsigcplusplus-package: libsigcplusplus-stage
	rm -rf $(BUILD_DIST)/libsigc++-2.0-0v5 $(BUILD_DIST)/libsigc++-2.0-dev
	mkdir -p $(BUILD_DIST)/libsigc++-2.0-0v5/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libsigc++-2.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/libsigcplusplus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libsigc-2.0.0.dylib \
		$(BUILD_DIST)/libsigc++-2.0-0v5/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/libsigcplusplus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libsigc++-2.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/libsigcplusplus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libsigc-2.0.0.dylib) \
		$(BUILD_DIST)/libsigc++-2.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	$(call SIGN,libsigc++-2.0-0v5,general.xml)
	$(call PACK,libsigc++-2.0-0v5,DEB_LIBSIGCPLUSPLUS_V)
	$(call PACK,libsigc++-2.0-dev,DEB_LIBSIGCPLUSPLUS_V)
	rm -rf $(BUILD_DIST)/libsigc++-2.0-0v5 $(BUILD_DIST)/libsigc++-2.0-dev

.PHONY: libsigcplusplus libsigcplusplus-package
