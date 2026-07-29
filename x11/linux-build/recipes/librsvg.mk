ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Dedicated Rust/autotools recipe, not folded into GTK: GdkPixbuf loads SVG support
# through its module system at runtime. Without this package, Adwaita symbolic SVGs
# fail with "Unrecognized image file format".

SUBPROJECTS       += librsvg
LIBRSVG_MAJOR_V   := 2.56
LIBRSVG_VERSION   := $(LIBRSVG_MAJOR_V).5
DEB_LIBRSVG_V     ?= $(LIBRSVG_VERSION)+ios1
LIBRSVG_CCTOOLS_BIN := $(dir $(shell command -v $(GNU_HOST_TRIPLE)-ld))
LIBRSVG_RUSTFLAGS := -Clink-arg=-B$(LIBRSVG_CCTOOLS_BIN) -Clink-arg=-isysroot -Clink-arg=$(TARGET_SYSROOT) -Clink-arg=-miphoneos-version-min=16.0

librsvg-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/librsvg/$(LIBRSVG_MAJOR_V)/librsvg-$(LIBRSVG_VERSION).tar.xz)
	$(call EXTRACT_TAR,librsvg-$(LIBRSVG_VERSION).tar.xz,librsvg-$(LIBRSVG_VERSION),librsvg)
	# The generated tarball's config.sub may predate our target spelling.
	find $(BUILD_WORK)/librsvg -name config.sub -exec cp -f /usr/share/misc/config.sub {} \; || true
	find $(BUILD_WORK)/librsvg -name config.guess -exec cp -f /usr/share/misc/config.guess {} \; || true
	# clang must find cctools' ld64 when Cargo links Rust binaries for iOS.
	ln -sf $(GNU_HOST_TRIPLE)-ld $(LIBRSVG_CCTOOLS_BIN)ld || true

ifneq ($(wildcard $(BUILD_WORK)/librsvg/.build_complete),)
librsvg:
	@echo "Using previously built librsvg."
else
librsvg: librsvg-setup glib2.0 gdk-pixbuf cairo pango harfbuzz freetype libxml2
	cd $(BUILD_WORK)/librsvg && \
		export PATH="$(BUILD_TOOLS):$$PATH"; \
		export PKG_CONFIG_ALLOW_CROSS=1; \
		export CARGO_TARGET_AARCH64_APPLE_IOS_LINKER=$(GNU_HOST_TRIPLE)-clang; \
		export CARGO_TARGET_AARCH64_APPLE_IOS_RUSTFLAGS="$(LIBRSVG_RUSTFLAGS)"; \
		export RUST_TARGET=aarch64-apple-ios; \
		export CC_aarch64_apple_ios="$(CC)"; \
		export CFLAGS_aarch64_apple_ios="$(CFLAGS)"; \
		export AR_aarch64_apple_ios="$(GNU_HOST_TRIPLE)-ar"; \
		./configure -C \
			$(DEFAULT_CONFIGURE_FLAGS) \
			--disable-static \
			--disable-gtk-doc \
			--disable-installed-tests \
			--disable-always-build-tests \
			--enable-pixbuf-loader \
			--enable-introspection=no \
			--enable-vala=no
	+cd $(BUILD_WORK)/librsvg && \
		export PATH="$(BUILD_TOOLS):$$PATH"; \
		export PKG_CONFIG_ALLOW_CROSS=1; \
		export CARGO_TARGET_AARCH64_APPLE_IOS_LINKER=$(GNU_HOST_TRIPLE)-clang; \
		export CARGO_TARGET_AARCH64_APPLE_IOS_RUSTFLAGS="$(LIBRSVG_RUSTFLAGS)"; \
		export RUST_TARGET=aarch64-apple-ios; \
		export CC_aarch64_apple_ios="$(CC)"; \
		export CFLAGS_aarch64_apple_ios="$(CFLAGS)"; \
		export AR_aarch64_apple_ios="$(GNU_HOST_TRIPLE)-ar"; \
		$(MAKE)
	+cd $(BUILD_WORK)/librsvg && \
		export PATH="$(BUILD_TOOLS):$$PATH"; \
		export PKG_CONFIG_ALLOW_CROSS=1; \
		export CARGO_TARGET_AARCH64_APPLE_IOS_LINKER=$(GNU_HOST_TRIPLE)-clang; \
		export CARGO_TARGET_AARCH64_APPLE_IOS_RUSTFLAGS="$(LIBRSVG_RUSTFLAGS)"; \
		export RUST_TARGET=aarch64-apple-ios; \
		$(MAKE) install DESTDIR=$(BUILD_STAGE)/librsvg
	$(call AFTER_BUILD,copy)
