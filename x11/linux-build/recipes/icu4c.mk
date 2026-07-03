ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# icu4c.mk — OVERRIDE of upstream Procursus icu4c (69.1 -> 74.2) for the Linux-Docker cross
# pipeline (build-icu.sh). ICU is built TWICE per its official cross pattern (icu4c/source
# README "How To Cross Compile ICU"): a NATIVE host build provides the data-generation tools
# (genrb/icupkg/pkgdata) that the iOS cross build reuses via --with-cross-build. Upstream's
# recipe already does that, but two leaks broke the native step on a Linux build host:
#   (1) our drivers pass CC/CXX=<darwin cross wrappers> on the make COMMAND LINE, and GNU
#       make forwards command-line overrides into every sub-make via MAKEFLAGS — so the host
#       tools compiled with the iOS clang++ ("'memory' file not found": no host libc++).
#       Explicit assignments on the sub-make invocation beat MAKEFLAGS-inherited ones, so the
#       host $(MAKE) below re-pins the *_FOR_BUILD toolchain.
#   (2) the parent Makefile exports the darwin AR/RANLIB into the environment and
#       BUILD_CONFIGURE_FLAGS does not cover them — pin host ones for the host build.
# Data packaging: default "library" (icudt embedded in libicudata.dylib, same as Debian) —
# loads through plain dyld, no ICU_DATA path lookup to break on-device.
# ICU 74.2 = the Ubuntu 24.04 pairing for our GNOME 46 stack (EDS 3.52, tracker 3.x).

SUBPROJECTS += icu4c
ICU_VERSION := 74.2
ICU_API_V   := $(shell echo $(ICU_VERSION) | cut -f1 -d.)
DEB_ICU_V   ?= $(ICU_VERSION)+ios1

RANLIB_FOR_BUILD := $(shell command -v ranlib)

icu4c-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE), \
		https://github.com/unicode-org/icu/releases/download/release-$(shell echo $(ICU_VERSION) | sed 's/\./-/')/icu4c-$(shell echo $(ICU_VERSION) | sed 's/\./_/g')-src.tgz)
	# EXTRACT_TAR no-ops when build_work/icu4c already exists, so a tree left by an older
	# recipe version (e.g. upstream 69.1) would silently get built instead of $(ICU_VERSION).
	# Wipe any tree whose extracted version doesn't match before extracting.
	if [ -d $(BUILD_WORK)/icu4c ] && ! grep -q "^PACKAGE_VERSION='$(ICU_VERSION)'" $(BUILD_WORK)/icu4c/source/configure 2>/dev/null; then \
		echo "icu4c: stale source tree in build_work (not $(ICU_VERSION)), wiping"; \
		rm -rf $(BUILD_WORK)/icu4c; \
	fi
	$(call EXTRACT_TAR,icu4c-$(shell echo $(ICU_VERSION) | sed 's/\./_/g')-src.tgz,icu,icu4c)
	mkdir -p $(BUILD_WORK)/icu4c/host

ifneq ($(wildcard $(BUILD_WORK)/icu4c/.build_complete),)
icu4c:
	@echo "Using previously built icu4c."
