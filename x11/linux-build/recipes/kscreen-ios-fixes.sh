#!/usr/bin/env bash
# kscreen-ios-fixes.sh - KScreen source trims and Apple guards for Xios.
set -euo pipefail

src=${1:?usage: kscreen-ios-fixes.sh <kscreen-source-dir>}

python3 - "$src/CMakeLists.txt" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    "find_package(Qt6 ${QT_MIN_VERSION} REQUIRED COMPONENTS Test Sensors)",
    "find_package(Qt6 ${QT_MIN_VERSION} REQUIRED COMPONENTS Sensors)",
)
text = text.replace("add_subdirectory(tests)", "# ios: tests are disabled in the cross build\n# add_subdirectory(tests)")
text = text.replace("include(KDEGitCommitHooks)", "# ios: source tarball build, no git hooks\n#include(KDEGitCommitHooks)")
text = text.replace("kde_configure_git_pre_commit_hook(CHECKS CLANG_FORMAT)", "# ios: no git hook in cross build")
text = text.replace("ki18n_install(po)", "# ios-bringup-no-linguist: ki18n_install(po)")
path.write_text(text)
PY

python3 - "$src/osd/osd.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
if "#if defined(HAVE_X11) && HAVE_X11\n#include <KX11Extras>\n#endif\n" not in text:
    text = text.replace("#include <KX11Extras>\n", "#if defined(HAVE_X11) && HAVE_X11\n#include <KX11Extras>\n#endif\n")
old = """    if (KWindowSystem::isPlatformWayland()) {
        auto layerWindow = LayerShellQt::Window::get(m_osdActionSelector.get());
        layerWindow->setScope(QStringLiteral("on-screen-display"));
        layerWindow->setLayer(LayerShellQt::Window::LayerOverlay);
        layerWindow->setAnchors({});
        layerWindow->setKeyboardInteractivity(LayerShellQt::Window::KeyboardInteractivityOnDemand);
        m_osdActionSelector->setScreen(screen);
    } else {
        auto newGeometry = m_osdActionSelector->geometry();
        newGeometry.moveCenter(screen->geometry().center());
        m_osdActionSelector->setGeometry(newGeometry);
        KX11Extras::setState(m_osdActionSelector->winId(), NET::SkipPager | NET::SkipSwitcher | NET::SkipTaskbar);
        KX11Extras::setType(m_osdActionSelector->winId(), NET::OnScreenDisplay);
        m_osdActionSelector->requestActivate();
    }
"""
new = """    if (KWindowSystem::isPlatformWayland()) {
        auto layerWindow = LayerShellQt::Window::get(m_osdActionSelector.get());
        layerWindow->setScope(QStringLiteral("on-screen-display"));
        layerWindow->setLayer(LayerShellQt::Window::LayerOverlay);
        layerWindow->setAnchors({});
        layerWindow->setKeyboardInteractivity(LayerShellQt::Window::KeyboardInteractivityOnDemand);
        m_osdActionSelector->setScreen(screen);
    }
#if defined(HAVE_X11) && HAVE_X11
    else {
        auto newGeometry = m_osdActionSelector->geometry();
        newGeometry.moveCenter(screen->geometry().center());
        m_osdActionSelector->setGeometry(newGeometry);
        KX11Extras::setState(m_osdActionSelector->winId(), NET::SkipPager | NET::SkipSwitcher | NET::SkipTaskbar);
        KX11Extras::setType(m_osdActionSelector->winId(), NET::OnScreenDisplay);
        m_osdActionSelector->requestActivate();
    }
#endif
"""
if old not in text:
    if "#if defined(HAVE_X11) && HAVE_X11\n    else {" not in text:
        raise SystemExit("KScreen OSD platform block not found")
else:
    text = text.replace(old, new)
path.write_text(text)
PY
