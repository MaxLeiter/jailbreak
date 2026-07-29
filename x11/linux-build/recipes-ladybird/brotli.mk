ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

STRAPPROJECTS    += brotli
BROTLI_VERSION   := 1.1.0
DEB_BROTLI_V     ?= $(BROTLI_VERSION)+ios1

brotli-setup: setup
	$(call GITHUB_ARCHIVE,google,brotli,$(BROTLI_VERSION),v$(BROTLI_VERSION))
	$(call EXTRACT_TAR,brotli-$(BROTLI_VERSION).tar.gz,brotli-$(BROTLI_VERSION),brotli)

ifneq ($(wildcard $(BUILD_WORK)/brotli/.build_complete),)
brotli:
	@echo "Using previously built brotli."
else
brotli: brotli-setup
	# First build static
	cd $(BUILD_WORK)/brotli && cmake . \
		$(DEFAULT_CMAKE_FLAGS) \
		-DBUILD_SHARED_LIBS=OFF
	+$(MAKE) -C $(BUILD_WORK)/brotli
	+$(MAKE) -C $(BUILD_WORK)/brotli install \
		DESTDIR="$(BUILD_STAGE)/brotli"
	# Then build dynamic
	cd $(BUILD_WORK)/brotli && cmake . \
		$(DEFAULT_CMAKE_FLAGS) \
		-DBUILD_SHARED_LIBS=ON
	+$(MAKE) -C $(BUILD_WORK)/brotli
	+$(MAKE) -C $(BUILD_WORK)/brotli install \
		DESTDIR="$(BUILD_STAGE)/brotli"
	$(call AFTER_BUILD,copy)
endif

brotli-package: brotli-stage
	rm -rf $(BUILD_DIST)/{brotli,libbrotli-dev,libbrotli1}
	mkdir -p $(BUILD_DIST)/brotli/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{bin,share/man/man1} \
			$(BUILD_DIST)/libbrotli-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{include/brotli,lib/pkgconfig} \
			$(BUILD_DIST)/libbrotli1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/brotli/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/brotli $(BUILD_DIST)/brotli/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin
	cp -a $(BUILD_WORK)/brotli/docs/brotli.1 $(BUILD_DIST)/brotli/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man/man1

	cp -a $(BUILD_STAGE)/brotli/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/brotli/{decode,encode,port,types}.h $(BUILD_DIST)/libbrotli-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/brotli
	cp -a $(BUILD_STAGE)/brotli/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libbrotli{common,dec,enc}.{a,dylib} $(BUILD_DIST)/libbrotli-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/brotli/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/libbrotli{common,dec,enc}.pc $(BUILD_DIST)/libbrotli-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig

	cp -a $(BUILD_STAGE)/brotli/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libbrotli{common,dec,enc}.1*.dylib $(BUILD_DIST)/libbrotli1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	$(call SIGN,brotli,general.xml)
	$(call SIGN,libbrotli1,general.xml)

	$(call PACK,brotli,DEB_BROTLI_V)
	$(call PACK,libbrotli-dev,DEB_BROTLI_V)
	$(call PACK,libbrotli1,DEB_BROTLI_V)

	rm -rf $(BUILD_DIST)/{brotli,libbrotli-dev,libbrotli1}

.PHONY: brotli brotli-package
