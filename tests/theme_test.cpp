#include "../services/theme/desktoptheme.h"

#include <QDBusArgument>
#include <QDBusMetaType>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QSaveFile>
#include <QScopeGuard>
#include <QTemporaryDir>
#include <QtTest>
#include <cstdio>
#include <limits>
#include <sys/stat.h>

using namespace NoteNoteTheme;

struct PortalAccent {
    double red;
    double green;
    double blue;
};
Q_DECLARE_METATYPE(PortalAccent)

QDBusArgument &operator<<(QDBusArgument &argument, const PortalAccent &color)
{
    argument.beginStructure();
    argument << color.red << color.green << color.blue;
    argument.endStructure();
    return argument;
}

const QDBusArgument &operator>>(const QDBusArgument &argument, PortalAccent &color)
{
    argument.beginStructure();
    argument >> color.red >> color.green >> color.blue;
    argument.endStructure();
    return argument;
}

// Runs only on the private session bus created by CTest.
class TestPortal : public QObject
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.freedesktop.portal.Settings")
public:
    QVariantMap settings;
    int reads = 0;
    void change(const QString &key, const QVariant &value)
    {
        settings.insert(key, value);
        emit SettingChanged("org.freedesktop.appearance", key, QDBusVariant(value));
    }

public slots:
    NoteNoteTheme::PortalValues ReadAll(const QStringList &namespaces)
    {
        ++reads;
        if (!namespaces.contains("org.freedesktop.appearance")) {
            return {};
        }
        return {{"org.freedesktop.appearance", settings}};
    }

signals:
    void SettingChanged(const QString &nameSpace, const QString &key, const QDBusVariant &value);
};

class ThemeTest : public QObject
{
    Q_OBJECT
private:
    static void write(const QString &path, const QByteArray &bytes)
    {
        QVERIFY(QDir().mkpath(QFileInfo(path).absolutePath()));
        QSaveFile file(path);
        QVERIFY(file.open(QIODevice::WriteOnly));
        QCOMPARE(file.write(bytes), bytes.size());
        QVERIFY(file.commit());
    }

    static Environment environment(const QTemporaryDir &home, const QString &desktop = "omarchy")
    {
        return {desktop, home.path() + "/config", home.path() + "/state", "generic"};
    }

    static QByteArray omarchyColors(const QByteArray &background = "#102030")
    {
        return "background='" + background + "'\nforeground='#eeeeee'\naccent='#40a080'\nred='#e05050'\n";
    }

    static QByteArray kdeColors()
    {
        return "[Colors:Window]\nBackgroundNormal=20,30,40\nForegroundNormal=220,230,240\n"
               "[Colors:Window][Inactive]\nBackgroundNormal=255,0,0\n"
               "[Colors:Selection]\nBackgroundNormal=70,80,90\nForegroundNormal=250,251,252\n"
               "[Colors:View]\nBackgroundNormal=10,20,30\nForegroundLink=40,150,250\nForegroundNegative=240,40,30\n";
    }

private slots:
    void hostThemeDirectories()
    {
        const QList<QByteArray> names = {"FLATPAK_ID", "XDG_CONFIG_HOME", "XDG_STATE_HOME",
                                       "HOST_XDG_CONFIG_HOME", "HOST_XDG_STATE_HOME"};
        QMap<QByteArray, QByteArray> original;
        for (const auto &name : names) {
            original.insert(name, qgetenv(name.constData()));
        }
        const auto restore = qScopeGuard([original]() {
            for (auto it = original.cbegin(); it != original.cend(); ++it) {
                if (it.value().isNull()) {
                    qunsetenv(it.key().constData());
                } else {
                    qputenv(it.key().constData(), it.value());
                }
            }
        });
        qputenv("XDG_CONFIG_HOME", "/private/config");
        qputenv("XDG_STATE_HOME", "/private/state");
        qputenv("HOST_XDG_CONFIG_HOME", "/desktop/config");
        qputenv("HOST_XDG_STATE_HOME", "/desktop/state");
        qunsetenv("FLATPAK_ID");
        QCOMPARE(Environment::current().configHome, "/private/config");
        QCOMPARE(Environment::current().stateHome, "/private/state");
        qputenv("FLATPAK_ID", "io.github.andreivinca.note-note");
        QCOMPARE(Environment::current().configHome, "/desktop/config");
        QCOMPARE(Environment::current().stateHome, "/desktop/state");
        qunsetenv("HOST_XDG_CONFIG_HOME");
        qputenv("HOST_XDG_STATE_HOME", "relative-path");
        QCOMPARE(Environment::current().configHome, QDir::homePath() + "/.config");
        QCOMPARE(Environment::current().stateHome, QDir::homePath() + "/.local/state");
    }

