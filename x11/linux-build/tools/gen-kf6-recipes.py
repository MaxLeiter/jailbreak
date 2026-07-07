#!/usr/bin/env python3
"""Generate the KDE Frameworks 6 (layer K) Procursus recipes + control files.

The TABLE below is the canonical output of the K0 audit (2026-07-01): the exact
find_package graphs of kwin 6.1.5, plasma-nano/plasma-mobile 6.1.5, libplasma
6.1.5 and every KF 6.3.0 framework in their closure were pulled from
invent.kde.org and reduced to the minimal framework subset + per-framework
direct deps. See x11/docs/kde-plasma-plan.md ("Layer K") for the prose version.

Emits, per entry:
  recipes/<target>.mk            (Procursus subproject, qtsvg.mk shape, kf6-common.mk macros)
  build_info/<deb>.control       (+ <deb>-dev.control unless data-only)

Regenerating OVERWRITES the emitted files. During the phase-2 build the .mk
files will accumulate hand-written gotcha fixes; at that point either fold the
fixes back into this table (preferred, keeps the table canonical) or stop
regenerating. Run from x11/linux-build: python3 tools/gen-kf6-recipes.py

The audit's dependency DAG doubles as the build order: the script topo-sorts
TABLE and prints the wave list that build-kf6.sh's TARGETS default must match.
"""

import os
import sys

KF6_V = "6.3.0"          # KDE Frameworks pin (kde-plasma-plan.md version table)
PLASMA_V = "6.1.5"       # Plasma pin (kwayland, kdecoration, kglobalacceld, ...)
PWP_V = "1.13.0"         # plasma-wayland-protocols (kwin's minimum)

