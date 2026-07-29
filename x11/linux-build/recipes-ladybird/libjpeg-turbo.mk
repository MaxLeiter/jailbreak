ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# WITH_JPEG8=ON matches Debian's libjpeg62-turbo convention (v6.2 soname, API v8) —
# consumers linking against libjpeg62-turbo expect the v8 API.

SUBPROJECTS           += libjpeg-turbo
LIBJPEG_TURBO_VERSION := 3.1.1
DEB_LIBJPEG_TURBO_V   ?= $(LIBJPEG_TURBO_VERSION)+ios1

libjpeg-turbo-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE), \
		https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/$(LIBJPEG_TURBO_VERSION)/libjpeg-turbo-$(LIBJPEG_TURBO_VERSION).tar.gz)
	# Stale-tree guard: wipe a mismatched (gtk-era 2.0.6) tree so 3.1.1 extracts.
	if [ -d $(BUILD_WORK)/libjpeg-turbo ] && ! grep -q "VERSION $(LIBJPEG_TURBO_VERSION)" $(BUILD_WORK)/libjpeg-turbo/CMakeLists.txt 2>/dev/null; then \
		echo "libjpeg-turbo: stale source tree (not $(LIBJPEG_TURBO_VERSION)), wiping"; \
		rm -rf $(BUILD_WORK)/libjpeg-turbo $(BUILD_STAGE)/libjpeg-turbo; \
	fi
	$(call EXTRACT_TAR,libjpeg-turbo-$(LIBJPEG_TURBO_VERSION).tar.gz,libjpeg-turbo-$(LIBJPEG_TURBO_VERSION),libjpeg-turbo)

ifneq ($(wildcard $(BUILD_WORK)/libjpeg-turbo/.build_complete),)
libjpeg-turbo:
	@echo "Using previously built libjpeg-turbo."
else
libjpeg-turbo: libjpeg-turbo-setup
	cd $(BUILD_WORK)/libjpeg-turbo && cmake . \
		$(DEFAULT_CMAKE_FLAGS) \
		-DENABLE_SHARED=ON \
		-DENABLE_STATIC=ON \
		-DWITH_TURBOJPEG=ON \
		-DWITH_SIMD=ON \
		-DWITH_JPEG8=ON
	+$(MAKE) -C $(BUILD_WORK)/libjpeg-turbo
	+$(MAKE) -C $(BUILD_WORK)/libjpeg-turbo install \
		DESTDIR="$(BUILD_STAGE)/libjpeg-turbo"
	$(call AFTER_BUILD,copy)
endif

libjpeg-turbo-package: libjpeg-turbo-stage
	# libjpeg-turbo.mk Package Structure
	rm -rf \
		$(BUILD_DIST)/libjpeg62-{turbo,turbo-dev} \
		$(BUILD_DIST)/{libjpeg-turbo-progs,libturbojpeg0{,-dev}}
	mkdir -p \
		$(BUILD_DIST)/libjpeg-turbo-progs/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{bin,share} \
		$(BUILD_DIST)/{libjpeg62-turbo,libturbojpeg0}/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/{libjpeg62-turbo-dev,libturbojpeg0-dev}/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{include,lib/pkgconfig}

	# libjpeg-turbo.mk Prep libjpeg-turbo-progs
	cp -a $(BUILD_STAGE)/libjpeg-turbo/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/* $(BUILD_DIST)/libjpeg-turbo-progs/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin
	-cp -a $(BUILD_STAGE)/libjpeg-turbo/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man $(BUILD_DIST)/libjpeg-turbo-progs/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share

	# libjpeg-turbo.mk Prep libjpeg62-turbo-dev
	cp -a $(BUILD_STAGE)/libjpeg-turbo/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/j*.h $(BUILD_DIST)/libjpeg62-turbo-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include
	cp -a $(BUILD_STAGE)/libjpeg-turbo/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libjpeg.{a,dylib} $(BUILD_DIST)/libjpeg62-turbo-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libjpeg-turbo/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/libjpeg.pc $(BUILD_DIST)/libjpeg62-turbo-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig

	# libjpeg-turbo.mk Prep libjpeg62-turbo
	cp -a $(BUILD_STAGE)/libjpeg-turbo/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libjpeg.62*.dylib $(BUILD_DIST)/libjpeg62-turbo/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libjpeg-turbo.mk Prep libturbojpeg0-dev
	cp -a $(BUILD_STAGE)/libjpeg-turbo/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/turbojpeg.h $(BUILD_DIST)/libturbojpeg0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include
	cp -a $(BUILD_STAGE)/libjpeg-turbo/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libturbojpeg.{a,dylib} $(BUILD_DIST)/libturbojpeg0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libjpeg-turbo/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/libturbojpeg.pc $(BUILD_DIST)/libturbojpeg0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig

	# libjpeg-turbo.mk Prep libturbojpeg0
	cp -a $(BUILD_STAGE)/libjpeg-turbo/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libturbojpeg.0*.dylib $(BUILD_DIST)/libturbojpeg0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libjpeg-turbo.mk Sign
	$(call SIGN,libjpeg-turbo-progs,general.xml)
	$(call SIGN,libjpeg62-turbo-dev,general.xml)
	$(call SIGN,libjpeg62-turbo,general.xml)
	$(call SIGN,libturbojpeg0-dev,general.xml)
	$(call SIGN,libturbojpeg0,general.xml)

	# libjpeg-turbo.mk Make .debs
	$(call PACK,libjpeg-turbo-progs,DEB_LIBJPEG_TURBO_V)
	$(call PACK,libjpeg62-turbo-dev,DEB_LIBJPEG_TURBO_V)
	$(call PACK,libjpeg62-turbo,DEB_LIBJPEG_TURBO_V)
	$(call PACK,libturbojpeg0-dev,DEB_LIBJPEG_TURBO_V)
	$(call PACK,libturbojpeg0,DEB_LIBJPEG_TURBO_V)

	# libjpeg-turbo.mk Build cleanup
	rm -rf \
		$(BUILD_DIST)/libjpeg62-{turbo,turbo-dev} \
		$(BUILD_DIST)/{libjpeg-turbo-progs,libturbojpeg0{,-dev}}

.PHONY: libjpeg-turbo libjpeg-turbo-package
