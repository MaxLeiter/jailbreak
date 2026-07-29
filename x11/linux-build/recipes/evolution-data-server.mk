ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# EDS 3.52 is the GNOME calendar/contacts backend gnome-shell's calendar-server needs
# (libecal-2.0/libedataserver-1.2 >= 3.33.1). Requires ICU unconditionally (e-alphabet-index is
# ICU C++). 3.52.4 matches the Ubuntu 24.04 / ICU 74.2 / GNOME 46 pairing.
#
# Feature surface is cut to what the shell's calendar needs (client libs + source registry +
# calendar/addressbook factories over D-Bus). Everything else disabled has a missing-on-iOS dep
# chain: GTK/GTK4+canberra, WebKitGTK OAuth2, GOA, gweather4, NSS/NSPR (SMIME), krb5, OpenLDAP,
# Berkeley DB. Introspection off (on-device g-ir pass later).
#
# Cross-build notes:
#  - Three CHECK_C_SOURCE_RUNS can't try_run cross-built iOS binaries, so their result vars are
#    pre-seeded: _correct_iconv, HAVE_LKSTRFTIME (Darwin strftime supports %l/%k), and _decoded
#    (data/CMakeLists.txt decodes an obfuscated Google OAuth client id and force-defaults it
#    when empty). Their real job is a side-effect file configure then file(READ)s, so those are
#    pre-dropped too: iconv-detect.h (from running iconv-detect.c against Darwin libiconv; the
#    values are also valid under the GNU libiconv 1.17 the target actually links) and an empty
#    oauth2-google-client-id (empty scheme -> the xdg URI registration self-skips, which is fine
#    since there's no xdg dispatch on iOS anyway).
#  - find_program resolves into the iOS sysroot ahead of the host, but the codegen scripts found
#    there (gdbus-codegen/mkenums/genmarshal) are Mach-O and can't run on the Linux build host
#    ("Exec format error"). Their cache vars are pinned to host copies instead
#    (glib-compile-schemas/-resources, xgettext/msgfmt/msgmerge — installed by build-eds.sh).
#  - camel hard-requires NSS/NSPR regardless of ENABLE_SMIME; no iOS port exists, so setup
#    applies an NSS-ectomy patch.
#  - Two in-tree code generators (camel-gen-tables, gen-western-table) are built for TARGET and
#    then executed by custom commands, which can't run cross (Linux can't exec Mach-O). setup
#    points the custom commands at *-host copies, compiled with the host toolchain right after
#    configure (they need the generated evolution-data-server-config.h). Their output is
#    platform-independent tables, which is why upstream generates them at build time at all.
#  - ENABLE_SCHEMAS_COMPILE=OFF: that install hook would compile schemas into the builder's
#    /var/jb; the desktop does one on-device glib-compile-schemas pass post-install instead.

SUBPROJECTS   += evolution-data-server
EDS_MAJOR_V   := 3.52
EDS_VERSION   := $(EDS_MAJOR_V).4
DEB_EDS_V     ?= $(EDS_VERSION)+ios2

evolution-data-server-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/evolution-data-server/$(EDS_MAJOR_V)/evolution-data-server-$(EDS_VERSION).tar.xz)
	$(call EXTRACT_TAR,evolution-data-server-$(EDS_VERSION).tar.xz,evolution-data-server-$(EDS_VERSION),evolution-data-server)
	$(call DO_PATCH,evolution-data-server,evolution-data-server,-p1)
	grep -q 'if(NOT ENABLE_SMIME)' $(BUILD_WORK)/evolution-data-server/cmake/modules/FindSMIME.cmake
	! grep -q -- '--no-undefined' $(BUILD_WORK)/evolution-data-server/cmake/modules/SetupBuildFlags.cmake
	! grep -q 'include <nspr.h>' $(BUILD_WORK)/evolution-data-server/src/camel/camel.c
	! grep -q 'include <nspr.h>' $(BUILD_WORK)/evolution-data-server/src/camel/camel-msgport.c
	! grep -q 'include <nspr.h>' $(BUILD_WORK)/evolution-data-server/src/camel/camel-operation.c
	grep -q 'include <glib.h>' $(BUILD_WORK)/evolution-data-server/src/camel/camel-smime-context.c
	grep -q 'camel-gen-tables-host' $(BUILD_WORK)/evolution-data-server/src/camel/CMakeLists.txt
	grep -q 'gen-western-table-host' $(BUILD_WORK)/evolution-data-server/src/addressbook/libebook-contacts/CMakeLists.txt

ifneq ($(wildcard $(BUILD_WORK)/evolution-data-server/.build_complete),)
evolution-data-server:
	@echo "Using previously built evolution-data-server."