else
icu4c: .SHELLFLAGS=-O extglob -c
icu4c: icu4c-setup
	cd $(BUILD_WORK)/icu4c/host && ../source/configure \
		$(BUILD_CONFIGURE_FLAGS) \
		AR="$(AR_FOR_BUILD)" \
		RANLIB="$(RANLIB_FOR_BUILD)" \
		--disable-samples \
		--disable-tests
	+$(MAKE) -C $(BUILD_WORK)/icu4c/host \
		CC="$(CC_FOR_BUILD)" \
		CXX="$(CXX_FOR_BUILD)" \
		AR="$(AR_FOR_BUILD)" \
		RANLIB="$(RANLIB_FOR_BUILD)"
	cd $(BUILD_WORK)/icu4c/source && ./configure \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--with-cross-build=$(BUILD_WORK)/icu4c/host \
		--with-data-packaging=library \
		--disable-samples \
		--disable-tests \
		LDFLAGS="$(LDFLAGS) -headerpad_max_install_names"
	+$(MAKE) -C $(BUILD_WORK)/icu4c/source
	+$(MAKE) -C $(BUILD_WORK)/icu4c/source install \
		DESTDIR=$(BUILD_STAGE)/icu4c
	$(call AFTER_BUILD,copy)

	for lib in $(BUILD_STAGE)/icu4c/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libicu*.$(ICU_VERSION).dylib $(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libicu*.$(ICU_VERSION).dylib; do \
		$(I_N_T) -id $(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/$$(basename $${lib} .$(ICU_VERSION).dylib).$(ICU_API_V).dylib $$lib; \
		$(LN_S) $$(basename $${lib} .$(ICU_VERSION).dylib).$(ICU_VERSION).dylib $$(echo $$lib | cut -d. -f-1).$(ICU_API_V).dylib; \
		$(LN_S) $$(basename $${lib} .$(ICU_VERSION).dylib).$(ICU_API_V).dylib $$(echo $$lib | cut -d. -f-1).dylib; \
	done

	for stuff in $(BUILD_STAGE)/icu4c/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libicu*.$(ICU_VERSION).dylib $(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libicu*.$(ICU_VERSION).dylib $(BUILD_STAGE)/icu4c/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/!(icu-config) $(BUILD_STAGE)/icu4c/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/sbin/*; do \
		$(I_N_T) -change libicudata.$(ICU_API_V).dylib $(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libicudata.$(ICU_API_V).dylib $$stuff; \
		$(I_N_T) -change libicui18n.$(ICU_API_V).dylib $(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libicui18n.$(ICU_API_V).dylib $$stuff; \
		$(I_N_T) -change libicuio.$(ICU_API_V).dylib $(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libicuio.$(ICU_API_V).dylib $$stuff; \
		$(I_N_T) -change libicutest.$(ICU_API_V).dylib $(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libicutest.$(ICU_API_V).dylib $$stuff; \
		$(I_N_T) -change libicutu.$(ICU_API_V).dylib $(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libicutu.$(ICU_API_V).dylib $$stuff; \
		$(I_N_T) -change libicuuc.$(ICU_API_V).dylib $(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libicuuc.$(ICU_API_V).dylib $$stuff; \
	done
endif

icu4c-package: .SHELLFLAGS=-O extglob -c
icu4c-package: icu4c-stage
	# icu4c.mk Package Structure
	rm -rf $(BUILD_DIST)/libicu{$(ICU_API_V),-dev} \
		$(BUILD_DIST)/icu-devtools
	mkdir -p $(BUILD_DIST)/libicu{$(ICU_API_V),-dev}/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libicu-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share \
		$(BUILD_DIST)/icu-devtools/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	# icu4c.mk Prep libicu$(ICU_API_V)
	cp -a $(BUILD_STAGE)/icu4c/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libicu*.$(ICU_API_V)*.dylib $(BUILD_DIST)/libicu$(ICU_API_V)/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# icu4c.mk Prep libicu-dev (libicutest only exists when tests are enabled; tolerate absence)
	cp -a $(BUILD_STAGE)/icu4c/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libicu{data,i18n,io,tu,uc}.dylib $(BUILD_DIST)/libicu-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	-cp -a $(BUILD_STAGE)/icu4c/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libicutest.dylib $(BUILD_DIST)/libicu-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/icu4c/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/{pkgconfig,icu} $(BUILD_DIST)/libicu-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/icu4c/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/icu $(BUILD_DIST)/libicu-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share
	# upstream's recipe forgot the headers — a -dev package without include/unicode is unusable
	# for on-device builds (the g-ir-scanner/introspection route compiles on the iPad)
	cp -a $(BUILD_STAGE)/icu4c/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libicu-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	# icu4c.mk Prep icu-devtools
	cp -a $(BUILD_STAGE)/icu4c/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{sbin,bin,share} $(BUILD_DIST)/icu-devtools/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	rm -f $(BUILD_DIST)/icu-devtools/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/icu-config
	rm -f $(BUILD_DIST)/icu-devtools/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man/man1/icu-config.1$(MEMO_MANPAGE_SUFFIX)
	rm -rf $(BUILD_DIST)/icu-devtools/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/icu

	# icu4c.mk Sign
	$(call SIGN,libicu$(ICU_API_V),general.xml)
	$(call SIGN,icu-devtools,general.xml)

	# icu4c.mk Make .debs
	$(call PACK,libicu$(ICU_API_V),DEB_ICU_V)
	$(call PACK,libicu-dev,DEB_ICU_V)
	$(call PACK,icu-devtools,DEB_ICU_V)

	# icu4c.mk Build cleanup
	rm -rf $(BUILD_DIST)/libicu{$(ICU_API_V),-dev} \
		$(BUILD_DIST)/icu-devtools

.PHONY: icu4c icu4c-package
