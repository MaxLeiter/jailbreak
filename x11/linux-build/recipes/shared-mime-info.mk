ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# shared-mime-info.mk — freedesktop MIME database + update-mime-database.
# KService/KApplicationTrader needs this database for common MIME types such as
# text/html; KDE's own kde6.xml is only an extension layer.

SUBPROJECTS += shared-mime-info
SHARED_MIME_INFO_VERSION := 2.4
DEB_SHARED_MIME_INFO_V ?= $(SHARED_MIME_INFO_VERSION)+ios1

shared-mime-info-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://gitlab.freedesktop.org/xdg/shared-mime-info/-/archive/$(SHARED_MIME_INFO_VERSION)/shared-mime-info-$(SHARED_MIME_INFO_VERSION).tar.gz)
	$(call EXTRACT_TAR,shared-mime-info-$(SHARED_MIME_INFO_VERSION).tar.gz,shared-mime-info-$(SHARED_MIME_INFO_VERSION),shared-mime-info)
	mkdir -p $(BUILD_WORK)/shared-mime-info/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/shared-mime-info/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/shared-mime-info/.build_complete),)
shared-mime-info:
	@echo "Using previously built shared-mime-info."
else
shared-mime-info: shared-mime-info-setup glib2.0 libxml2
	cd $(BUILD_WORK)/shared-mime-info/build && meson \
		--cross-file cross.txt \
		-Dbuild-tests=false \
		-Dbuild-translations=false \
		-Dupdate-mimedb=false \
		..
	+ninja -C $(BUILD_WORK)/shared-mime-info/build
	+DESTDIR="$(BUILD_STAGE)/shared-mime-info" ninja -C $(BUILD_WORK)/shared-mime-info/build install
	$(call AFTER_BUILD,copy)
endif

shared-mime-info-package: shared-mime-info-stage
	rm -rf $(BUILD_DIST)/shared-mime-info
	mkdir -p $(BUILD_DIST)/shared-mime-info/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/shared-mime-info/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/shared-mime-info/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/shared-mime-info/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/shared-mime-info/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,shared-mime-info,general.xml)
	$(call PACK,shared-mime-info,DEB_SHARED_MIME_INFO_V)
	rm -rf $(BUILD_DIST)/shared-mime-info

.PHONY: shared-mime-info shared-mime-info-package
