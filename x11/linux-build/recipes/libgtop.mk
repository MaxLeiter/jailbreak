ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# libgtop.mk — minimal libgtop-2.0 SHIM for the GNOME track (iOS). GNOME Console hard-links
# libgtop for terminal process monitoring; upstream libgtop has no Procursus recipe and its
# darwin backend uses iOS-restricted sysctl(KERN_PROC)/libproc paths. This compiles a tiny stub
# dylib + headers + .pc (sources: /work/recipes/libgtop_stub.c + /work/recipes/libgtop/glibtop/*.h)
# that satisfy the dependency so gnome-console links and launches. No deb is packed — the staged
# .pc/headers feed the cross-build and the dylib is shipped alongside the app for validation.

SUBPROJECTS     += libgtop
LIBGTOP_VERSION := 2.41.3
DEB_LIBGTOP_V   ?= $(LIBGTOP_VERSION)

libgtop-setup: setup
	mkdir -p $(BUILD_WORK)/libgtop

ifneq ($(wildcard $(BUILD_WORK)/libgtop/.build_complete),)
libgtop:
	@echo "Using previously built libgtop."
else
libgtop: libgtop-setup
	mkdir -p $(BUILD_STAGE)/libgtop$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_STAGE)/libgtop$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/glibtop
	cp -a /work/recipes/libgtop/glibtop/*.h $(BUILD_STAGE)/libgtop$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/glibtop/
	$(CC) -dynamiclib -fno-common -install_name @rpath/libgtop-2.0.11.dylib \
		-I$(BUILD_STAGE)/libgtop$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		/work/recipes/libgtop_stub.c \
		-o $(BUILD_STAGE)/libgtop$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgtop-2.0.11.dylib
	ln -sf libgtop-2.0.11.dylib $(BUILD_STAGE)/libgtop$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgtop-2.0.dylib
	printf 'prefix=%s\nlibdir=$${prefix}/lib\nincludedir=$${prefix}/include\n\nName: libgtop-2.0\nDescription: libgtop stub (iOS)\nVersion: %s\nLibs: -L$${libdir} -lgtop-2.0\nCflags: -I$${includedir}\n' \
		"$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)" "$(LIBGTOP_VERSION)" \
		> $(BUILD_STAGE)/libgtop$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/libgtop-2.0.pc
	$(call AFTER_BUILD,copy)
endif

libgtop-package: libgtop-stage
	# Ship the stub runtime dylib as a proper deb so the dependency graph closes for apt
	# (gnome-console links @rpath/libgtop-2.0.11.dylib and Depends: libgtop-2.0-11).
	rm -rf $(BUILD_DIST)/libgtop-2.0-11
	mkdir -p $(BUILD_DIST)/libgtop-2.0-11$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libgtop$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgtop-2.0.11.dylib $(BUILD_DIST)/libgtop-2.0-11$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	$(call SIGN,libgtop-2.0-11,general.xml)
	$(call PACK,libgtop-2.0-11,DEB_LIBGTOP_V)
	rm -rf $(BUILD_DIST)/libgtop-2.0-11

.PHONY: libgtop libgtop-package
