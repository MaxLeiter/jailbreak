ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# transmission.mk - Transmission BitTorrent client, daemon, CLI, utils, and web UI.
# 4.1.3 is the current official stable release. The GTK client is intentionally
# disabled for this first pass because upstream 4.1.x requires gtkmm-3.0 or
# gtkmm-4.0, and this tree currently packages GTK but not gtkmm/glibmm/cairomm.
# Most auxiliary libraries are bundled and linked statically from upstream's
# third-party/ tree; libcurl, OpenSSL, and libpsl use our packaged builds.

SUBPROJECTS          += transmission
TRANSMISSION_VERSION := 4.1.3
DEB_TRANSMISSION_V   ?= $(TRANSMISSION_VERSION)+ios1

transmission-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/transmission/transmission/releases/download/$(TRANSMISSION_VERSION)/transmission-$(TRANSMISSION_VERSION).tar.xz)
	$(call EXTRACT_TAR,transmission-$(TRANSMISSION_VERSION).tar.xz,transmission-$(TRANSMISSION_VERSION),transmission)
	$(call DO_PATCH,transmission,transmission,-p1)
	rm -rf $(BUILD_WORK)/transmission/build
	mkdir -p $(BUILD_WORK)/transmission/build

ifneq ($(wildcard $(BUILD_WORK)/transmission/.build_complete),)
transmission:
	@echo "Using previously built transmission."
else
transmission: transmission-setup curl openssl libpsl
	cd $(BUILD_WORK)/transmission/build && cmake .. \
		-G Ninja \
		$(DEFAULT_CMAKE_FLAGS) \
		-DPKG_CONFIG_EXECUTABLE=$(BUILD_TOOLS)/cross-pkg-config \
		-DCMAKE_BUILD_TYPE=RelWithDebInfo \
		-DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
		-DWITH_CRYPTO=openssl \
		-DWITH_SYSTEMD=OFF \
		-DWITH_INOTIFY=OFF \
		-DWITH_KQUEUE=ON \
		-DENABLE_DAEMON=ON \
		-DENABLE_CLI=ON \
		-DENABLE_UTILS=ON \
		-DENABLE_GTK=OFF \
		-DENABLE_QT=OFF \
		-DENABLE_MAC=OFF \
		-DENABLE_TESTS=OFF \
		-DENABLE_NLS=OFF \
		-DENABLE_WERROR=OFF \
		-DRUN_CLANG_TIDY=OFF \
		-DINSTALL_DOC=OFF \
		-DINSTALL_WEB=ON \
		-DINSTALL_LIB=OFF \
		-DREBUILD_WEB=OFF \
		-DUSE_SYSTEM_EVENT2=OFF \
		-DUSE_SYSTEM_DEFLATE=OFF \
		-DUSE_SYSTEM_DHT=OFF \
		-DUSE_SYSTEM_MINIUPNPC=OFF \
		-DUSE_SYSTEM_NATPMP=OFF \
		-DUSE_SYSTEM_UTP=OFF \
		-DUSE_SYSTEM_B64=OFF \
		-DUSE_SYSTEM_PSL=ON
	+ninja -C $(BUILD_WORK)/transmission/build
	+DESTDIR="$(BUILD_STAGE)/transmission" ninja -C $(BUILD_WORK)/transmission/build install
	$(call AFTER_BUILD,copy)
endif

transmission-package: transmission-stage
	rm -rf $(BUILD_DIST)/transmission
	mkdir -p $(BUILD_DIST)/transmission/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	cp -a $(BUILD_STAGE)/transmission/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin \
		$(BUILD_DIST)/transmission/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	if [ -d "$(BUILD_STAGE)/transmission/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share" ]; then \
		cp -a $(BUILD_STAGE)/transmission/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share \
			$(BUILD_DIST)/transmission/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi
	rm -rf $(BUILD_DIST)/transmission/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/doc \
		$(BUILD_DIST)/transmission/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man

	$(call SIGN,transmission,general.xml)
	$(call PACK,transmission,DEB_TRANSMISSION_V)
	rm -rf $(BUILD_DIST)/transmission

.PHONY: transmission transmission-package
