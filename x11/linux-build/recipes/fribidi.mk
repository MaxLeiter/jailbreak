ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Drop-in replacement for Procursus libfribidi0/libfribidi-dev/libfribidi-bin 1.0.10
# (CVE-2022-25308/25309/25310, fixed in 1.0.12).
#
# Built with AUTOTOOLS on purpose. The 1.0.13 meson build we tried in July exported
# 36 symbols against Procursus's 49: lib/meson.build sets gnu_symbol_visibility
# 'hidden' and the char-set helpers carry no FRIBIDI_ENTRY. lib/Makefile.am
# instead exports by -export-symbols-regex "^fribidi_.*", which is what
# Procursus's own build did, so every one of the 49 survives. See the
# _comment_fribidi note in bin/lib/shadow-waivers.json.
#
# libfribidi-bin is shipped too: Procursus pins it to libfribidi0 (= 1.0.10), so
# a device that has it installed could not take our libfribidi0 otherwise.

SUBPROJECTS       += fribidi
FRIBIDI_VERSION   := 1.0.17
# Procursus ships build_info/libfribidi*.control templates keyed on @DEB_LIBFRIBIDI_V@.
DEB_LIBFRIBIDI_V  ?= $(FRIBIDI_VERSION)+ios1

fribidi-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/fribidi/fribidi/releases/download/v$(FRIBIDI_VERSION)/fribidi-$(FRIBIDI_VERSION).tar.xz)
	$(call EXTRACT_TAR,fribidi-$(FRIBIDI_VERSION).tar.xz,fribidi-$(FRIBIDI_VERSION),fribidi)

ifneq ($(wildcard $(BUILD_WORK)/fribidi/.build_complete),)
fribidi:
	@echo "Using previously built fribidi."
else
fribidi: fribidi-setup
	cd $(BUILD_WORK)/fribidi && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--disable-docs \
		CC_FOR_BUILD='$(shell command -v cc) $(CFLAGS_FOR_BUILD)' \
		CPP_FOR_BUILD='$(shell command -v cc) -E $(CPPFLAGS_FOR_BUILD)'
	# dist_man_MANS= : bin/'s man page is made by running the just-built fribidi under
	# help2man, which cannot work for an iOS binary on the Linux build host.
	+$(MAKE) -C $(BUILD_WORK)/fribidi dist_man_MANS=
	+$(MAKE) -C $(BUILD_WORK)/fribidi install \
		DESTDIR=$(BUILD_STAGE)/fribidi \
		dist_man_MANS=
	$(call AFTER_BUILD,copy)
endif

fribidi-package: fribidi-stage
	rm -rf $(BUILD_DIST)/libfribidi{0,-dev,-bin}
	mkdir -p $(BUILD_DIST)/libfribidi{0,-dev}/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libfribidi-bin/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	# libfribidi0 (runtime)
	cp -a $(BUILD_STAGE)/fribidi/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libfribidi.0.dylib $(BUILD_DIST)/libfribidi0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libfribidi-dev (headers, unversioned symlink, .pc, static archive)
	cp -a $(BUILD_STAGE)/fribidi/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libfribidi.0.dylib) $(BUILD_DIST)/libfribidi-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/fribidi/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libfribidi-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	# libfribidi-bin (the fribidi CLI)
	cp -a $(BUILD_STAGE)/fribidi/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/libfribidi-bin/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,libfribidi0,general.xml)
	$(call SIGN,libfribidi-bin,general.xml)
	$(call PACK,libfribidi0,DEB_LIBFRIBIDI_V)
	$(call PACK,libfribidi-dev,DEB_LIBFRIBIDI_V)
	$(call PACK,libfribidi-bin,DEB_LIBFRIBIDI_V)
	rm -rf $(BUILD_DIST)/libfribidi{0,-dev,-bin}

.PHONY: fribidi fribidi-package
