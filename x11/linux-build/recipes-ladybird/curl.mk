ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# curl.mk — Ladybird leaf closure. BUMP 8.7.1 -> 8.20.0 (Ladybird pin). This is a
# Ladybird-appropriate curl, distinct from the stripped GNOME-track override (which built for
# AppStream's basic-HTTPS probe). M0 feature set per ladybird-deps-plan.md:
#   openssl (TLS) + nghttp2 (http2) + zlib + brotli + libpsl + zstd + websockets.
# HTTP/3 is OFF for M0 (no nghttp3/ngtcp2/quictls). IDN (libidn2) is dropped — Ladybird does not
# need it and gtk-era libidn2 may linger in build_base, so we force --without-libidn2 to keep the
# link/Depends closure minimal. SSH/RTMP/c-ares off. +ios1 deb marker.
# Depends closure (dynamically linked): libssl3, libnghttp2-14, libpsl5, libzstd1, libbrotli1,
# libz1  (see build_info-ladybird/libcurl4.control override — no libidn2-0).

SUBPROJECTS  += curl
CURL_VERSION := 8.20.0
DEB_CURL_V   ?= $(CURL_VERSION)+ios1

curl-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://curl.se/download/curl-$(CURL_VERSION).tar.xz)
	# Stale-tree guard: the ladybird volume carries an OLD curl 8.7.1 tree in build_work. EXTRACT_TAR
	# no-ops when build_work/curl exists, so without a wipe the 8.7.1 source rebuilds mislabeled
	# $(CURL_VERSION)+ios1. The Wave-3 driver wipes the keyed path first; belt-and-suspenders here.
	if [ -d $(BUILD_WORK)/curl ] && ! grep -qs "$(CURL_VERSION)" $(BUILD_WORK)/curl/include/curl/curlver.h 2>/dev/null; then \
		echo "curl: stale source tree in build_work (not $(CURL_VERSION)), wiping"; \
		rm -rf $(BUILD_WORK)/curl $(BUILD_STAGE)/curl; \
	fi
	$(call EXTRACT_TAR,curl-$(CURL_VERSION).tar.xz,curl-$(CURL_VERSION),curl)
	$(call DO_PATCH,curl,curl,-p1)

ifneq ($(wildcard $(BUILD_WORK)/curl/.build_complete),)
curl:
	@echo "Using previously built curl."
else
curl: curl-setup openssl zlib brotli zstd nghttp2 libpsl
	cd $(BUILD_WORK)/curl && autoreconf -vi
	cd $(BUILD_WORK)/curl && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--with-openssl \
		--with-zlib \
		--with-brotli \
		--with-zstd \
		--with-nghttp2 \
		--with-libpsl \
		--enable-websockets \
		--without-libidn2 \
		--without-nghttp3 \
		--without-ngtcp2 \
		--without-libssh2 \
		--without-librtmp \
		--disable-ares \
		--with-ca-bundle=$(MEMO_PREFIX)/etc/ssl/certs/cacert.pem
	+$(MAKE) -C $(BUILD_WORK)/curl
	+$(MAKE) -C $(BUILD_WORK)/curl install \
		DESTDIR="$(BUILD_STAGE)/curl"
	$(call AFTER_BUILD,copy)
endif

curl-package: curl-stage
	# curl.mk Package Structure
	rm -rf $(BUILD_DIST)/curl \
		$(BUILD_DIST)/libcurl4{,-openssl-dev}
	mkdir -p $(BUILD_DIST)/curl/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{bin,share/man/man1} \
		$(BUILD_DIST)/libcurl4-openssl-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{bin,lib,share/man/man1} \
		$(BUILD_DIST)/libcurl4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# curl.mk Prep curl
	cp -a $(BUILD_STAGE)/curl/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/curl $(BUILD_DIST)/curl/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin
	cp -a $(BUILD_STAGE)/curl/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man/man1/curl.1$(MEMO_MANPAGE_SUFFIX) $(BUILD_DIST)/curl/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man/man1

	# curl.mk Prep libcurl4
	cp -a $(BUILD_STAGE)/curl/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libcurl.4.dylib $(BUILD_DIST)/libcurl4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# curl.mk Prep libcurl4-openssl-dev
	cp -a $(BUILD_STAGE)/curl/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/{pkgconfig,libcurl.{dylib,a}} $(BUILD_DIST)/libcurl4-openssl-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/curl/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man/man1/curl-config.1$(MEMO_MANPAGE_SUFFIX) $(BUILD_DIST)/libcurl4-openssl-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man/man1
	cp -a $(BUILD_STAGE)/curl/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man/man3 $(BUILD_DIST)/libcurl4-openssl-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man
	cp -a $(BUILD_STAGE)/curl/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/curl-config $(BUILD_DIST)/libcurl4-openssl-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin
	cp -a $(BUILD_STAGE)/curl/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libcurl4-openssl-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	# curl.mk Sign
	$(call SIGN,curl,general.xml)
	$(call SIGN,libcurl4,general.xml)
	$(call SIGN,libcurl4-openssl-dev,general.xml)

	# curl.mk Make .debs
	$(call PACK,curl,DEB_CURL_V)
	$(call PACK,libcurl4,DEB_CURL_V)
	$(call PACK,libcurl4-openssl-dev,DEB_CURL_V)

	# curl.mk Build cleanup
	rm -rf $(BUILD_DIST)/curl \
		$(BUILD_DIST)/libcurl4{,-openssl-dev}

.PHONY: curl curl-package
