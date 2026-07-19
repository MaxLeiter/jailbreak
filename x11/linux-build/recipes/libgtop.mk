ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# libgtop.mk — focused libgtop-2.0 Darwin backend for the GNOME track (iOS). GNOME Console
# hard-links libgtop for terminal child-process monitoring. Rather than carrying all of upstream
# libgtop, this builds the three calls Console consumes using kern.proc/kern.procargs2 sysctls.
# Sources: /work/recipes/libgtop_ios.c + /work/recipes/libgtop/glibtop/*.h.

SUBPROJECTS     += libgtop
LIBGTOP_VERSION := 2.41.3
DEB_LIBGTOP_V   ?= $(LIBGTOP_VERSION)+ios2

libgtop-setup: setup
	mkdir -p $(BUILD_WORK)/libgtop

# This focused backend compiles in a fraction of a second. Always rebuild it so a warm
# Procursus volume cannot silently repackage an older compatibility implementation after
# libgtop_ios.c changes.
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
	# Ship the focused runtime dylib as a proper deb so the dependency graph closes for apt
	# (gnome-console links @rpath/libgtop-2.0.11.dylib and Depends: libgtop-2.0-11).
	rm -rf $(BUILD_DIST)/libgtop-2.0-11
	mkdir -p $(BUILD_DIST)/libgtop-2.0-11$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libgtop$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgtop-2.0.11.dylib $(BUILD_DIST)/libgtop-2.0-11$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	$(call SIGN,libgtop-2.0-11,general.xml)
	$(call PACK,libgtop-2.0-11,DEB_LIBGTOP_V)
	rm -rf $(BUILD_DIST)/libgtop-2.0-11

.PHONY: libgtop libgtop-package
