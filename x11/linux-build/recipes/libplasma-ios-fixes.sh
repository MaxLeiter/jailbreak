#!/usr/bin/env bash
# Plasma's top-level WITHOUT_X11 option skips finding/linking X11, but a few
# source files still include KX11Extras or call it behind runtime
# KWindowSystem::isPlatformX11() checks. On iOS that platform can never be X11,
# so guard those uses at compile time and leave the Wayland path intact.
set -euo pipefail

src=${1:?usage: libplasma-ios-fixes.sh <libplasma-source-dir>}

wrap_kx11_include() {
  local file=$1
  perl -0pi -e 's/#include <KX11Extras>/#if defined(HAVE_X11) \&\& HAVE_X11\n#include <KX11Extras>\n#endif/g' "$file"
}

add_config_include() {
  local file=$1
  local anchor=$2
  grep -Eq '#include ["<]config-plasma.h[">]' "$file" && return 0
  case "$anchor" in
    '#include "plasmawindow.h"')
      perl -0pi -e 's/(#include "plasmawindow.h"\n)/$1#include "config-plasma.h"\n/' "$file"
      ;;
    '#include "appletpopup.h"')
      perl -0pi -e 's/(#include "appletpopup.h"\n)/$1#include "config-plasma.h"\n/' "$file"
      ;;
  esac
}

theme_cpp="$src/src/plasma/private/theme_p.cpp"
wrap_kx11_include "$theme_cpp"
perl -0pi -e 's/    if \(KWindowSystem::isPlatformX11\(\)\) \{\n        compositingActive = KX11Extras::self\(\)->compositingActive\(\);\n    \}/#if HAVE_X11\n    if (KWindowSystem::isPlatformX11()) {\n        compositingActive = KX11Extras::self()->compositingActive();\n    }\n#endif/g' "$theme_cpp"
perl -0pi -e 's/    if \(KWindowSystem::isPlatformX11\(\)\) \{\n        connect\(KX11Extras::self\(\), &KX11Extras::compositingChanged, this, &ThemePrivate::compositingChanged\);\n        compositingChanged\(KX11Extras::compositingActive\(\)\);\n    \}/#if HAVE_X11\n    if (KWindowSystem::isPlatformX11()) {\n        connect(KX11Extras::self(), &KX11Extras::compositingChanged, this, &ThemePrivate::compositingChanged);\n        compositingChanged(KX11Extras::compositingActive());\n    }\n#endif/g' "$theme_cpp"

thumbnail_cpp="$src/src/declarativeimports/core/windowthumbnail.cpp"
wrap_kx11_include "$thumbnail_cpp"
perl -0pi -e 's/    if \(KWindowSystem::isPlatformX11\(\) && !KX11Extras::self\(\)->hasWId\(winId\)\) \{\n        \/\/ invalid Id, don'\''t updated\n        return;\n    \}/#if HAVE_X11\n    if (KWindowSystem::isPlatformX11() && !KX11Extras::self()->hasWId(winId)) {\n        \/\/ invalid Id, don'\''t updated\n        return;\n    }\n#endif/g' "$thumbnail_cpp"
perl -0pi -e 's/    if \(KWindowSystem::isPlatformX11\(\) && KX11Extras::self\(\)->hasWId\(m_winId\)\) \{\n        icon = KX11Extras::self\(\)->icon\(m_winId, boundingRect\(\)\.width\(\), boundingRect\(\)\.height\(\)\);\n    \} else \{\n        \/\/ fallback to plasma icon\n        icon = QIcon::fromTheme\(QStringLiteral\("plasma"\)\);\n    \}/#if HAVE_X11\n    if (KWindowSystem::isPlatformX11() && KX11Extras::self()->hasWId(m_winId)) {\n        icon = KX11Extras::self()->icon(m_winId, boundingRect().width(), boundingRect().height());\n    } else\n#endif\n    {\n        \/\/ fallback to plasma icon\n        icon = QIcon::fromTheme(QStringLiteral("plasma"));\n    }/g' "$thumbnail_cpp"

