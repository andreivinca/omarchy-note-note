#pragma once

#include <QColor>
#include <QMap>
#include <QPalette>
#include <QStringList>
#include <QVariantMap>
#include <optional>

namespace NoteNoteTheme {

struct Environment {
    QString desktop;
    QString configHome;
    QString stateHome;
    QString platformTheme;

    static Environment current();
    static QString detectDesktop(const QString &current, const QString &session, const QString &loginSession);
    QStringList omarchyDirectories() const;
};

struct Appearance {
    Qt::ColorScheme scheme = Qt::ColorScheme::Unknown;
    QColor accent;
};

struct Palette {
    QPalette qt;
    QColor urgent;
    QColor border;
    QColor scrim;
    QColor selectedBackground;
    QColor selectedText;
    QColor popupText;
    QString source;

    QVariantMap colors() const;
};

using Values = QMap<QString, QString>;

QByteArray readThemeFile(const QString &path);
Values parseValues(const QByteArray &bytes);
Palette fromQt(const QPalette &palette, const QString &source);
Palette fallback(Qt::ColorScheme scheme);
std::optional<Palette> omarchy(const Values &base, const Values &surfaces);
std::optional<Palette> kde(const Values &values);
Palette resolve(const Environment &environment, const Appearance &appearance,
                const QPalette &systemPalette, Qt::ColorScheme systemScheme);

}
