ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# mozjs-jit.mk — SpiderMonkey 115 (ESR), JIT-ENABLED variant, for gjs 1.78. #46.
# Sibling of mozjs.mk (the shipping JIT-less build). This builds into its OWN work tree
# (build_work/mozjs-jit) and objdir and packages as libmozjs-115-jit-0, so it never touches
# the JIT-less mozjs recipe, its .build_complete marker, or the libmozjs-115-0 debs.
#
# Shares the SAME patch series as mozjs (build_patch/mozjs, staged by build-gjs.sh). NB: no extra
# W^X patch is needed — SpiderMonkey 115's POSIX/Darwin executable-memory path is already pure
# mprotect (no MAP_JIT / pthread_jit fast-WX; that machinery post-dates 115), and the mprotect
# flip is validated on the A10 (ports/mozjs/tools/wxprobe.c). See docs/mozjs-jit-plan.md.
# Heavy build; coordinator-gated.

SUBPROJECTS   += mozjs-jit
MOZJSJIT_VERSION := 115.12.0
DEB_MOZJSJIT_V   ?= $(MOZJSJIT_VERSION)
MOZJSJIT_WORK  := $(BUILD_WORK)/mozjs-jit

mozjs-jit-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://ftp.mozilla.org/pub/firefox/releases/$(MOZJSJIT_VERSION)esr/source/firefox-$(MOZJSJIT_VERSION)esr.source.tar.xz)
	# NB: the ESR source tarball unpacks to firefox-<ver>/ (NO 'esr' suffix), so that is
	# EXTRACT_TAR's 2nd arg (the dir it copies into mozjs-jit). Getting this wrong leaves an
	# empty tree (EXTRACT_TAR's leading '-' swallows the failed copy). mozjs.mk has the same
	# latent typo but was only ever run by hand (its header says "draft, NOT to run").
	$(call EXTRACT_TAR,firefox-$(MOZJSJIT_VERSION)esr.source.tar.xz,firefox-$(MOZJSJIT_VERSION),mozjs-jit)
	# config.sub copies in the tree don't know 'ios' — replace with the host's modern one.
	find $(MOZJSJIT_WORK) -name config.sub  -exec cp -f /usr/share/misc/config.sub  {} \; || true
	find $(MOZJSJIT_WORK) -name config.guess -exec cp -f /usr/share/misc/config.guess {} \; || true
	# Apply the shared iOS portability series from build_patch/mozjs (0001-0004) + the JIT W^X
	# patch (0005). DO_PATCH's .done tracking means re-running after 0005 is added applies only 0005.
	$(call DO_PATCH,mozjs,mozjs-jit,-p1)
	# moz's ld64 probe hardcodes -fuse-ld=ld: give clang an `ld` next to the cross toolchain.
	ln -sf $(GNU_HOST_TRIPLE)-ld $(dir $(shell command -v $(GNU_HOST_TRIPLE)-ld))ld || true
	# Render the JIT cross mozconfig into the JIT work tree.
	mkdir -p $(MOZJSJIT_WORK)/build
	sed -e 's|@TARGET_SYSROOT@|$(TARGET_SYSROOT)|g' \
	    -e 's|@CROSS_PREFIX@|$(GNU_HOST_TRIPLE)|g' \
	    -e 's|@CCTOOLS_BIN@|$(dir $(shell command -v $(GNU_HOST_TRIPLE)-ld))|g' \
	    -e 's|@MOZ_OBJDIR@|$(MOZJSJIT_WORK)/obj|g' \
	    $(BUILD_INFO)/mozjs115-jit.mozconfig > $(MOZJSJIT_WORK)/.mozconfig

ifneq ($(wildcard $(MOZJSJIT_WORK)/.build_complete),)
mozjs-jit:
	@echo "Using previously built mozjs-jit."
