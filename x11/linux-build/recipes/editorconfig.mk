ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# editorconfig-core-c — libeditorconfig, the EditorConfig (.editorconfig) parser/locator.
# HARD build dependency of gnome-text-editor (meson `dependency('editorconfig')`, not a
# feature option), and Procursus ships no recipe for it — so we add one. Plain CMake
# project; its only external dependency is PCRE2 (already built). DEFAULT_CMAKE_FLAGS
# cross-compiles to Darwin/iOS (CMAKE_SYSTEM_NAME=Darwin, CMAKE_FIND_ROOT_PATH=BUILD_BASE),
# so find_library/find_path resolve PCRE2 out of the sysroot with no extra wiring.

SUBPROJECTS          += editorconfig
EDITORCONFIG_VERSION := 0.12.11
DEB_EDITORCONFIG_V   ?= $(EDITORCONFIG_VERSION)+ios1

editorconfig-setup: setup
	$(call GITHUB_ARCHIVE,editorconfig,editorconfig-core-c,$(EDITORCONFIG_VERSION),v$(EDITORCONFIG_VERSION))
	$(call EXTRACT_TAR,editorconfig-core-c-$(EDITORCONFIG_VERSION).tar.gz,editorconfig-core-c-$(EDITORCONFIG_VERSION),editorconfig)

ifneq ($(wildcard $(BUILD_WORK)/editorconfig/.build_complete),)
editorconfig:
	@echo "Using previously built editorconfig."
else
editorconfig: editorconfig-setup pcre2
	# Clean the build dir so a prior crashed configure can't leave a poisoned cache.
	# -DBUILD_DOCUMENTATION=OFF avoids the doxygen/man pass; -DBUILD_TESTING=OFF skips
	# the editorconfig-core-test submodule (absent in the release tarball).
	# CMAKE_INSTALL_PKGCONFIGDIR must be ABSOLUTE (it's a CACHE PATH; CMake resolves a
	# relative value against cmake's CWD, not the prefix — same gotcha as epoll-shim).
	rm -rf $(BUILD_WORK)/editorconfig/build
	cd $(BUILD_WORK)/editorconfig && cmake -B build \
		$(DEFAULT_CMAKE_FLAGS) \
		-DBUILD_DOCUMENTATION=OFF \
		-DBUILD_TESTING=OFF \
		-DPKG_CONFIG_EXECUTABLE=$(BUILD_TOOLS)/cross-pkg-config \
		-DCMAKE_INSTALL_PKGCONFIGDIR=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig
	+$(MAKE) -C $(BUILD_WORK)/editorconfig/build
	+$(MAKE) -C $(BUILD_WORK)/editorconfig/build install \
		DESTDIR="$(BUILD_STAGE)/editorconfig"
	$(call AFTER_BUILD,copy)
endif

editorconfig-package: editorconfig-stage
	# editorconfig.mk Package Structure
	rm -rf $(BUILD_DIST)/libeditorconfig0 $(BUILD_DIST)/libeditorconfig-dev
	mkdir -p $(BUILD_DIST)/libeditorconfig0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libeditorconfig-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# editorconfig.mk Prep libeditorconfig0 (runtime dylib + soname symlink)
	cp -a $(BUILD_STAGE)/editorconfig/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libeditorconfig.*.dylib \
		$(BUILD_DIST)/libeditorconfig0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# editorconfig.mk Prep libeditorconfig-dev (headers, .pc, bare symlink, static lib).
	# The editorconfig CLI (bin/editorconfig) is not needed by gnome-text-editor; drop it.
	cp -a $(BUILD_STAGE)/editorconfig/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libeditorconfig-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/editorconfig/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libeditorconfig.*.dylib) \
		$(BUILD_DIST)/libeditorconfig-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true

	# editorconfig.mk Sign
	$(call SIGN,libeditorconfig0,general.xml)

	# editorconfig.mk Make .debs
	$(call PACK,libeditorconfig0,DEB_EDITORCONFIG_V)
	$(call PACK,libeditorconfig-dev,DEB_EDITORCONFIG_V)

	# editorconfig.mk Build cleanup
	rm -rf $(BUILD_DIST)/libeditorconfig0 $(BUILD_DIST)/libeditorconfig-dev

.PHONY: editorconfig editorconfig-package