# kind: kf | plasma | pwp | ecm  (source tarball family)
# deps: DIRECT required deps on other TABLE targets (audit result; drives the
#       DAG, the control Depends and the doc). Qt/system deps go in qt_deps/extra_deps.
# qt_deps: runtime deb Depends outside the KF set.
# dev_extra: extra Depends for the -dev deb (beyond runtime pkg + deps' -dev + ECM).
# flags: extra cmake flags (audited feature cuts).
# seds: raw recipe lines run in -setup after extraction (leading tab added).
# data_only: single deb, no dev split, no SIGN (no Mach-O content).
# host_tool: framework also gets a NATIVE build in build-kf6.sh stage 1
#       (provides build-time tools resolved through KF6_HOST_TOOLING).
# rev: iOS package revision suffix (defaults to ios1).
# notes: recipe header comment lines (the audit's per-framework findings).
TABLE = [
    dict(t="extra-cmake-modules", kind="ecm", deb="extra-cmake-modules", deps=[],
         qt_deps=[], data_only=True, host_tool=True, section="Development",
         desc=("KDE's CMake module collection, the build system layer under "
               "every KDE Frameworks 6 and Plasma component."),
         notes=["ECM is cmake scripts only (arch-independent): one deb, no dev split, no",
                "SIGN. The same staged tree serves the cross builds (CMAKE_FIND_ROOT_PATH)",
                "and, via CMAKE_PREFIX_PATH, the stage-1 host tooling builds in build-kf6.sh."]),

    dict(t="plasma-wayland-protocols", kind="pwp", deb="plasma-wayland-protocols", deps=[],
         qt_deps=[], data_only=True, section="Development",
         desc=("Plasma-specific Wayland protocol XML files. Build-time input for "
               "kguiaddons, kwindowsystem, kidletime, kwayland and kwin."),
         notes=["Protocol XML + cmake config only; compiled INTO its consumers, so this is",
                "build-time data (Section: Development, single deb, no SIGN). Pinned to",
                "kwin 6.1's minimum (1.13.0)."]),

    # ---- wave 1: Qt-only frameworks ----
    dict(t="kcoreaddons", kind="kf", deb="kf6-coreaddons", deps=[],
         qt_deps=["qt6-base", "qt6-declarative"], host_tool=True, rev="ios2",
         seds=["sed -i 's/^if(NOT WIN32)$$/if(NOT WIN32 AND NOT APPLE)/' $(BUILD_WORK)/kcoreaddons/src/lib/CMakeLists.txt"],
         desc="Qt addon library with utilities for text, io, jobs and plugins.",
         notes=["Host-tooling provider (desktoptojson): stage 1 of build-kf6.sh builds this",
                "natively; cross consumers resolve the tool via KF6_HOST_TOOLING.",
                "iOS uses the non-mmap shared-data-cache backend: the POSIX backend tears",
                "down shared mappings with munmap(), which trips iOS guarded VM checks at",
                "plasmashell shutdown/restart."]),
    dict(t="karchive", kind="kf", deb="kf6-archive", deps=[],
         qt_deps=["qt6-base"], host_tool=True,
         flags=["-DWITH_BZIP2=OFF", "-DWITH_LIBLZMA=OFF", "-DWITH_LIBZSTD=OFF"],
         desc="Reading, creating and manipulating archive formats (zip, tar, 7z).",
         notes=["bzip2/xz/zstd backends disabled on purpose: zlib comes from the SDK, but",
                "the compression side-deps would add Depends we would have to name blind",
                "(the Procursus libsqlite3-1 naming lesson). KPackage/KIconThemes only need",
                "zip/tar.gz. Use the WITH_* options, NOT CMAKE_DISABLE_FIND_PACKAGE: each",
                "WITH_*=ON (the default) sets its backend to REQUIRED (bzip2/lzma via",
                "feature_summary, zstd via pkg_check_modules REQUIRED which errors on the",
                "spot), so disabling the find-package alone still fatals. WITH_*=OFF demotes",
                "them to RECOMMENDED and makes zstd's pkg-config lookup non-required.",
                "Host build exists only as a dependency of host ki18n/kpackage."]),
    dict(t="kcodecs", kind="kf", deb="kf6-codecs", deps=[],
         qt_deps=["qt6-base"],
         desc="Text encoding detection and translation collection.",
         notes=["Needs gperf on the build host (build-kf6.sh apt-installs it)."]),
    dict(t="kconfig", kind="kf", deb="kf6-config", deps=[],
         qt_deps=["qt6-base", "qt6-declarative"], host_tool=True,
         desc="Configuration file storage and kcfg code generation.",
         notes=["Host-tooling provider (kconfig_compiler_kf6): nearly every KDE cmake project",
                "runs it at build time. Its Config.cmake takes the KF6_HOST_TOOLING branch",
                "when CMAKE_CROSSCOMPILING, the same mechanism Android KDE builds use."]),
    dict(t="kwidgetsaddons", kind="kf", deb="kf6-widgetsaddons", deps=[],
         qt_deps=["qt6-base"],
         desc="Large set of QtWidgets addons and dialogs."),
    dict(t="kitemviews", kind="kf", deb="kf6-itemviews", deps=[],
         qt_deps=["qt6-base"],
         desc="Widget addons for Qt Model/View."),
    dict(t="kitemmodels", kind="kf", deb="kf6-itemmodels", deps=[],
         qt_deps=["qt6-base", "qt6-declarative"],
         desc="Set of item models extending the Qt model-view framework.",
         notes=["Required directly by plasma-nano. QML bindings enabled because",
                "qt6-declarative is staged (optional dep auto-detected)."]),
    dict(t="kdbusaddons", kind="kf", deb="kf6-dbusaddons", deps=[],
         qt_deps=["qt6-base"],
         desc="Convenience classes on top of QtDBus.",
         notes=["Hard gate: qtbase must be the round-2 build (FEATURE_dbus=ON, plan Q3)."]),
    dict(t="kglobalaccel", kind="kf", deb="kf6-globalaccel", deps=[],
         qt_deps=["qt6-base"],
         desc="Global keyboard shortcut client library.",
         notes=["Client half only; the daemon moved to the Plasma-released kglobalacceld",
                "(built later in this layer). On Wayland the compositor (kwin) does the",
                "actual grabbing."]),
    dict(t="kguiaddons", kind="kf", deb="kf6-guiaddons", deps=[],
         qt_deps=["qt6-base", "qt6-wayland"],
         flags=["-DWITH_WAYLAND=ON", "-DWITH_X11=OFF", "-DWITH_DBUS=ON"],
         seds=["sed -i 's/if (UNIX AND NOT ANDROID AND NOT APPLE)/if (UNIX AND NOT ANDROID)/' $(BUILD_WORK)/kguiaddons/CMakeLists.txt",
               # $$ = literal $ once Make expands the recipe line (end-of-line anchor)
               "sed -i 's/^if(APPLE)$$/if(FALSE) # iOS: no AppKit/' $(BUILD_WORK)/kguiaddons/src/CMakeLists.txt"],
         desc="Utilities for graphical user interfaces (color, font, keys, cursors).",
         notes=["APPLE guards audited against the real v6.3.0 tree and pre-patched in -setup:",
                "(1) the top-level 'UNIX AND NOT APPLE' guard hard-sets WITH_WAYLAND/X11/DBUS",
                "OFF on APPLE before the -D flags can win, so APPLE is let into the UNIX",
                "branch; (2) src/CMakeLists.txt if(APPLE) adds kcolorschemewatcher_mac.mm +",
                "links AppKit (absent on iPhoneOS) -> forced off; the runtime picker compiles",
                "the xdg/DBus watcher because Qt for iOS defines Q_OS_IOS, not Q_OS_MACOS.",
                "Wayland codegen (keystate/wlr-data-control/shortcut-inhibit) runs the HOST",
                "qtwaylandscanner via QT_HOST_PATH, and Wayland_DATADIR must resolve to the",
                "staged wayland deb's share/wayland/wayland.xml."]),
    dict(t="kwindowsystem", kind="kf", deb="kf6-windowsystem", deps=[],
         qt_deps=["qt6-base", "qt6-declarative", "qt6-wayland"],
         flags=["-DKWINDOWSYSTEM_X11=OFF", "-DKWINDOWSYSTEM_WAYLAND=ON"],
         seds=["sed -i '/set(KWINDOWSYSTEM_WAYLAND OFF)/d' $(BUILD_WORK)/kwindowsystem/CMakeLists.txt"],
         desc="Access to window manager properties and protocols.",
         notes=["X11 OFF is automatic on APPLE (audited: WIN32 OR APPLE OR ANDROID guard)",
                "but pinned explicitly anyway; the mutter X11-off lesson applies verbatim.",
                "That same guard also hard-sets KWINDOWSYSTEM_WAYLAND OFF (plain set(), which",
                "beats the -D cache flag), so the sed drops just that line: X11 stays forced",
                "off, wayland survives. No codegen: the wayland half (kwaylandextras.cpp +",
                "KWaylandExtras) is plain sources, no qtwaylandscanner involved.",
                "The wayland half is what kwin, plasma-nano and libplasma consume."]),
    dict(t="kidletime", kind="kf", deb="kf6-idletime", deps=[],
         qt_deps=["qt6-base", "qt6-wayland"],
         flags=["-DWITH_WAYLAND=ON", "-DWITH_X11=OFF"],
         seds=["sed -i '/set(WITH_WAYLAND OFF)/d' $(BUILD_WORK)/kidletime/CMakeLists.txt",
               "sed -i '/cmake_find_frameworks(CoreFoundation Carbon)/d' $(BUILD_WORK)/kidletime/CMakeLists.txt",
               "sed -i '/add_subdirectory(osx)/d' $(BUILD_WORK)/kidletime/src/plugins/CMakeLists.txt"],
         desc="Monitoring user activity and idle time.",
         notes=["APPLE guards audited against the real v6.3.0 tree and pre-patched in -setup:",
                "the 'APPLE OR WIN32' block hard-sets WITH_WAYLAND OFF (X11 line kept: still",
                "forced off), the Carbon framework probe is dropped (no Carbon on iPhoneOS),",
                "and the osx idle poller plugin (Carbon/ApplicationServices APIs) is removed",
                "from src/plugins. The wayland (ext-idle-notify) poller plugin builds instead;",
                "its protocol codegen runs the HOST qtwaylandscanner via QT_HOST_PATH.",
                "Runtime plugin choice keys off platformName()==wayland, so the mac plugin is",
                "dead weight even where it compiles."]),
    dict(t="ki18n", kind="kf", deb="kf6-i18n", deps=[],
         qt_deps=["qt6-base", "qt6-declarative", "libgtkintl", "iso-codes"], host_tool=True,
         desc="Advanced internationalization framework on top of gettext.",
         notes=["libintl comes from the proxy-libintl deb (libgtkintl), the same precedent",
                "as the GTK stack. Needs python3 + gettext on the build host. iso-codes",
                "(deb exists) feeds language name lookups at runtime.",
                "Host build is a dependency of host kpackage (stage 1)."]),
    dict(t="solid", kind="kf", deb="kf6-solid", deps=[],
         qt_deps=["qt6-base"],
         seds=["sed -i '/find_package(IOKit REQUIRED)/d' $(BUILD_WORK)/solid/CMakeLists.txt",
               "sed -i '/add_device_backend(iokit)/d' $(BUILD_WORK)/solid/CMakeLists.txt"],
         desc="Hardware discovery and power management abstraction.",
         notes=["Backend list pre-patched down to fakehw-only in -setup: the elseif(APPLE)",
                "branch wants the IOKit backend, which is written against macOS IOKit +",
                "DiskArbitration (headers/framework absent on the iPhoneOS SDK). Verified",
                "against v6.3.0: managerbase.cpp gates every backend on the generated",
                "BUILD_DEVICE_BACKEND_* defines (no Q_OS ifdefs), so a fakehw-only build",
                "compiles clean and yields an empty device list at runtime unless",
                "SOLID_FAKEHW points at an XML fixture. KIO only needs the lib to link.",
                "The emptied elseif(APPLE) block is valid CMake.",
                "bison/flex on the build host (predicate parser)."]),
    dict(t="sonnet", kind="kf", deb="kf6-sonnet", deps=[],
         qt_deps=["qt6-base", "qt6-declarative"],
         desc="Spell checking framework.",
         notes=["No backends staged (no hunspell/aspell debs), which sonnet supports: the",
                "core lib builds with zero plugins and reports no spellcheckers at runtime.",
                "Only in the subset because KTextWidgets (via KXmlGui, via KCMUtils) links it."]),
    dict(t="kirigami", kind="kf", deb="kf6-kirigami", deps=[],
         qt_deps=["qt6-declarative", "qt6-svg"],
         desc="QtQuick based components set for mobile and convergent UIs.",
         notes=["Plasma Mobile's UI toolkit and, since KF6, the KirigamiPlatform package that",
                "KSvg and libplasma hard-require. Shaders bake at build time through the host",
                "qsb (QT_HOST_PATH); the cross Qt6ShaderTools cmake package must be staged",
                "(qtshadertools recipe)."]),
    dict(t="qqc2-desktop-style", kind="kf", deb="kf6-qqc2-desktop-style",
         deps=["kcolorscheme", "kconfig", "kiconthemes", "kirigami"],
         qt_deps=["qt6-base", "qt6-declarative", "qt6-svg"],
         rev="ios2",
         seds=["bash /work/recipes/qqc2-desktop-style-ios-fixes.sh $(BUILD_WORK)/qqc2-desktop-style"],
         desc="Qt Quick Controls 2 desktop style and the org.kde.desktop QML import.",
         notes=["Runtime dependency for Plasma Desktop shell error delegates and desktop QML.",
                "This package provides the org.kde.desktop QML module that real plasmashell",
                "loads when the upstream desktop shell is selected. The iOS package keeps",
                "the real style controls and lazy-loads the private text context menu so",
                "the upstream public/private import path does not create a startup cycle."]),
    dict(t="breeze-icons", kind="kf", deb="kf6-breeze-icons", deps=[],
         qt_deps=[], data_only=True, section="Themes",
         flags=["-DBINARY_ICONS_RESOURCE=OFF"],
         desc="Default KDE icon theme (Breeze).",
         notes=["Data-only (icon files + cmake config in one deb, no SIGN). KIconThemes",
                "REQUIREs it at build on non-Android, so it sits in wave 1, not in theming",
                "polish. BINARY_ICONS_RESOURCE=OFF skips the icons.rcc bake; plain files are",
                "friendlier to the icon repack pipeline anyway."]),

    # ---- wave 2: single-hop frameworks ----
    dict(t="kauth", kind="kf", deb="kf6-auth", deps=["kcoreaddons"],
         qt_deps=["qt6-base"],
         flags=["-DKAUTH_BACKEND_NAME=FAKE", "-DKAUTH_HELPER_BACKEND_NAME=FAKE"],
         desc="Execute actions as privileged user.",
         notes=["FAKE backend on purpose: the real one wants polkit-qt6-1 (a lib we have not",
                "built; only plain polkit exists) and the jailbreak runtime has no privilege",
                "boundary that KAuth could meaningfully broker anyway. Revisit if a Plasma",
                "KCM genuinely needs privileged apply."]),
    dict(t="kcrash", kind="kf", deb="kf6-crash", deps=["kcoreaddons"],
         qt_deps=["qt6-base"],
         desc="Crash interception and backtrace generation.",
         notes=["drkonqi is not in the subset; KCrash without it just forwards to the default",
                "signal handlers. In the subset because kwin and kglobalacceld link it."]),
    dict(t="kcolorscheme", kind="kf", deb="kf6-colorscheme", deps=["kconfig", "kguiaddons", "ki18n"],
         qt_deps=["qt6-base"],
         desc="Color scheme access classes (split out of KConfigWidgets in KF6)."),
    dict(t="kservice", kind="kf", deb="kf6-service", deps=["kconfig", "kcoreaddons", "ki18n"],
         qt_deps=["qt6-base"],
         desc="Plugin framework for desktop services (sycoca).",
         notes=["bison/flex on the build host (trader query parser). Ships kbuildsycoca6 in",
                "the runtime deb; the sycoca cache builds on-device at first login."]),
    dict(t="kpackage", kind="kf", deb="kf6-package", deps=["karchive", "kcoreaddons", "ki18n"],
         qt_deps=["qt6-base"], host_tool=True,
         desc="Installation and loading of content packages (plasmoids, themes).",
         notes=["Host-tooling provider (kpackagetool6): plasma_install_package() runs it at",
                "build time in libplasma/plasma-nano/plasma-mobile, so stage 1 builds it",
                "natively (which is why host karchive/ki18n exist at all)."]),
    dict(t="knotifications", kind="kf", deb="kf6-notifications", deps=["kconfig"],
         qt_deps=["qt6-base", "qt6-declarative"],
         seds=["sed -i 's/find_package(Canberra REQUIRED)/find_package(Canberra)/' $(BUILD_WORK)/knotifications/CMakeLists.txt",
               "sed -i 's/if (NOT APPLE AND NOT ANDROID AND NOT WIN32 OR (WIN32 AND NOT WITH_SNORETOAST))/if (TRUE)/' $(BUILD_WORK)/knotifications/CMakeLists.txt",
               "sed -i '/notifybymacosnotificationcenter.mm/d' $(BUILD_WORK)/knotifications/src/CMakeLists.txt",
               "sed -i '/-framework AppKit/d' $(BUILD_WORK)/knotifications/src/CMakeLists.txt"],
         desc="Desktop notifications over the freedesktop DBus interface.",
         notes=["Four audited patches, applied in -setup: (1) Canberra demoted from REQUIRED;",
                "the code already guards on the target existing, and sound notifications are",
                "not worth a libcanberra+vorbis chain right now. (2) the freedesktop/DBus",
                "branch is forced; the APPLE branch selects the macOS NSUserNotification",
                "backend, which does not exist on iPhoneOS. (3)+(4) the matching src-level",
                "if(APPLE) blocks: notifybymacosnotificationcenter.mm (NSUserNotificationCenter",
                "= macOS-only) and the AppKit link line are dropped; both deletions leave",
                "empty-but-valid if(APPLE) blocks. The runtime manager only reaches the mac",
                "backend under Q_OS_MACOS, which Qt for iOS does not define."]),

    # ---- wave 3 ----
    dict(t="kconfigwidgets", kind="kf", deb="kf6-configwidgets",
         deps=["kcodecs", "kcolorscheme", "kconfig", "kcoreaddons", "kguiaddons", "ki18n", "kwidgetsaddons"],
         qt_deps=["qt6-base"],
         desc="Widgets for configuration dialogs."),
    dict(t="kcompletion", kind="kf", deb="kf6-completion", deps=["kcodecs", "kconfig", "kwidgetsaddons"],
         qt_deps=["qt6-base"],
         desc="String completion framework and widgets."),
    dict(t="kjobwidgets", kind="kf", deb="kf6-jobwidgets", deps=["kcoreaddons", "knotifications", "kwidgetsaddons"],
         qt_deps=["qt6-base"],
         desc="Widgets and DBus glue for tracking KJob instances.",
         notes=["The reason KNotifications is unavoidable: kjobwidgets REQUIREs it",
                "unconditionally and KIO REQUIREs kjobwidgets."]),
    dict(t="ksvg", kind="kf", deb="kf6-svg",
         deps=["karchive", "kcolorscheme", "kconfig", "kcoreaddons", "kguiaddons", "kirigami"],
         qt_deps=["qt6-base", "qt6-svg", "qt6-declarative"],
         desc="SVG rendering framework with theming support (Plasma themes).",
         notes=["Direct kwin requirement (KF6::Svg). The KirigamiPlatform dep is why kirigami",
                "sits in wave 1."]),
    dict(t="kiconthemes", kind="kf", deb="kf6-iconthemes",
         deps=["karchive", "breeze-icons", "kcolorscheme", "kconfigwidgets", "ki18n", "kwidgetsaddons"],
         qt_deps=["qt6-base", "qt6-svg", "qt6-declarative"],
         desc="Icon theme handling per the freedesktop spec."),
    dict(t="kdecoration", kind="plasma", deb="kdecoration", deps=["ki18n"],
         qt_deps=["qt6-base"],
         desc="Plugin-based window decoration API for KWin (KDecoration2).",
         notes=["Plasma-released, version 6.1.5, library name KDecoration2 (KDecoration3 only",
                "exists from Plasma 6.3; the plan doc's earlier mention was wrong). kwin's",
                "server-side decoration support REQUIREs it even for the nested case."]),

    # ---- wave 4 ----
    dict(t="kbookmarks", kind="kf", deb="kf6-bookmarks",
         deps=["kconfig", "kconfigwidgets", "kcoreaddons", "kwidgetsaddons"],
         qt_deps=["qt6-base"],
         desc="Bookmark management (XBEL format).",
         notes=["Only in the subset as a hard KIO dep."]),
    dict(t="ktextwidgets", kind="kf", deb="kf6-textwidgets",
         deps=["kcompletion", "kconfig", "kconfigwidgets", "ki18n", "sonnet", "kwidgetsaddons"],
         qt_deps=["qt6-base"],
         flags=["-DWITH_TEXT_TO_SPEECH=OFF"],
         desc="Text editing widgets.",
         notes=["WITH_TEXT_TO_SPEECH=OFF is load-bearing: ON would pull Qt6TextToSpeech and",
                "with it the whole qtspeech module. The audit found this switch; without it",
                "the Qt module set would grow by one for a feature nobody asked for."]),

    # ---- wave 5 ----
    dict(t="kxmlgui", kind="kf", deb="kf6-xmlgui",
         deps=["kconfig", "kconfigwidgets", "kcoreaddons", "kglobalaccel", "kguiaddons",
               "ki18n", "kiconthemes", "kitemviews", "ktextwidgets", "kwidgetsaddons", "kwindowsystem"],
         qt_deps=["qt6-base"],
         desc="XML-described action and menu framework.",
         notes=["REQUIREs Qt6PrintSupport (audited, unconditional): qtbase round 1 built",
                "printsupport OFF, so the round-2 rebuild (plan Q3) must flip",
                "FEATURE_printsupport=ON alongside dbus/xkbcommon. cups stays OFF."]),
    dict(t="kio", kind="kf", deb="kf6-kio", rev="ios2",
         deps=["karchive", "kauth", "kbookmarks", "kcolorscheme", "kcompletion", "kconfig",
               "kconfigwidgets", "kcoreaddons", "kcrash", "kdbusaddons", "kguiaddons", "ki18n",
               "kiconthemes", "kitemviews", "kjobwidgets", "kservice", "solid",
               "kwidgetsaddons", "kwindowsystem"],
         qt_deps=["qt6-base", "qt6-5compat"],
         flags=["-DCMAKE_DISABLE_FIND_PACKAGE_ACL=TRUE",
                "-DCMAKE_DISABLE_FIND_PACKAGE_KF6DocTools=TRUE"],
         seds=["sed -i 's/if(UNIX AND NOT APPLE AND NOT ANDROID)/if(UNIX AND NOT ANDROID)/' $(BUILD_WORK)/kio/CMakeLists.txt",
               "sed -i 's/^if (APPLE)$$/if (FALSE) # iOS: no AppKit kiod agent/' $(BUILD_WORK)/kio/src/kiod/CMakeLists.txt",
               "sed -i 's/defined(Q_OS_LINUX) || defined(Q_OS_FREEBSD)/defined(Q_OS_LINUX) || defined(Q_OS_FREEBSD) || defined(Q_OS_IOS)/' $(BUILD_WORK)/kio/src/gui/openfilemanagerwindowjob_p.h",
               "sed -i 's/ Widgets Network Concurrent Xml Test)/ Widgets Network Concurrent Xml)/' $(BUILD_WORK)/kio/CMakeLists.txt",
               "sed -i 's/#ifdef Q_OS_MACOS/#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)/' $(BUILD_WORK)/kio/src/kioworkers/file/file_unix.cpp",
               "sed -i 's/Q_OS_OSX/Q_OS_MACOS/g' $(BUILD_WORK)/kio/src/kioworkers/trash/trashimpl.cpp",
               "sed -i 's/-framework DiskArbitration //' $(BUILD_WORK)/kio/src/kioworkers/trash/CMakeLists.txt"],
         desc="Network-transparent file and data access framework.",
         notes=["The widest framework in the subset; unavoidable, libplasma and kglobalacceld",
                "both REQUIRE it. Darwin spares us two Linux-isms (audited): LibMount is",
                "Linux-guarded (KMountPoint uses getmntinfo, present in the iOS libc) and X11",
                "integration is APPLE-guarded off. Qt6Core5Compat (QTextCodec) is REQUIRED,",
                "hence the qt6-5compat module dep - one of the three Qt module gaps the audit",
                "opened against the Qt layer. Qt6Test is only used by KIO's test programs;",
                "drop it from the unconditional Qt component list while BUILD_TESTING=OFF.",
                "Plasma Workspace's real desktop:/ worker needs KIOCore's DBus-gated",
                "ForwardingWorkerBase/KDirNotify sources, so the iOS build uses the Unix",
                "QtDBus branch instead of upstream's broad APPLE exclusion.",
                "Enabling that branch exposes kiod; keep kiod6 but drop the macOS AppKit",
                "LSUIElement agent/link path because the iPhoneOS SDK has no AppKit.",
                "KIOGui's file-manager DBus strategy has a Linux/FreeBSD declaration guard",
                "but source-level WITH_QTDBUS use, so include Q_OS_IOS in that guard.",
                "The file worker's NTFS hidden-attribute helper already has Darwin getxattr()",
                "arguments but upstream guards it as Q_OS_MACOS-only; include Q_OS_IOS too.",
                "The trash worker's macOS DiskArbitration branch is unavailable in the",
                "iPhoneOS SDK, so keep the worker on the generic Solid/stat path."]),

    # ---- wave 6 ----
    dict(t="kcmutils", kind="kf", deb="kf6-kcmutils",
         deps=["kconfigwidgets", "kcoreaddons", "kguiaddons", "ki18n", "kio", "kitemviews", "kxmlgui"],
         qt_deps=["qt6-base", "qt6-declarative"],
         seds=["sed -i 's|PATHS $${KF6_HOST_TOOLING} $${CMAKE_CURRENT_LIST_DIR}|PATHS $${KF6_HOST_TOOLING} $${CMAKE_CURRENT_LIST_DIR}/.. $${CMAKE_CURRENT_LIST_DIR}|' $(BUILD_WORK)/kcmutils/KF6KCMUtilsConfig.cmake.in"],
         desc="Utilities for KDE System Settings modules (KCMs).",
         notes=["Top of the widget-tier chain: libplasma REQUIREs KCMUtils, KCMUtils REQUIREs",
                "KXmlGui + KIO, and that chain (not kwin) is what drags ktextwidgets/sonnet/",
                "kbookmarks into the subset. Uses QtQuickWidgets from qt6-declarative.",
                "Its Config.cmake assumes host-built tooling targets while cross-compiling;",
                "the sed lets consumers fall back to the installed local tooling targets",
                "when no host KCMUtils tooling build exists."]),

    # ---- Plasma Workspace support wave ----
    dict(t="attica", kind="kf", deb="kf6-attica", deps=[],
         qt_deps=["qt6-base"],
         desc="Open Collaboration Services client library.",
         notes=["Workspace pulls this through KNewStuff. It is Qt Core+Network only and",
                "does not need a first-light feature cut."]),
    dict(t="kdeclarative", kind="kf", deb="kf6-declarative",
         deps=["kconfig", "kguiaddons", "ki18n", "kwidgetsaddons"],
         qt_deps=["qt6-declarative", "qt6-shadertools"],
         desc="Integration helpers for using KDE frameworks from QtQuick.",
         notes=["Plasma Workspace REQUIREs KF6::Declarative. On APPLE, upstream already skips",
                "the KGlobalAccel branch; Qt ShaderTools is needed for the graphical effects",
                "QML module and is already part of the Qt6 module layer."]),
    dict(t="krunner", kind="kf", deb="kf6-runner",
         deps=["kconfig", "kcoreaddons", "ki18n", "kitemmodels"],
         qt_deps=["qt6-base", "qt6-declarative"],
         desc="Framework for Plasma runner plugins and query matches.",
         notes=["KF6ItemModels is optional upstream but staged in our base KF6 set; keep the",
                "runtime/control dependency explicit because Workspace runner plumbing uses it."]),
    dict(t="kded", kind="kf", deb="kf6-kded",
         deps=["kconfig", "kcoreaddons", "kcrash", "kdbusaddons", "kservice"],
         qt_deps=["qt6-base"],
         rev="ios2",
         flags=["-DCMAKE_DISABLE_FIND_PACKAGE_KF6DocTools=TRUE"],
         seds=["sed -i 's|KCONF_UPDATE_EXE=\"[$$]<TARGET_FILE:KF6::kconf_update>\"|KCONF_UPDATE_EXE=\"$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/kf6/kconf_update\"|' $(BUILD_WORK)/kded/src/CMakeLists.txt"],
         desc="KDE background services daemon framework.",
         notes=["Plasma Workspace expects KF6KDED. DocTools is optional and disabled for the",
                "bring-up package to avoid another host-tool/docs branch. The iOS package",
                "also points kded at the target kconf_update helper instead of baking the",
                "host KF6 tooling path into the runtime daemon."]),
    dict(t="kstatusnotifieritem", kind="kf", deb="kf6-statusnotifieritem",
         deps=["kwindowsystem"],
         qt_deps=["qt6-base"],
         flags=["-DWITHOUT_X11=ON"],
         seds=["sed -i 's/^if(APPLE)$/if(FALSE) # iOS: no AppKit/' $(BUILD_WORK)/kstatusnotifieritem/src/CMakeLists.txt"],
         desc="Status notifier item support for tray-style application indicators.",
         notes=["Workspace wants KF6::StatusNotifierItem. X11 probing is disabled explicitly;",
                "the DBus/freedesktop status notifier path remains. The APPLE source block",
                "is macOS-only (macutils.mm imports AppKit), so iOS patches it out."]),
    dict(t="kunitconversion", kind="kf", deb="kf6-unitconversion",
         deps=["ki18n"],
         qt_deps=["qt6-base"],
         desc="Unit conversion framework used by Plasma runners and data engines."),
    dict(t="kparts", kind="kf", deb="kf6-parts",
         deps=["kconfig", "kcoreaddons", "ki18n", "kio", "kjobwidgets", "kservice",
               "kwidgetsaddons", "kxmlgui"],
         qt_deps=["qt6-base"],
         desc="Embeddable component framework used by KDE applications and plugins."),
    dict(t="knewstuff", kind="kf", deb="kf6-newstuff",
         deps=["attica", "karchive", "kconfig", "kcoreaddons", "ki18n", "kpackage",
               "kwidgetsaddons"],
         qt_deps=["qt6-base", "qt6-declarative"],
         rev="ios2",
         flags=["-DCMAKE_DISABLE_FIND_PACKAGE_KF6Kirigami2=TRUE",
                "-DCMAKE_DISABLE_FIND_PACKAGE_KF6Syndication=TRUE"],
         pkg_lines=["rm -f $(BUILD_DIST)/kf6-newstuff/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/applications/org.kde.knewstuff-dialog6.desktop"],
         desc="Download and installation framework for add-on content.",
         notes=["Workspace's component gate requires NewStuff, but first light does not need",
                "Kirigami2 UI polish or feed support, so both optional branches are disabled.",
                "The helper app is not installed in this cut, so the package removes its",
                "desktop entry instead of advertising a missing knewstuff-dialog6 binary."]),
    dict(t="kwallet", kind="kf", deb="kf6-wallet",
         deps=["kconfig", "kcoreaddons", "ki18n", "kwindowsystem"],
         qt_deps=["qt6-base"],
         flags=["-DBUILD_KWALLETD=OFF", "-DBUILD_KWALLET_QUERY=OFF",
                "-DCMAKE_DISABLE_FIND_PACKAGE_KF6DocTools=TRUE"],
         desc="KWallet client API for secret storage integration.",
         notes=["API-only first-light build. Disabling kwalletd/query avoids QCA, Gcrypt,",
                "GpgME and daemon productization while still satisfying Workspace's Wallet",
                "CMake component."]),
    dict(t="knotifyconfig", kind="kf", deb="kf6-notifyconfig",
         deps=["kcompletion", "kconfig", "ki18n", "kio"],
         qt_deps=["qt6-base"],
         seds=["sed -i 's/find_package(Phonon4Qt6 4\\.6\\.60 NO_MODULE REQUIRED)/find_package(Phonon4Qt6 4.6.60 NO_MODULE)/' $(BUILD_WORK)/knotifyconfig/CMakeLists.txt"],
         desc="Configuration widgets for KDE notification events.",
         notes=["The source already treats Canberra/Phonon as optional after configure; this",
                "sed demotes the fallback Phonon lookup so sound-preview support can stay off",
                "without blocking Workspace configuration."]),

    # ---- Plasma-released libraries (version 6.1.5), same layer ----
    dict(t="kwayland", kind="plasma", deb="kwayland", deps=[],
         qt_deps=["qt6-base", "qt6-wayland", "angle"],
         desc="Qt-style client library for Plasma's Wayland protocols.",
         notes=["Links EGL directly (audited REQUIRED): headers/libs resolve from the staged",
                "ANGLE chain in build_base, on-device from the angle deb. No KF deps at all,",
                "so it builds in wave 1 alongside the Qt-only frameworks."]),
    dict(t="plasma-activities", kind="plasma", deb="plasma-activities", deps=[],
         qt_deps=["qt6-base"],
         desc="Activities client library (libPlasmaActivities).",
         notes=["Slim in Plasma 6 (Qt Core+DBus only; the old boost dependency is gone -",
                "audited). libplasma REQUIREs it; the kactivitymanagerd daemon is NOT in this",
                "subset, activity state just stays static until the workspace layer."]),
    dict(t="layer-shell-qt", kind="plasma", deb="layer-shell-qt", deps=[],
         qt_deps=["qt6-base", "qt6-declarative", "qt6-wayland"],
         rev="ios9",
         seds=["bash /work/recipes/layer-shell-qt-ios-fixes.sh $(BUILD_WORK)/layer-shell-qt"],
         desc="Qt integration for the wlr-layer-shell protocol.",
         notes=["Not a kwin dep; plasma-workspace panels sit on it (and iosc already speaks",
                "zwlr_layer_shell_v1 v4, so nested-kwin panels can bypass kwin entirely).",
                "Needs the host wayland-scanner (build-kf6.sh apt gate, same as qtwayland).",
                "The iOS package carries the popup/surface fixes needed by Plasma panels."]),
    dict(t="kglobalacceld", kind="plasma", deb="kglobalacceld",
         deps=["kconfig", "kcoreaddons", "kcrash", "kdbusaddons", "kglobalaccel",
               "kjobwidgets", "kio", "kservice", "kwindowsystem"],
         qt_deps=["qt6-base"],
         desc="Global shortcut daemon for KDE Plasma.",
         notes=["kwin REQUIREs it unless KWIN_BUILD_GLOBALSHORTCUTS=OFF; building it keeps",
                "that kwin option open. Note the KIO dep: even with kcms off, the kwin",
                "runtime needs the KIO chain through this daemon."]),
]

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RECIPES = os.path.join(HERE, "recipes")
BUILD_INFO = os.path.join(HERE, "build_info")

