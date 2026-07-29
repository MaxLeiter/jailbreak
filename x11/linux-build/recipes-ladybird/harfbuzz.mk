ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Meson-only build (harfbuzz dropped autotools at 8.0); Ladybird requires -Dicu=enabled.
# CC/CXX go through cc-nounused wrappers so meson's link probe survives Procursus's
# -Wl,-adhoc_codesign injection.
#
# EVERY backend is on, deliberately. This package name shadows Procursus's harfbuzz
# 2.8.1, so it must be a strict SUPERSET of it or consumers linked against theirs
# lose symbols at load. +ios1 shipped with glib/gobject/coretext/graphite2 disabled
# and dropped _hb_glib_*, _hb_coretext_* and _hb_graphite2_*; libgtk-4.1.dylib binds
# _hb_glib_script_to_script, so every GTK4 app died with "Symbol not found" the
# moment that deb landed (found on device 2026-07-29). Do not disable a backend
# here to shorten a build: check `nm -gU` against the Procursus dylib first, which
# is exactly what bin/lib/check-procursus-shadow.py does at publish time.

SUBPROJECTS      += harfbuzz
HARFBUZZ_VERSION := 10.2.0
DEB_HARFBUZZ_V   ?= $(HARFBUZZ_VERSION)+ios2

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
# ICU, glib and graphite2 are pre-staged in BUILD_BASE already; only depend on freetype
# here (icu-uc/icu-i18n/glib-2.0/gobject-2.0/graphite2 resolve via cross-pkg-config).
# utilities=enabled keeps hb-subset/hb-shape in the same family as the libs they link;
# the old 2.8.1 hb-subset imported _hb_subset, deleted upstream at 3.0.
harfbuzz: harfbuzz-setup freetype
	cd $(BUILD_WORK)/harfbuzz/build && meson \
		--cross-file cross.txt \
		--default-library shared \
		-Dicu=enabled \
		-Dfreetype=enabled \
		-Dglib=enabled \
		-Dgobject=enabled \
		-Dcairo=disabled \
		-Dgraphite2=enabled \
		-Dchafa=disabled \
		-Dcoretext=enabled \
		-Dintrospection=disabled \
		-Dutilities=enabled \
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
	rm -rf $(BUILD_DIST)/libharfbuzz{0b,-dev,-icu0,-subset0,-gobject0,-bin}
	mkdir -p $(BUILD_DIST)/libharfbuzz{0b,-icu0,-subset0,-gobject0,-dev}/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	mkdir -p $(BUILD_DIST)/libharfbuzz-bin/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin

	# harfbuzz.mk Prep libharfbuzz0b (core shaping engine)
	cp -a $(BUILD_STAGE)/harfbuzz/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libharfbuzz.0.dylib $(BUILD_DIST)/libharfbuzz0b/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# harfbuzz.mk Prep libharfbuzz-icu0 (ICU backend)
	cp -a $(BUILD_STAGE)/harfbuzz/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libharfbuzz-icu.0.dylib $(BUILD_DIST)/libharfbuzz-icu0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# harfbuzz.mk Prep libharfbuzz-subset0 (subset backend)
	cp -a $(BUILD_STAGE)/harfbuzz/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libharfbuzz-subset.0.dylib $(BUILD_DIST)/libharfbuzz-subset0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# harfbuzz.mk Prep libharfbuzz-gobject0 (GObject bindings; keeps the family at one version)
	cp -a $(BUILD_STAGE)/harfbuzz/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libharfbuzz-gobject.0.dylib $(BUILD_DIST)/libharfbuzz-gobject0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# harfbuzz.mk Prep libharfbuzz-bin (hb-shape / hb-subset / hb-ot-shape-closure)
	cp -a $(BUILD_STAGE)/harfbuzz/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/hb-* $(BUILD_DIST)/libharfbuzz-bin/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin

	# harfbuzz.mk Prep libharfbuzz-dev (headers, unversioned dylibs, pkgconfig)
	cp -a $(BUILD_STAGE)/harfbuzz/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libharfbuzz-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/harfbuzz/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(*.0.dylib) $(BUILD_DIST)/libharfbuzz-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# harfbuzz.mk Sign
	$(call SIGN,libharfbuzz0b,general.xml)
	$(call SIGN,libharfbuzz-icu0,general.xml)
	$(call SIGN,libharfbuzz-subset0,general.xml)
	$(call SIGN,libharfbuzz-gobject0,general.xml)
	$(call SIGN,libharfbuzz-bin,general.xml)

	# harfbuzz.mk Make .debs
	$(call PACK,libharfbuzz0b,DEB_HARFBUZZ_V)
	$(call PACK,libharfbuzz-icu0,DEB_HARFBUZZ_V)
	$(call PACK,libharfbuzz-subset0,DEB_HARFBUZZ_V)
	$(call PACK,libharfbuzz-gobject0,DEB_HARFBUZZ_V)
	$(call PACK,libharfbuzz-bin,DEB_HARFBUZZ_V)
	$(call PACK,libharfbuzz-dev,DEB_HARFBUZZ_V)

	# harfbuzz.mk Build cleanup
	rm -rf $(BUILD_DIST)/libharfbuzz{0b,-dev,-icu0,-subset0,-gobject0,-bin}

.PHONY: harfbuzz harfbuzz-package
