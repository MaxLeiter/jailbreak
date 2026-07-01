ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# tracker.mk — Tracker SPARQL (libtracker-sparql-3.0), the local RDF/SQLite store. Required
# by nautilus (its search engine links tracker-sparql-3.0, no build-time opt-out). NOTE: this
# is only the CLIENT/STORE library; the indexer daemon is `localsearch`/tracker-miners, which
# is runtime-OPTIONAL — without it, nautilus runs but full-text search returns nothing. So we
# build tracker(-sparql) and skip the miners for first-light.
#
# DEPENDS (target): glib + sqlite3 (prebuilt) + json-glib + libunistring (+ dbus at runtime).
# VERIFY before build: soname (libtracker-sparql-3.0.0.dylib) and that cross meson doesn't try
# to run target tooling for the ontology resources.
#
# DRAFT — Phase 1, NOT built/verified. Mirrors recipes/pango.mk style.

SUBPROJECTS      += tracker
TRACKER_MAJOR_V  := 3.7
TRACKER_VERSION  := $(TRACKER_MAJOR_V).3
# -2: rebuilt with -Dunicode_support=icu (was unistring) once icu4c.mk landed — real
# ICU collation/tokenization for FTS. Same upstream version, so bump the deb revision.
DEB_TRACKER_V    ?= $(TRACKER_VERSION)-2

tracker-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/tracker/$(TRACKER_MAJOR_V)/tracker-$(TRACKER_VERSION).tar.xz)
	$(call EXTRACT_TAR,tracker-$(TRACKER_VERSION).tar.xz,tracker-$(TRACKER_VERSION),tracker)
	# meson.build probes the libc strftime 4-digit-year modifier with cc.run() and has NO
	# cross fallback (unlike the sqlite fts5 probe, which reads a cross property) -> it hard
	# aborts with "Can not run test applications in this cross environment." Replace the whole
	# cc.run block with the correct Darwin answer: '%Y' formats every modern (>=1000) date
	# correctly; only pre-1000 years (irrelevant to a file manager) would differ.
	perl -0777 -i -pe "s/result = cc\.run\('''.*?year_modifier = result\.stdout\(\)\s*\n\s*endif/year_modifier = '%Y'/s" $(BUILD_WORK)/tracker/meson.build
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
	# unicode_support: `icu`. The first build forced unistring because ICU "couldn't cross-
	# build here" — that wall was a MAKEFLAGS CC/CXX leak into ICU's native host tools, fixed
	# in recipes/icu4c.mk (native-then-cross). With libicu74 in BUILD_BASE, tracker-fts gets
	# real ICU locale collation + tokenization (the one cost the unistring build accepted).
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
