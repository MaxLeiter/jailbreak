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
# only as a transitional build-dep; its -package target below is a no-op (see PACK guard).

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

atk-package: atk-stage
	# DISABLED: libatk1.0-0/libatk1.0-dev now ship from at-spi2-core.mk at 2.52 (ABI-consistent
	# with the 2.52 atk-bridge). Emitting the standalone 2.38 debs here reintroduced the atk skew
	# (missing atk_document_get_text_selections -> atk-bridge dyld abort). Kept as a no-op so the
	# target still resolves; re-enabling requires reverting the at-spi2-core.mk carve-out.
	@echo "atk-package: no-op — libatk1.0-0/libatk1.0-dev are produced by at-spi2-core.mk (2.52)."

.PHONY: atk atk-package