else
evolution-data-server: evolution-data-server-setup glib2.0 sqlite3 libxml2 json-glib \
		libsoup3 libsecret libical icu4c
	rm -rf $(BUILD_WORK)/evolution-data-server/build
	mkdir -p $(BUILD_WORK)/evolution-data-server/build
	printf '/* Pre-generated for the iOS cross build — see recipes/evolution-data-server.mk.\n * Output of iconv-detect.c run against Darwin libiconv; names verified against\n * GNU libiconv 1.17 (case-insensitive), the iconv the target actually links. */\n\n#define ICONV_ISO_D_FORMAT "iso-%%d-%%d"\n#define ICONV_ISO_S_FORMAT "iso-%%d-%%s"\n#define ICONV_10646 "UCS-4BE"\n' \
		> $(BUILD_WORK)/evolution-data-server/build/iconv-detect.h
	touch $(BUILD_WORK)/evolution-data-server/build/oauth2-google-client-id
	cd $(BUILD_WORK)/evolution-data-server && cmake -B build \
		$(DEFAULT_CMAKE_FLAGS) \
		-DPKG_CONFIG_EXECUTABLE=$(BUILD_TOOLS)/cross-pkg-config \
		-D_correct_iconv=1 \
		-DHAVE_LKSTRFTIME=1 \
		-D_decoded=1 \
		-DGLIB_COMPILE_SCHEMAS=/usr/bin/glib-compile-schemas \
		-DGLIB_COMPILE_RESOURCES=/usr/bin/glib-compile-resources \
		-DGETTEXT_XGETTEXT_EXECUTABLE=/usr/bin/xgettext \
		-DGETTEXT_MSGFMT_EXECUTABLE=/usr/bin/msgfmt \
		-DGETTEXT_MSGMERGE_EXECUTABLE=/usr/bin/msgmerge \
		-DENABLE_GTK=OFF \
		-DENABLE_GTK4=OFF \
		-DENABLE_OAUTH2_WEBKITGTK=OFF \
		-DENABLE_OAUTH2_WEBKITGTK4=OFF \
		-DENABLE_GOA=OFF \
		-DENABLE_WEATHER=OFF \
		-DENABLE_CANBERRA=OFF \
		-DENABLE_SMIME=OFF \
		-DWITH_KRB5=OFF \
		-DWITH_OPENLDAP=OFF \
		-DWITH_LIBDB=OFF \
		-DENABLE_INTROSPECTION=OFF \
		-DENABLE_VALA_BINDINGS=OFF \
		-DENABLE_GTK_DOC=OFF \
		-DENABLE_TESTS=OFF \
		-DENABLE_EXAMPLES=OFF \
		-DENABLE_DOT_LOCKING=OFF \
		-DENABLE_SCHEMAS_COMPILE=OFF \
		-DWITH_SYSTEMDUSERUNITDIR=no
	# env -u: Procursus exports the darwin flags into the environment; host gcc/pkg-config
	# must not see them or the host-copy compile breaks.
	cd $(BUILD_WORK)/evolution-data-server && \
		env -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS \
			-u PKG_CONFIG_PATH -u PKG_CONFIG_LIBDIR -u PKG_CONFIG_SYSROOT_DIR \
		sh -c 'gcc -O2 -Ibuild $$(/usr/bin/pkg-config --cflags glib-2.0) \
				src/camel/camel-gen-tables.c \
				-o build/camel-gen-tables-host $$(/usr/bin/pkg-config --libs glib-2.0) && \
			gcc -O2 -Ibuild $$(/usr/bin/pkg-config --cflags glib-2.0) \
				src/addressbook/libebook-contacts/gen-western-table.c \
				-o build/gen-western-table-host $$(/usr/bin/pkg-config --libs glib-2.0)'
	$(BUILD_WORK)/evolution-data-server/build/camel-gen-tables-host >/dev/null
	+$(MAKE) -C $(BUILD_WORK)/evolution-data-server/build
	+$(MAKE) -C $(BUILD_WORK)/evolution-data-server/build install \
		DESTDIR="$(BUILD_STAGE)/evolution-data-server"
	$(call AFTER_BUILD,copy)
endif

evolution-data-server-package: evolution-data-server-stage
	# One runtime + one -dev deb; Debian's 15-way split buys nothing since gnome-shell is
	# the only consumer.
	rm -rf $(BUILD_DIST)/evolution-data-server{,-dev}
	mkdir -p $(BUILD_DIST)/evolution-data-server$(MEMO_PREFIX) \
		$(BUILD_DIST)/evolution-data-server-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# Copy the CONTENTS of the staged prefix — copying $(MEMO_PREFIX) itself would drop the
	# leading var/ from /var/jb.
	cp -a $(BUILD_STAGE)/evolution-data-server$(MEMO_PREFIX)/. \
		$(BUILD_DIST)/evolution-data-server$(MEMO_PREFIX)/

	# Leave every dylib symlink in the runtime deb so its lib/ dirs stay self-consistent.
	mv $(BUILD_DIST)/evolution-data-server/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/evolution-data-server-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	mv $(BUILD_DIST)/evolution-data-server/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/evolution-data-server-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	rm -rf $(BUILD_DIST)/evolution-data-server/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man \
		$(BUILD_DIST)/evolution-data-server/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/doc

	$(call SIGN,evolution-data-server,general.xml)

	$(call PACK,evolution-data-server,DEB_EDS_V)
	$(call PACK,evolution-data-server-dev,DEB_EDS_V)

	rm -rf $(BUILD_DIST)/evolution-data-server{,-dev}

.PHONY: evolution-data-server evolution-data-server-package
