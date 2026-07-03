ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# nghttp2.mk — Ladybird leaf closure. REUSE of the lean lib-only build (1.61.0, curl's HTTP/2
# dep). Identical to the GNOME-track override: `--enable-lib-only` so we get just libnghttp2 (no
# nghttpx/nghttpd/nghttp apps and therefore no nghttp3/ngtcp2/libev/jansson pull-in). On the
# ladybird volume this tree is already built + staged (build_work/nghttp2/.build_complete), so the
# `.build_complete` guard makes -package just repackage the existing dylib. Not a Ladybird pin;
# curl links it for http2. +ios1 deb marker.

SUBPROJECTS     += nghttp2
NGHTTP2_VERSION := 1.61.0
DEB_NGHTTP2_V   ?= $(NGHTTP2_VERSION)+ios1

nghttp2-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/nghttp2/nghttp2/releases/download/v$(NGHTTP2_VERSION)/nghttp2-$(NGHTTP2_VERSION).tar.xz)
	$(call EXTRACT_TAR,nghttp2-$(NGHTTP2_VERSION).tar.xz,nghttp2-$(NGHTTP2_VERSION),nghttp2)
	sed -i '1i #define\ __APPLE_USE_RFC_3542\ 1' $(BUILD_WORK)/nghttp2/src/util.cc

ifneq ($(wildcard $(BUILD_WORK)/nghttp2/.build_complete),)
nghttp2:
	@echo "Using previously built nghttp2."
else
nghttp2: nghttp2-setup
	cd $(BUILD_WORK)/nghttp2; \
	autoconf; \
	./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--disable-dependency-tracking \
		--enable-lib-only \
		--without-systemd \
		--enable-python-bindings=no
	+$(MAKE) -C $(BUILD_WORK)/nghttp2
	+$(MAKE) -C $(BUILD_WORK)/nghttp2 install \
		DESTDIR="$(BUILD_STAGE)/nghttp2"
	$(call AFTER_BUILD,copy)
endif

nghttp2-package: .SHELLFLAGS=-O extglob -c
nghttp2-package: nghttp2-stage
	# nghttp2.mk Package Structure (lib-only)
	rm -rf $(BUILD_DIST)/libnghttp2-{14,dev}
	mkdir -p $(BUILD_DIST)/libnghttp2-{14,dev}/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# nghttp2.mk Prep libnghttp2-14
	cp -a $(BUILD_STAGE)/nghttp2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libnghttp2.14.dylib $(BUILD_DIST)/libnghttp2-14/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# nghttp2.mk Prep libnghttp2-dev
	cp -a $(BUILD_STAGE)/nghttp2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libnghttp2.14.dylib) $(BUILD_DIST)/libnghttp2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/nghttp2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libnghttp2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,libnghttp2-14,general.xml)
	$(call PACK,libnghttp2-14,DEB_NGHTTP2_V)
	$(call PACK,libnghttp2-dev,DEB_NGHTTP2_V)

	rm -rf $(BUILD_DIST)/libnghttp2-{14,dev}

.PHONY: nghttp2 nghttp2-package
