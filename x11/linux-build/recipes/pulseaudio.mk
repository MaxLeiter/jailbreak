ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# pulseaudio.mk — client libraries AND the daemon.
#
# History: first built -Ddaemon=false for gnome-shell's vendored gvc (which
# hard-requires libpulse + libpulse-mainloop-glib >= 12.99.3; Procursus has no
# PulseAudio). Now the daemon is on: gvc is a full native-protocol client
# (context/introspect/subscribe), so a real PA server must answer it. The server's hardware output is
# module-xios-sink/module-xios-source (injected by
# recipes/pulseaudio-ios-fixes.sh), which forward playback to xios-audiod and
# capture from xios-mediad. The Xios daemons keep sole ownership of the iOS
# device APIs. Playback pipeline:
#   gvc / GTK apps -> libpulse -> pulseaudio -> module-xios-sink
#     -> /var/jb/tmp/xios-audio.sock -> xios-audiod -> RemoteIO -> speakers
# Capture pipeline:
#   GTK/GStreamer/parec -> libpulse -> pulseaudio -> module-xios-source
#     -> /var/jb/tmp/xios-media-mic.sock -> xios-mediad -> RemoteIO input
#
# PA builds on macOS (Homebrew) with the daemon, so the Darwin server path is
# exercised upstream; the only iOS delta is the module set (no CoreAudio HAL —
# see ports/pulseaudio/patches and pulseaudio-ios-fixes.sh).
#
# Packaging split (Debian-shaped):
#   libpulse0         client dylibs + private libpulsecommon (UNCHANGED content)
#   libpulse-dev      headers, .pc, unversioned symlinks
#   pulseaudio        daemon, modules (incl. module-xios-sink/source), libpulsecore,
#                     etc/pulse configs, profile.d/xios-pulse.sh
#   pulseaudio-utils  pactl/pacat/paplay/... debug + scripting tools
#
# The daemon needs ltdl (module loader) -> depends on the libtool subproject.
# adrian-aec=true because meson hard-errors a daemon build with zero echo
# cancellers (speex/webrtc are disabled); adrian is bundled dependency-free C.
# Requires /work/audio and /work/media mounted (module-xios-*.c, protocol
# headers, pulse-config/) — see build-audio-server.sh.

SUBPROJECTS         += pulseaudio
PULSEAUDIO_VERSION  := 17.0
DEB_PULSEAUDIO_V    ?= $(PULSEAUDIO_VERSION)-7+ios1

pulseaudio-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://www.freedesktop.org/software/pulseaudio/releases/pulseaudio-$(PULSEAUDIO_VERSION).tar.xz)
	$(call EXTRACT_TAR,pulseaudio-$(PULSEAUDIO_VERSION).tar.xz,pulseaudio-$(PULSEAUDIO_VERSION),pulseaudio)
	$(call DO_PATCH,pulseaudio,pulseaudio,-p1)
	bash /work/recipes/pulseaudio-ios-fixes.sh $(BUILD_WORK)/pulseaudio /work/audio /work/media
	rm -rf $(BUILD_WORK)/pulseaudio/build
	mkdir -p $(BUILD_WORK)/pulseaudio/build
	echo -e "[host_machine]\n \
	system = 'darwin'\n \
	cpu_family = '$(shell echo $(GNU_HOST_TRIPLE) | cut -d- -f1)'\n \
	cpu = '$(MEMO_ARCH)'\n \
	endian = 'little'\n \
	[properties]\n \
	root = '$(BUILD_BASE)'\n \
	needs_exe_wrapper = true\n \
	[built-in options]\n \
	prefix ='$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)'\n \
	[binaries]\n \
	c = '$(CC)'\n \
	cpp = '$(CXX)'\n \
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/pulseaudio/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/pulseaudio/.build_complete),)
pulseaudio:
	@echo "Using previously built pulseaudio."
