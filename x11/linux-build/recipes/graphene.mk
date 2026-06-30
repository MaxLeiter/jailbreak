ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

SUBPROJECTS        += graphene
GRAPHENE_VERSION   := 1.10.8
DEB_LIBGRAPHENE_V  ?= $(GRAPHENE_VERSION)

graphene-setup: setup
	$(call GITHUB_ARCHIVE,ebassi,graphene,$(GRAPHENE_VERSION),$(GRAPHENE_VERSION))
	$(call EXTRACT_TAR,graphene-$(GRAPHENE_VERSION).tar.gz,graphene-$(GRAPHENE_VERSION),graphene)
	rm -rf $(BUILD_WORK)/graphene/build
	mkdir -p $(BUILD_WORK)/graphene/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/graphene/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/graphene/.build_complete),)
graphene:
	@echo "Using previously built graphene."
else
graphene: graphene-setup glib2.0
	cd $(BUILD_WORK)/graphene/build && meson \
		--cross-file cross.txt \
		-Dintrospection=disabled \
		-Dgtk_doc=false \
		-Dtests=false \
		-Dinstalled_tests=false \
		-Dgobject_types=true \
		-Darm_neon=true \
		-Dsse2=false \
		-Dgcc_vector=false \
		..
	cd $(BUILD_WORK)/graphene/build; \
		DESTDIR="$(BUILD_STAGE)/graphene" meson install
	$(call AFTER_BUILD,copy)
endif

graphene-package: graphene-stage
	# graphene.mk Package Structure
	rm -rf $(BUILD_DIST)/libgraphene-1.0-0 $(BUILD_DIST)/libgraphene-1.0-dev
	mkdir -p $(BUILD_DIST)/libgraphene-1.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libgraphene-1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# graphene.mk Prep libgraphene-1.0-0 (runtime dylib)
	cp -a $(BUILD_STAGE)/graphene/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/*-1.0.0.dylib $(BUILD_DIST)/libgraphene-1.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# graphene.mk Prep libgraphene-1.0-dev (headers, symlinks, .pc)
	cp -a $(BUILD_STAGE)/graphene/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libgraphene-1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/graphene/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(*-1.0.0.dylib) $(BUILD_DIST)/libgraphene-1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# graphene.mk Sign
	$(call SIGN,libgraphene-1.0-0,general.xml)

	# graphene.mk Make .debs
	$(call PACK,libgraphene-1.0-0,DEB_LIBGRAPHENE_V)
	$(call PACK,libgraphene-1.0-dev,DEB_LIBGRAPHENE_V)

	# graphene.mk Build cleanup
	rm -rf $(BUILD_DIST)/libgraphene-1.0-0 $(BUILD_DIST)/libgraphene-1.0-dev

.PHONY: graphene graphene-package
