ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Compiled Boost components shared by Wesnoth and 0 A.D.  Headers remain in a
# separate package so ports which only use header-only Boost do not pull these
# dylibs into their runtime closure.

SUBPROJECTS              += boost-games
BOOST_GAMES_VERSION       := 1.90.0
DEB_BOOST_GAMES_V        ?= $(BOOST_GAMES_VERSION)+ios1

boost-games-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/boostorg/boost/releases/download/boost-$(BOOST_GAMES_VERSION)/boost-$(BOOST_GAMES_VERSION)-cmake.tar.xz)
	$(call EXTRACT_TAR,boost-$(BOOST_GAMES_VERSION)-cmake.tar.xz,boost-$(BOOST_GAMES_VERSION),boost-games)
	rm -rf $(BUILD_WORK)/boost-games/build
	mkdir -p $(BUILD_WORK)/boost-games/build

ifneq ($(wildcard $(BUILD_WORK)/boost-games/.build_complete),)
boost-games:
	@echo "Using previously built Boost game libraries."
else
boost-games: boost-games-setup
	cd $(BUILD_WORK)/boost-games/build && cmake .. -G Ninja \
		$(DEFAULT_CMAKE_FLAGS) \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_INSTALL_PREFIX=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) \
		-DBUILD_SHARED_LIBS=ON \
		-DBUILD_TESTING=OFF \
		-DBOOST_ENABLE_CMAKE=ON \
		-DBOOST_INCLUDE_LIBRARIES="atomic;chrono;context;coroutine;date_time;filesystem;iostreams;locale;program_options;random;regex;system;thread"
	+ninja -C $(BUILD_WORK)/boost-games/build
	+DESTDIR="$(BUILD_STAGE)/boost-games" ninja -C $(BUILD_WORK)/boost-games/build install
	$(call AFTER_BUILD,copy)
endif

boost-games-package: boost-games-stage
	rm -rf $(BUILD_DIST)/libboost-game1.90 $(BUILD_DIST)/libboost-game-dev
	mkdir -p \
		$(BUILD_DIST)/libboost-game1.90/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libboost-game-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/boost-games/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libboost_*.*.dylib \
		$(BUILD_DIST)/libboost-game1.90/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/
	cp -a $(BUILD_STAGE)/boost-games/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libboost-game-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/
	mkdir -p $(BUILD_DIST)/libboost-game-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/boost-games/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libboost_*.dylib \
		$(BUILD_DIST)/libboost-game-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/
	if [ -d "$(BUILD_STAGE)/boost-games/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/cmake" ]; then \
		cp -a $(BUILD_STAGE)/boost-games/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/cmake \
			$(BUILD_DIST)/libboost-game-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/; \
	fi
	$(call SIGN,libboost-game1.90,general.xml)
	$(call PACK,libboost-game1.90,DEB_BOOST_GAMES_V)
	$(call PACK,libboost-game-dev,DEB_BOOST_GAMES_V)
	rm -rf $(BUILD_DIST)/libboost-game1.90 $(BUILD_DIST)/libboost-game-dev

.PHONY: boost-games boost-games-package
