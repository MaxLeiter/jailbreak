#!/usr/bin/env bash
# kf6-windowsystem ships X11-off with no KX11Extras header, so
# policykitlistener.cpp's KX11Extras include/call site must be guarded behind
# HAVE_X11 (same treatment as libplasma/kscreen).
#
# Left untouched deliberately: the prctl ptrace-disable probes just resolve
# false on iOS; the systemd unit is inert data; PolkitQt1::UnixSessionSubject
# is a runtime problem (no logind/polkitd), not a build one — see
# polkit-kde-agent-1.mk.
set -euo pipefail

src=${1:?usage: polkit-kde-agent-1-ios-fixes.sh <polkit-kde-agent-1-source-dir>}

python3 - "$src/CMakeLists.txt" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

if "# ios: source tarball build" not in text:
    text = text.replace(
        "include(KDEGitCommitHooks)",
        "# ios: source tarball build, no git hooks\n# include(KDEGitCommitHooks)",
    )
text = text.replace(
    "kde_configure_git_pre_commit_hook(CHECKS CLANG_FORMAT)",
    "# ios: no git hook in cross build",
)
text = text.replace("\nki18n_install(po)", "\n# ios-no-target-linguist: ki18n_install(po)")

path.write_text(text)
PY

python3 - "$src/policykitlistener.cpp" <<'PY'
import sys
from pathlib import Path

MARKER = "// ios: kf6-windowsystem is built X11-off"

path = Path(sys.argv[1])
text = path.read_text()

if MARKER not in text:
    old_include = "#include <KX11Extras>\n"
    new_include = (
        MARKER + " here and ships no KX11Extras.\n"
        "#if defined(HAVE_X11) && HAVE_X11\n"
        "#include <KX11Extras>\n"
        "#endif\n"
    )
    if old_include not in text:
        raise SystemExit("polkit-kde-agent-1-ios-fixes.sh: KX11Extras include not found")
    text = text.replace(old_include, new_include, 1)

    old_call = """    } else if (KWindowSystem::isPlatformX11()) {
        KX11Extras::forceActiveWindow(m_dialog->windowHandle()->winId());
    }
"""
    new_call = """    }
#if defined(HAVE_X11) && HAVE_X11
    else if (KWindowSystem::isPlatformX11()) {
        KX11Extras::forceActiveWindow(m_dialog->windowHandle()->winId());
    }
#endif
"""
    if old_call not in text:
        raise SystemExit("polkit-kde-agent-1-ios-fixes.sh: KX11Extras call site not found")
    text = text.replace(old_call, new_call, 1)

    path.write_text(text)
PY
