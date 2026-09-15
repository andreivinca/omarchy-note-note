#pragma once

#include "palette.h"
#include "portalsettings.h"

#include <QFileSystemWatcher>
#include <QObject>
#include <QTimer>

class DesktopTheme : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QVariantMap colors READ colors NOTIFY changed)
    Q_PROPERTY(QString source READ source NOTIFY changed)
    Q_PROPERTY(QString desktop READ desktop CONSTANT)
    Q_PROPERTY(bool dark READ dark NOTIFY changed)

public:
    explicit DesktopTheme(QObject *parent = nullptr);
    DesktopTheme(const NoteNoteTheme::Environment &environment, const QDBusConnection &bus, QObject *parent = nullptr);
    QVariantMap colors() const;
    QString source() const;
    QString desktop() const;
    bool dark() const;

signals:
    void changed();

protected:
    bool eventFilter(QObject *object, QEvent *event) override;

private:
    void reload();
    void watchFiles();
    NoteNoteTheme::Environment m_environment;
    NoteNoteTheme::PortalSettings m_portal;
    NoteNoteTheme::Palette m_palette;
    QFileSystemWatcher m_files;
    QTimer m_reload;
};
