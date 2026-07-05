ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# wayland — libwayland-client/server/cursor/egl + protocol data, for iOS/Darwin.
#
# DRAFT — Wayland track W0. NOT built yet (Docker gated). Drop-in:
#   recipe        -> Procursus/makefiles/wayland.mk
#   control files -> Procursus/build_info/libwayland0.control, libwayland-dev.control
#
# Two findings from inspecting wayland 1.23.1 make this small:
#   * 1.23.1 is already Darwin-aware everywhere EXCEPT the epoll dependency: it has a
#     `struct xucred`/LOCAL_PEERCRED credentials branch (src/wayland-os.c), and accept4 /
#     memfd_create / MSG_CMSG_CLOEXEC are feature-detected with portable fallbacks. The
#     ONLY source change needed is to pull epoll-shim on darwin too — upstream meson only
#     does so for freebsd/openbsd (see the sed below).
#   * Cross-compiling, wayland needs a *native, version-matched* wayland-scanner to codegen
#     its own protocol headers (`dependency('wayland-scanner', native:true, version:...)`,
#     src/meson.build). A host scanner from Debian's libwayland-bin won't version-match, so
#     we build the scanner natively from this same tarball first, then cross-build the libs.

SUBPROJECTS     += wayland
WAYLAND_VERSION := 1.23.1
DEB_WAYLAND_V   ?= $(WAYLAND_VERSION)+ios1

# Host (build-machine) prefix holding the version-matched native wayland-scanner + its .pc,
# consumed by the cross build's native pkg-config. Self-contained under BUILD_WORK.
WAYLAND_NATIVE_ROOT := $(BUILD_WORK)/wayland/native-root

wayland-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://gitlab.freedesktop.org/wayland/wayland/-/releases/$(WAYLAND_VERSION)/downloads/wayland-$(WAYLAND_VERSION).tar.xz)
	$(call EXTRACT_TAR,wayland-$(WAYLAND_VERSION).tar.xz,wayland-$(WAYLAND_VERSION),wayland)
	# Keep the Darwin/iOS source portability edits in the port patch stack.
	$(call DO_PATCH,wayland,wayland,-p1)
	mkdir -p $(BUILD_WORK)/wayland/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/wayland/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/wayland/.build_complete),)
wayland:
	@echo "Using previously built wayland."
