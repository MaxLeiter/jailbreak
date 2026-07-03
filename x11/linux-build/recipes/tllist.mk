ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# tllist.mk — foot's author's typesafe, intrusive linked-list library (codeberg.org/dnkl/tllist).
# Header-only: the whole library is a single tllist.h. `meson install` just drops the header and
# a tllist.pc (whose Version = 1.1.0 satisfies foot's `dependency('tllist', version:'>=1.1.0')`).
# Nothing is compiled, so there is no runtime dylib — this ships a single -dev deb (headers + .pc).
#
# DEPENDS (build-only, consumed by fcft/foot at configure via cross-pkg-config): none.

SUBPROJECTS   += tllist
TLLIST_VERSION := 1.1.0
DEB_TLLIST_V   ?= $(TLLIST_VERSION)+ios1

tllist-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://codeberg.org/dnkl/tllist/releases/download/$(TLLIST_VERSION)/tllist-$(TLLIST_VERSION).tar.gz)
	$(call EXTRACT_TAR,tllist-$(TLLIST_VERSION).tar.gz,tllist-$(TLLIST_VERSION),tllist)
	mkdir -p $(BUILD_WORK)/tllist/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/tllist/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/tllist/.build_complete),)
tllist:
	@echo "Using previously built tllist."
else
tllist: tllist-setup
	cd $(BUILD_WORK)/tllist/build && meson \
		--cross-file cross.txt \
		..
	+ninja -C $(BUILD_WORK)/tllist/build
	+DESTDIR="$(BUILD_STAGE)/tllist" ninja -C $(BUILD_WORK)/tllist/build install
	$(call AFTER_BUILD,copy)
endif

tllist-package: tllist-stage
	rm -rf $(BUILD_DIST)/libtllist-dev
	mkdir -p $(BUILD_DIST)/libtllist-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	# -dev only: the single header + tllist.pc (header-only lib, no runtime dylib).
	cp -a $(BUILD_STAGE)/tllist/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libtllist-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	if [ -d "$(BUILD_STAGE)/tllist/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib" ]; then \
		cp -a $(BUILD_STAGE)/tllist/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib $(BUILD_DIST)/libtllist-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi
	if [ -d "$(BUILD_STAGE)/tllist/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share" ]; then \
		cp -a $(BUILD_STAGE)/tllist/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/libtllist-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi

	$(call PACK,libtllist-dev,DEB_TLLIST_V)
	rm -rf $(BUILD_DIST)/libtllist-dev

.PHONY: tllist tllist-package
