ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# mozjs.mk — SpiderMonkey 115 (ESR), JIT-less, for gjs 1.78. DRAFT / UNBUILT.
# The single hardest cross in the tree (Linux->iOS Mach-O of mach/moz.configure + Rust).
# Heavy build is GATED on coordinator go. See docs/gjs-plan.md Blocker #1 and
# build_info/mozjs115.mozconfig. This recipe is committed as a draft for review, NOT to run.

SUBPROJECTS   += mozjs
MOZJS_VERSION := 115.12.0
DEB_MOZJS_V   ?= $(MOZJS_VERSION)
# mozjs ships inside the firefox-esr source tarball; the standalone "mozjs" tarball mirrors it.
MOZJS_SRC     := mozjs-$(MOZJS_VERSION)

mozjs-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://ftp.mozilla.org/pub/firefox/releases/$(MOZJS_VERSION)esr/source/firefox-$(MOZJS_VERSION)esr.source.tar.xz)
	$(call EXTRACT_TAR,firefox-$(MOZJS_VERSION)esr.source.tar.xz,firefox-$(MOZJS_VERSION)esr,mozjs)
	# SETUP FIX 1: mozjs-115's bundled config.sub copies (5 of them) don't know 'ios'.
	# Replace with the host's modern one (Debian autotools-dev).
	find $(BUILD_WORK)/mozjs -name config.sub  -exec cp -f /usr/share/misc/config.sub  {} \; || true
	find $(BUILD_WORK)/mozjs -name config.guess -exec cp -f /usr/share/misc/config.guess {} \; || true
	# The iOS portability series. patches/0001 = the moz.configure iOS-target patch (VALIDATED:
	# configure is clean with it); 0002 drops the js shell; 0003 fixes old-configure darwin cases;
	# 0004 page-aligns the helper-thread stack size (Darwin pthread_attr_setstacksize rejects the
	# 4 KiB-aligned 2 MiB-8 KiB default with EINVAL on iOS's 16 KiB pages, which MOZ_CRASH turned
	# into the JS_NewContext SIGSEGV — VALIDATED on-device: JS_NewContext + eval now succeed).
	# Later entries get appended as the build shakes out.
	$(call DO_PATCH,mozjs,mozjs,-p1)
	# SETUP FIX 2: moz's ld64 probe hardcodes `-fuse-ld=ld`, so clang must resolve `ld` to the
	# cctools ld64. Symlink it next to the cross toolchain (CC carries -B@CCTOOLS_BIN@).
	ln -sf $(GNU_HOST_TRIPLE)-ld $(dir $(shell command -v $(GNU_HOST_TRIPLE)-ld))ld || true
	# Render the cross mozconfig with our paths.
	mkdir -p $(BUILD_WORK)/mozjs/build
	sed -e 's|@TARGET_SYSROOT@|$(TARGET_SYSROOT)|g' \
	    -e 's|@CROSS_PREFIX@|$(GNU_HOST_TRIPLE)|g' \
	    -e 's|@CCTOOLS_BIN@|$(dir $(shell command -v $(GNU_HOST_TRIPLE)-ld))|g' \
	    -e 's|@MOZ_OBJDIR@|$(BUILD_WORK)/mozjs/obj|g' \
	    $(BUILD_INFO)/mozjs115.mozconfig > $(BUILD_WORK)/mozjs/.mozconfig

ifneq ($(wildcard $(BUILD_WORK)/mozjs/.build_complete),)
mozjs:
	@echo "Using previously built mozjs."
