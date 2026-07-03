#!/usr/bin/env bash
set -euo pipefail

src=${1:?usage: kactivitymanagerd-ios-fixes.sh <source-dir>}

# The virtual desktop switch plugin includes KX11Extras even though its runtime
# has a non-X11 DBus branch. Drop it for the iOS/Wayland bring-up.
sed -i '/^[[:space:]]*add_subdirectory[[:space:]]*(virtualdesktopswitch)/s/^/# ios-bringup-no-x11: /' \
  "$src/src/service/plugins/CMakeLists.txt"

# The Apple cross compiler is invoked with an iPhoneOS sysroot, so it does not
# search Debian's /usr/include for host-only header dependencies like Boost.
if ! grep -q 'ios-bringup-host-boost' "$src/src/CMakeLists.txt"; then
  sed -i '/include_directories (${Boost_INCLUDE_DIRS})/a add_compile_options(-isystem /work/Procursus/build_tools/boost-host-include) # ios-bringup-host-boost' \
    "$src/src/CMakeLists.txt"
fi

# The resource module can still accept explicit resource events without X11
# focus tracking. Guard the KX11Extras-only auto focus hooks for iOS.
python3 - "$src/src/service/Resources.cpp" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("#include <KX11Extras>\n", "#ifndef Q_OS_IOS\n#include <KX11Extras>\n#endif\n")
text = text.replace(
"""    connect(KX11Extras::self(), &KX11Extras::windowRemoved, d.operator->(), &Resources::Private::windowClosed);
    connect(KX11Extras::self(), &KX11Extras::activeWindowChanged, d.operator->(), &Resources::Private::activeWindowChanged);
""",
"""#ifndef Q_OS_IOS
    connect(KX11Extras::self(), &KX11Extras::windowRemoved, d.operator->(), &Resources::Private::windowClosed);
    connect(KX11Extras::self(), &KX11Extras::activeWindowChanged, d.operator->(), &Resources::Private::activeWindowChanged);
#endif
""")
path.write_text(text)
PY

# KIO's kdirnotify.h is a generated/private header in this build, not an
# installed KF6KIOCore public header. ResourceLinking only needs the static DBus
# signal emitters, so provide the tiny emitter locally.
python3 - "$src/src/service/plugins/sqlite/ResourceLinking.cpp" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("#include <QDBusConnection>\n", "#include <QDBusConnection>\n#include <QDBusMessage>\n")
text = text.replace("#include <QSqlQuery>\n", "#include <QSqlQuery>\n#include <QUrl>\n#include <QVariant>\n")
text = text.replace("#include <kdirnotify.h>\n", "")

marker = '#include "resourcelinkingadaptor.h"\n'
shim = r'''

namespace
{
void emitKDirNotifySignal(const QString &signalName, const QVariantList &args)
{
    QDBusMessage message = QDBusMessage::createSignal(QStringLiteral("/"), QStringLiteral("org.kde.KDirNotify"), signalName);
    message.setArguments(args);
    QDBusConnection::sessionBus().send(message);
}
}

namespace org
{
namespace kde
{
struct KDirNotify {
    static void emitFilesAdded(const QUrl &directory)
    {
        emitKDirNotifySignal(QStringLiteral("FilesAdded"), QVariantList{QVariant(directory.toString())});
    }

    static void emitFilesRemoved(const QList<QUrl> &fileList)
    {
        emitKDirNotifySignal(QStringLiteral("FilesRemoved"), QVariantList{QVariant(QUrl::toStringList(fileList))});
    }
};
}
}
'''

if shim.strip() not in text:
    text = text.replace(marker, marker + shim)

path.write_text(text)
PY
