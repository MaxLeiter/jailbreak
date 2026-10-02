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
