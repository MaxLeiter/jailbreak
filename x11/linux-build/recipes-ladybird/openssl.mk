ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

SUBPROJECTS     += openssl
OPENSSL_VERSION := 3.5.3
DEB_OPENSSL_V   ?= $(OPENSSL_VERSION)+ios1

openssl-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/openssl/openssl/releases/download/openssl-$(OPENSSL_VERSION)/openssl-$(OPENSSL_VERSION).tar.gz)
	# Stale-tree guard (ICU/gtk-clone lesson): this volume carries an OLD openssl 3.2.1 tree in
	# build_work. EXTRACT_TAR no-ops when build_work/openssl exists, so without a wipe the 3.2.1
	# source would rebuild mislabeled $(OPENSSL_VERSION)+ios1. The Wave-3 driver wipes the keyed
	# build_work path before calling; this is belt-and-suspenders in case the recipe is run raw.
	if [ -d $(BUILD_WORK)/openssl ] && ! grep -qs "3\.5\.3" $(BUILD_WORK)/openssl/VERSION.dat 2>/dev/null; then \
		echo "openssl: stale source tree in build_work (not $(OPENSSL_VERSION)), wiping"; \
		rm -rf $(BUILD_WORK)/openssl $(BUILD_STAGE)/openssl; \
	fi
	$(call EXTRACT_TAR,openssl-$(OPENSSL_VERSION).tar.gz,openssl-$(OPENSSL_VERSION),openssl)

ifneq ($(wildcard $(BUILD_WORK)/openssl/.build_complete),)
openssl:
	@echo "Using previously built openssl."
else
openssl: openssl-setup
	touch $(BUILD_WORK)/openssl/Configurations/15-openssl.conf
	# These targets (armv7k/armv7/arm64_32) are unused on arm64 — Configure below resolves
	# to OpenSSL's stock darwin64-arm64 target instead.
	@echo -e "my %targets = (\n\
		\"darwin64-armv7k\" => {\n\
			inherit_from     => [ \"darwin-common\" ],\n\
			CC               => add(\"-Wall\"),\n\
			cflags           => add(\"-arch armv7k\"),\n\
			lib_cppflags     => add(\"-DL_ENDIAN\"),\n\
			perlasm_scheme   => \"ios32\",\n\
			disable          => [ \"async\" ],\n\
		},\n\
		\"darwin64-armv7\" => {\n\
			inherit_from     => [ \"darwin-common\" ],\n\
			CC               => add(\"-Wall\"),\n\
			cflags           => add(\"-arch armv7\"),\n\
			lib_cppflags     => add(\"-DL_ENDIAN\"),\n\
			perlasm_scheme   => \"ios32\",\n\
			disable          => [ \"async\" ],\n\
		},\n\
		\"darwin64-arm64_32\" => {\n\
			inherit_from     => [ \"darwin-common\" ],\n\
			CC               => add(\"-Wall\"),\n\
			cflags           => add(\"-arch arm64_32\"),\n\
			lib_cppflags     => add(\"-DL_ENDIAN\"),\n\
			perlasm_scheme   => \"ios64\",\n\
		},\n\
	);" > $(BUILD_WORK)/openssl/Configurations/15-openssl.conf
	cd $(BUILD_WORK)/openssl && ./Configure \
		--prefix=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) \
		--openssldir=$(MEMO_PREFIX)/etc/ssl \
		shared \
		no-tests \
		darwin64-$$(echo $(LLVM_TARGET) | cut -f1 -d-)
	+$(MAKE) -C $(BUILD_WORK)/openssl
	+$(MAKE) -C $(BUILD_WORK)/openssl install install_ssldirs \
		DESTDIR=$(BUILD_STAGE)/openssl
	$(call AFTER_BUILD,copy)
endif

openssl-package: openssl-stage
	# openssl.mk Package Structure
	rm -rf $(BUILD_DIST)/{openssl,libssl{3,-dev,-doc}}
	mkdir -p $(BUILD_DIST)/{openssl/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin,libssl{3,-dev}/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib} \
		$(BUILD_DIST)/libssl-doc/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/

	# openssl.mk Prep libssl3
	cp -a $(BUILD_STAGE)/openssl/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/{*.3.dylib,engines-3,ossl-modules} $(BUILD_DIST)/libssl3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# openssl.mk Prep libssl-dev
	cp -a $(BUILD_STAGE)/openssl/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/{lib{ssl,crypto}.{a,dylib},pkgconfig} $(BUILD_DIST)/libssl-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/openssl/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libssl-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	# openssl.mk Prep libssl-doc
	cp -a $(BUILD_STAGE)/openssl/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man $(BUILD_DIST)/libssl-doc/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/

	# openssl.mk Prep openssl
	cp -a $(BUILD_STAGE)/openssl/$(MEMO_PREFIX)/etc $(BUILD_DIST)/openssl/$(MEMO_PREFIX)
	cp -a $(BUILD_STAGE)/openssl/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/* $(BUILD_DIST)/openssl/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin

	# openssl.mk Sign
	$(call SIGN,libssl3,general.xml)
	$(call SIGN,openssl,general.xml)

	# openssl.mk Make .debs
	$(call PACK,libssl3,DEB_OPENSSL_V)
	$(call PACK,libssl-dev,DEB_OPENSSL_V)
	$(call PACK,libssl-doc,DEB_OPENSSL_V)
	$(call PACK,openssl,DEB_OPENSSL_V)

	# openssl.mk Build cleanup
	rm -rf $(BUILD_DIST)/{openssl,libssl{3,-dev,-doc}}

.PHONY: openssl openssl-package
