ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# pulseaudio.mk — client libraries AND the daemon.
#
# History: first built -Ddaemon=false for gnome-shell's vendored gvc (which
# hard-requires libpulse + libpulse-mainloop-glib >= 12.99.3; Procursus has no
# PulseAudio). Now the daemon is on: gvc is a full native-protocol client
# (context/introspect/subscribe), so a real PA server must answer it — the old
# pa_simple shim can't and was never meant to. The server's hardware output is
# module-xios-sink (injected by recipes/pulseaudio-ios-fixes.sh), which
# forwards the mixed stream to xios-audiod's Unix socket; xios-audiod (the
# audio track's fakesigned CoreAudio RemoteIO daemon, package xios-audio-server)
# keeps sole ownership of the device. Pipeline:
#   gvc / GTK apps -> libpulse -> pulseaudio -> module-xios-sink
#     -> /var/jb/tmp/xios-audio.sock -> xios-audiod -> RemoteIO -> speakers
#
# NOTE: the audio track's libpulse-simple-xios0 SHIM overlaps our real
# libpulse-simple. DECIDED (team lead): the real PA 17 lib SUPERSEDES the shim.
# Encoded in build_info: libpulse0 Provides libpulse-simple0 + Conflicts/
# Replaces libpulse-simple-xios0 (and libpulse-dev the -dev equivalents), so
# apt evicts the shim on install. PA builds on macOS (Homebrew) with the
# daemon, so the Darwin server path is exercised upstream; the only iOS delta
# is the module set (no CoreAudio HAL — see pulseaudio-ios-fixes.sh).
#
# Packaging split (Debian-shaped):
#   libpulse0         client dylibs + private libpulsecommon (UNCHANGED content)
#   libpulse-dev      headers, .pc, unversioned symlinks
#   pulseaudio        daemon, modules (incl. module-xios-sink), libpulsecore,
#                     etc/pulse configs, profile.d/xios-pulse.sh
#   pulseaudio-utils  pactl/pacat/paplay/... debug + scripting tools
#
# The daemon needs ltdl (module loader) -> depends on the libtool subproject.
# adrian-aec=true because meson hard-errors a daemon build with zero echo
# cancellers (speex/webrtc are disabled); adrian is bundled dependency-free C.
# Requires /work/audio mounted (module-xios-sink.c, xios_audio_protocol.h,
# pulse-config/) — see build-audio-server.sh.

SUBPROJECTS         += pulseaudio
PULSEAUDIO_VERSION  := 17.0
DEB_PULSEAUDIO_V    ?= $(PULSEAUDIO_VERSION)-1

pulseaudio-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://www.freedesktop.org/software/pulseaudio/releases/pulseaudio-$(PULSEAUDIO_VERSION).tar.xz)
	$(call EXTRACT_TAR,pulseaudio-$(PULSEAUDIO_VERSION).tar.xz,pulseaudio-$(PULSEAUDIO_VERSION),pulseaudio)
	bash /work/recipes/pulseaudio-ios-fixes.sh $(BUILD_WORK)/pulseaudio /work/audio
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
		$(BUILD_DIST)/pulseaudio/$(MEMO_PREFIX)/etc/{pulse,profile.d} \
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

	# pulseaudio — daemon + private core lib + modules (module-xios-sink among
	# them) + our iOS configs. Ship the stock etc/pulse tree first, then force
	# the Xios daemon.conf/default.pa/client.conf over it.
	cp -a $(BUILD_STAGE)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/pulseaudio \
		$(BUILD_DIST)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin
	cp -a $(BUILD_STAGE)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pulseaudio/libpulsecore-*.dylib \
		$(BUILD_DIST)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pulseaudio
	cp -a $(BUILD_STAGE)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pulseaudio/modules \
		$(BUILD_DIST)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pulseaudio
	if [ -d "$(BUILD_STAGE)/pulseaudio/$(MEMO_PREFIX)/etc/pulse" ]; then \
		cp -a $(BUILD_STAGE)/pulseaudio/$(MEMO_PREFIX)/etc/pulse/. $(BUILD_DIST)/pulseaudio/$(MEMO_PREFIX)/etc/pulse/; \
	fi
	install -m0644 /work/audio/pulse-config/daemon.conf /work/audio/pulse-config/default.pa \
		/work/audio/pulse-config/client.conf \
		$(BUILD_DIST)/pulseaudio/$(MEMO_PREFIX)/etc/pulse/
	install -m0755 /work/audio/pulse-config/xios-pulse.sh \
		$(BUILD_DIST)/pulseaudio/$(MEMO_PREFIX)/etc/profile.d/xios-pulse.sh

	# pulseaudio-utils — pactl/pacat + their paplay/parec/... symlinks; skip the
	# daemon binary itself.
	for f in $(BUILD_STAGE)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/pa*; do \
		case "$$(basename $$f)" in pulseaudio) ;; *) \
			cp -a $$f $(BUILD_DIST)/pulseaudio-utils/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin;; esac; \
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