    void desktopDetection()
    {
        QCOMPARE(Environment::detectDesktop("Hyprland", "Hyprland", "omarchy"), "omarchy");
        QCOMPARE(Environment::detectDesktop("Hyprland", "", ""), "hyprland");
        QCOMPARE(Environment::detectDesktop("ubuntu:GNOME", "Hyprland", "omarchy"), "gnome");
        QCOMPARE(Environment::detectDesktop("KDE", "", "omarchy"), "kde");
        QCOMPARE(Environment::detectDesktop("", "plasma", ""), "kde");
        QCOMPARE(Environment::detectDesktop("", "", ""), "unknown");
    }

    void omarchySurfaces()
    {
        const auto base = parseValues(omarchyColors());
        auto surfaces = parseValues("[hyprland]\nactive-border-foreground='rgba(abcdef33) rgba(ffffff22) 90deg'\n"
            "[menu]\nbackground='background'\ntext='foreground'\nborder='hyprland.active-border-foreground'\n"
            "border-alpha=0.4\nselected-background='foreground'\nselected-background-alpha=.08\n"
            "selected-text='accent'\n[popups]\ntext='#123456'\n");
        const auto palette = omarchy(base, surfaces);
        QVERIFY(palette.has_value());
        QCOMPARE(palette->qt.color(QPalette::Window), QColor("#102030"));
        QCOMPARE(palette->qt.color(QPalette::Accent), QColor("#40a080"));
        QCOMPARE(palette->border.name(), "#abcdef");
        QVERIFY(qAbs(palette->border.alphaF() - 0.4) < 0.001);
        QVERIFY(qAbs(palette->selectedBackground.alphaF() - 0.08) < 0.001);
        QCOMPARE(palette->popupText, QColor("#123456"));
        surfaces.insert("menu.text", "menu.selected-text");
        surfaces.insert("menu.selected-text", "menu.text");
        QCOMPARE(omarchy(base, surfaces)->qt.color(QPalette::WindowText), QColor("#eeeeee"));
        QVERIFY(!omarchy(parseValues("background='invalid'\nforeground='#ffffff'"), {}).has_value());
        QVERIFY(!omarchy({}, {}).has_value());
        QVERIFY(omarchy(parseValues("color0='#112233'\ncolor7='#aabbcc'\ncolor4='#445566'"), {}).has_value());
    }

    void kdeRoles()
    {
        const auto palette = kde(parseValues(kdeColors()));
        QVERIFY(palette.has_value());
        QCOMPARE(palette->qt.color(QPalette::Window), QColor(20, 30, 40));
        QCOMPARE(palette->qt.color(QPalette::Base), QColor(10, 20, 30));
        QCOMPARE(palette->qt.color(QPalette::Link), QColor(40, 150, 250));
        QCOMPARE(palette->selectedText, QColor(250, 251, 252));
        QCOMPARE(palette->urgent, QColor(240, 40, 30));
        auto invalid = parseValues(kdeColors());
        invalid.insert("Colors:Window.BackgroundNormal", "256,0,0");
        QVERIFY(!kde(invalid).has_value());
        QVERIFY(!kde(parseValues("[KFileDialog Settings]\nShow hidden files=true")).has_value());
    }

