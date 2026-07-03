ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# geoclue.mk — libgeoclue (the CLIENT library) only, for rootless iOS. gnome-shell imports
# gi://Geoclue (2.0) via misc/weather.js <- dateMenu.js at panel boot, so the Geoclue-2.0
# typelib + dylib are boot-critical. The geoclue DAEMON (src/, with its ModemManager/WiFi/
# GPS/compass backends) is dropped (-Denable-backend=false); the client library is a GDBus
# proxy. Location is inert without the daemon, but the typelib must exist for the static import.
# Introspection off (Geoclue-2.0 typelib generated on-device).

SUBPROJECTS      += geoclue
GEOCLUE_VERSION  := 2.7.1
DEB_GEOCLUE_V    ?= $(GEOCLUE_VERSION)+ios1

geoclue-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://gitlab.freedesktop.org/geoclue/geoclue/-/archive/$(GEOCLUE_VERSION)/geoclue-$(GEOCLUE_VERSION).tar.bz2)
	$(call EXTRACT_TAR,geoclue-$(GEOCLUE_VERSION).tar.bz2,geoclue-$(GEOCLUE_VERSION),geoclue)
	rm -rf $(BUILD_WORK)/geoclue/build && mkdir -p $(BUILD_WORK)/geoclue/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/geoclue/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/geoclue/.build_complete),)
geoclue:
	@echo "Using previously built geoclue."
else
geoclue: geoclue-setup glib2.0 json-glib libsoup3
	cd $(BUILD_WORK)/geoclue/build && meson \
		--cross-file cross.txt \
		-Dlibgeoclue=true \
		-Denable-backend=false \
		-Dintrospection=false \
		-Dvapi=false \
		-Dgtk-doc=false \
		-Ddemo-agent=false \
		-D3g-source=false \
		-Dcdma-source=false \
		-Dmodem-gps-source=false \
		-Dnmea-source=false \
		-Dcompass=false \
		..
	+ninja -C $(BUILD_WORK)/geoclue/build
	+DESTDIR="$(BUILD_STAGE)/geoclue" ninja -C $(BUILD_WORK)/geoclue/build install
	$(call AFTER_BUILD,copy)
endif

geoclue-package: geoclue-stage
	rm -rf $(BUILD_DIST)/libgeoclue-2-0 $(BUILD_DIST)/libgeoclue-dev
	mkdir -p $(BUILD_DIST)/libgeoclue-2-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libgeoclue-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/geoclue/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgeoclue-2*.dylib \
		$(BUILD_DIST)/libgeoclue-2-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/
	cp -a $(BUILD_STAGE)/geoclue/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libgeoclue-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/ 2>/dev/null || true
	cp -a $(BUILD_STAGE)/geoclue/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/libgeoclue-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/ 2>/dev/null || true
	$(call SIGN,libgeoclue-2-0,general.xml)
	$(call PACK,libgeoclue-2-0,DEB_GEOCLUE_V)
	$(call PACK,libgeoclue-dev,DEB_GEOCLUE_V)
	rm -rf $(BUILD_DIST)/libgeoclue-2-0 $(BUILD_DIST)/libgeoclue-dev

.PHONY: geoclue geoclue-package
