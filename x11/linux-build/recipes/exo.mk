ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# exo — XFCE application/extension helper library (libexo-2 + exo-* utilities).
# GTK3 is available; this recipe is not yet build-validated.
SUBPROJECTS += exo
EXO_MAJOR_V := 4.16
EXO_VERSION := $(EXO_MAJOR_V).4
DEB_EXO_V   ?= $(EXO_VERSION)+ios1

exo-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://archive.xfce.org/src/xfce/exo/$(EXO_MAJOR_V)/exo-$(EXO_VERSION).tar.bz2)
	$(call EXTRACT_TAR,exo-$(EXO_VERSION).tar.bz2,exo-$(EXO_VERSION),exo)

ifneq ($(wildcard $(BUILD_WORK)/exo/.build_complete),)
exo:
	@echo "Using previously built exo."
else
exo: exo-setup gtk+3.0 libxfce4util libxfce4ui
	cd $(BUILD_WORK)/exo && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--disable-static \
		--disable-gtk-doc \
		--disable-debug
	+$(MAKE) -C $(BUILD_WORK)/exo
	+$(MAKE) -C $(BUILD_WORK)/exo install DESTDIR=$(BUILD_STAGE)/exo
	$(call AFTER_BUILD,copy)
endif

exo-package: exo-stage
	rm -rf $(BUILD_DIST)/libexo-2-0
	mkdir -p $(BUILD_DIST)/libexo-2-0
	cp -a $(BUILD_STAGE)/exo/$(MEMO_PREFIX) $(BUILD_DIST)/libexo-2-0/

	rm -rf $(BUILD_DIST)/libexo-2-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libexo-2-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/libexo-2-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/*.a \
		$(BUILD_DIST)/libexo-2-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/gtk-doc

	$(call SIGN,libexo-2-0,general.xml)
	$(call PACK,libexo-2-0,DEB_EXO_V)
	rm -rf $(BUILD_DIST)/libexo-2-0

.PHONY: exo exo-package