else
pulseaudio: pulseaudio-setup glib2.0 libsndfile libtool
	cd $(BUILD_WORK)/pulseaudio/build && meson \
		--cross-file cross.txt \
		-Ddaemon=true \
		-Dclient=true \
		-Ddoxygen=false \
		-Dman=false \
		-Dtests=false \
		-Ddatabase=simple \
		-Dglib=enabled \
		-Dipv6=true \
		-Dalsa=disabled \
		-Dasyncns=disabled \
		-Davahi=disabled \
		-Dbluez5=disabled \
		-Dconsolekit=disabled \
		-Ddbus=disabled \
		-Delogind=disabled \
		-Dfftw=disabled \
		-Dgsettings=disabled \
		-Dgstreamer=disabled \
		-Dgtk=disabled \
		-Dhal-compat=false \
		-Djack=disabled \
		-Dlirc=disabled \
		-Dopenssl=disabled \
		-Dorc=disabled \
		-Doss-output=disabled \
		-Dsamplerate=disabled \
		-Dsoxr=disabled \
		-Dspeex=disabled \
		-Dsystemd=disabled \
		-Dtcpwrap=disabled \
		-Dudev=disabled \
		-Dvalgrind=disabled \
		-Dx11=disabled \
		-Dadrian-aec=true \
		-Dwebrtc-aec=disabled \
		-Datomic-arm-linux-helpers=false \
		..
	+ninja -C $(BUILD_WORK)/pulseaudio/build
	+DESTDIR="$(BUILD_STAGE)/pulseaudio" ninja -C $(BUILD_WORK)/pulseaudio/build install
	$(call AFTER_BUILD,copy)
endif

