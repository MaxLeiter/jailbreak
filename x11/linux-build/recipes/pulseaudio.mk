ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Client libraries and daemon. The daemon's hardware output is module-xios-sink/
# module-xios-source (injected by pulseaudio-ios-fixes.sh), forwarding playback to
# xios-audiod and capture to xios-mediad — the Xios daemons keep sole ownership of the
# iOS device APIs:
#   gvc / GTK apps -> libpulse -> pulseaudio -> module-xios-sink
#     -> /var/jb/tmp/xios-audio.sock -> xios-audiod -> RemoteIO -> speakers
#   GTK/GStreamer/parec -> libpulse -> pulseaudio -> module-xios-source
#     -> /var/jb/tmp/xios-media-mic.sock -> xios-mediad -> RemoteIO input
#
# Packaging split (Debian-shaped):
#   libpulse0         client dylibs + private libpulsecommon
#   libpulse-dev      headers, .pc, unversioned symlinks
#   pulseaudio        daemon, modules (incl. module-xios-sink/source), libpulsecore,
#                     etc/pulse configs, profile.d/xios-pulse.sh
#   pulseaudio-utils  pactl/pacat/paplay/... debug + scripting tools
#
# adrian-aec=true because meson hard-errors a daemon build with zero echo cancellers
# (speex/webrtc disabled); adrian is bundled dependency-free C. Requires /work/audio
# and /work/media mounted (module-xios-*.c, protocol headers, pulse-config/).

SUBPROJECTS         += pulseaudio
PULSEAUDIO_VERSION  := 17.0
DEB_PULSEAUDIO_V    ?= $(PULSEAUDIO_VERSION)-7+ios2

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

	# Only libpulsecommon from the private dir; the daemon build also drops
	# libpulsecore + modules/ there, which belong to the pulseaudio deb.
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

	# The daemon/clients were compiled with sysconfdir /var/jb/usr/etc, so PA only reads
	# daemon.conf/default.pa/client.conf from /var/jb/usr/etc/pulse — shipping them to
	# /var/jb/etc/pulse instead left the daemon with zero modules ("refusing to work").
	# profile.d is a shell concern, not PA's, so xios-pulse.sh stays at /var/jb/etc/profile.d.
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

	# pactl/pacat + their paplay/parec/... symlinks; skip the daemon binary itself.
	for f in $(BUILD_STAGE)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/pa*; do \
		case "$$(basename $$f)" in pulseaudio) ;; *) \
			cp -a $$f $(BUILD_DIST)/pulseaudio-utils/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin;; esac; \
	done

	# meson only emits build-tree-relative @loader_path entries plus a stale absolute
	# rpath that's absent on device, so without fixing rpaths a freshly launched daemon
	# SIGABRTs in dyld on @rpath/libgtkintl, and pacat/paplay die the same way (previously
	# needed DYLD_LIBRARY_PATH=/var/jb/usr/lib to run at all). dyld resolves each @rpath
	# dep against the LOADING image's own LC_RPATHs, so every binary needs its own path to
	# lib/ (libgtkintl, libpulse.0) and, for the private libs, lib/pulseaudio.
	# add_rpath errors on a duplicate entry, so swallow that to stay idempotent.
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

	# pactl/pacat/pacmd/pasuspender link @rpath/libpulsecommon directly, so libpulse.0's
	# rpath can't rescue them transitively (dyld resolves each direct dep against the
	# loading image's own rpaths). They need both lib/pulseaudio and lib on their own
	# LC_RPATH. Skip symlinks (pamon/paplay/parec/parecord -> pacat) and the
	# magic-byte-gated pa-info shell script.
	for f in $(BUILD_DIST)/pulseaudio-utils/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/pa*; do \
		[ -f $$f ] || continue; [ -L $$f ] && continue; \
		case "$$(od -An -N4 -tx1 $$f 2>/dev/null | tr -d ' \n')" in \
			cffaedfe) \
				$(I_N_T) -delete_rpath $(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib $$f 2>/dev/null || true; \
				$(I_N_T) -add_rpath $(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pulseaudio $$f 2>/dev/null || true; \
				$(I_N_T) -add_rpath @loader_path/../lib $$f 2>/dev/null || true;; \
		esac; \
	done

	# Modules link sibling helpers in the same modules/ dir (e.g. module-native-protocol-unix
	# -> @rpath/libprotocol-native), but none of their LC_RPATHs point at the modules dir
	# itself, so the sibling never resolves and the daemon dies "without any loaded
	# modules". Add @loader_path to every module. They also link @rpath/libpulse.0 (and
	# some libgtkintl) two levels up, normally pre-loaded by the daemon, but add that
	# rpath too so each module is self-sufficient.
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
