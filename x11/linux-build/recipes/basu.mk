ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# basu.mk — basu, the standalone sd-bus library (git.sr.ht/~emersion/basu), extracted from
# systemd so non-systemd systems can provide the sd-bus API. mako links it as its sd-bus provider.
#
# STATUS: BLOCKED on iOS/Darwin (mako's sd-bus provider — kept as documentation of the attempt).
# The meson-level GNU-isms below ARE fixed by this recipe and meson now configures cleanly:
#   * `link_args : ['-shared', '-Wl,--version-script=...']` — both GNU-ld-only; ld64 rejects them.
#     Collapsed to `[]` (meson emits -dynamiclib itself; the symbol version script is dropped).
#   * `cc.find_library('rt')` — no librt on iOS (made non-required).
#   * audit + libcap optional features disabled (absent on the image).
# But the sd-bus C SOURCE is architecturally Linux-bound. Concrete walls hit at compile time
# (first 7 of 94 objects, all structural — not one-line shims):
#   1. bus-gvariant.c / bus-protocol.h: glibc <endian.h> le16toh/htole16/... (Darwin has none;
#      would need an OSByteOrder-backed endian.h shim — the tractable one).
#   2. bus-error.c / bus-common-errors.c: BUS_ERROR_MAP_ELF_REGISTER =
#      __attribute__((section("BUS_ERROR_MAP"))). Mach-O needs "__SEG,__sect" and, worse, the
#      runtime WALKS that ELF section (__start_/__stop_ symbols) to assemble the sd_bus_error_map
#      table. Mach-O has no __start_/__stop_ section symbols; this registration mechanism must be
#      rewritten with getsectiondata()/__DATA sections.
#   3. bus-internal.h: `struct ucred` (Linux SO_PEERCRED / SCM_CREDENTIALS peer-credential model).
#      Darwin has no struct ucred; LOCAL_PEERCRED yields a different struct xucred and there is no
#      SCM_CREDENTIALS ancillary-credential passing — sd-bus's whole creds path is Linux-only.
# Still unbuilt beyond that: bus-kernel.c (Linux kdbus), bus-socket.c (accept4/memfd_create/
# MSG_CMSG_CLOEXEC), socket-util.c, capability-util.c (Linux capabilities), sd-id128 (/proc,
# /etc/machine-id), process-util (/proc/self). This is a multi-file architectural port, not a
# portability-shim cascade, so per the build brief mako is stopped here rather than spun on.

SUBPROJECTS  += basu
BASU_VERSION := 0.2.1
DEB_BASU_V   ?= $(BASU_VERSION)

basu-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://git.sr.ht/~emersion/basu/archive/v$(BASU_VERSION).tar.gz)
	$(call EXTRACT_TAR,v$(BASU_VERSION).tar.gz,basu-v$(BASU_VERSION),basu)
	# iOS has no librt (clock_gettime is in libc); make the lookup non-fatal.
	sed -i "s/cc.find_library('rt')/cc.find_library('rt', required: false)/" $(BUILD_WORK)/basu/meson.build
	# Apple ld64 has neither `-shared` (that's the GCC spelling; meson emits -dynamiclib itself)
	# nor GNU ld's `--version-script`. Collapse the whole hardcoded link_args array to empty so
	# the library links (perl -0777 spans the two-line array).
	perl -0777 -i -pe "s/link_args : \['-shared',.*?\],/link_args : [],/s" $(BUILD_WORK)/basu/meson.build
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
