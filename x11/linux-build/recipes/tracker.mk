ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Tracker SPARQL client/store library only (libtracker-sparql-3.0). Required
# by nautilus's search engine, which links it with no build-time opt-out.
# The indexer daemon (localsearch/tracker-miners) is runtime-optional:
# without it nautilus runs but full-text search returns nothing.

SUBPROJECTS      += tracker
TRACKER_MAJOR_V  := 3.7
TRACKER_VERSION  := $(TRACKER_MAJOR_V).3
# -2: bumped after switching -Dunicode_support to icu (was unistring); same
# upstream version, different deb revision.
DEB_TRACKER_V    ?= $(TRACKER_VERSION)-2+ios1

tracker-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/tracker/$(TRACKER_MAJOR_V)/tracker-$(TRACKER_VERSION).tar.xz)
	$(call EXTRACT_TAR,tracker-$(TRACKER_VERSION).tar.xz,tracker-$(TRACKER_VERSION),tracker)
	# Keep the strftime cross-build probe fallback in the port patch stack.
	$(call DO_PATCH,tracker,tracker,-p1)
	mkdir -p $(BUILD_WORK)/tracker/build
	echo -e "[host_machine]\n \
	system = 'darwin'\n \
	cpu_family = '$(shell echo $(GNU_HOST_TRIPLE) | cut -d- -f1)'\n \
	cpu = '$(MEMO_ARCH)'\n \
	endian = 'little'\n \
	[properties]\n \
	root = '$(BUILD_BASE)'\n \
	needs_exe_wrapper = true\n \
	sqlite3_has_fts5 = 'true'\n \
	[built-in options]\n \
	prefix ='$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)'\n \
	[binaries]\n \
	c = '$(CC)'\n \
	cpp = '$(CXX)'\n \
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/tracker/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/tracker/.build_complete),)
tracker:
	@echo "Using previously built tracker."
else
tracker: tracker-setup glib2.0 sqlite3 json-glib icu4c
	# unicode_support=icu now that icu4c.mk fixes the cross-build (it was blocked by a
	# MAKEFLAGS CC/CXX leak into ICU's native host tools). Gives tracker-fts real ICU
	# collation/tokenization instead of unistring's fallback.
	cd $(BUILD_WORK)/tracker/build && meson \
		--cross-file cross.txt \
		-Ddocs=false \
		-Dintrospection=disabled \
		-Dvapi=disabled \
		-Dman=false \
		-Dstemmer=disabled \
		-Dunicode_support=icu \
		-Dsystemd_user_services=false \
		-Dtests=false \
		-Dtest_utils=false \
		-Dbash_completion=false \
		..
	+ninja -C $(BUILD_WORK)/tracker/build
	+DESTDIR="$(BUILD_STAGE)/tracker" ninja -C $(BUILD_WORK)/tracker/build install
	$(call AFTER_BUILD,copy)
endif

tracker-package: tracker-stage
	rm -rf $(BUILD_DIST)/libtracker-sparql-3.0-0 $(BUILD_DIST)/libtracker-sparql-dev
	mkdir -p $(BUILD_DIST)/libtracker-sparql-3.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libtracker-sparql-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libtracker-sparql-3.0-0 (runtime dylib + tracker-3.0 store modules + bin + share/tracker3)
	cp -a $(BUILD_STAGE)/tracker/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libtracker-sparql-3.0.0.dylib $(BUILD_DIST)/libtracker-sparql-3.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	if [ -d "$(BUILD_STAGE)/tracker/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/tracker-3.0" ]; then \
		cp -a $(BUILD_STAGE)/tracker/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/tracker-3.0 $(BUILD_DIST)/libtracker-sparql-3.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib; \
	fi
	if [ -d "$(BUILD_STAGE)/tracker/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/tracker3" ]; then \
		mkdir -p $(BUILD_DIST)/libtracker-sparql-3.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share; \
		cp -a $(BUILD_STAGE)/tracker/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/tracker3 $(BUILD_DIST)/libtracker-sparql-3.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share; \
	fi

	# libtracker-sparql-dev (headers, symlink, .pc)
	cp -a $(BUILD_STAGE)/tracker/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libtracker-sparql-3.0.0.dylib|tracker-3.0) $(BUILD_DIST)/libtracker-sparql-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/tracker/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libtracker-sparql-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,libtracker-sparql-3.0-0,general.xml)
	$(call PACK,libtracker-sparql-3.0-0,DEB_TRACKER_V)
	$(call PACK,libtracker-sparql-dev,DEB_TRACKER_V)
	rm -rf $(BUILD_DIST)/libtracker-sparql-3.0-0 $(BUILD_DIST)/libtracker-sparql-dev

.PHONY: tracker tracker-package
