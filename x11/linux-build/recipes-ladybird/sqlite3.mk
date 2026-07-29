ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Compiles the amalgamation directly (sqlite.org's ./configure needs autosetup since 3.49,
# incompatible with our flags). SONAME MUST be libsqlite3.1.dylib, not upstream's .0 — shipping
# .0 previously let apt upgrade devices onto libsqlite3-1 and delete the .1 dylib, bricking
# every consumer (tracker/nautilus/GNOME, Qt6/KDE).

SUBPROJECTS         += sqlite3
SQLITE3_VERSION     := 3.52.0
SQLITE3_AUTOCONF_V  := 3520000
SQLITE3_DL_YEAR     := 2026
DEB_SQLITE3_V       ?= $(SQLITE3_VERSION)+ios3
# This package name shadows Procursus's libsqlite3-1, so the build must export at least
# what theirs does or consumers linked against theirs lose symbols at dyld. PREUPDATE_HOOK
# and SESSION are the two that matter: without them we drop the whole sqlite3_preupdate_*
# and sqlite3session_*/sqlite3changeset_*/sqlite3changegroup_* surface (49 symbols) that
# the Procursus deb exports. Procursus's current recipe no longer sets them, but their
# PUBLISHED deb does, and the published deb is what a device already has installed.
# Not matched on purpose: sqlite3_fts3_may_be_corrupt, sqlite3_fts5_may_be_corrupt and
# sqlite3_unsupported_selecttrace only exist under SQLITE_DEBUG/SQLITE_TEST, which carry
# assert() and tracing costs no shipping build should take.
SQLITE3_DEFINES     := -DSQLITE_ENABLE_COLUMN_METADATA=1 -DSQLITE_MAX_VARIABLE_NUMBER=250000 \
	-DSQLITE_ENABLE_RTREE=1 -DSQLITE_ENABLE_FTS3=1 -DSQLITE_ENABLE_FTS3_PARENTHESIS=1 \
	-DSQLITE_ENABLE_FTS5=1 -DSQLITE_ENABLE_JSON1=1 -DSQLITE_ENABLE_DBSTAT_VTAB=1 \
	-DSQLITE_THREADSAFE=1 -DSQLITE_ENABLE_UNLOCK_NOTIFY=1 \
	-DSQLITE_ENABLE_PREUPDATE_HOOK=1 -DSQLITE_ENABLE_SESSION=1
SQLITE3_STAGE_PREFIX = $(BUILD_STAGE)/sqlite3$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

sqlite3-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://www.sqlite.org/$(SQLITE3_DL_YEAR)/sqlite-autoconf-$(SQLITE3_AUTOCONF_V).tar.gz)
	# Stale-tree guard (ICU lesson): this volume was cloned from the gtk track, which carries an
	# OLD sqlite3 3.34.1 tree in build_work. EXTRACT_TAR no-ops when build_work/sqlite3 exists, so
	# without this wipe the 3.34.1 source rebuilds and gets mislabeled $(SQLITE3_VERSION)+ios1.
	if [ -d $(BUILD_WORK)/sqlite3 ] && ! grep -q "^PACKAGE_VERSION='$(SQLITE3_VERSION)'" $(BUILD_WORK)/sqlite3/configure 2>/dev/null; then \
		echo "sqlite3: stale source tree in build_work (not $(SQLITE3_VERSION)), wiping"; \
		rm -rf $(BUILD_WORK)/sqlite3 $(BUILD_STAGE)/sqlite3; \
	fi
	$(call EXTRACT_TAR,sqlite-autoconf-$(SQLITE3_AUTOCONF_V).tar.gz,sqlite-autoconf-$(SQLITE3_AUTOCONF_V),sqlite3)

ifneq ($(wildcard $(BUILD_WORK)/sqlite3/.build_complete),)
sqlite3:
	@echo "Using previously built sqlite3."
else
sqlite3: sqlite3-setup
	mkdir -p $(SQLITE3_STAGE_PREFIX)/lib/pkgconfig $(SQLITE3_STAGE_PREFIX)/include $(SQLITE3_STAGE_PREFIX)/bin
	# shared library (libsqlite3.1.dylib, Procursus soname) straight from the amalgamation
	cd $(BUILD_WORK)/sqlite3 && $(CC) $(CFLAGS) $(CPPFLAGS) $(SQLITE3_DEFINES) \
		-dynamiclib -install_name $(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libsqlite3.1.dylib \
		-compatibility_version 9.0.0 -current_version 9.6.0 \
		-o $(SQLITE3_STAGE_PREFIX)/lib/libsqlite3.1.dylib sqlite3.c $(LDFLAGS)
	$(LN_S) libsqlite3.1.dylib $(SQLITE3_STAGE_PREFIX)/lib/libsqlite3.dylib
	# ladybird linked against the .0 name while +ios1 was current; keep it resolvable
	$(LN_S) libsqlite3.1.dylib $(SQLITE3_STAGE_PREFIX)/lib/libsqlite3.0.dylib
	# static library
	cd $(BUILD_WORK)/sqlite3 && $(CC) $(CFLAGS) $(CPPFLAGS) $(SQLITE3_DEFINES) -c sqlite3.c -o sqlite3.o
	$(AR) rcs $(SQLITE3_STAGE_PREFIX)/lib/libsqlite3.a $(BUILD_WORK)/sqlite3/sqlite3.o
	# CLI (linked against the staged dylib)
	cd $(BUILD_WORK)/sqlite3 && $(CC) $(CFLAGS) $(CPPFLAGS) $(SQLITE3_DEFINES) \
		-o $(SQLITE3_STAGE_PREFIX)/bin/sqlite3 shell.c \
		-L$(SQLITE3_STAGE_PREFIX)/lib -lsqlite3 $(LDFLAGS)
	# headers
	cp -a $(BUILD_WORK)/sqlite3/sqlite3.h $(BUILD_WORK)/sqlite3/sqlite3ext.h $(SQLITE3_STAGE_PREFIX)/include
	# pkg-config
	printf 'prefix=%s\nexec_prefix=$${prefix}\nlibdir=$${exec_prefix}/lib\nincludedir=$${prefix}/include\n\nName: SQLite\nDescription: SQL database engine\nVersion: %s\nLibs: -L$${libdir} -lsqlite3\nCflags: -I$${includedir}\n' \
		"$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)" "$(SQLITE3_VERSION)" > $(SQLITE3_STAGE_PREFIX)/lib/pkgconfig/sqlite3.pc
	$(call AFTER_BUILD,copy)
endif

sqlite3-package: .SHELLFLAGS=-O extglob -c
sqlite3-package: sqlite3-stage
	# sqlite3.mk Package Structure
	rm -rf $(BUILD_DIST)/sqlite3 $(BUILD_DIST)/libsqlite3-{1,dev}
	mkdir -p $(BUILD_DIST)/sqlite3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin \
		$(BUILD_DIST)/libsqlite3-{1,dev}/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# sqlite3.mk Prep sqlite3 (CLI)
	cp -a $(BUILD_STAGE)/sqlite3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/sqlite3 $(BUILD_DIST)/sqlite3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin

	# sqlite3.mk Prep libsqlite3-1 (runtime: versioned dylib)
	cp -a $(BUILD_STAGE)/sqlite3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libsqlite3.[0-9]*.dylib $(BUILD_DIST)/libsqlite3-1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# sqlite3.mk Prep libsqlite3-dev
	cp -a $(BUILD_STAGE)/sqlite3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libsqlite3-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/sqlite3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/{pkgconfig,libsqlite3.{a,dylib}} $(BUILD_DIST)/libsqlite3-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# sqlite3.mk Sign
	$(call SIGN,sqlite3,general.xml)
	$(call SIGN,libsqlite3-1,general.xml)

	# sqlite3.mk Make .debs
	$(call PACK,sqlite3,DEB_SQLITE3_V)
	$(call PACK,libsqlite3-1,DEB_SQLITE3_V)
	$(call PACK,libsqlite3-dev,DEB_SQLITE3_V)

	# sqlite3.mk Build cleanup
	rm -rf $(BUILD_DIST)/sqlite3 $(BUILD_DIST)/libsqlite3-{1,dev}

.PHONY: sqlite3 sqlite3-package