BY_T = {e["t"]: e for e in TABLE}


def upvar(t):
    return t.replace("-", "").upper()


def topo_waves():
    waves, placed = [], set()
    remaining = [e["t"] for e in TABLE]
    while remaining:
        wave = [t for t in remaining if all(d in placed for d in BY_T[t]["deps"])]
        if not wave:
            sys.exit("dependency cycle involving: %s" % remaining)
        waves.append(wave)
        placed.update(wave)
        remaining = [t for t in remaining if t not in placed]
    return waves


def dl_and_extract(e):
    t = e["t"]
    if e["kind"] == "kf":
        url = "$(call KF6_URL,%s)" % t
        tar = "%s-$(KF6_VERSION).tar.xz" % t
        d = "%s-$(KF6_VERSION)" % t
    elif e["kind"] == "plasma":
        url = "$(call PLASMA_URL,%s)" % t
        tar = "%s-$(PLASMA_VERSION).tar.xz" % t
        d = "%s-$(PLASMA_VERSION)" % t
    elif e["kind"] == "pwp":
        url = "https://download.kde.org/stable/plasma-wayland-protocols/plasma-wayland-protocols-$(PWP_VERSION).tar.xz"
        tar = "plasma-wayland-protocols-$(PWP_VERSION).tar.xz"
        d = "plasma-wayland-protocols-$(PWP_VERSION)"
    else:  # ecm
        url = "$(call KF6_URL,extra-cmake-modules)"
        tar = "extra-cmake-modules-$(KF6_VERSION).tar.xz"
        d = "extra-cmake-modules-$(KF6_VERSION)"
    return url, tar, d


