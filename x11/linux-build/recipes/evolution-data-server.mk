ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# evolution-data-server.mk — EDS 3.52 (libedataserver/libecal/libebook + the D-Bus factories),
# the GNOME calendar/contacts backend. This is THE package ICU was built to unblock: gnome-shell
# 46's calendar-server needs libecal-2.0/libedataserver-1.2 (both >= 3.33.1; see
# recipes/gnome-shell-ios-fixes.sh, whose EDS-ectomy this build makes reversible), and EDS
# requires ICU unconditionally (pkg_check_modules icu-i18n; e-alphabet-index is ICU C++).
# 3.52.4 = last 3.52 point release, the Ubuntu 24.04 / ICU 74.2 / GNOME 46 pairing.
#
# Feature surface is cut to what the shell's calendar needs (client libs + source registry +
# calendar/addressbook factories over D-Bus). Everything OFF has a missing-on-iOS dep chain:
# GTK/GTK4+canberra (UI/alarm-notify), WebKitGTK OAuth2 prompts, GOA, gweather4 (weather
# calendars; re-enable later if task #29's gweather4 lands), NSS/NSPR (SMIME), krb5, OpenLDAP,
# Berkeley DB (ancient addressbook migration). Introspection OFF = on-device g-ir pass later.
#
# CROSS NOTES (all verified against the 3.52.4 tree before this recipe was written):
#  - Three CHECK_C_SOURCE_RUNS need their result vars pre-seeded (try_run can't execute the
#    cross-built iOS binaries): _correct_iconv, HAVE_LKSTRFTIME (Darwin strftime supports
#    %l/%k), and _decoded (data/CMakeLists.txt decodes the obfuscated Google OAuth client id;
#    can't be configured away — the top-level CMakeLists force-defaults the id whenever it's
#    ""). The iconv and _decoded probes' real job is a side-effect FILE the configure then
#    file(READ)s, so both get pre-dropped into the build dir: iconv-detect.h with values from
#    running iconv-detect.c against Darwin libiconv on a macOS host ("iso-%d-%d" /
#    "iso-%d-%s" / "UCS-4BE" — all three names also valid in GNU libiconv 1.17, what the
#    target actually links, which is case-insensitive), and an EMPTY oauth2-google-client-id
#    (empty scheme -> the x-scheme-handler registration self-skips; there is no xdg URI
#    dispatch on iOS to register with anyway).
#  - All glib codegen (mkenums/genmarshal/gdbus-codegen/compile-resources) is find_program ->
#    host tools; gperf is a host tool (build-eds.sh installs it).
#  - ENABLE_SCHEMAS_COMPILE=OFF: the install hook would compile schemas into the BUILDER's
#    /var/jb; the desktop's model is one on-device glib-compile-schemas pass post-install.
#  - malloc_trim/_NL_ADDRESS_COUNTRY_AB2/elf-backtrace probes all fail cleanly on Darwin
#    (guarded fallbacks); the vendored-strptime locale_t code is behind #ifdef _LIBC (inert).

SUBPROJECTS   += evolution-data-server
EDS_MAJOR_V   := 3.52
EDS_VERSION   := $(EDS_MAJOR_V).4
DEB_EDS_V     ?= $(EDS_VERSION)

