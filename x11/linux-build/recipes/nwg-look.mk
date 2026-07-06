ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# nwg-look.mk - GTK settings editor for wlroots desktops.
#
# BLOCKED, intentionally not implemented as a build: upstream nwg-look 1.1.1 is
# Go 1.25 + gotk3. That means the target binary is cgo code linking GTK3/GDK,
# GLib, and friends into a Mach-O iOS executable. This repo has C/C++/Vala/Rust
# cross patterns, but no packageable Go+cgo iPhoneOS cross-link path, no staged
# Go toolchain target integration, and no xcur2png package for cursor previews.
# Adding that path belongs in shared build tooling, outside this slice.
#
# Keeping this explicit blocker target is useful: `TARGETS="nwg-look-package"`
# fails immediately with the required shared-work items instead of pretending a
# Linux GOOS/GOARCH build would produce an iOS-runnable binary.

SUBPROJECTS        += nwg-look
NWG-LOOK_VERSION   := 1.1.1
DEB_NWG-LOOK_V     ?= $(NWG-LOOK_VERSION)+ios1

nwg-look-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/nwg-piotr/nwg-look/archive/refs/tags/v$(NWG-LOOK_VERSION).tar.gz)
	$(call EXTRACT_TAR,v$(NWG-LOOK_VERSION).tar.gz,nwg-look-$(NWG-LOOK_VERSION),nwg-look)

nwg-look:
	@echo "ERROR: nwg-look is blocked for iphoneos-arm64-rootless." >&2
	@echo "       It needs a shared Go+cgo iPhoneOS cross-build path for gotk3/GTK3" >&2
	@echo "       and an xcur2png package or feature cut for cursor previews." >&2
	@exit 2

nwg-look-package: nwg-look

.PHONY: nwg-look nwg-look-package