def version_ref(e):
    return {"kf": "$(KF6_VERSION)", "plasma": "$(PLASMA_VERSION)",
            "pwp": "$(PWP_VERSION)", "ecm": "$(KF6_VERSION)"}[e["kind"]]


def emit_recipe(e):
    t, deb, uv = e["t"], e["deb"], upvar(e["t"])
    url, tar, xdir = dl_and_extract(e)
    data_only = e.get("data_only", False)
    # ECM/pwp are plain cmake trees; frameworks get the full KF6 flag block.
    flagvar = "$(DEFAULT_CMAKE_FLAGS) \\\n\t\t-DBUILD_TESTING=OFF" if e["kind"] in ("ecm", "pwp") \
        else "$(KF6_CMAKE_FLAGS)"
    extra = "".join(" \\\n\t\t%s" % f for f in e.get("flags", []))

    hdr = ["ifneq ($(PROCURSUS),1)", "$(error Use the main Makefile)", "endif", ""]
    hdr.append("# %s.mk — %s for rootless iOS (KDE flavor, layer K; docs/kde-plasma-plan.md)." % (t, deb))
    for n in e.get("notes", []):
        hdr.append("# %s" % n)
    hdr.append("# Generated by tools/gen-kf6-recipes.py from the K0 audit table; regenerating")
    hdr.append("# overwrites hand edits (fold phase-2 fixes back into the table).")
    hdr.append("")
    hdr.append("SUBPROJECTS += %s" % t)
    hdr.append("%s_VERSION = %s" % (uv, version_ref(e)))
    hdr.append("DEB_%s_V ?= $(%s_VERSION)+%s" % (uv, uv, e.get("rev", "ios1")))
    hdr.append("")

    setup = ["%s-setup: setup" % t,
             "\t$(call DOWNLOAD_FILES,$(BUILD_SOURCE),%s)" % url,
             "\t$(call EXTRACT_TAR,%s,%s,%s)" % (tar, xdir, t)]
    for s in e.get("seds", []):
        setup.append("\t%s" % s)
    # Comment out ecm_install_po_files_as_qm(): it runs find_package(Qt6LinguistTools
    # REQUIRED) → host lrelease to compile .po into Qt .qm, but qt-modules' host Qt has
    # no LinguistTools (qttools isn't in the ladder) so configure dies (proved on host
    # kcoreaddons). Translations are a non-essential bring-up cut; the SEPARATE gettext
    # path ki18n_install(po) uses msgfmt (host-apt'd) and is left working. Unconditional
    # + idempotent: no-op for units without the call. Top-level CMakeLists only — that's
    # where the project-level install macro always lives. build-kf6.sh's host_kf applies
    # the same sed for the stage-1 host builds. Re-enable by dropping this if host
    # LinguistTools ever lands.
    if e["kind"] not in ("ecm", "pwp"):
        setup.append("\tsed -i '/^[[:space:]]*ecm_install_po_files_as_qm(/s/^/# ios-bringup-no-linguist: /' $(BUILD_WORK)/%s/CMakeLists.txt" % t)
    if e["kind"] not in ("ecm", "pwp"):
        setup.append("\t$(call QT6_WRITE_IOSEXEC_FIXUP)")
    # Staged xpc/ + os/log.h headers shadow the 16.4 SDK (xpc_session API newer than
    # the SDK; ObjC++ TUs die in Foundation.h). Procursus `setup` RE-STAGES them on
    # EVERY make invocation, so driver-level parking is undone by the next unit's make
    # (proven in the Qt module ladder, cef1068) — the rm must be in-recipe, last line
    # of every -setup. Unconditional for all units: idempotent, and qt6-common.mk is
    # always in makefiles/ (build-kf6.sh copies it ahead of kf6-common.mk).
    setup.append("\t$(call QT6_RM_SHADOW_HEADERS)")
    setup.append("")

    build = ["ifneq ($(wildcard $(BUILD_WORK)/%s/.build_complete),)" % t,
             "%s:" % t,
             "\t@echo \"Using previously built %s.\"" % t,
             "else",
             "# Deps come pre-staged from build_base (mutter.mk precedent, no make-level",
             "# prereqs); build-kf6.sh runs the targets in audit wave order.",
             "%s: %s-setup" % (t, t),
             "\tmkdir -p $(BUILD_WORK)/%s/build" % t,
             "\tcd $(BUILD_WORK)/%s/build && cmake .. \\" % t,
             "\t\t-G Ninja \\",
             "\t\t%s%s" % (flagvar, extra),
             "\t+ninja -C $(BUILD_WORK)/%s/build" % t,
             "\t+DESTDIR=\"$(BUILD_STAGE)/%s\" ninja -C $(BUILD_WORK)/%s/build install" % (t, t),
             "\t$(call AFTER_BUILD,copy)",
             "endif",
             ""]

    pkg = ["%s-package: %s-stage" % (t, t)]
    if data_only:
        pkg += ["\trm -rf $(BUILD_DIST)/%s" % deb,
                "\t$(call KF6_COPY_ALL,%s,%s)" % (t, deb),
                "\t$(call PACK,%s,DEB_%s_V)" % (deb, uv),
                "\trm -rf $(BUILD_DIST)/%s" % deb]
    else:
        pkg += ["\trm -rf $(BUILD_DIST)/%s $(BUILD_DIST)/%s-dev" % (deb, deb),
                "\t$(call KF6_COPY_RUNTIME,%s,%s)" % (t, deb),
                "\t$(call KF6_COPY_DEV,%s,%s)" % (t, deb)]
        for line in e.get("pkg_lines", []):
            pkg.append("\t%s" % line)
        pkg += [
                "\t$(call SIGN,%s,general.xml)" % deb,
                "\t$(call SIGN,%s-dev,general.xml)" % deb,
                "\t$(call PACK,%s,DEB_%s_V)" % (deb, uv),
                "\t$(call PACK,%s-dev,DEB_%s_V)" % (deb, uv)]
        if t == "ki18n":
            pkg.append("\tbash /work/recipes/relink-gtkintl.sh $(BUILD_DIST)/ki18n")
        pkg.append("\trm -rf $(BUILD_DIST)/%s $(BUILD_DIST)/%s-dev" % (deb, deb))
    pkg += ["", ".PHONY: %s %s-package" % (t, t), ""]

    with open(os.path.join(RECIPES, "%s.mk" % t), "w") as f:
        f.write("\n".join(hdr + setup + build + pkg))