endif

librsvg-package: librsvg-stage
	rm -rf $(BUILD_DIST)/librsvg2-2 $(BUILD_DIST)/librsvg2-common \
		$(BUILD_DIST)/librsvg2-dev $(BUILD_DIST)/librsvg2-bin
	mkdir -p $(BUILD_DIST)/librsvg2-2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/librsvg2-common/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/gdk-pixbuf-2.0/2.10.0 \
		$(BUILD_DIST)/librsvg2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/librsvg2-bin/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	# Runtime library.
	cp -a $(BUILD_STAGE)/librsvg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/librsvg-2.*.dylib \
		$(BUILD_DIST)/librsvg2-2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# GdkPixbuf SVG loader + thumbnailer metadata. loaders.cache is generated on device.
	if [ -d "$(BUILD_STAGE)/librsvg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/gdk-pixbuf-2.0" ]; then \
		cp -a $(BUILD_STAGE)/librsvg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/gdk-pixbuf-2.0 \
			$(BUILD_DIST)/librsvg2-common/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib; \
	fi
	if [ -d "$(BUILD_STAGE)/librsvg$(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/gdk-pixbuf-2.0" ]; then \
		cp -a $(BUILD_STAGE)/librsvg$(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/gdk-pixbuf-2.0 \
			$(BUILD_DIST)/librsvg2-common/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib; \
	fi
	if [ -d "$(BUILD_STAGE)/librsvg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/thumbnailers" ]; then \
		mkdir -p $(BUILD_DIST)/librsvg2-common/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share; \
		cp -a $(BUILD_STAGE)/librsvg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/thumbnailers \
			$(BUILD_DIST)/librsvg2-common/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share; \
	fi
	find $(BUILD_DIST)/librsvg2-common -name '*.la' -delete
	find $(BUILD_DIST)/librsvg2-common -name loaders.cache -delete

	# Development files.
	cp -a $(BUILD_STAGE)/librsvg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(librsvg-2.*.dylib|gdk-pixbuf-2.0) \
		$(BUILD_DIST)/librsvg2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/librsvg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/librsvg2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	if [ -d "$(BUILD_STAGE)/librsvg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/gir-1.0" ]; then \
		mkdir -p $(BUILD_DIST)/librsvg2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share; \
		cp -a $(BUILD_STAGE)/librsvg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/gir-1.0 \
			$(BUILD_DIST)/librsvg2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share; \
	fi

	# Optional command-line converter.
	if [ -d "$(BUILD_STAGE)/librsvg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin" ]; then \
		cp -a $(BUILD_STAGE)/librsvg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin \
			$(BUILD_DIST)/librsvg2-bin/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi
	if [ -d "$(BUILD_STAGE)/librsvg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man" ]; then \
		mkdir -p $(BUILD_DIST)/librsvg2-bin/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share; \
		cp -a $(BUILD_STAGE)/librsvg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man \
			$(BUILD_DIST)/librsvg2-bin/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share; \
	fi

	$(call SIGN,librsvg2-2,general.xml)
	$(call SIGN,librsvg2-common,general.xml)
	$(call SIGN,librsvg2-bin,general.xml)
	$(call PACK,librsvg2-2,DEB_LIBRSVG_V)
	$(call PACK,librsvg2-common,DEB_LIBRSVG_V)
	$(call PACK,librsvg2-dev,DEB_LIBRSVG_V)
	$(call PACK,librsvg2-bin,DEB_LIBRSVG_V)
	rm -rf $(BUILD_DIST)/librsvg2-2 $(BUILD_DIST)/librsvg2-common \
		$(BUILD_DIST)/librsvg2-dev $(BUILD_DIST)/librsvg2-bin

librsvg2-common-package: librsvg-package
librsvg2-2-package: librsvg-package
librsvg2-dev-package: librsvg-package
librsvg2-bin-package: librsvg-package

.PHONY: librsvg librsvg-package librsvg2-common-package librsvg2-2-package librsvg2-dev-package librsvg2-bin-package