evolution-data-server-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/evolution-data-server/$(EDS_MAJOR_V)/evolution-data-server-$(EDS_VERSION).tar.xz)
	$(call EXTRACT_TAR,evolution-data-server-$(EDS_VERSION).tar.xz,evolution-data-server-$(EDS_VERSION),evolution-data-server)
	# UPSTREAM BUG (3.52.4): FindSMIME.cmake's header says the nss/nspr search is skipped
	# "unless -DENABLE_SMIME=OFF is used", but the module never consults the option — its
	# only return() is the pkg-config-success path, so on a sysroot without nss/nspr the
	# manual search FATAL_ERRORs ("NSPR headers not found") even with SMIME off. Insert the
	# missing early return right after the output vars get their documented empty defaults.
	if ! grep -q 'if(NOT ENABLE_SMIME)' $(BUILD_WORK)/evolution-data-server/cmake/modules/FindSMIME.cmake; then \
		perl -0pi -e 's{set\(MOZILLA_NSS_LIB_DIR ""\)\n}{set(MOZILLA_NSS_LIB_DIR "")\n\nif(NOT ENABLE_SMIME)\n\treturn()\nendif(NOT ENABLE_SMIME)\n}' \
			$(BUILD_WORK)/evolution-data-server/cmake/modules/FindSMIME.cmake; \
	fi
	grep -q 'if(NOT ENABLE_SMIME)' $(BUILD_WORK)/evolution-data-server/cmake/modules/FindSMIME.cmake
	# SetupBuildFlags.cmake prepends the GNU-ld-only `-Wl,--no-undefined` to ALL linker flags
	# for any Clang/GNU compiler not on *BSD — Darwin falls in, but ld64 spells it
	# `-undefined error` and errors out on the GNU form ("ld: unknown option: --no-undefined"),
	# which torpedoes EVERY configure probe link (sys/wait.h/zlib/fsync all "not found").
	# Strip it: ld64's default for dylibs/two-level namespace is -undefined error anyway, so
	# the NOUNDEFS discipline is preserved.
	sed -i 's/-Wl,--no-undefined //g' \
		$(BUILD_WORK)/evolution-data-server/cmake/modules/SetupBuildFlags.cmake
	! grep -q -- '--no-undefined' $(BUILD_WORK)/evolution-data-server/cmake/modules/SetupBuildFlags.cmake

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
	+$(MAKE) -C $(BUILD_WORK)/evolution-data-server/build
	+$(MAKE) -C $(BUILD_WORK)/evolution-data-server/build install \
		DESTDIR="$(BUILD_STAGE)/evolution-data-server"
	$(call AFTER_BUILD,copy)
endif

evolution-data-server-package: evolution-data-server-stage
	# evolution-data-server.mk Package Structure — one runtime deb (Debian's 15-way split
	# buys nothing here: gnome-shell is the only consumer) + one -dev deb.
	rm -rf $(BUILD_DIST)/evolution-data-server{,-dev}
	mkdir -p $(BUILD_DIST)/evolution-data-server$(MEMO_PREFIX) \
		$(BUILD_DIST)/evolution-data-server-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# evolution-data-server.mk Prep evolution-data-server (dylibs+symlinks, module dirs,
	# libexec factories, D-Bus services, GSettings schemas). Copy the CONTENTS of the staged
	# prefix (copying $(MEMO_PREFIX) itself would drop the leading var/ from /var/jb).
	cp -a $(BUILD_STAGE)/evolution-data-server$(MEMO_PREFIX)/. \
		$(BUILD_DIST)/evolution-data-server$(MEMO_PREFIX)/

	# evolution-data-server.mk Prep evolution-data-server-dev (headers + pkgconfig; leave
	# every dylib symlink in the runtime deb so its lib/ dirs stay self-consistent)
	mv $(BUILD_DIST)/evolution-data-server/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/evolution-data-server-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	mv $(BUILD_DIST)/evolution-data-server/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/evolution-data-server-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	rm -rf $(BUILD_DIST)/evolution-data-server/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man \
		$(BUILD_DIST)/evolution-data-server/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/doc

	# evolution-data-server.mk Sign
	$(call SIGN,evolution-data-server,general.xml)

	# evolution-data-server.mk Make .debs
	$(call PACK,evolution-data-server,DEB_EDS_V)
	$(call PACK,evolution-data-server-dev,DEB_EDS_V)

	# evolution-data-server.mk Build cleanup
	rm -rf $(BUILD_DIST)/evolution-data-server{,-dev}

.PHONY: evolution-data-server evolution-data-server-package
