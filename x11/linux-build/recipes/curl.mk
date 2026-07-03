ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# curl.mk — OVERRIDE of upstream Procursus curl for the GNOME (build-gnome.sh) track.
# Only here because AppStream 1.0 hard-requires libcurl. AppStream only needs basic HTTP(S)
# downloads, so this strips the heavy/blocking backends: libssh2, librtmp, c-ares, and HTTP/3
# tooling. Keep HTTP/2 via our lib-only nghttp2 recipe plus openssl (TLS) and
# zstd/brotli/libidn2 (already built in the volume → free). Result: a lean libcurl.4 that
# satisfies appstream's pkg-config probe without the HTTP/2+3 dependency tree.

SUBPROJECTS  += curl
CURL_VERSION := 8.7.1
DEB_CURL_V   ?= $(CURL_VERSION)+ios1

curl-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://curl.haxx.se/download/curl-$(CURL_VERSION).tar.xz{$(comma).asc})
	$(call PGP_VERIFY,curl-$(CURL_VERSION).tar.xz,asc)
	$(call EXTRACT_TAR,curl-$(CURL_VERSION).tar.xz,curl-$(CURL_VERSION),curl)
	sed -i '/CURL_VERIFY_RUNTIMELIBS/d' $(BUILD_WORK)/curl/configure.ac

ifneq ($(wildcard $(BUILD_WORK)/curl/.build_complete),)
curl:
	@echo "Using previously built curl."
else
curl: curl-setup gettext openssl libidn2 brotli zstd nghttp2
	cd $(BUILD_WORK)/curl && autoreconf -vi
	cd $(BUILD_WORK)/curl && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--with-openssl \
		--with-libidn2 \
		--with-brotli \
		--with-zstd \
		--with-nghttp2 \
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
