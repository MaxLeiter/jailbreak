ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Focused libgtop-2.0 Darwin backend. GNOME Console hard-links libgtop for terminal
# child-process monitoring; rather than porting all of upstream libgtop, this implements
# just the three calls Console uses, via kern.proc/kern.procargs2 sysctls.
# Sources: /work/recipes/libgtop_ios.c + /work/recipes/libgtop/glibtop/*.h.

SUBPROJECTS     += libgtop
LIBGTOP_VERSION := 2.41.3
DEB_LIBGTOP_V   ?= $(LIBGTOP_VERSION)+ios2

libgtop-setup: setup
	mkdir -p $(BUILD_WORK)/libgtop

# Always rebuild (compiles instantly) so a warm Procursus volume can't silently
# repackage a stale libgtop_ios.c.
libgtop: libgtop-setup
	rm -rf $(BUILD_STAGE)/libgtop
	mkdir -p $(BUILD_STAGE)/libgtop$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_STAGE)/libgtop$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/glibtop
	cp -a /work/recipes/libgtop/glibtop/*.h $(BUILD_STAGE)/libgtop$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/glibtop/
	$(CC) -dynamiclib -fno-common -install_name @rpath/libgtop-2.0.11.dylib \
		-I$(BUILD_STAGE)/libgtop$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		/work/recipes/libgtop_ios.c \
		-o $(BUILD_STAGE)/libgtop$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgtop-2.0.11.dylib
	ln -sf libgtop-2.0.11.dylib $(BUILD_STAGE)/libgtop$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgtop-2.0.dylib
	printf 'prefix=%s\nlibdir=$${prefix}/lib\nincludedir=$${prefix}/include\n\nName: libgtop-2.0\nDescription: libgtop process backend (iOS)\nVersion: %s\nLibs: -L$${libdir} -lgtop-2.0\nCflags: -I$${includedir}\n' \
		"$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)" "$(LIBGTOP_VERSION)" \
		> $(BUILD_STAGE)/libgtop$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/libgtop-2.0.pc
	$(call AFTER_BUILD,copy)

libgtop-package: libgtop-stage
	# Ships as a proper deb so the apt dependency graph closes: gnome-console links
	# @rpath/libgtop-2.0.11.dylib and Depends: libgtop-2.0-11.
	rm -rf $(BUILD_DIST)/libgtop-2.0-11
	mkdir -p $(BUILD_DIST)/libgtop-2.0-11$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libgtop$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgtop-2.0.11.dylib $(BUILD_DIST)/libgtop-2.0-11$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	$(call SIGN,libgtop-2.0-11,general.xml)
	$(call PACK,libgtop-2.0-11,DEB_LIBGTOP_V)
	rm -rf $(BUILD_DIST)/libgtop-2.0-11

.PHONY: libgtop libgtop-package
