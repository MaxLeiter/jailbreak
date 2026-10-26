ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

STRAPPROJECTS  += gnutls
# 3.8.5 -> 3.8.13: 20 advisories fixed in 3.8.9..3.8.13 (CVE-2026-42010 RSA-PSK
# auth bypass, CVE-2026-33845/33846 DTLS heap overruns, the name-constraint
# bypasses, CVE-2025-32989, CVE-2024-12243, ...). Soname libgnutls.30 unchanged.
# Built against the nettle 3.10.2 / libtasn1 4.21.0 / p11-kit 0.26.5 / libidn2
# 2.3.8 from this batch, so build_info/libgnutls30.control (and xx30, gnutls-bin)
# version those Depends: apt links gnutls, and it must never meet nettle 3.9.1.
GNUTLS_VERSION := 3.8.13
DEB_GNUTLS_V   ?= $(GNUTLS_VERSION)+ios1

gnutls-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://www.gnupg.org/ftp/gcrypt/gnutls/v$(shell echo $(GNUTLS_VERSION) | cut -d. -f-2)/gnutls-$(GNUTLS_VERSION).tar.xz)
	$(call EXTRACT_TAR,gnutls-$(GNUTLS_VERSION).tar.xz,gnutls-$(GNUTLS_VERSION),gnutls)
	sed -i 's/-keep_private_externs -nostdlib/-keep_private_externs $(PLATFORM_VERSION_MIN) -arch $(MEMO_ARCH) -nostdlib/g' $(BUILD_WORK)/gnutls/configure

ifneq ($(wildcard $(BUILD_WORK)/gnutls/.build_complete),)
gnutls:
	@echo "Using previously built gnutls."
else
gnutls: gnutls-setup readline gettext libgcrypt libgmp10 libidn2 libunistring nettle p11-kit brotli zstd
	find $(BUILD_BASE) -name "*.la" -type f -delete
	cd $(BUILD_WORK)/gnutls && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--disable-guile \
		--enable-local-libopts \
		--with-default-trust-store-file=$(MEMO_PREFIX)/etc/ssl/certs/cacert.pem \
		ac_cv_func_malloc_0_nonnull=yes \
		ac_cv_func_realloc_0_nonnull=yes \
		P11_KIT_CFLAGS=-I$(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/p11-kit-1
	+$(MAKE) -C $(BUILD_WORK)/gnutls
	+$(MAKE) -C $(BUILD_WORK)/gnutls install \
		DESTDIR=$(BUILD_STAGE)/gnutls
	$(call AFTER_BUILD,copy)
endif

gnutls-package: gnutls-stage
	# gnutls.mk Package Structure
	rm -rf $(BUILD_DIST)/gnutls-bin \
		$(BUILD_DIST)/libgnutls30 \
		$(BUILD_DIST)/libgnutlsxx30 \
		$(BUILD_DIST)/libgnutls30-dev
	mkdir -p $(BUILD_DIST)/gnutls-bin/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) \
		$(BUILD_DIST)/libgnutls30/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libgnutlsxx30/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libgnutls30-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# gnutls.mk Prep gnutls-bin
	cp -a $(BUILD_STAGE)/gnutls/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/gnutls-bin/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	# gnutls.mk Prep libgnutls30
	cp -a $(BUILD_STAGE)/gnutls/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgnutls.30.dylib $(BUILD_DIST)/libgnutls30/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# gnutls.mk Prep libgnutlsxx30
	cp -a $(BUILD_STAGE)/gnutls/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgnutlsxx.30.dylib $(BUILD_DIST)/libgnutlsxx30/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# gnutls.mk Prep libgnutls30-dev
	cp -a $(BUILD_STAGE)/gnutls/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/{pkgconfig,libgnutls{,xx}.dylib} $(BUILD_DIST)/libgnutls30-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/gnutls/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libgnutls30-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	# gnutls.mk Sign
	$(call SIGN,gnutls-bin,general.xml)
	$(call SIGN,libgnutls30,general.xml)
	$(call SIGN,libgnutlsxx30,general.xml)

	# gnutls.mk Make .debs
	$(call PACK,gnutls-bin,DEB_GNUTLS_V)
	$(call PACK,libgnutls30,DEB_GNUTLS_V)
	$(call PACK,libgnutlsxx30,DEB_GNUTLS_V)
	$(call PACK,libgnutls30-dev,DEB_GNUTLS_V)

	# gnutls.mk Build cleanup
	rm -rf $(BUILD_DIST)/gnutls-bin \
		$(BUILD_DIST)/libgnutls30 \
		$(BUILD_DIST)/libgnutlsxx30 \
		$(BUILD_DIST)/libgnutls30-dev

.PHONY: gnutls gnutls-package
