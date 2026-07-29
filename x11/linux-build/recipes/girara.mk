ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# so_major is hard-coded to '4' in girara's own meson.build, hence the libgirara-gtk3-4
# naming below (GIRARA_SOV). -Dtests=disabled: the `check` unit-test lib isn't staged.
# No libnotify option exists in girara 0.4.5.

SUBPROJECTS     += girara
GIRARA_VERSION  := 0.4.5
GIRARA_SOV      := 4
DEB_GIRARA_V    ?= $(GIRARA_VERSION)+ios1

girara-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://pwmt.org/projects/girara/download/girara-$(GIRARA_VERSION).tar.xz)
	$(call EXTRACT_TAR,girara-$(GIRARA_VERSION).tar.xz,girara-$(GIRARA_VERSION),girara)
	mkdir -p $(BUILD_WORK)/girara/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/girara/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/girara/.build_complete),)
girara:
	@echo "Using previously built girara."
else
girara: girara-setup gtk+3.0
	cd $(BUILD_WORK)/girara/build && meson \
		--cross-file cross.txt \
		-Ddocs=disabled \
		-Dtests=disabled \
		-Djson=enabled \
		..
	+ninja -C $(BUILD_WORK)/girara/build
	+DESTDIR="$(BUILD_STAGE)/girara" ninja -C $(BUILD_WORK)/girara/build install
	$(call AFTER_BUILD,copy)
endif

girara-package: girara-stage
	rm -rf $(BUILD_DIST)/libgirara-gtk3-$(GIRARA_SOV) $(BUILD_DIST)/libgirara-gtk3-dev
	mkdir -p $(BUILD_DIST)/libgirara-gtk3-$(GIRARA_SOV)/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libgirara-gtk3-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# runtime: the versioned dylib(s) (the '.' after gtk3 excludes the bare libgirara-gtk3.dylib
	# symlink, which is a -dev artifact) + translations.
	cp -a $(BUILD_STAGE)/girara/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgirara-gtk3.*.dylib \
		$(BUILD_DIST)/libgirara-gtk3-$(GIRARA_SOV)/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	if [ -d "$(BUILD_STAGE)/girara/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/locale" ]; then \
		mkdir -p $(BUILD_DIST)/libgirara-gtk3-$(GIRARA_SOV)/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share; \
		cp -a $(BUILD_STAGE)/girara/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/locale \
			$(BUILD_DIST)/libgirara-gtk3-$(GIRARA_SOV)/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share; \
	fi

	# -dev: bare symlink, headers, .pc.
	cp -a $(BUILD_STAGE)/girara/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgirara-gtk3.dylib \
		$(BUILD_DIST)/libgirara-gtk3-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true
	cp -a $(BUILD_STAGE)/girara/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libgirara-gtk3-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	if [ -d "$(BUILD_STAGE)/girara/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig" ]; then \
		cp -a $(BUILD_STAGE)/girara/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
			$(BUILD_DIST)/libgirara-gtk3-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib; \
	fi

	$(call SIGN,libgirara-gtk3-$(GIRARA_SOV),general.xml)
	$(call PACK,libgirara-gtk3-$(GIRARA_SOV),DEB_GIRARA_V)
	$(call PACK,libgirara-gtk3-dev,DEB_GIRARA_V)
	rm -rf $(BUILD_DIST)/libgirara-gtk3-$(GIRARA_SOV) $(BUILD_DIST)/libgirara-gtk3-dev

.PHONY: girara girara-package
