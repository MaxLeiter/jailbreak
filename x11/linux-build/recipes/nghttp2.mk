ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# nghttp2.mk — OVERRIDE for the GNOME track. libsoup3 needs libnghttp2 (HTTP/2). Upstream's
# recipe builds nghttp2's APP tools (nghttpx/nghttpd/nghttp) too, which deps nghttp3 + ngtcp2
# (HTTP/3) — and nghttp3 fails to cross-compile (std::invoke_result_t / C++17). libsoup only
# links libnghttp2, so build it `--enable-lib-only`: just the library, no apps, no nghttp3/ngtcp2
# (and none of the app-only deps libev/jansson/jemalloc/libevent/c-ares). Mirrors the lean
# approach in our curl.mk override.

SUBPROJECTS     += nghttp2
NGHTTP2_VERSION := 1.61.0
DEB_NGHTTP2_V   ?= $(NGHTTP2_VERSION)+ios1

nghttp2-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/nghttp2/nghttp2/releases/download/v$(NGHTTP2_VERSION)/nghttp2-$(NGHTTP2_VERSION).tar.xz)
	$(call EXTRACT_TAR,nghttp2-$(NGHTTP2_VERSION).tar.xz,nghttp2-$(NGHTTP2_VERSION),nghttp2)
	$(call DO_PATCH,nghttp2,nghttp2,-p1)

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

nghttp2-package: nghttp2-stage
	# nghttp2.mk Package Structure (lib-only: no nghttp2-{proxy,server,client} app debs)
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