else
wayland: wayland-setup epoll-shim libffi expat
	# Pass 1 — native (build-machine) wayland-scanner only, version-matched, so the cross
	# build's `dependency('wayland-scanner', native:true, version:$(WAYLAND_VERSION))` resolves.
	# No cross file => must build for the HOST, but the recipe inherits Procursus's full CROSS
	# toolchain in the environment: CC=cc-nounused, iOS CFLAGS/PKG_CONFIG_*, AND the cross
	# binutils (AR/RANLIB/NM/STRIP=aarch64-apple-darwin-*). We must override ALL of them:
	#  - cross CC/CFLAGS -> host => else meson builds a Mach-O it can't exec ("Exec format error").
	#  - cross AR/RANLIB -> host => else libwayland-util.a is a Darwin archive whose symbol table
	#    GNU ld can't read, so the scanner link fails with "undefined reference to wl_list_*".
	# Needs host expat (libexpat1-dev) + python3.
	#  - --libdir=lib => the native (Debian) meson would otherwise install wayland-scanner.pc to
	#    native-root/lib/<triple>/pkgconfig (multiarch), but pass 2 sets PKG_CONFIG_PATH to
	#    native-root/lib/pkgconfig, so the cross build wouldn't find the scanner. Flatten it.
	cd $(BUILD_WORK)/wayland && rm -rf build-native && \
		env -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS -u OBJCFLAGS -u OBJCXXFLAGS \
		    -u PKG_CONFIG_PATH -u PKG_CONFIG_LIBDIR -u LD -u CPP -u OBJC \
		    CC=cc CXX=c++ AR=ar RANLIB=ranlib NM=nm STRIP=strip meson setup build-native \
		-Dscanner=true \
		-Dlibraries=false \
		-Dtests=false \
		-Ddocumentation=false \
		-Ddtd_validation=false \
		--prefix=$(WAYLAND_NATIVE_ROOT) \
		--libdir=lib
	+ninja -C $(BUILD_WORK)/wayland/build-native
	+ninja -C $(BUILD_WORK)/wayland/build-native install
	# Pass 2 — cross-build the target libraries. cross-pkg-config (in cross.txt) finds target
	# epoll-shim/ffi/expat. For the NATIVE wayland-scanner, dependency('wayland-scanner',native:true)
	# is resolved by the BUILD machine's pkg-config — and meson ignores the env PKG_CONFIG_PATH for
	# the build machine in a cross build, so we hand it a native file whose [built-in options]
	# pkg_config_path adds the native-root, and pin pkgconfig to plain pkg-config (not cross-pkg-config).
	cd $(BUILD_WORK)/wayland/build && \
		printf "[binaries]\npkgconfig = 'pkg-config'\n[built-in options]\npkg_config_path = ['$(WAYLAND_NATIVE_ROOT)/lib/pkgconfig']\n" > native.txt && \
		PATH="$(WAYLAND_NATIVE_ROOT)/bin:$$PATH" meson \
		--cross-file cross.txt \
		--native-file native.txt \
		-Dscanner=true \
		-Dlibraries=true \
		-Dtests=false \
		-Ddocumentation=false \
		-Ddtd_validation=false \
		..
	+PATH="$(WAYLAND_NATIVE_ROOT)/bin:$$PATH" ninja -C $(BUILD_WORK)/wayland/build
	+DESTDIR="$(BUILD_STAGE)/wayland" ninja -C $(BUILD_WORK)/wayland/build install
	$(call AFTER_BUILD,copy)
endif

wayland-package: wayland-stage
	# wayland.mk Package Structure
	rm -rf $(BUILD_DIST)/libwayland{0,-dev}
	mkdir -p $(BUILD_DIST)/libwayland0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libwayland-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# wayland.mk Prep libwayland0 (runtime dylibs: client/server/cursor/egl)
	cp -a $(BUILD_STAGE)/wayland/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libwayland-client.*.dylib \
		$(BUILD_STAGE)/wayland/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libwayland-server.*.dylib \
		$(BUILD_STAGE)/wayland/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libwayland-cursor.*.dylib \
		$(BUILD_STAGE)/wayland/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libwayland-egl.*.dylib \
		$(BUILD_DIST)/libwayland0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# wayland.mk Prep libwayland-dev (headers, .pc, unversioned symlinks, share/{wayland,aclocal})
	cp -a $(BUILD_STAGE)/wayland/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libwayland-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/wayland/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libwayland-client.*.dylib|libwayland-server.*.dylib|libwayland-cursor.*.dylib|libwayland-egl.*.dylib) \
		$(BUILD_DIST)/libwayland-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	if [ -d "$(BUILD_STAGE)/wayland/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share" ]; then \
		cp -a $(BUILD_STAGE)/wayland/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share \
			$(BUILD_DIST)/libwayland-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi
	if [ -d "$(BUILD_STAGE)/wayland/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin" ]; then \
		cp -a $(BUILD_STAGE)/wayland/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin \
			$(BUILD_DIST)/libwayland-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi

	# wayland.mk Sign
	$(call SIGN,libwayland0,general.xml)
	if [ -d "$(BUILD_DIST)/libwayland-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin" ]; then \
		$(call SIGN,libwayland-dev,general.xml); \
	fi

	# wayland.mk Make .debs
	$(call PACK,libwayland0,DEB_WAYLAND_V)
	$(call PACK,libwayland-dev,DEB_WAYLAND_V)

	# wayland.mk Build cleanup
	rm -rf $(BUILD_DIST)/libwayland{0,-dev}

.PHONY: wayland wayland-package