    void sourcePriorityAndFallback()
    {
        QTemporaryDir home;
        auto env = environment(home);
        write(env.omarchyDirectories().first() + "/colors.toml", omarchyColors());
        write(env.configHome + "/kdeglobals", kdeColors());
        write(env.configHome + "/omarchy/shell.toml", "[menu]\nbackground='#203040'\n");
        const QPalette native = fallback(Qt::ColorScheme::Light).qt;
        const Appearance dark{Qt::ColorScheme::Dark, QColor("#a02080")};
        QCOMPARE(resolve(env, dark, native, Qt::ColorScheme::Unknown).qt.color(QPalette::Window), QColor("#203040"));
        env.desktop = "kde";
        QCOMPARE(resolve(env, dark, native, Qt::ColorScheme::Unknown).source, "kde");
        env.desktop = "gnome";
        auto palette = resolve(env, dark, native, Qt::ColorScheme::Unknown);
        QCOMPARE(palette.source, "portal");
        QCOMPARE(palette.qt.color(QPalette::Window), QColor("#202228"));
        QCOMPARE(palette.qt.color(QPalette::Accent), dark.accent);
        QCOMPARE(palette.qt.color(QPalette::HighlightedText), QColor(Qt::white));
        env.platformTheme = "gtk3";
        QCOMPARE(resolve(env, {}, native, Qt::ColorScheme::Light).source, "qt");
        // A stale light Qt palette must not defeat a new dark preference.
        QCOMPARE(resolve(env, dark, native, Qt::ColorScheme::Light).source, "portal");
        env.platformTheme = "generic";
        QCOMPARE(resolve(env, {}, native, Qt::ColorScheme::Unknown).source, "builtin");
        QCOMPARE(resolve(env, {}, native, Qt::ColorScheme::Unknown).qt.color(QPalette::Window), QColor("#f4f5f7"));
        env.desktop = "hyprland";
        QCOMPARE(resolve(env, {}, native, Qt::ColorScheme::Unknown).source, "omarchy");
        QVERIFY(QFile::remove(env.omarchyDirectories().first() + "/colors.toml"));
        QCOMPARE(resolve(env, {}, native, Qt::ColorScheme::Unknown).source, "builtin");
        write(env.omarchyDirectories().last() + "/colors.toml", omarchyColors());
        QCOMPARE(resolve(env, {}, native, Qt::ColorScheme::Unknown).source, "omarchy");
    }

    void boundedFiles()
    {
        QTemporaryDir home;
        const QString path = home.filePath("theme");
        write(path, QByteArray(256 * 1024 + 1, 'a'));
        QVERIFY(readThemeFile(path).isEmpty());
        QVERIFY(QFile::remove(path));
        QCOMPARE(::mkfifo(QFile::encodeName(path).constData(), 0600), 0);
        QVERIFY(readThemeFile(path).isEmpty());
        QVERIFY(readThemeFile(home.path()).isEmpty());
        QVERIFY(parseValues(QByteArray("background='\xff'", 14)).isEmpty());
    }

    void liveOmarchyFiles()
    {
        QTemporaryDir home;
        const auto env = environment(home);
        DesktopTheme theme(env, QDBusConnection("no-theme-test-bus"));
        QCOMPARE(theme.source(), "builtin");
        const QString path = env.omarchyDirectories().first() + "/colors.toml";
        write(path, omarchyColors());
        QTRY_COMPARE(theme.source(), "omarchy");
        write(path, omarchyColors("#223344"));
        QTRY_COMPARE(theme.colors().value("background").value<QColor>(), QColor("#223344"));
        const QString overrides = env.configHome + "/omarchy/shell.toml";
        write(overrides, "[menu]\nbackground='#304050'\n");
        QTRY_COMPARE(theme.colors().value("background").value<QColor>(), QColor("#304050"));
        QVERIFY(QFile::remove(overrides));
        QTRY_COMPARE(theme.colors().value("background").value<QColor>(), QColor("#223344"));
        QVERIFY(QFile::remove(path));
        QTRY_COMPARE(theme.source(), "builtin");
        write(path, omarchyColors());
        QTRY_COMPARE(theme.source(), "omarchy");
    }

