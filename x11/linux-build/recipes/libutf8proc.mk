ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# fcft/foot need @rpath/libutf8proc.3.dylib but no runtime deb existed — on-device smoke
# test hit "dyld: Library not loaded" launching foot.
# OS=Darwin makes upstream's Makefile emit a plain .dylib + SONAME-3 symlink directly, no
# meson/cross.txt needed. SONAME 3 is why the runtime package is named libutf8proc3.

SUBPROJECTS         += libutf8proc
LIBUTF8PROC_VERSION := 2.9.0
DEB_LIBUTF8PROC_V   ?= $(LIBUTF8PROC_VERSION)+ios1

libutf8proc-setup: setup
	$(call GITHUB_ARCHIVE,JuliaStrings,utf8proc,$(LIBUTF8PROC_VERSION),v$(LIBUTF8PROC_VERSION),libutf8proc)
	$(call EXTRACT_TAR,libutf8proc-$(LIBUTF8PROC_VERSION).tar.gz,utf8proc-$(LIBUTF8PROC_VERSION),libutf8proc)

ifneq ($(wildcard $(BUILD_WORK)/libutf8proc/.build_complete),)
libutf8proc:
	@echo "Using previously built libutf8proc."
else
libutf8proc: libutf8proc-setup
	+$(MAKE) -C $(BUILD_WORK)/libutf8proc install \
		OS=Darwin \
		prefix=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) \
		DESTDIR="$(BUILD_STAGE)/libutf8proc"
	$(call AFTER_BUILD,copy)
endif

libutf8proc-package: libutf8proc-stage
	rm -rf $(BUILD_DIST)/libutf8proc{3,-dev}
	mkdir -p $(BUILD_DIST)/libutf8proc{3,-dev}/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/libutf8proc/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libutf8proc-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/libutf8proc/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/{pkgconfig,libutf8proc.{a,dylib}} $(BUILD_DIST)/libutf8proc-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/libutf8proc/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libutf8proc.3.dylib $(BUILD_DIST)/libutf8proc3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	$(call SIGN,libutf8proc-dev,general.xml)
	$(call SIGN,libutf8proc3,general.xml)

	$(call PACK,libutf8proc-dev,DEB_LIBUTF8PROC_V)
	$(call PACK,libutf8proc3,DEB_LIBUTF8PROC_V)

	rm -rf $(BUILD_DIST)/libutf8proc{3,-dev}

.PHONY: libutf8proc libutf8proc-package
