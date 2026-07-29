ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# 1.10.0 is the last pre-rewrite release: d-spy 47+ moved to libdex (a new async dep) and
# needs gtk4 >=4.15, neither of which we have. 1.10.0 matches our gtk4 4.14.5 / libadwaita 1.5.

SUBPROJECTS       += d-spy
D-SPY_MAJOR_V     := 1.10
D-SPY_VERSION     := $(D-SPY_MAJOR_V).0
DEB_D-SPY_V       ?= $(D-SPY_VERSION)+ios1

d-spy-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/d-spy/$(D-SPY_MAJOR_V)/d-spy-$(D-SPY_VERSION).tar.xz)
	$(call EXTRACT_TAR,d-spy-$(D-SPY_VERSION).tar.xz,d-spy-$(D-SPY_VERSION),d-spy)
	mkdir -p $(BUILD_WORK)/d-spy/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/d-spy/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/d-spy/.build_complete),)
d-spy:
	@echo "Using previously built d-spy."
else
d-spy: d-spy-setup gtk4 libadwaita
	cd $(BUILD_WORK)/d-spy/build && meson \
		--cross-file cross.txt \
		-Ddevelopment=false \
		..
	+ninja -C $(BUILD_WORK)/d-spy/build
	+DESTDIR="$(BUILD_STAGE)/d-spy" ninja -C $(BUILD_WORK)/d-spy/build install
	$(call AFTER_BUILD,copy)
endif

d-spy-package: d-spy-stage
	rm -rf $(BUILD_DIST)/d-spy
	mkdir -p $(BUILD_DIST)/d-spy/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/d-spy/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/d-spy/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	if [ -d "$(BUILD_STAGE)/d-spy/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib" ]; then \
		cp -a $(BUILD_STAGE)/d-spy/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib $(BUILD_DIST)/d-spy/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi
	cp -a $(BUILD_STAGE)/d-spy/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/d-spy/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,d-spy,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,d-spy,DEB_D-SPY_V)
	rm -rf $(BUILD_DIST)/d-spy

.PHONY: d-spy d-spy-package
