ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# pulseaudio.mk — CLIENT LIBRARIES ONLY (-Ddaemon=false): libpulse, libpulse-simple,
# libpulse-mainloop-glib + the private libpulsecommon. gnome-shell's vendored gvc
# subproject hard-requires libpulse + libpulse-mainloop-glib >= 12.99.3; there is no
# PulseAudio in Procursus. No PA server exists on the device yet — gvc will simply fail
# to connect at runtime (volume UI inert), which is fine for bring-up; later the
# CoreAudio daemon track can grow a real PA-protocol server behind these libs.
# NOTE: the audio track's libpulse-simple-xios0 SHIM overlaps our real libpulse-simple.
# DECIDED (team lead): the real PA 17 lib SUPERSEDES the shim (the shim was only a stopgap
# for "no PA on Procursus"). Encoded in build_info: libpulse0 Provides libpulse-simple0 +
# Conflicts/Replaces libpulse-simple-xios0 (and libpulse-dev the -dev equivalents), so apt
# evicts the shim on install. PA builds on macOS (Homebrew), so the Darwin client path is
# exercised upstream. Mirrors recipes/gnome-desktop.mk (meson).

SUBPROJECTS         += pulseaudio
PULSEAUDIO_VERSION  := 17.0
DEB_PULSEAUDIO_V    ?= $(PULSEAUDIO_VERSION)

pulseaudio-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://www.freedesktop.org/software/pulseaudio/releases/pulseaudio-$(PULSEAUDIO_VERSION).tar.xz)
	$(call EXTRACT_TAR,pulseaudio-$(PULSEAUDIO_VERSION).tar.xz,pulseaudio-$(PULSEAUDIO_VERSION),pulseaudio)
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
pulseaudio: pulseaudio-setup glib2.0 libsndfile
	cd $(BUILD_WORK)/pulseaudio/build && meson \
		--cross-file cross.txt \
		-Ddaemon=false \
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
		-Dadrian-aec=false \
		-Dwebrtc-aec=disabled \
		-Datomic-arm-linux-helpers=false \
		..
	+ninja -C $(BUILD_WORK)/pulseaudio/build
	+DESTDIR="$(BUILD_STAGE)/pulseaudio" ninja -C $(BUILD_WORK)/pulseaudio/build install
	$(call AFTER_BUILD,copy)
endif

pulseaudio-package: pulseaudio-stage
	rm -rf $(BUILD_DIST)/libpulse0 $(BUILD_DIST)/libpulse-dev
	mkdir -p $(BUILD_DIST)/libpulse0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libpulse-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libpulse0 — all client dylibs incl. the private pulseaudio/ dir + client.conf
	cp -a $(BUILD_STAGE)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libpulse.*.dylib \
		$(BUILD_DIST)/libpulse0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libpulse-simple.*.dylib \
		$(BUILD_DIST)/libpulse0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true
	cp -a $(BUILD_STAGE)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libpulse-mainloop-glib.*.dylib \
		$(BUILD_DIST)/libpulse0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	if [ -d "$(BUILD_STAGE)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pulseaudio" ]; then \
		cp -a $(BUILD_STAGE)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pulseaudio $(BUILD_DIST)/libpulse0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib; \
	fi
	if [ -d "$(BUILD_STAGE)/pulseaudio/$(MEMO_PREFIX)/etc/pulse" ]; then \
		mkdir -p $(BUILD_DIST)/libpulse0/$(MEMO_PREFIX)/etc; \
		cp -a $(BUILD_STAGE)/pulseaudio/$(MEMO_PREFIX)/etc/pulse $(BUILD_DIST)/libpulse0/$(MEMO_PREFIX)/etc; \
	fi

	# libpulse-dev — headers + .pc + unversioned symlinks
	cp -a $(BUILD_STAGE)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libpulse-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig $(BUILD_DIST)/libpulse-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libpulse.dylib \
		$(BUILD_STAGE)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libpulse-mainloop-glib.dylib \
		$(BUILD_DIST)/libpulse-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/pulseaudio/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libpulse-simple.dylib \
		$(BUILD_DIST)/libpulse-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true

	$(call SIGN,libpulse0,general.xml)
	$(call PACK,libpulse0,DEB_PULSEAUDIO_V)
	$(call PACK,libpulse-dev,DEB_PULSEAUDIO_V)
	rm -rf $(BUILD_DIST)/libpulse0 $(BUILD_DIST)/libpulse-dev

.PHONY: pulseaudio pulseaudio-package
