ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Written in Vala: valac transpiles Vala->C on the host at build time, no target binary
# runs during the build (see linux-build/vapi/README.md). cross.txt sets vala='valac';
# build-gnome.sh stages the gtk4 + libadwaita-1 .vapi onto valac's search path.
# Pinned to GNOME 46.0 to match our gtk4 4.14.5 / libadwaita 1.5 (47+ needs newer versions
# we don't have).

SUBPROJECTS       += baobab
BAOBAB_MAJOR_V    := 46
BAOBAB_VERSION    := $(BAOBAB_MAJOR_V).0
DEB_BAOBAB_V      ?= $(BAOBAB_VERSION)+ios1

baobab-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/baobab/$(BAOBAB_MAJOR_V)/baobab-$(BAOBAB_VERSION).tar.xz)
	$(call EXTRACT_TAR,baobab-$(BAOBAB_VERSION).tar.xz,baobab-$(BAOBAB_VERSION),baobab)
	mkdir -p $(BUILD_WORK)/baobab/build
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
	vala = 'valac'\n \
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/baobab/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/baobab/.build_complete),)
baobab:
	@echo "Using previously built baobab."
else
baobab: baobab-setup gtk4 libadwaita
	cd $(BUILD_WORK)/baobab/build && meson \
		--cross-file cross.txt \
		..
	+ninja -C $(BUILD_WORK)/baobab/build
	+DESTDIR="$(BUILD_STAGE)/baobab" ninja -C $(BUILD_WORK)/baobab/build install
	$(call AFTER_BUILD,copy)
endif

baobab-package: baobab-stage
	rm -rf $(BUILD_DIST)/baobab
	mkdir -p $(BUILD_DIST)/baobab/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/baobab/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/baobab/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/baobab/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/baobab/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,baobab,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,baobab,DEB_BAOBAB_V)
	rm -rf $(BUILD_DIST)/baobab

.PHONY: baobab baobab-package
