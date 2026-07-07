#!/usr/bin/env bash
# systemsettings-ios-fixes.sh - source trims for System Settings on Xios.
set -euo pipefail

src=${1:?usage: systemsettings-ios-fixes.sh <systemsettings-source-dir>}

python3 - "$src/CMakeLists.txt" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("ki18n_install(po)", "# ios-bringup-no-linguist: ki18n_install(po)")
text = text.replace("    add_subdirectory(doc)", "    # ios-bringup-no-docs: add_subdirectory(doc)")
text = text.replace("    kdoctools_install(po)", "    # ios-bringup-no-docs: kdoctools_install(po)")
path.write_text(text)
PY

python3 - "$src/app/SettingsBase.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("#include <QDebug>\n", "")
text = text.replace('    qWarning() << "xios-systemsettings-menu-diagnostic" << "pluginModules" << pluginModules.size() << "categoryDirs" << dirs << "categoryFiles" << categories.size();\n', "")
text = text.replace('    qWarning() << "xios-systemsettings-menu-diagnostic" << "rootChildren" << rootModule->children().size();\n', "")
old = '    const QStringList dirs = QStandardPaths::locateAll(QStandardPaths::AppDataLocation, QStringLiteral("categories"), QStandardPaths::LocateDirectory);\n'
new = '''    QStringList dirs = QStandardPaths::locateAll(QStandardPaths::AppDataLocation, QStringLiteral("categories"), QStandardPaths::LocateDirectory);
    // On rootless iOS the app bundle identity can keep AppDataLocation from
    // resolving /var/jb/usr/share/systemsettings. Keep the upstream lookup, but
    // also search the generic data location where the package installs category
    // metadata.
    dirs << QStandardPaths::locateAll(QStandardPaths::GenericDataLocation, QStringLiteral("systemsettings/categories"), QStandardPaths::LocateDirectory);
    if (QFileInfo::exists(QStringLiteral("/var/jb/usr/share/systemsettings/categories"))) {
        dirs << QStringLiteral("/var/jb/usr/share/systemsettings/categories");
    }
    dirs.removeDuplicates();
'''
if "QStandardPaths::GenericDataLocation, QStringLiteral(\"systemsettings/categories\")" not in text:
    if old not in text:
        raise SystemExit("SettingsBase category lookup block not found")
    text = text.replace(old, new, 1)
elif '"/var/jb/usr/share/systemsettings/categories"' not in text:
    text = text.replace(
        '    dirs << QStandardPaths::locateAll(QStandardPaths::GenericDataLocation, QStringLiteral("systemsettings/categories"), QStandardPaths::LocateDirectory);\n'
        '    dirs.removeDuplicates();\n',
        '    dirs << QStandardPaths::locateAll(QStandardPaths::GenericDataLocation, QStringLiteral("systemsettings/categories"), QStandardPaths::LocateDirectory);\n'
        '    if (QFileInfo::exists(QStringLiteral("/var/jb/usr/share/systemsettings/categories"))) {\n'
        '        dirs << QStringLiteral("/var/jb/usr/share/systemsettings/categories");\n'
        '    }\n'
        '    dirs.removeDuplicates();\n',
        1,
    )
path.write_text(text)
PY