plasmawindow_cpp="$src/src/plasmaquick/plasmawindow.cpp"
add_config_include "$plasmawindow_cpp" '#include "plasmawindow.h"'
wrap_kx11_include "$plasmawindow_cpp"
perl -0pi -e 's/    if \(KWindowSystem::isPlatformX11\(\)\) \{\n        KX11Extras::setState\(winId\(\), NET::SkipTaskbar \| NET::SkipPager \| NET::SkipSwitcher\);\n    \}/#if HAVE_X11\n    if (KWindowSystem::isPlatformX11()) {\n        KX11Extras::setState(winId(), NET::SkipTaskbar | NET::SkipPager | NET::SkipSwitcher);\n    }\n#endif/g' "$plasmawindow_cpp"
perl -0pi -e 's/    if \(!KWindowSystem::isPlatformX11\(\) \|\| KX11Extras::compositingActive\(\)\) \{\n        q->setMask\(QRegion\(\)\);\n    \} else \{\n        q->setMask\(mask\);\n    \}/#if HAVE_X11\n    if (!KWindowSystem::isPlatformX11() || KX11Extras::compositingActive()) {\n        q->setMask(QRegion());\n    } else {\n        q->setMask(mask);\n    }\n#else\n    q->setMask(QRegion());\n#endif/g' "$plasmawindow_cpp"

appletpopup_cpp="$src/src/plasmaquick/appletpopup.cpp"
add_config_include "$appletpopup_cpp" '#include "appletpopup.h"'
wrap_kx11_include "$appletpopup_cpp"
perl -0pi -e 's/    if \(KWindowSystem::isPlatformX11\(\)\) \{\n        KX11Extras::setType\(winId\(\), NET::AppletPopup\);\n    \} else \{\n        PlasmaShellWaylandIntegration::get\(this\)->setRole\(QtWayland::org_kde_plasma_surface::role::role_appletpopup\);\n    \}/#if HAVE_X11\n    if (KWindowSystem::isPlatformX11()) {\n        KX11Extras::setType(winId(), NET::AppletPopup);\n    } else\n#endif\n    {\n        PlasmaShellWaylandIntegration::get(this)->setRole(QtWayland::org_kde_plasma_surface::role::role_appletpopup);\n    }/g' "$appletpopup_cpp"

