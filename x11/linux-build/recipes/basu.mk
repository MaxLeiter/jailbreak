ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# BLOCKED on iOS/Darwin (mako's sd-bus provider). The meson-level GNU-isms (GNU-ld
# version-script link args, librt) are patched around, but the sd-bus C source itself is
# structurally Linux-bound: error-map registration walks an ELF section via __start_/__stop_
# symbols Mach-O doesn't have, and the creds path needs Linux struct ucred/SO_PEERCRED
# (Darwin's LOCAL_PEERCRED/struct xucred aren't equivalent). kdbus, socket, capability, and
# /proc-based code are untouched. Architectural port, not a shim cascade — left here unbuilt.

SUBPROJECTS  += basu
BASU_VERSION := 0.2.1
DEB_BASU_V   ?= $(BASU_VERSION)+ios1

basu-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://git.sr.ht/~emersion/basu/archive/v$(BASU_VERSION).tar.gz)
	$(call EXTRACT_TAR,v$(BASU_VERSION).tar.gz,basu-v$(BASU_VERSION),basu)
	# iOS has no librt, and ld64 rejects basu's GNU-ld link_args; fixed via patch.
	$(call DO_PATCH,basu,basu,-p1)
	rm -rf $(BUILD_WORK)/basu/build && mkdir -p $(BUILD_WORK)/basu/build
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
	c_args = ['-Wno-error']\n \
	[binaries]\n \
	c = '$(CC)'\n \
	cpp = '$(CXX)'\n \
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/basu/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/basu/.build_complete),)
basu:
	@echo "Using previously built basu."
else
basu: basu-setup
	cd $(BUILD_WORK)/basu/build && meson \
		--cross-file cross.txt \
		--buildtype=release \
		-Daudit=disabled \
		-Dlibcap=disabled \
		..
	+ninja -C $(BUILD_WORK)/basu/build
	+DESTDIR="$(BUILD_STAGE)/basu" ninja -C $(BUILD_WORK)/basu/build install
	$(call AFTER_BUILD,copy)
endif

basu-package: basu-stage
	rm -rf $(BUILD_DIST)/basu
	mkdir -p $(BUILD_DIST)/basu/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/basu/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib $(BUILD_DIST)/basu/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) 2>/dev/null || true
	cp -a $(BUILD_STAGE)/basu/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/basu/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) 2>/dev/null || true
	if [ -d "$(BUILD_STAGE)/basu/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin" ]; then \
		cp -a $(BUILD_STAGE)/basu/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/basu/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi

	$(call SIGN,basu,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,basu,DEB_BASU_V)
	rm -rf $(BUILD_DIST)/basu

.PHONY: basu basu-package