def emit_controls(e):
    t, deb, uv = e["t"], e["deb"], upvar(e["t"])
    data_only = e.get("data_only", False)
    section = e.get("section", "Libraries")
    rt_deps = list(e.get("qt_deps", []))
    rt_deps += [BY_T[d]["deb"] for d in e["deps"]]

    common = ["Version: @DEB_%s_V@" % uv,
              "Architecture: @DEB_ARCH@",
              "Maintainer: @DEB_MAINTAINER@",
              "Priority: optional",
              "Homepage: https://kde.org/"]
    tail = (" .\n Part of the KDE Frameworks 6 tier for the KDE Plasma Mobile flavor of the\n"
            " Xios desktop.")

    lines = ["Package: %s" % deb] + common
    lines.insert(4, "Section: %s" % section)
    if rt_deps:
        lines.append("Depends: %s" % ", ".join(rt_deps))
    lines.append("Description: %s" % ("%s for the Xios desktop" % pretty_name(e)))
    lines.append(" " + e["desc"])
    lines.append(tail)
    with open(os.path.join(BUILD_INFO, "%s.control" % deb), "w") as f:
        f.write("\n".join(lines) + "\n")

    if data_only:
        return
    dev_deps = ["%s (= @DEB_%s_V@)" % (deb, uv), "extra-cmake-modules", "qt6-base-dev"]
    for q in e.get("qt_deps", []):
        if q.startswith("qt6-"):
            qdev = "%s-dev" % q
            if qdev not in dev_deps:
                dev_deps.append(qdev)
    dev_deps += ["%s-dev" % BY_T[d]["deb"] for d in e["deps"] if not BY_T[d].get("data_only")]
    dev_deps += [BY_T[d]["deb"] for d in e["deps"] if BY_T[d].get("data_only")]
    lines = ["Package: %s-dev" % deb] + common
    lines.insert(4, "Section: Development")
    lines.append("Depends: %s" % ", ".join(dev_deps))
    lines.append("Description: Development files for %s" % pretty_name(e))
    lines.append(" Headers and CMake package files for %s. Needed to cross-build the" % pretty_name(e))
    lines.append(" KDE components that depend on it.")
    with open(os.path.join(BUILD_INFO, "%s-dev.control" % deb), "w") as f:
        f.write("\n".join(lines) + "\n")