dialog_cpp="$src/src/plasmaquick/dialog.cpp"
perl -0pi -e 's/#include <KWindowInfo>/#if HAVE_X11\n#include <KWindowInfo>\n#endif/g' "$dialog_cpp"
wrap_kx11_include "$dialog_cpp"
perl -0pi -e 's/#include <KWindowInfo>/#if defined(HAVE_X11) \&\& HAVE_X11\n#include <KWindowInfo>\n#endif/g' "$dialog_cpp"
perl -0pi -e 's/        if \(!KWindowSystem::isPlatformX11\(\) \|\| KX11Extras::compositingActive\(\)\) \{\n            if \(hasMask\) \{\n                hasMask = false;\n                q->setMask\(QRegion\(\)\);\n            \}\n        \} else \{\n            hasMask = true;\n            q->setMask\(dialogBackground->mask\(\)\);\n        \}/#if HAVE_X11\n        if (!KWindowSystem::isPlatformX11() || KX11Extras::compositingActive()) {\n            if (hasMask) {\n                hasMask = false;\n                q->setMask(QRegion());\n            }\n        } else {\n            hasMask = true;\n            q->setMask(dialogBackground->mask());\n        }\n#else\n        if (hasMask) {\n            hasMask = false;\n        }\n        q->setMask(QRegion());\n#endif/g' "$dialog_cpp"
perl -0pi -e 's/    if \(!wmType && type != Dialog::Normal && KWindowSystem::isPlatformX11\(\)\) \{\n        KX11Extras::setType\(q->winId\(\), static_cast<NET::WindowType>\(type\)\);\n    \}/#if HAVE_X11\n    if (!wmType && type != Dialog::Normal && KWindowSystem::isPlatformX11()) {\n        KX11Extras::setType(q->winId(), static_cast<NET::WindowType>(type));\n    }\n#endif/g' "$dialog_cpp"
perl -0pi -e 's/    if \(KWindowSystem::isPlatformX11\(\)\) \{\n        if \(type == Dialog::Dock \|\| type == Dialog::Notification \|\| type == Dialog::OnScreenDisplay \|\| type == Dialog::CriticalNotification\) \{\n            KX11Extras::setOnAllDesktops\(q->winId\(\), true\);\n        \} else \{\n            KX11Extras::setOnAllDesktops\(q->winId\(\), false\);\n        \}\n    \}/#if HAVE_X11\n    if (KWindowSystem::isPlatformX11()) {\n        if (type == Dialog::Dock || type == Dialog::Notification || type == Dialog::OnScreenDisplay || type == Dialog::CriticalNotification) {\n            KX11Extras::setOnAllDesktops(q->winId(), true);\n        } else {\n            KX11Extras::setOnAllDesktops(q->winId(), false);\n        }\n    }\n#endif/g' "$dialog_cpp"
perl -0pi -e 's/    if \(KWindowSystem::isPlatformX11\(\)\) \{\n        KX11Extras::setState\(winId\(\), NET::SkipTaskbar \| NET::SkipPager \| NET::SkipSwitcher\);\n    \}/#if HAVE_X11\n    if (KWindowSystem::isPlatformX11()) {\n        KX11Extras::setState(winId(), NET::SkipTaskbar | NET::SkipPager | NET::SkipSwitcher);\n    }\n#endif/g' "$dialog_cpp"
perl -0pi -e 's/    \/\/ if the item is in a dock or in a window that ignores WM we want to position the popups outside of the dock\n    const KWindowInfo winInfo\(item->window\(\)->winId\(\), NET::WMWindowType\);\n    const bool outsideParentWindow =\n        \(\(winInfo.windowType\(NET::AllTypesMask\) == NET::Dock\) \|\| \(item->window\(\)->flags\(\) & Qt::X11BypassWindowManagerHint\)\) && item->window\(\)->mask\(\)\.isNull\(\);/    \/\/ if the item is in a dock or in a window that ignores WM we want to position the popups outside of the dock\n#if HAVE_X11\n    const KWindowInfo winInfo(item->window()->winId(), NET::WMWindowType);\n    const bool outsideParentWindow =\n        ((winInfo.windowType(NET::AllTypesMask) == NET::Dock) || (item->window()->flags() & Qt::X11BypassWindowManagerHint)) && item->window()->mask().isNull();\n#else\n    const bool outsideParentWindow = false;\n#endif/g' "$dialog_cpp"
perl -0pi -e 's/    \/\/ if the item is in a dock or in a window that ignores WM we want to position the popups outside of the dock\n    const KWindowInfo winInfo\(item->window\(\)->winId\(\), NET::WMWindowType\);\n    const bool outsideParentWindow =\n        \(\(winInfo.windowType\(NET::AllTypesMask\) == NET::Dock\) \|\| \(item->window\(\)->flags\(\) & Qt::X11BypassWindowManagerHint\)\) && item->window\(\)->mask\(\).isNull\(\);/    \/\/ If the item is in an X11 dock or in a window that ignores WM we want to\n    \/\/ position popups outside of that dock. The iOS bring-up path is nested\n    \/\/ Wayland-only, so keep the X11 query compiled out when X11 is disabled.\n    bool outsideParentWindow = false;\n#if defined(HAVE_X11) \&\& HAVE_X11\n    const KWindowInfo winInfo(item->window()->winId(), NET::WMWindowType);\n    outsideParentWindow = ((winInfo.windowType(NET::AllTypesMask) == NET::Dock) || (item->window()->flags() & Qt::X11BypassWindowManagerHint))\n        && item->window()->mask().isNull();\n#endif/g' "$dialog_cpp"

for f in "$theme_cpp" "$thumbnail_cpp" "$plasmawindow_cpp" "$appletpopup_cpp" "$dialog_cpp"; do
  perl -0pi -e 's/#if HAVE_X11/#if defined(HAVE_X11) \&\& HAVE_X11/g' "$f"
done
