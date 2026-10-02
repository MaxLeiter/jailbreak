"""Drop-in for pathlib.Path in the *-ios-fixes.sh python hunks (used by the Plasma 6.7 re-port).

A hunk whose target file no longer exists upstream (Plasma 6.7 removed/moved a lot) must not abort the whole fix
script: reading a missing file yields '' (so every replace/regex is a harmless no-op) and writing '' back to a missing
file is skipped. Every such skip is logged as SKIP-MISSING so the list of moved files is visible in the build log."""
import pathlib
import sys

_Base = type(pathlib.Path())


class Path(_Base):
    def read_text(self, *a, **k):
        if not self.exists():
            print(f"SKIP-MISSING {self}", file=sys.stderr)
            return ""
        return super().read_text(*a, **k)

    def write_text(self, data, *a, **k):
        if not self.exists() and data == "":
            return 0
        return super().write_text(data, *a, **k)


def todo(msg):
    """Replacement for `raise SystemExit(msg)` in port hunks whose anchors moved: log PORT-TODO and keep going, so one
    pass lists every hunk that still needs a 6.7 port (the compile loop then shows which of them matter)."""
    print(f"PORT-TODO {msg}", file=sys.stderr)


# ---- X11 guarding (shared by the plasma-workspace / plasma-desktop fix scripts) -------------------------------------
# KWindowSystem is built WITHOUT_X11 here, so KX11Extras / netwm / KStartupInfo / Xlib headers do not exist. Upstream
# calls them only behind KWindowSystem::isPlatformX11() (false at runtime), so compiling the calls out is exact.
# HAVE_X11 comes from config-X11.h (0 on iOS); an undefined HAVE_X11 also evaluates to 0.
import re as _re

_X11_INCLUDE = _re.compile(
    r'^#include [<"](?:KX11Extras|NETWM|netwm\.h|fixx11h\.h|KStartupInfo|X11/[A-Za-z0-9_/]+\.h|private/qtx11extras_p\.h|QX11Info)[>"]\s*$',
    _re.M)
_X11_STMT_START = _re.compile(r'^\s*(?:KX11Extras::|KStartupInfo::|NETRootInfo\b|NETWinInfo\b|XChangeProperty\b|XSetClassHint\b|XClassHint\b)')


def guard_x11_tree(root, subdirs=("",)):
    """guard_x11 over every C++ source/header below root that mentions an X11-only API."""
    total = 0
    root = pathlib.Path(root)
    for sub in subdirs:
        for f in sorted((root / sub).rglob("*")):
            if f.suffix in (".cpp", ".cc", ".h", ".hpp", ".mm") and "/build/" not in str(f):
                try:
                    t = f.read_text()
                except (UnicodeDecodeError, OSError):
                    continue
                if "KX11Extras" in t or "KStartupInfo" in t or "NETRootInfo" in t or "NETWinInfo" in t:
                    total += guard_x11(f)
    return total


def guard_x11(path, label=""):
    """Wrap X11-only includes and whole X11-only statements in `#if HAVE_X11`. Idempotent. Returns the number of edits."""
    p = Path(path)
    text = p.read_text()
    if not text or "xios-x11-guarded" in text:
        return 0
    n = 0

    def inc(m):
        nonlocal n
        n += 1
        if "KX11Extras" in m.group(0):
            return "#include <KWindowSystem> // xios: KX11Extras is X11-only; KWindowSystem stays"
        return "#if defined(HAVE_X11) && HAVE_X11\n" + m.group(0) + "\n#endif"

    text = _X11_INCLUDE.sub(inc, text)

    lines = text.split("\n")
    out = []
    i = 0
    in_guard = 0
    while i < len(lines):
        ln = lines[i]
        s = ln.strip()
        if s.startswith("#if") and "HAVE_X11" in s and "!" not in s:
            in_guard += 1
        elif s.startswith("#if"):
            if in_guard:
                in_guard += 1
        elif s.startswith("#endif") and in_guard:
            in_guard -= 1
        if not in_guard and _X11_STMT_START.match(ln):
            j, depth = i, 0
            while j < len(lines):
                depth += lines[j].count("(") - lines[j].count(")")
                if depth <= 0 and lines[j].rstrip().endswith(";"):
                    break
                j += 1
            out.append("#if defined(HAVE_X11) && HAVE_X11")
            out.extend(lines[i:j + 1])
            out.append("#endif")
            n += 1
            i = j + 1
            continue
        out.append(ln)
        i += 1
    text = "\n".join(out)
    if n:
        text += "\n// xios-x11-guarded\n"
        p.write_text(text)
    return n