    void liveThemeSymlink()
    {
        QTemporaryDir home;
        const auto env = environment(home);
        const QString first = home.filePath("first");
        const QString second = home.filePath("second");
        write(first + "/colors.toml", omarchyColors());
        write(second + "/colors.toml", omarchyColors("#405060"));
        const QString link = env.omarchyDirectories().first();
        QVERIFY(QDir().mkpath(QFileInfo(link).absolutePath()));
        QVERIFY(QFile::link(first, link));
        DesktopTheme theme(env, QDBusConnection("no-theme-test-bus"));
        QCOMPARE(theme.source(), "omarchy");
        QVERIFY(QFile::link(second, link + "-next"));
        QCOMPARE(::rename(QFile::encodeName(link + "-next").constData(), QFile::encodeName(link).constData()), 0);
        QTRY_COMPARE(theme.colors().value("background").value<QColor>(), QColor("#405060"));
        write(second + "/colors.toml", omarchyColors("#506070"));
        QTRY_COMPARE(theme.colors().value("background").value<QColor>(), QColor("#506070"));
    }

    void liveKdeFiles()
    {
        QTemporaryDir home;
        const auto env = environment(home, "kde");
        write(env.configHome + "/kdeglobals", kdeColors());
        DesktopTheme theme(env, QDBusConnection("no-theme-test-bus"));
        QCOMPARE(theme.source(), "kde");
        write(env.configHome + "/kdeglobals", QByteArray(kdeColors()).replace("20,30,40", "40,50,60"));
        QTRY_COMPARE(theme.colors().value("background").value<QColor>(), QColor(40, 50, 60));
        write(env.configHome + "/kdeglobals", "[KFileDialog Settings]\nShow hidden files=true");
        QTRY_COMPARE(theme.source(), "builtin");
    }

    void livePortal()
    {
        qDBusRegisterMetaType<PortalAccent>();
        qDBusRegisterMetaType<PortalValues>();
        auto bus = QDBusConnection::sessionBus();
        QVERIFY(bus.isConnected());
        TestPortal portal;
        portal.settings = {{"color-scheme", 1u}, {"accent-color", QVariant::fromValue(PortalAccent{0.2, 0.4, 0.6})}};
        const QString service = "org.freedesktop.portal.Desktop";
        const QString path = "/org/freedesktop/portal/desktop";
        QVERIFY(bus.registerObject(path, &portal, QDBusConnection::ExportAllSlots | QDBusConnection::ExportAllSignals));
        QVERIFY(bus.registerService(service));
        QTemporaryDir home;
        DesktopTheme theme(environment(home, "gnome"), bus);
        QTRY_COMPARE(theme.source(), "portal");
        QVERIFY(theme.dark());
        QCOMPARE(theme.colors().value("accent").value<QColor>(), QColor::fromRgbF(0.2, 0.4, 0.6));
        portal.change("color-scheme", 2u);
        QTRY_VERIFY(!theme.dark());
        portal.change("accent-color", QVariant::fromValue(PortalAccent{0.9, 0.8, 0.1}));
        QTRY_COMPARE(theme.colors().value("accent").value<QColor>(), QColor::fromRgbF(0.9, 0.8, 0.1));
        QCOMPARE(theme.colors().value("highlightedText").value<QColor>(), QColor(Qt::black));
        portal.change("accent-color", QVariant::fromValue(PortalAccent{-1, 0, 0}));
        QTRY_COMPARE(theme.colors().value("accent").value<QColor>(), QColor("#3f6fd9"));
        portal.change("accent-color", QVariant::fromValue(PortalAccent{std::numeric_limits<double>::quiet_NaN(), 0, 0}));
        portal.change("color-scheme", 0u);
        QTRY_COMPARE(theme.source(), "builtin");
        portal.settings.insert("color-scheme", 1u);
        QVERIFY(bus.unregisterService(service));
        // Wait for owner loss before re-registering the portal.
        QTest::qWait(150);
        const int reads = portal.reads;
        QVERIFY(bus.registerService(service));
        QTRY_VERIFY(portal.reads > reads);
        QTRY_COMPARE(theme.source(), "portal");
        QVERIFY(theme.dark());
        QVERIFY(bus.unregisterService(service));
        QTRY_COMPARE(theme.source(), "builtin");
        bus.unregisterObject(path);
    }
};

QTEST_MAIN(ThemeTest)
#include "theme_test.moc"
