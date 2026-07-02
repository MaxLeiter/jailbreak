ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# libutf8proc.mk — utf8proc, a small, single-file C library for UTF-8 processing / Unicode
# normalization + grapheme segmentation (github.com/JuliaStrings/utf8proc). fcft links it for
# grapheme shaping (-Dgrapheme-shaping=enabled) and foot pulls it transitively (both import
# `@rpath/libutf8proc.3.dylib`), yet no runtime deb was ever produced — the on-device smoke test
# hit `dyld: Library not loaded: @rpath/libutf8proc.3.dylib` launching foot. This recipe builds
# the SONAME-3 dylib and packages the runtime/-dev split (mirrors recipes/libgee.mk's split and
# the small-C-lib cross pattern of recipes/tllist.mk / recipes/fcft.mk).
#
# The upstream Makefile builds a plain `.dylib` on Darwin (OS=Darwin); its `install` lays down
# libutf8proc.3.dylib + the unversioned symlink + libutf8proc.a + utf8proc.h + pkgconfig. No
# meson/cross.txt is needed — the Procursus toolchain CC/AR/RANLIB are already exported into the
# sub-make, and utf8proc is pure portable C (no target execution). SONAME major = 3, so the
# runtime pkg is libutf8proc3; foot.control Depends on it.
#
# DEPENDS (target): none (self-contained, only libSystem).

SUBPROJECTS         += libutf8proc
LIBUTF8PROC_VERSION := 2.9.0
DEB_LIBUTF8PROC_V   ?= $(LIBUTF8PROC_VERSION)

libutf8proc-setup: setup
	$(call GITHUB_ARCHIVE,JuliaStrings,utf8proc,$(LIBUTF8PROC_VERSION),v$(LIBUTF8PROC_VERSION),libutf8proc)
	$(call EXTRACT_TAR,libutf8proc-$(LIBUTF8PROC_VERSION).tar.gz,utf8proc-$(LIBUTF8PROC_VERSION),libutf8proc)

ifneq ($(wildcard $(BUILD_WORK)/libutf8proc/.build_complete),)
libutf8proc:
	@echo "Using previously built libutf8proc."
else
libutf8proc: libutf8proc-setup
	+$(MAKE) -C $(BUILD_WORK)/libutf8proc install \
		OS=Darwin \
		prefix=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) \
		DESTDIR="$(BUILD_STAGE)/libutf8proc"
	$(call AFTER_BUILD,copy)
endif

libutf8proc-package: libutf8proc-stage
	# libutf8proc.mk Package Structure
	rm -rf $(BUILD_DIST)/libutf8proc{3,-dev}
	mkdir -p $(BUILD_DIST)/libutf8proc{3,-dev}/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libutf8proc.mk Prep libutf8proc-dev (headers, unversioned symlink, .a, .pc)
	cp -a $(BUILD_STAGE)/libutf8proc/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libutf8proc-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/libutf8proc/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/{pkgconfig,libutf8proc.{a,dylib}} $(BUILD_DIST)/libutf8proc-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libutf8proc.mk Prep libutf8proc3 (runtime SONAME dylib: libutf8proc.3.dylib)
	cp -a $(BUILD_STAGE)/libutf8proc/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libutf8proc.3.dylib $(BUILD_DIST)/libutf8proc3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libutf8proc.mk Sign
	$(call SIGN,libutf8proc-dev,general.xml)
	$(call SIGN,libutf8proc3,general.xml)

	# libutf8proc.mk Make .debs
	$(call PACK,libutf8proc-dev,DEB_LIBUTF8PROC_V)
	$(call PACK,libutf8proc3,DEB_LIBUTF8PROC_V)

	# libutf8proc.mk Build cleanup
	rm -rf $(BUILD_DIST)/libutf8proc{3,-dev}

.PHONY: libutf8proc libutf8proc-package
