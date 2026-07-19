ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# epoll-shim — epoll/timerfd/signalfd/eventfd implemented on top of kqueue.
# This is the lynchpin that lets libwayland's event loop (src/event-loop.c, written
# against <sys/epoll.h>) build for Darwin/iOS, which has no epoll. Upstream is the
# same shim the BSDs and MacPorts use to build Wayland; it has a maintained macOS port.
#
# BUILT/PUBLISHED — libepoll-shim0 0.0.20240608+ios1. Recipe integration:
#   recipe        -> Procursus/makefiles/epoll-shim.mk
#   control files -> Procursus/build_info/libepoll-shim{0,-dev}.control
# (the wayland build driver copies recipes/ + recipes/build_info/ into the clone).
#
# CMake project. We build the shared lib for the *target* (iOS/Darwin) — DEFAULT_CMAKE_FLAGS
# already sets CMAKE_SYSTEM_NAME=Darwin, so epoll-shim selects its kqueue backend.

SUBPROJECTS       += epoll-shim
EPOLLSHIM_VERSION := 0.0.20240608
DEB_EPOLLSHIM_V   ?= $(EPOLLSHIM_VERSION)+ios1

epoll-shim-setup: setup
	$(call GITHUB_ARCHIVE,jiixyj,epoll-shim,$(EPOLLSHIM_VERSION),v$(EPOLLSHIM_VERSION))
	$(call EXTRACT_TAR,epoll-shim-$(EPOLLSHIM_VERSION).tar.gz,epoll-shim-$(EPOLLSHIM_VERSION),epoll-shim)

ifneq ($(wildcard $(BUILD_WORK)/epoll-shim/.build_complete),)
epoll-shim:
	@echo "Using previously built epoll-shim."
else
epoll-shim: epoll-shim-setup
	# Cross-compile: epoll-shim has two runtime probes that try to RUN a target binary on
	# the build host. ALLOWS_ONESHOT_TIMERS_WITH_TIMEOUT_ZERO (a kqueue check_c_source_runs)
	# compiles fine for Darwin, so CMake tries to exec the arm64 Mach-O on Linux and crashes
	# (std::bad_alloc). Pre-seed both result vars in the cache so the runs are skipped:
	#  - ALLOWS_ONESHOT...=0 enables the QUIRK_EVFILT_TIMER_DISALLOWS_ONESHOT_TIMEOUT_ZERO
	#    workaround (data 0 -> 1 for the zero-timeout one-shot edge case). This is the SAFE
	#    direction: correct whether or not XNU actually allows it, costing only a negligible
	#    1-unit delay in that rare case. (Re-verify on-device if zero-interval timerfd matters.)
	#  - HAVE_POLLRDHUP=0: POLLRDHUP is Linux-only (absent in iOS poll.h) — the default
	#    POLLRDHUP_VALUE 0x2000 is used.
	# CMAKE_INSTALL_PKGCONFIGDIR must be ABSOLUTE: it's a CACHE PATH var, and CMake resolves a
	# relative PATH cache value against cmake's CWD ($(BUILD_WORK)/epoll-shim), NOT the install
	# prefix. A relative "lib/pkgconfig" therefore lands epoll-shim.pc at build_work/.../lib/
	# pkgconfig — missing from the -dev deb AND unfindable by cross-pkg-config (breaks wayland).
	# Clean the build dir so a prior crashed configure can't leave a poisoned cache.
	rm -rf $(BUILD_WORK)/epoll-shim/build
	cd $(BUILD_WORK)/epoll-shim && cmake -B build \
		$(DEFAULT_CMAKE_FLAGS) \
		-DBUILD_SHARED_LIBS=ON \
		-DBUILD_TESTING=OFF \
		-DALLOWS_ONESHOT_TIMERS_WITH_TIMEOUT_ZERO=0 \
		-DHAVE_POLLRDHUP=0 \
		-DCMAKE_INSTALL_PKGCONFIGDIR=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig
	+$(MAKE) -C $(BUILD_WORK)/epoll-shim/build
	+$(MAKE) -C $(BUILD_WORK)/epoll-shim/build install \
		DESTDIR="$(BUILD_STAGE)/epoll-shim"
	$(call AFTER_BUILD,copy)
endif

epoll-shim-package: epoll-shim-stage
	# epoll-shim.mk Package Structure
	rm -rf $(BUILD_DIST)/libepoll-shim{0,-dev}
	mkdir -p $(BUILD_DIST)/libepoll-shim0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libepoll-shim-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# epoll-shim.mk Prep libepoll-shim0 (runtime dylib)
	cp -a $(BUILD_STAGE)/epoll-shim/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libepoll-shim.*.dylib \
		$(BUILD_DIST)/libepoll-shim0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# epoll-shim.mk Prep libepoll-shim-dev (headers under include/libepoll-shim, .pc, symlink, .a)
	cp -a $(BUILD_STAGE)/epoll-shim/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libepoll-shim-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/epoll-shim/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libepoll-shim.*.dylib) \
		$(BUILD_DIST)/libepoll-shim-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true

	# epoll-shim.mk Sign
	$(call SIGN,libepoll-shim0,general.xml)

	# epoll-shim.mk Make .debs
	$(call PACK,libepoll-shim0,DEB_EPOLLSHIM_V)
	$(call PACK,libepoll-shim-dev,DEB_EPOLLSHIM_V)

	# epoll-shim.mk Build cleanup
	rm -rf $(BUILD_DIST)/libepoll-shim{0,-dev}

.PHONY: epoll-shim epoll-shim-package
