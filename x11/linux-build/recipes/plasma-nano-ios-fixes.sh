#!/usr/bin/env bash
# plasma-nano-ios-fixes.sh — source trims for first-light Plasma Nano on iOS.
set -euo pipefail

src=${1:?usage: plasma-nano-ios-fixes.sh <plasma-nano-source-dir>}

perl -0pi -e 's/#include <KX11Extras>\n/#if HAVE_X11\n#include <KX11Extras>\n#endif\n/' \
  "$src/components/fullscreenoverlay.cpp"
perl -0pi -e 's/        if \(KWindowSystem::isPlatformX11\(\)\) \{\n            KX11Extras::setState\(winId\(\), NET::SkipTaskbar \| NET::SkipPager\);\n        \} else \{\n            if \(m_plasmaShellSurface\) \{\n                m_plasmaShellSurface->setSkipTaskbar\(true\);\n                m_plasmaShellSurface->setSkipSwitcher\(true\);\n            \}\n        \}/#if HAVE_X11\n        if (KWindowSystem::isPlatformX11()) {\n            KX11Extras::setState(winId(), NET::SkipTaskbar | NET::SkipPager);\n        } else\n#endif\n        {\n            if (m_plasmaShellSurface) {\n                m_plasmaShellSurface->setSkipTaskbar(true);\n                m_plasmaShellSurface->setSkipSwitcher(true);\n            }\n        }/g' \
  "$src/components/fullscreenoverlay.cpp"

sed -i '/^[[:space:]]*ki18n_install(po)/s/^/# ios-firstlight-skip: /' "$src/CMakeLists.txt"