pulseaudio-package: pulseaudio-stage
	rm -rf $(BUILD_DIST)/libpulse0 $(BUILD_DIST)/libpulse-dev \
		$(BUILD_DIST)/pulseaudio $(BUILD_DIST)/pulseaudio-utils
	mkdir -p $(BUILD_DIST)/libpulse0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pulseaudio \
		$(BUILD_DIST)/libpulse-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{bin,lib/pulseaudio} \
		$(BUILD_DIST)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/etc/pulse \
		$(BUILD_DIST)/pulseaudio/$(MEMO_PREFIX)/etc/profile.d \
		$(BUILD_DIST)/pulseaudio-utils/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin

	# libpulse0 — client dylibs + ONLY libpulsecommon from the private dir (the
	# daemon build drops libpulsecore + modules/ in there too; those belong to
	# the pulseaudio deb).
	cp -a $(BUILD_STAGE)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libpulse.*.dylib \
		$(BUILD_DIST)/libpulse0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libpulse-simple.*.dylib \
		$(BUILD_DIST)/libpulse0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true
	cp -a $(BUILD_STAGE)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libpulse-mainloop-glib.*.dylib \
		$(BUILD_DIST)/libpulse0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pulseaudio/libpulsecommon-*.dylib \
		$(BUILD_DIST)/libpulse0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pulseaudio

	# libpulse-dev — headers + .pc + unversioned symlinks
	cp -a $(BUILD_STAGE)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libpulse-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig $(BUILD_DIST)/libpulse-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libpulse.dylib \
		$(BUILD_STAGE)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libpulse-mainloop-glib.dylib \
		$(BUILD_DIST)/libpulse-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libpulse-simple.dylib \
		$(BUILD_DIST)/libpulse-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true

	# pulseaudio — daemon + private core lib + modules (module-xios-sink/source among
	# them) + our iOS configs. Ship the stock etc/pulse tree first, then force
	# the Xios daemon.conf/default.pa/client.conf over it.
	#
	# CONFIG LOCATION: the daemon/clients were compiled with sysconfdir
	# $(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/etc = /var/jb/usr/etc, so PA only reads
	# daemon.conf/default.pa/client.conf from /var/jb/usr/etc/pulse. Shipping
	# them to $(MEMO_PREFIX)/etc/pulse = /var/jb/etc/pulse (as this did before)
	# meant the daemon never found default.pa and started with zero modules
	# ("refusing to work"). Install to the compiled sysconfdir. profile.d is a
	# shell concern, not PA's, so xios-pulse.sh stays at /var/jb/etc/profile.d.
	cp -a $(BUILD_STAGE)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/pulseaudio \
		$(BUILD_DIST)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin
	cp -a $(BUILD_STAGE)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pulseaudio/libpulsecore-*.dylib \
		$(BUILD_DIST)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pulseaudio
	cp -a $(BUILD_STAGE)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pulseaudio/modules \
		$(BUILD_DIST)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pulseaudio
	if [ -d "$(BUILD_STAGE)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/etc/pulse" ]; then \
		cp -a $(BUILD_STAGE)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/etc/pulse/. \
			$(BUILD_DIST)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/etc/pulse/; \
	fi
	install -m0644 /work/audio/pulse-config/daemon.conf /work/audio/pulse-config/default.pa \
		/work/audio/pulse-config/client.conf \
		$(BUILD_DIST)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/etc/pulse/
	install -m0755 /work/audio/pulse-config/xios-pulse.sh \
		$(BUILD_DIST)/pulseaudio/$(MEMO_PREFIX)/etc/profile.d/xios-pulse.sh

	# pulseaudio-utils — pactl/pacat + their paplay/parec/... symlinks; skip the
	# daemon binary itself.
	for f in $(BUILD_STAGE)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/pa*; do \
		case "$$(basename $$f)" in pulseaudio) ;; *) \
			cp -a $$f $(BUILD_DIST)/pulseaudio-utils/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin;; esac; \
	done

	# The private libs (libpulsecommon, libpulsecore) live in lib/pulseaudio/,
	# and the libgtkintl shim (that the shared relink pass points every
	# libintl consumer at) lives in lib/ — NEITHER is on anyone's run path:
	# meson emits only build-tree-relative @loader_path entries plus a STALE
	# absolute $(BUILD_BASE)/.../lib that is /work/... on the build host and
	# absent on device. dyld resolves each @rpath dep against the LOADING
	# image's own LC_RPATHs, so every image that links libgtkintl/libpulse.0
	# needs lib/ reachable from ITS rpath, and the private core/common need
	# lib/pulseaudio. Without this a freshly launched daemon SIGABRTs in dyld
	# on @rpath/libgtkintl before it can open its log, and standalone
	# pacat/paplay (no GTK stack to pre-load libgtkintl) die the same way —
	# which is why they needed DYLD_LIBRARY_PATH=/var/jb/usr/lib. Drop the
	# stale build-tree rpath and add the real ones. add_rpath errors if the
	# entry already exists, so swallow to stay idempotent across repackage runs.
	#
	# Client dylibs (in lib/): @loader_path == lib/ reaches libgtkintl; add
	# lib/pulseaudio for libpulsecommon. The daemon + utils (in bin/) reach
	# lib/ via @loader_path/../lib. Loadable modules (in lib/pulseaudio/modules)
	# reach lib/ via @loader_path/../.. (their libgtkintl/libpulse.0 deps are
	# normally already loaded by the daemon, but keep them self-sufficient).
	for f in $(BUILD_DIST)/libpulse0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libpulse.0.dylib \
			$(BUILD_DIST)/libpulse0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libpulse-simple.0.dylib \
			$(BUILD_DIST)/libpulse0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libpulse-mainloop-glib.0.dylib; do \
		[ -f $$f ] || continue; \
		$(I_N_T) -delete_rpath $(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib $$f 2>/dev/null || true; \
		$(I_N_T) -add_rpath $(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pulseaudio $$f 2>/dev/null || true; \
		$(I_N_T) -add_rpath @loader_path $$f 2>/dev/null || true; \
	done
	for f in $(BUILD_DIST)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/pulseaudio; do \
		[ -f $$f ] || continue; \
		$(I_N_T) -delete_rpath $(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib $$f 2>/dev/null || true; \
		$(I_N_T) -add_rpath $(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pulseaudio $$f 2>/dev/null || true; \
		$(I_N_T) -add_rpath @loader_path/../lib $$f 2>/dev/null || true; \
	done

	# The utils (pactl/pacat/pacmd/pasuspender) link @rpath/libpulsecommon
	# DIRECTLY, and it is their first-listed dep, so libpulse.0's rpath can't
	# rescue them transitively (dyld resolves each direct dep against the loading
	# image's own rpaths). They need /var/jb/usr/lib/pulseaudio (libpulsecommon)
	# AND /var/jb/usr/lib (libgtkintl + libpulse.0) on their own LC_RPATH, plus
	# the stale build-tree rpath dropped — else paplay only ran under
	# DYLD_LIBRARY_PATH=/var/jb/usr/lib. Skip symlinks (pamon/paplay/parec/
	# parecord -> pacat, patched via pacat itself) and the pa-info shell script
	# (magic-byte gated).
	for f in $(BUILD_DIST)/pulseaudio-utils/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/pa*; do \
		[ -f $$f ] || continue; [ -L $$f ] && continue; \
		case "$$(od -An -N4 -tx1 $$f 2>/dev/null | tr -d ' \n')" in \
			cffaedfe) \
				$(I_N_T) -delete_rpath $(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib $$f 2>/dev/null || true; \
				$(I_N_T) -add_rpath $(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pulseaudio $$f 2>/dev/null || true; \
				$(I_N_T) -add_rpath @loader_path/../lib $$f 2>/dev/null || true;; \
		esac; \
	done

	# Loadable modules link sibling helper libs that live in the SAME modules/
	# dir (e.g. module-native-protocol-unix -> @rpath/libprotocol-native), but
	# their LC_RPATHs are [@loader_path/../pulsecore, ../pulse, .., <buildpath>,
	# /var/jb/usr/lib] — none of which is the modules dir itself. So the sibling
	# never resolves, the native-protocol module fails to load, no unix socket
	# comes up, and (with every module tripping over its siblings) the daemon
	# dies "without any loaded modules". Add @loader_path (= the modules dir) to
	# every module. Gate on the arm64 Mach-O magic; add_rpath errors on an
	# rpath that already exists, so swallow that to stay idempotent across
	# repackage runs (same pattern as mutter.mk). The
	# $(call SIGN,pulseaudio,...) below re-signs the whole tree afterwards, so
	# the install_name_tool edits do not leave a broken signature.
	# Modules also link @rpath/libpulse.0 (and some @rpath/libgtkintl), both in
	# lib/ two levels up (@loader_path/../..). The daemon normally pre-loads
	# those before dlopening any module (so install-name reuse would cover it),
	# but add the rpath anyway so each module is self-sufficient, and drop the
	# stale build-tree rpath.
	for f in $(BUILD_DIST)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pulseaudio/modules/*.dylib; do \
		[ -f $$f ] || continue; [ -L $$f ] && continue; \
		[ "$$(od -An -N4 -tx1 $$f 2>/dev/null | tr -d ' \n')" = cffaedfe ] || continue; \
		$(I_N_T) -delete_rpath $(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib $$f 2>/dev/null || true; \
		$(I_N_T) -add_rpath @loader_path $$f 2>/dev/null || true; \
		$(I_N_T) -add_rpath @loader_path/../.. $$f 2>/dev/null || true; \
	done

	$(call SIGN,libpulse0,general.xml)
	$(call SIGN,pulseaudio,general.xml)
	$(call SIGN,pulseaudio-utils,general.xml)
	$(call PACK,libpulse0,DEB_PULSEAUDIO_V)
	$(call PACK,libpulse-dev,DEB_PULSEAUDIO_V)
	$(call PACK,pulseaudio,DEB_PULSEAUDIO_V)
	$(call PACK,pulseaudio-utils,DEB_PULSEAUDIO_V)
	rm -rf $(BUILD_DIST)/libpulse0 $(BUILD_DIST)/libpulse-dev \
		$(BUILD_DIST)/pulseaudio $(BUILD_DIST)/pulseaudio-utils

.PHONY: pulseaudio pulseaudio-package
