#!/usr/bin/env bash
# polkit-kde-agent-1-ios-fixes.sh — source trims for the Xios (rootless iOS) cross build.
#
# Audited against Plasma 6.1.5's polkit-kde-agent-1 tarball. The project is small and
# almost entirely portable; only one real iOS wall exists:
#
#   * policykitlistener.cpp includes <KX11Extras> and calls
#     KX11Extras::forceActiveWindow() in the non-Wayland branch. The published
#     kf6-windowsystem 6.3.0+ios1 is built X11-off and ships no KX11Extras header
#     (verified against the -dev deb), so the include alone breaks the build. Same
#     treatment libplasma/kscreen already got: guard the include and the call site
#     behind HAVE_X11 so the Wayland branch is the only live path.
#
# Everything else is cross-build hygiene shared with kscreen.mk / milou.mk: no git
# hooks, no target-side linguist install.
#
# NOT touched (deliberate): the sys/prctl.h / sys/procctl.h ptrace-disable probes are
# already check_include_file/check_symbol_exists driven, so on iOS they simply come
# back false and config.h gets HAVE_PR_SET_DUMPABLE=0. The plasma-polkit-agent.service
# systemd unit is just an installed data file. PolkitQt1::UnixSessionSubject in
# main.cpp is a RUNTIME problem (no logind session, no polkitd), not a build problem,
# and stubbing it would be a behavior decision — see polkit-kde-agent-1.mk.
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
