#include "desktoptheme.h"

#include <QDir>
#include <QEvent>
#include <QFileInfo>
#include <QGuiApplication>
#include <QSet>
#include <QStyleHints>

DesktopTheme::DesktopTheme(QObject *parent)
    : DesktopTheme(NoteNoteTheme::Environment::current(), QDBusConnection::sessionBus(), parent)
{
}

DesktopTheme::DesktopTheme(const NoteNoteTheme::Environment &environment, const QDBusConnection &bus, QObject *parent)
    : QObject(parent), m_environment(environment), m_portal(bus)
{
    m_reload.setSingleShot(true);
    m_reload.setInterval(75);
    connect(&m_reload, &QTimer::timeout, this, &DesktopTheme::reload);
    connect(&m_files, &QFileSystemWatcher::fileChanged, this, [this]() {
        m_reload.start();
    });
    connect(&m_files, &QFileSystemWatcher::directoryChanged, this, [this]() {
        m_reload.start();
    });
    connect(&m_portal, &NoteNoteTheme::PortalSettings::changed, this, [this]() {
        m_reload.start();
    });
    connect(QGuiApplication::styleHints(), &QStyleHints::colorSchemeChanged, this, [this]() {
        m_reload.start();
    });
    qGuiApp->installEventFilter(this);
    reload();
}

QVariantMap DesktopTheme::colors() const
{
    return m_palette.colors();
}

QString DesktopTheme::source() const
{
    return m_palette.source;
}

QString DesktopTheme::desktop() const
{
    return m_environment.desktop;
}

bool DesktopTheme::dark() const
{
    return m_palette.qt.color(QPalette::Window).lightnessF() < 0.5;
}

bool DesktopTheme::eventFilter(QObject *object, QEvent *event)
{
    if (object == qGuiApp && event->type() == QEvent::ApplicationPaletteChange) {
        m_reload.start();
    }
    return QObject::eventFilter(object, event);
}

void DesktopTheme::reload()
{
    watchFiles();
    const auto next = NoteNoteTheme::resolve(m_environment, m_portal.appearance(), QGuiApplication::palette(),
                                           QGuiApplication::styleHints()->colorScheme());
    const bool different = next.source != m_palette.source || next.colors() != m_palette.colors();
    m_palette = next;
    if (different) {
        emit changed();
    }
}

void DesktopTheme::watchFiles()
{
    QStringList paths;
    if (m_environment.desktop == "omarchy" || m_environment.desktop == "hyprland") {
        for (const QString &directory : m_environment.omarchyDirectories()) {
            paths << directory + "/colors.toml" << directory + "/shell.toml";
        }
        paths << m_environment.configHome + "/omarchy/shell.toml";
    } else if (m_environment.desktop == "kde") {
        paths << m_environment.configHome + "/kdeglobals";
    }
    QSet<QString> wanted;
    for (const QString &path : paths) {
        if (QFileInfo::exists(path)) {
            wanted.insert(path);
        }
        // Watch parents as well: theme switches and editors replace files or
        // symlink targets atomically. Re-arm removed file watches on reload.
        QDir parent = QFileInfo(path).dir();
        bool reachedRoot = false;
        while (true) {
            reachedRoot = reachedRoot || parent.absolutePath() == m_environment.configHome
                || parent.absolutePath() == m_environment.stateHome;
            if (parent.exists()) {
                wanted.insert(parent.absolutePath());
                if (reachedRoot) {
                    break;
                }
            }
            const QDir ancestor = QFileInfo(parent.absolutePath()).dir();
            if (ancestor.absolutePath() == parent.absolutePath()) {
                break;
            }
            parent = ancestor;
        }
    }
    const QStringList current = m_files.files() + m_files.directories();
    // Re-arm even unchanged path names: a theme symlink can now point to a
    // different inode while the old target still exists.
    if (!current.isEmpty()) {
        m_files.removePaths(current);
    }
    if (!wanted.isEmpty()) {
        m_files.addPaths(wanted.values());
    }
}
