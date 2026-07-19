ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

SUBPROJECTS  += atk
ATK_MAJOR_V  := 2.38
ATK_VERSION  := $(ATK_MAJOR_V).0
DEB_LIBATK_V ?= $(ATK_VERSION)+ios1

# NOTE: the shippable libatk1.0-0 / libatk1.0-dev debs are NO LONGER produced here.
# ATK was merged into at-spi2-core at 2.51/2.52, so at-spi2-core.mk builds libatk-1.0 2.52
# (with atk_document_get_text_selections — the symbol the 2.52 atk-bridge needs) and PACKs
# libatk1.0-0/libatk1.0-dev at DEB_ATSPI2_V. Shipping the standalone 2.38 here caused the
# atk/atk-bridge ABI skew (2.38 lib vs 2.52 bridge -> dyld abort). This recipe now builds atk
# only as a transitional build-dep (no -package target); at-spi2-core.mk owns the debs.

atk-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://ftp.gnome.org/pub/gnome/sources/atk/$(ATK_MAJOR_V)/atk-$(ATK_VERSION).tar.xz)
	$(call EXTRACT_TAR,atk-$(ATK_VERSION).tar.xz,atk-$(ATK_VERSION),atk)
	mkdir -p $(BUILD_WORK)/atk/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/atk/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/atk/.build_complete),)
atk:
	@echo "Using previously built atk."
else
atk: atk-setup glib2.0
	cd $(BUILD_WORK)/atk/build && meson \
		--cross-file cross.txt \
		-Dintrospection=false \
		-Ddocs=false \
		..
	cd $(BUILD_WORK)/atk/build; \
		DESTDIR="$(BUILD_STAGE)/atk" meson install
	$(call AFTER_BUILD,copy)
endif

.PHONY: atk
