ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Header-only (INTERFACE library): no dylib, just headers + CMake config + pkgconfig.
# Ships a single -dev deb.

SUBPROJECTS         += fast-float
FASTFLOAT_VERSION   := 8.1.0
DEB_FASTFLOAT_V     ?= $(FASTFLOAT_VERSION)+ios1

fast-float-setup: setup
	$(call GITHUB_ARCHIVE,fastfloat,fast_float,$(FASTFLOAT_VERSION),v$(FASTFLOAT_VERSION))
	$(call EXTRACT_TAR,fast_float-$(FASTFLOAT_VERSION).tar.gz,fast_float-$(FASTFLOAT_VERSION),fast-float)

ifneq ($(wildcard $(BUILD_WORK)/fast-float/.build_complete),)
fast-float:
	@echo "Using previously built fast-float."
else
fast-float: fast-float-setup
	cd $(BUILD_WORK)/fast-float && cmake . \
		$(DEFAULT_CMAKE_FLAGS) \
		-DFASTFLOAT_TEST=OFF \
		-DFASTFLOAT_INSTALL=ON
	+$(MAKE) -C $(BUILD_WORK)/fast-float install \
		DESTDIR="$(BUILD_STAGE)/fast-float"
	$(call AFTER_BUILD,copy)
endif

fast-float-package: fast-float-stage
	rm -rf $(BUILD_DIST)/fast-float-dev
	mkdir -p $(BUILD_DIST)/fast-float-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	cp -a $(BUILD_STAGE)/fast-float/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/fast-float-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	-cp -a $(BUILD_STAGE)/fast-float/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib $(BUILD_DIST)/fast-float-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	-cp -a $(BUILD_STAGE)/fast-float/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/fast-float-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	# no binaries produced -> no SIGN call needed
	$(call PACK,fast-float-dev,DEB_FASTFLOAT_V)

	rm -rf $(BUILD_DIST)/fast-float-dev

.PHONY: fast-float fast-float-package
