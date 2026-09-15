#pragma once

#include "palette.h"

#include <QDBusConnection>
#include <QDBusServiceWatcher>
#include <QDBusVariant>
#include <QObject>

namespace NoteNoteTheme {

using PortalValues = QMap<QString, QVariantMap>;

class PortalSettings : public QObject
{
    Q_OBJECT

public:
    explicit PortalSettings(const QDBusConnection &bus, QObject *parent = nullptr);
    Appearance appearance() const;
    static QColor decodeAccent(const QVariant &value);

signals:
    void changed();

private slots:
    void settingChanged(const QString &nameSpace, const QString &key, const QDBusVariant &value);

private:
    void read();
    void publish(const QVariantMap &settings);
    QDBusConnection m_bus;
    QDBusServiceWatcher m_service;
    QVariantMap m_settings;
    Appearance m_appearance;
    quint64 m_generation = 0;
    quint64 m_revision = 0;
};

}

Q_DECLARE_METATYPE(NoteNoteTheme::PortalValues)