def pretty_name(e):
    special = {"extra-cmake-modules": "Extra CMake Modules (ECM)",
               "plasma-wayland-protocols": "Plasma Wayland protocols",
               "breeze-icons": "Breeze icon theme",
               "kdecoration": "KDecoration2",
               "kglobalacceld": "kglobalacceld",
               "kwayland": "KWayland",
               "plasma-activities": "PlasmaActivities",
               "layer-shell-qt": "LayerShellQt",
               "kio": "KIO", "ki18n": "KI18n", "kcmutils": "KCMUtils",
               "kxmlgui": "KXmlGui", "ksvg": "KSvg",
               "kcoreaddons": "KCoreAddons", "kwidgetsaddons": "KWidgetsAddons",
               "kitemviews": "KItemViews", "kitemmodels": "KItemModels",
               "kdbusaddons": "KDBusAddons", "kglobalaccel": "KGlobalAccel",
               "kguiaddons": "KGuiAddons", "kwindowsystem": "KWindowSystem",
               "kidletime": "KIdleTime", "kcolorscheme": "KColorScheme",
               "kconfigwidgets": "KConfigWidgets", "kjobwidgets": "KJobWidgets",
               "kiconthemes": "KIconThemes", "ktextwidgets": "KTextWidgets",
               "karchive": "KArchive", "kcodecs": "KCodecs", "kconfig": "KConfig",
               "kauth": "KAuth", "kcrash": "KCrash", "kservice": "KService",
               "kpackage": "KPackage", "knotifications": "KNotifications",
               "kcompletion": "KCompletion", "kbookmarks": "KBookmarks",
               "attica": "Attica", "kdeclarative": "KDeclarative",
               "krunner": "KRunner", "kded": "KDED",
               "kstatusnotifieritem": "KStatusNotifierItem",
               "kunitconversion": "KUnitConversion", "kparts": "KParts",
               "knewstuff": "KNewStuff", "kwallet": "KWallet",
               "knotifyconfig": "KNotifyConfig",
               "qqc2-desktop-style": "QQC2DesktopStyle",
               "solid": "Solid", "sonnet": "Sonnet", "kirigami": "Kirigami"}
    if e["t"] in special:
        return special[e["t"]]
    return "K" + e["t"][1:].capitalize() if e["t"].startswith("k") else e["t"]


def main():
    for e in TABLE:
        emit_recipe(e)
        emit_controls(e)
    waves = topo_waves()
    print("emitted %d recipes into %s" % (len(TABLE), RECIPES))
    print("\nbuild waves (build-kf6.sh TARGETS default must match):")
    for i, w in enumerate(waves):
        print("  wave %d: %s" % (i, " ".join(w)))
    print("\nTARGETS=\"%s\"" % " ".join(t for w in waves for t in w))
    print("\nhost tooling (stage 1, native): %s" %
          " ".join(e["t"] for e in TABLE if e.get("host_tool")))


if __name__ == "__main__":
    main()