else
mozjs: mozjs-setup readline zlib
	# Host needs: rustup toolchain with `rustup target add aarch64-apple-ios`, cbindgen,
	# python3, yasm/nasm. These are build-host tools (Dockerfile/build-gjs.sh), not recipes.
	# VALIDATED end-to-end (2026-06-30): libmozjs-115.dylib built for iOS arm64 (platform=iOS).
	# The fixes (besides patches 0001-0003 + the config.sub/ld setup above):
	#  * fake `xcrun` so the Rust cc-crate can locate the iOS SDK on a Linux host
	#  * CRATE_CC_NO_DEFAULTS=1 — the cc-crate auto-adds -fembed-bitcode for iOS (conflicts
	#    with mozbuild's -ffunction-sections); with it, cc uses only moz's full CXXFLAGS.
	# NOTE: mozconfig currently pins --without-intl-api (first validated pass). gjs needs Intl —
	# flip to bundled in-tree ICU (--enable-intl-api) once that pass is validated.
	printf '#!/bin/sh\nfor a in "$$@"; do case "$$a" in --show-sdk-path*) echo $(TARGET_SYSROOT); exit 0;; esac; done\nif [ "$$1" = --find ]; then command -v "$(GNU_HOST_TRIPLE)-$$2" || command -v "$$2" || true; exit 0; fi\necho $(TARGET_SYSROOT)\n' > $(BUILD_TOOLS)/xcrun
	chmod +x $(BUILD_TOOLS)/xcrun
	cd $(BUILD_WORK)/mozjs; \
		export PATH="$(BUILD_TOOLS):$$PATH"; \
		export MOZCONFIG=$(BUILD_WORK)/mozjs/.mozconfig; \
		export CRATE_CC_NO_DEFAULTS=1; \
		export CARGO_TARGET_AARCH64_APPLE_IOS_LINKER=$(GNU_HOST_TRIPLE)-clang; \
		export PKG_CONFIG_PATH=$(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig; \
		python3 ./mach configure && \
		python3 ./mach build
	# `mach install` isn't a command for --enable-project=js; the build already populates
	# obj/dist/{bin,include}. Stage that as the install tree.
	mkdir -p $(BUILD_STAGE)/mozjs$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{lib,include,bin,lib/pkgconfig}
	cp -a $(BUILD_WORK)/mozjs/obj/dist/bin/libmozjs-115*.dylib $(BUILD_STAGE)/mozjs$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/
	# obj/dist/include is a tree of SYMLINKS into obj/ + the source tree; -aL DEREFERENCES
	# them to real files so the -dev deb is self-contained (plain -a captured symlinks that
	# dangle the moment build_work is cleaned — the on-device gir build then can't compile
	# against gjs). The link targets exist now (fresh build tree), so this needs no extra vol.
	cp -aL $(BUILD_WORK)/mozjs/obj/dist/include/. $(BUILD_STAGE)/mozjs$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/
	-cp -a $(BUILD_WORK)/mozjs/obj/dist/bin/js-config $(BUILD_STAGE)/mozjs$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/ 2>/dev/null
	# SpiderMonkey emits the pkg-config file as obj/js/src/build/js.pc (NOT mozjs-115.pc, which
	# is why the old `find -name mozjs-115.pc` silently produced nothing). Rename it and retarget
	# its prefix (js.pc ships prefix=/usr/local) so gjs-1.0.pc's Requires.private resolves.
	sed 's|^prefix=.*|prefix=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)|' \
		$(BUILD_WORK)/mozjs/obj/js/src/build/js.pc \
		> $(BUILD_STAGE)/mozjs$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/mozjs-115.pc
	$(call AFTER_BUILD)
endif

mozjs-package: mozjs-stage
	rm -rf $(BUILD_DIST)/libmozjs-115-0 $(BUILD_DIST)/libmozjs-115-dev
	mkdir -p $(BUILD_DIST)/libmozjs-115-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libmozjs-115-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# runtime: the shared JS engine
	cp -a $(BUILD_STAGE)/mozjs/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libmozjs-115*.dylib \
		$(BUILD_DIST)/libmozjs-115-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# dev: real-file headers (deref'd at stage) + mozjs-115.pc + js-config. NO libjs_static.a
	# (615MB, and nothing in the stack links it — gjs/consumers use libmozjs-115.dylib).
	cp -a $(BUILD_STAGE)/mozjs/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libmozjs-115-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/mozjs/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/libmozjs-115-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true
	if [ -d "$(BUILD_STAGE)/mozjs/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin" ]; then \
		cp -a $(BUILD_STAGE)/mozjs/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin \
			$(BUILD_DIST)/libmozjs-115-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); fi

	$(call SIGN,libmozjs-115-0,general.xml)
	$(call PACK,libmozjs-115-0,DEB_MOZJS_V)
	$(call PACK,libmozjs-115-dev,DEB_MOZJS_V)
	rm -rf $(BUILD_DIST)/libmozjs-115-0 $(BUILD_DIST)/libmozjs-115-dev

.PHONY: mozjs mozjs-package
