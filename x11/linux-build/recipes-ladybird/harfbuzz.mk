ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# harfbuzz.mk — Ladybird leaf closure. NEW meson recipe at 10.2.0 (the old autotools --without-icu
# recipe is dead: harfbuzz dropped autotools at 8.0, and Ladybird REQUIRES -Dicu=enabled). Builds
# WITH freetype + ICU 78.3 (both staged), everything else off (glib/gobject/cairo/graphite2/chafa/
# utilities/tests/docs/introspection disabled) to keep the closure tight. Meson cross build mirrors
# graphene.mk's cross.txt; CC/CXX route through the cc-nounused wrappers so meson's link probe
# survives the Procursus wrapper's -Wl,-adhoc_codesign injection. Produces libharfbuzz.0,
# libharfbuzz-subset.0, libharfbuzz-icu.0. The driver wipes the staged gtk-era 2.8.1 shadow first.
# +ios1 marker.

SUBPROJECTS      += harfbuzz
HARFBUZZ_VERSION := 10.2.0
DEB_HARFBUZZ_V   ?= $(HARFBUZZ_VERSION)+ios1

harfbuzz-setup: setup
	$(call GITHUB_ARCHIVE,harfbuzz,harfbuzz,$(HARFBUZZ_VERSION),$(HARFBUZZ_VERSION))
	# Stale-tree guard: wipe a mismatched (gtk-era 2.8.1) tree so 10.2.0 extracts.
	if [ -d $(BUILD_WORK)/harfbuzz ] && ! grep -q "version: '$(HARFBUZZ_VERSION)'" $(BUILD_WORK)/harfbuzz/meson.build 2>/dev/null; then \
		echo "harfbuzz: stale source tree (not $(HARFBUZZ_VERSION)), wiping"; \
		rm -rf $(BUILD_WORK)/harfbuzz $(BUILD_STAGE)/harfbuzz; \
	fi
	$(call EXTRACT_TAR,harfbuzz-$(HARFBUZZ_VERSION).tar.gz,harfbuzz-$(HARFBUZZ_VERSION),harfbuzz)
	rm -rf $(BUILD_WORK)/harfbuzz/build
	mkdir -p $(BUILD_WORK)/harfbuzz/build
	echo -e "[host_machine]\n \
	system = 'darwin'\n \
	cpu_family = '$(shell echo $(GNU_HOST_TRIPLE) | cut -d- -f1)'\n \
	cpu = '$(MEMO_ARCH)'\n \
	endian = 'little'\n \
	[properties]\n \
	root = '$(BUILD_BASE)'\n \
	needs_exe_wrapper = true\n \
	[built-in options]\n \
	prefix ='$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)'\n \
	[binaries]\n \
	c = '$(CC)'\n \
	cpp = '$(CXX)'\n \
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/harfbuzz/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/harfbuzz/.build_complete),)
harfbuzz:
	@echo "Using previously built harfbuzz."
else
# NOTE: ICU 78.3 is pre-staged in BUILD_BASE (icu4c is DONE, do not rebuild) — depend only on
# freetype (built this wave); harfbuzz finds icu-uc/icu-i18n via cross-pkg-config.
harfbuzz: harfbuzz-setup freetype
	cd $(BUILD_WORK)/harfbuzz/build && meson \
		--cross-file cross.txt \
		--default-library shared \
		-Dicu=enabled \
		-Dfreetype=enabled \
		-Dglib=disabled \
		-Dgobject=disabled \
		-Dcairo=disabled \
		-Dgraphite2=disabled \
		-Dchafa=disabled \
		-Dcoretext=disabled \
		-Dintrospection=disabled \
		-Dutilities=disabled \
		-Dtests=disabled \
		-Ddocs=disabled \
		..
	cd $(BUILD_WORK)/harfbuzz/build; \
		DESTDIR="$(BUILD_STAGE)/harfbuzz" meson install
	$(call AFTER_BUILD,copy)
endif

harfbuzz-package: .SHELLFLAGS=-O extglob -c
harfbuzz-package: harfbuzz-stage
	# harfbuzz.mk Package Structure
	rm -rf $(BUILD_DIST)/libharfbuzz{0b,-dev,-icu0,-subset0}
	mkdir -p $(BUILD_DIST)/libharfbuzz{0b,-icu0,-subset0,-dev}/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# harfbuzz.mk Prep libharfbuzz0b (core shaping engine)
	cp -a $(BUILD_STAGE)/harfbuzz/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libharfbuzz.0.dylib $(BUILD_DIST)/libharfbuzz0b/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# harfbuzz.mk Prep libharfbuzz-icu0 (ICU backend)
	cp -a $(BUILD_STAGE)/harfbuzz/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libharfbuzz-icu.0.dylib $(BUILD_DIST)/libharfbuzz-icu0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# harfbuzz.mk Prep libharfbuzz-subset0 (subset backend)
	cp -a $(BUILD_STAGE)/harfbuzz/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libharfbuzz-subset.0.dylib $(BUILD_DIST)/libharfbuzz-subset0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# harfbuzz.mk Prep libharfbuzz-dev (headers, unversioned dylibs, pkgconfig)
	cp -a $(BUILD_STAGE)/harfbuzz/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libharfbuzz-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/harfbuzz/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(*.0.dylib) $(BUILD_DIST)/libharfbuzz-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# harfbuzz.mk Sign
	$(call SIGN,libharfbuzz0b,general.xml)
	$(call SIGN,libharfbuzz-icu0,general.xml)
	$(call SIGN,libharfbuzz-subset0,general.xml)

	# harfbuzz.mk Make .debs
	$(call PACK,libharfbuzz0b,DEB_HARFBUZZ_V)
	$(call PACK,libharfbuzz-icu0,DEB_HARFBUZZ_V)
	$(call PACK,libharfbuzz-subset0,DEB_HARFBUZZ_V)
	$(call PACK,libharfbuzz-dev,DEB_HARFBUZZ_V)

	# harfbuzz.mk Build cleanup
	rm -rf $(BUILD_DIST)/libharfbuzz{0b,-dev,-icu0,-subset0}

.PHONY: harfbuzz harfbuzz-package
