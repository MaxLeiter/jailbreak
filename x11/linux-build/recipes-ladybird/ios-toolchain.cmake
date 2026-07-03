# Ladybird-on-iOS (Wave 4) — CMake cross toolchain, Linux(arm64 host) -> iphoneos-arm64.
#
# Why CMAKE_SYSTEM_NAME=Darwin (not iOS): CMake's Platform/iOS-Initialize + Darwin-Initialize
# shell out to xcrun/sw_vers/plutil, which do not exist on this Debian host. The house pattern
# (recipes/qtbase.mk) drives CMAKE_SYSTEM_NAME=Darwin with a fake `xcrun` on PATH and an explicit
# CMAKE_OSX_SYSROOT, so APPLE=1 while the Apple platform probe is satisfied off-Mac. The compiler
# (-isysroot iPhoneOS16.5.sdk + -miphoneos-version-min via the wrapper) defines TARGET_OS_IPHONE,
# so every source file compiles its iOS branch. Ladybird keys its *source-level* iOS off `__IOS__`
# (AK/Platform.h) which the wrapper injects, and its *CMake-level* iOS off a plain `if (IOS)` var,
# which we force TRUE below (CMAKE_SYSTEM_NAME=iOS is what normally sets it, and we can't use that).
#
# Requires a shim dir (LB_SHIM, default /work/shim) populated by build-ladybird-wave4.sh with:
#   lb-cc / lb-cxx  (clang-19 --target=arm64-apple-ios16.0 -isysroot <SDK> -fuse-ld=<cctools ld>)
#   unprefixed cctools mach-o tools: ld ar ranlib libtool install_name_tool otool nm strip lipo
#   fake xcrun / sw_vers
# and LB_STAGED_PREFIX = the staged build_base sysroot (…/var/jb) for find_root.

set(CMAKE_SYSTEM_NAME Darwin)
set(CMAKE_SYSTEM_PROCESSOR arm64)
set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING "" FORCE)

# Ladybird reads plain `if (IOS)` / `if (ANDROID OR IOS)`; assert it since Darwin system-name
# does not set the CMake IOS var. This routes: BUILD_SHARED_LIBS OFF (static Lagom), Utilities
# skipped, sandbox->Unimplemented (with our patch), and the M0 source gates.
set(IOS TRUE CACHE BOOL "Target is iOS" FORCE)

if (NOT DEFINED ENV{LB_SHIM})
  set(LB_SHIM "/work/shim")
else()
  set(LB_SHIM "$ENV{LB_SHIM}")
endif()

set(LADYBIRD_IOS_SDK "/root/cctools/SDK/iPhoneOS16.5.sdk" CACHE PATH "iPhoneOS SDK")
set(CMAKE_OSX_SYSROOT "${LADYBIRD_IOS_SDK}" CACHE PATH "" FORCE)
set(CMAKE_OSX_DEPLOYMENT_TARGET "16.0" CACHE STRING "" FORCE)

set(CMAKE_C_COMPILER   "${LB_SHIM}/lb-cc")
set(CMAKE_CXX_COMPILER "${LB_SHIM}/lb-cxx")
set(CMAKE_ASM_COMPILER "${LB_SHIM}/lb-cc")
set(CMAKE_OBJC_COMPILER   "${LB_SHIM}/lb-cc")
set(CMAKE_OBJCXX_COMPILER "${LB_SHIM}/lb-cxx")

# cctools mach-o tools, exposed unprefixed on the shim dir.
set(CMAKE_AR                "${LB_SHIM}/ar"                CACHE FILEPATH "" FORCE)
set(CMAKE_RANLIB            "${LB_SHIM}/ranlib"            CACHE FILEPATH "" FORCE)
set(CMAKE_LIBTOOL           "${LB_SHIM}/libtool"           CACHE FILEPATH "" FORCE)
set(CMAKE_INSTALL_NAME_TOOL "${LB_SHIM}/install_name_tool" CACHE FILEPATH "" FORCE)
set(CMAKE_STRIP             "${LB_SHIM}/strip"             CACHE FILEPATH "" FORCE)
set(CMAKE_NM                "${LB_SHIM}/nm"                CACHE FILEPATH "" FORCE)

# C++23 core; do not let a missing compiler feature probe downgrade it.
set(CMAKE_C_STANDARD 17)
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Executable link flags:
#  -L/var/jb/usr/lib : deps linked as absolute paths resolve fine, but a few CMake targets emit a
#    bare -l<name> (e.g. harfbuzz's config target -> -lharfbuzz); give ld the staged libdir.
#  -liosexec : the staged Procursus headers redirect getpwuid/endpwent/exec* to ie_* (libiosexec
#    interposition); Core::StandardPaths references ie_getpwuid/ie_endpwent, so every executable
#    must link libiosexec (shipped as a .tbd in build_base; resolves to libiosexec.1.dylib on device).
#  -lladybird_gapfill : small static lib (build-ladybird-wave4b.sh prep) providing tommath's
#    mp_set_double, which the staged libtommath.dylib was built without (LibCrypto references it).
#    Placed after the archives on the link line so its object resolves the late reference.
set(CMAKE_EXE_LINKER_FLAGS_INIT    "-L/var/jb/usr/lib -liosexec -lladybird_gapfill")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-L/var/jb/usr/lib")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "-L/var/jb/usr/lib")

# The wrapper already carries --target/-isysroot/-fuse-ld; keep the SDK on the flags too so
# find_library / try_compile that bypass the wrapper's implicit sysroot still resolve.
# -Wno-error: Ladybird builds with -Werror; clang-19 flags real-but-benign warnings that upstream's
# newer clang does not (e.g. -Wabsolute-value in ColorConversion/BMPLoader). Neutralize -Werror for
# the cross bring-up rather than patch each site.
set(CMAKE_C_FLAGS_INIT   "-D__IOS__ -miphoneos-version-min=16.0 -Wno-error")
set(CMAKE_CXX_FLAGS_INIT "-D__IOS__ -miphoneos-version-min=16.0 -Wno-error")

# find_package/library/include resolve against the staged Procursus tree, which the driver
# exposes at its device-absolute path (symlink /var/jb -> build_base/.../var/jb) so the .pc and
# CMake-config packages' baked /var/jb paths resolve on the host. Programs come from the host
# (python3, the shim tools). ONLY (not BOTH) so a host Linux libz/libpng is never picked over the
# staged iOS dylib.
set(LB_STAGED_PREFIX "/var/jb")
if (DEFINED ENV{LB_STAGED_PREFIX})
  set(LB_STAGED_PREFIX "$ENV{LB_STAGED_PREFIX}")
endif()
set(CMAKE_FIND_ROOT_PATH "${LB_STAGED_PREFIX};${LB_STAGED_PREFIX}/usr" CACHE PATH "" FORCE)
set(CMAKE_PREFIX_PATH    "${LB_STAGED_PREFIX};${LB_STAGED_PREFIX}/usr" CACHE PATH "" FORCE)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# Skip CMake's compiler ABI link probe indirection issues on the cross linker: let it link.
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
