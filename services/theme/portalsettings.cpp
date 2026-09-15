#include "portalsettings.h"

#include <QDBusArgument>
#include <QDBusMessage>
#include <QDBusMetaType>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QTimer>
#include <cmath>

namespace NoteNoteTheme {
namespace {

const QString service = QStringLiteral("org.freedesktop.portal.Desktop");
const QString path = QStringLiteral("/org/freedesktop/portal/desktop");
const QString interface = QStringLiteral("org.freedesktop.portal.Settings");
const QString appearanceNamespace = QStringLiteral("org.freedesktop.appearance");

QVariant unpack(QVariant value)
{
    if (value.metaType() == QMetaType::fromType<QDBusVariant>()) {
        value = value.value<QDBusVariant>().variant();
    }
    return value;
}

}

PortalSettings::PortalSettings(const QDBusConnection &bus, QObject *parent)
    : QObject(parent), m_bus(bus), m_service(service, bus, QDBusServiceWatcher::WatchForOwnerChange)
{
    qDBusRegisterMetaType<PortalValues>();
    if (!bus.isConnected()) {
        return;
    }
    m_bus.connect(service, path, interface, QStringLiteral("SettingChanged"), this,
                  SLOT(settingChanged(QString,QString,QDBusVariant)));
    connect(&m_service, &QDBusServiceWatcher::serviceOwnerChanged, this,
            [this](const QString &, const QString &, const QString &owner) {
        ++m_generation;
        publish({});
        if (!owner.isEmpty()) {
            read();
        }
    });
    QTimer::singleShot(0, this, &PortalSettings::read);
}

Appearance PortalSettings::appearance() const
{
    return m_appearance;
}

QColor PortalSettings::decodeAccent(const QVariant &value)
{
    const QVariant raw = unpack(value);
    if (raw.metaType() != QMetaType::fromType<QDBusArgument>()) {
        return {};
    }
    const auto argument = raw.value<QDBusArgument>();
    if (argument.currentSignature() != "(ddd)") {
        return {};
    }
    double red = 0;
    double green = 0;
    double blue = 0;
    argument.beginStructure();
    argument >> red >> green >> blue;
    argument.endStructure();
    for (const double channel : {red, green, blue}) {
        if (!std::isfinite(channel) || channel < 0 || channel > 1) {
            return {};
        }
    }
    return QColor::fromRgbF(red, green, blue);
}

void PortalSettings::read()
{
    const quint64 generation = ++m_generation;
    const quint64 revision = m_revision;
    auto request = QDBusMessage::createMethodCall(service, path, interface, QStringLiteral("ReadAll"));
    request << QStringList{appearanceNamespace};
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(request, 2000), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, generation, revision](QDBusPendingCallWatcher *call) {
        const QDBusPendingReply<PortalValues> reply = *call;
        call->deleteLater();
        if (generation != m_generation || reply.isError()) {
            return;
        }
        // A change signal may arrive while the initial snapshot is in flight.
        // Re-read rather than overwriting the newer state with an old reply.
        if (revision != m_revision) {
            read();
            return;
        }
        publish(reply.value().value(appearanceNamespace));
    });
}

void PortalSettings::publish(const QVariantMap &settings)
{
    m_settings = settings;
    Appearance next;
    const QVariant schemeValue = unpack(settings.value(QStringLiteral("color-scheme")));
    if (schemeValue.metaType() == QMetaType::fromType<uint>()) {
        const uint scheme = schemeValue.toUInt();
        if (scheme == 1) {
            next.scheme = Qt::ColorScheme::Dark;
        } else if (scheme == 2) {
            next.scheme = Qt::ColorScheme::Light;
        }
    }
    next.accent = decodeAccent(settings.value(QStringLiteral("accent-color")));
    if (next.scheme != m_appearance.scheme || next.accent != m_appearance.accent) {
        m_appearance = next;
        emit changed();
    }
}

void PortalSettings::settingChanged(const QString &nameSpace, const QString &key, const QDBusVariant &value)
{
    if (nameSpace != appearanceNamespace || (key != "color-scheme" && key != "accent-color")) {
        return;
    }
    ++m_revision;
    auto settings = m_settings;
    settings.insert(key, value.variant());
    publish(settings);
}

}