else
mozjs-jit: mozjs-jit-setup readline zlib
	# Same host toolchain as the JIT-less build (rustup + aarch64-apple-ios target + cbindgen +
	# nasm, set up by build-gjs.sh). fake `xcrun` so the Rust cc-crate finds the iOS SDK on Linux;
	# CRATE_CC_NO_DEFAULTS=1 stops cc auto-adding -fembed-bitcode (conflicts with -ffunction-sections).
	printf '#!/bin/sh\nfor a in "$$@"; do case "$$a" in --show-sdk-path*) echo $(TARGET_SYSROOT); exit 0;; esac; done\nif [ "$$1" = --find ]; then command -v "$(GNU_HOST_TRIPLE)-$$2" || command -v "$$2" || true; exit 0; fi\necho $(TARGET_SYSROOT)\n' > $(BUILD_TOOLS)/xcrun
	chmod +x $(BUILD_TOOLS)/xcrun
	cd $(MOZJSJIT_WORK); \
		export PATH="$(BUILD_TOOLS):$$PATH"; \
		export MOZCONFIG=$(MOZJSJIT_WORK)/.mozconfig; \
		export CRATE_CC_NO_DEFAULTS=1; \
		export CARGO_TARGET_AARCH64_APPLE_IOS_LINKER=$(GNU_HOST_TRIPLE)-clang; \
		export PKG_CONFIG_PATH=$(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig; \
		python3 ./mach configure && \
		python3 ./mach build
	# Stage obj/dist/{bin,include} (mach install isn't a thing for --enable-project=js).
	mkdir -p $(BUILD_STAGE)/mozjs-jit$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{lib,include,bin,lib/pkgconfig}
	cp -a $(MOZJSJIT_WORK)/obj/dist/bin/libmozjs-115*.dylib $(BUILD_STAGE)/mozjs-jit$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/
	# -aL DEREFERENCES the dist/include symlink tree so the -dev deb is self-contained.
	cp -aL $(MOZJSJIT_WORK)/obj/dist/include/. $(BUILD_STAGE)/mozjs-jit$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/
	-cp -a $(MOZJSJIT_WORK)/obj/dist/bin/js-config $(BUILD_STAGE)/mozjs-jit$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/ 2>/dev/null
	# js.pc -> mozjs-115.pc with our prefix (so gjs-1.0.pc Requires.private resolves).
	sed 's|^prefix=.*|prefix=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)|' \
		$(MOZJSJIT_WORK)/obj/js/src/build/js.pc \
		> $(BUILD_STAGE)/mozjs-jit$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/mozjs-115.pc
	$(call AFTER_BUILD)
endif

mozjs-jit-package: mozjs-jit-stage
	rm -rf $(BUILD_DIST)/libmozjs-115-jit-0 $(BUILD_DIST)/libmozjs-115-jit-dev
	mkdir -p $(BUILD_DIST)/libmozjs-115-jit-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libmozjs-115-jit-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# runtime: the JIT-enabled shared JS engine (same soname; drop-in for libmozjs-115-0)
	cp -a $(BUILD_STAGE)/mozjs-jit/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libmozjs-115*.dylib \
		$(BUILD_DIST)/libmozjs-115-jit-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# dev: real-file headers + mozjs-115.pc + js-config. No libjs_static.a (nothing links it).
	cp -a $(BUILD_STAGE)/mozjs-jit/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libmozjs-115-jit-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/mozjs-jit/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/libmozjs-115-jit-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true
	if [ -d "$(BUILD_STAGE)/mozjs-jit/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin" ]; then \
		cp -a $(BUILD_STAGE)/mozjs-jit/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin \
			$(BUILD_DIST)/libmozjs-115-jit-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); fi

	$(call SIGN,libmozjs-115-jit-0,general.xml)
	$(call PACK,libmozjs-115-jit-0,DEB_MOZJSJIT_V)
	$(call PACK,libmozjs-115-jit-dev,DEB_MOZJSJIT_V)
	rm -rf $(BUILD_DIST)/libmozjs-115-jit-0 $(BUILD_DIST)/libmozjs-115-jit-dev

.PHONY: mozjs-jit mozjs-jit-package
