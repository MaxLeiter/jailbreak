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
	# DOWNLOAD_FILES neither verifies nor re-fetches, and skips any file that
	# already exists. A connection that drops mid-transfer therefore leaves a
	# truncated archive that tar unpacks *partially* and every later run reuses:
	# the 2026-08-02 failure was a half-extracted tree where CMake could not find
	# Boost::config because libs/config had never been written. Fail here, and
	# discard the bad archive so the next run refetches instead of repeating it.
	if ! xz -t $(BUILD_SOURCE)/boost-$(BOOST_GAMES_VERSION)-cmake.tar.xz 2>/dev/null; then \
		echo "ERROR: boost-$(BOOST_GAMES_VERSION)-cmake.tar.xz is corrupt or truncated; removing" >&2; \
		rm -f $(BUILD_SOURCE)/boost-$(BOOST_GAMES_VERSION)-cmake.tar.xz; \
		exit 1; \
	fi
	# A partial tree from an earlier truncated archive survives re-extraction,
	# so clear it the way the OpenTTD recipe clears its stale source directory.
	rm -rf $(BUILD_WORK)/boost-games $(BUILD_WORK)/boost-$(BOOST_GAMES_VERSION)
	$(call EXTRACT_TAR,boost-$(BOOST_GAMES_VERSION)-cmake.tar.xz,boost-$(BOOST_GAMES_VERSION),boost-games)
	test -f $(BUILD_WORK)/boost-games/libs/config/CMakeLists.txt
	rm -rf $(BUILD_WORK)/boost-games/build
	mkdir -p $(BUILD_WORK)/boost-games/build

ifneq ($(wildcard $(BUILD_WORK)/boost-games/.build_complete),)
boost-games:
	@echo "Using previously built Boost game libraries."
else
# NOTE: keep every line of the cmake invocation below free of '#' comments. The
# backslashes join it into ONE shell command, so a comment line silently eats
# every argument after it -- which once dropped BOOST_INCLUDE_LIBRARIES, built
# all of Boost, and failed in libs/process on wordexp being unavailable on iOS.
# Wesnoth's find_package requires the graph component, and a subset build only
# creates targets for the libraries named there.
boost-games: boost-games-setup
	cd $(BUILD_WORK)/boost-games/build && cmake .. -G Ninja \
		$(DEFAULT_CMAKE_FLAGS) \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_INSTALL_PREFIX=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) \
		-DBUILD_SHARED_LIBS=ON \
		-DBUILD_TESTING=OFF \
		-DCMAKE_CXX_STANDARD=17 \
		-DCMAKE_CXX_STANDARD_REQUIRED=ON \
		-DBOOST_ENABLE_CMAKE=ON \
		-DBOOST_INCLUDE_LIBRARIES="atomic;chrono;context;coroutine;date_time;filesystem;graph;iostreams;locale;program_options;random;regex;system;thread"
	+ninja -C $(BUILD_WORK)/boost-games/build
	+DESTDIR="$(BUILD_STAGE)/boost-games" ninja -C $(BUILD_WORK)/boost-games/build install
	# A subset build installs headers ONLY for the libraries it compiles, but
	# consumers pull in far more of Boost than they link. Wesnoth alone wanted
	# process/v1/search_path.hpp, circular_buffer.hpp and logic/tribool.hpp, all
	# header-only and none of them link components. Chasing those one build at a
	# time is a treadmill, and adding them to BOOST_INCLUDE_LIBRARIES is worse:
	# Boost.Process's compiled part cannot build for iOS at all
	# (libs/process/src/shell.cpp uses wordexp/wordfree, both unavailable).
	# So install every header and keep only the COMPILED set restricted, which
	# is what an ordinary Boost distribution looks like. Headers cost build time
	# nothing.
	find $(BUILD_WORK)/boost-games/libs -type d -path '*/include/boost' | \
		while read -r headers; do \
			cp -a "$$headers/." \
				$(BUILD_STAGE)/boost-games$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/boost/; \
		done
	for header in process/v1/search_path.hpp circular_buffer.hpp logic/tribool.hpp; do \
		test -f "$(BUILD_STAGE)/boost-games$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/boost/$$header" || \
			{ echo "ERROR: boost header $$header not staged" >&2; exit 1; }; \
	done
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
