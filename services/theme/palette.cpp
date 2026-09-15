#include "palette.h"

#include <QDir>
#include <QFile>
#include <QRegularExpression>
#include <QStringDecoder>
#include <cmath>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace NoteNoteTheme {
namespace {

QString themeDirectory(const char *variable, const char *hostVariable, const QString &fallback)
{
    // Flatpak redirects application storage into ~/.var/app. Desktop theme
    // files still belong to the host's XDG directories, granted read-only
    // by the manifest. This does not change application or account storage.
    const QString value = qEnvironmentVariable(qEnvironmentVariableIsEmpty("FLATPAK_ID") ? variable : hostVariable);
    return QDir::isAbsolutePath(value) ? value : QDir::homePath() + fallback;
}

QColor alpha(QColor color, qreal value)
{
    color.setAlphaF(qBound(0.0, value, 1.0));
    return color;
}

QColor blend(const QColor &background, const QColor &foreground, qreal amount)
{
    return QColor::fromRgbF(background.redF() * (1 - amount) + foreground.redF() * amount,
        background.greenF() * (1 - amount) + foreground.greenF() * amount,
        background.blueF() * (1 - amount) + foreground.blueF() * amount);
}

QColor selectionText(const QColor &background)
{
    // Relative luminance selects readable ink for arbitrary desktop accents.
    const auto linear = [](qreal value) {
        return value <= 0.04045 ? value / 12.92 : std::pow((value + 0.055) / 1.055, 2.4);
    };
    const qreal luminance = 0.2126 * linear(background.redF()) + 0.7152 * linear(background.greenF())
        + 0.0722 * linear(background.blueF());
    return QColor(luminance > 0.179 ? Qt::black : Qt::white);
}

QPalette basePalette(const QColor &background, const QColor &foreground, const QColor &accent)
{
    QPalette palette;
    palette.setColor(QPalette::Window, background);
    palette.setColor(QPalette::WindowText, foreground);
    palette.setColor(QPalette::Base, background);
    palette.setColor(QPalette::AlternateBase, blend(background, foreground, 0.04));
    palette.setColor(QPalette::Text, foreground);
    palette.setColor(QPalette::Button, blend(background, foreground, 0.06));
    palette.setColor(QPalette::ButtonText, foreground);
    palette.setColor(QPalette::Highlight, accent);
    palette.setColor(QPalette::HighlightedText, selectionText(accent));
    palette.setColor(QPalette::Accent, accent);
    palette.setColor(QPalette::Link, accent);
    palette.setColor(QPalette::LinkVisited, accent);
    palette.setColor(QPalette::ToolTipBase, background);
    palette.setColor(QPalette::ToolTipText, foreground);
    palette.setColor(QPalette::Light, blend(background, foreground, 0.2));
    palette.setColor(QPalette::Midlight, blend(background, foreground, 0.15));
    palette.setColor(QPalette::Mid, blend(background, foreground, 0.1));
    palette.setColor(QPalette::Dark, background.darker(130));
    palette.setColor(QPalette::Shadow, background.darker(160));
    for (const auto role : {QPalette::WindowText, QPalette::Text, QPalette::ButtonText}) {
        palette.setColor(QPalette::Disabled, role, blend(background, foreground, 0.45));
    }
    palette.setColor(QPalette::PlaceholderText, blend(background, foreground, 0.6));
    return palette;
}

QColor tokenColor(QString value, const Values &roles, const QColor &fallback)
{
    // Omarchy color surfaces can reference another role or use a gradient.
    // Flat application surfaces use its first color stop, as the shell does.
    static const QRegularExpression space(QStringLiteral("\\s+"));
    static const QRegularExpression hypr(QStringLiteral("^rgba?\\(([0-9a-fA-F]{6}(?:[0-9a-fA-F]{2})?)\\)$"));
    for (int depth = 0; depth < 16; ++depth) {
        const QStringList stops = value.trimmed().split(space, Qt::SkipEmptyParts);
        value.clear();
        for (const QString &stop : stops) {
            if (!stop.endsWith(QStringLiteral("deg"))) {
                value = stop;
                break;
            }
        }
        if (roles.contains(value)) {
            value = roles.value(value);
            continue;
        }
        const auto match = hypr.match(value);
        if (match.hasMatch()) {
            const QString hex = match.captured(1);
            value = QStringLiteral("#") + (hex.size() == 8 ? hex.right(2) + hex.left(6) : hex);
        }
        const QColor color(value);
        return color.isValid() ? color : fallback;
    }
    return fallback;
}

QColor surface(const Values &values, const QString &key, const QColor &fallback, qreal opacity = 1)
{
    const QColor color = tokenColor(values.value(key), values, fallback);
    bool valid = false;
    const qreal configured = values.value(key + QStringLiteral("-alpha")).toDouble(&valid);
    return alpha(color, valid && std::isfinite(configured) ? configured : opacity);
}

QColor kdeColor(const QString &value)
{
    const QStringList components = value.split(',');
    if (components.size() != 3 && components.size() != 4) {
        return {};
    }
    int channels[4] = {0, 0, 0, 255};
    for (int i = 0; i < components.size(); ++i) {
        bool valid = false;
        channels[i] = components[i].trimmed().toInt(&valid);
        if (!valid || channels[i] < 0 || channels[i] > 255) {
            return {};
        }
    }
    return QColor(channels[0], channels[1], channels[2], channels[3]);
}

}

Environment Environment::current()
{
    return {detectDesktop(qEnvironmentVariable("XDG_CURRENT_DESKTOP"), qEnvironmentVariable("XDG_SESSION_DESKTOP"),
                          qEnvironmentVariable("DESKTOP_SESSION")),
        themeDirectory("XDG_CONFIG_HOME", "HOST_XDG_CONFIG_HOME", QStringLiteral("/.config")),
        themeDirectory("XDG_STATE_HOME", "HOST_XDG_STATE_HOME", QStringLiteral("/.local/state")),
        qEnvironmentVariable("QT_QPA_PLATFORMTHEME")};
}

QString Environment::detectDesktop(const QString &current, const QString &session, const QString &loginSession)
{
    // Current desktop wins over stale files or a login-session name inherited
    // from an environment where another desktop was installed previously.
    for (const QString &candidate : {current, session, loginSession}) {
        const QStringList names = candidate.toLower().split(':', Qt::SkipEmptyParts);
        if (names.contains(QStringLiteral("kde")) || names.contains(QStringLiteral("plasma"))) {
            return QStringLiteral("kde");
        }
        if (names.contains(QStringLiteral("gnome"))) {
            return QStringLiteral("gnome");
        }
        if (names.contains(QStringLiteral("omarchy"))) {
            return QStringLiteral("omarchy");
        }
        if (names.contains(QStringLiteral("hyprland"))) {
            return loginSession.compare(QStringLiteral("omarchy"), Qt::CaseInsensitive) == 0
                ? QStringLiteral("omarchy") : QStringLiteral("hyprland");
        }
    }
    return QStringLiteral("unknown");
}

QStringList Environment::omarchyDirectories() const
{
    return {stateHome + QStringLiteral("/omarchy/current/theme"), configHome + QStringLiteral("/omarchy/current/theme")};
}

QByteArray readThemeFile(const QString &path)
{
    // Read one bounded regular descriptor. Nonblocking open also rejects a
    // replaced FIFO without waiting. Theme-directory symlinks are supported.
    constexpr qint64 limit = 256 * 1024;
    const int descriptor = ::open(QFile::encodeName(path).constData(), O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (descriptor < 0) {
        return {};
    }
    struct stat info {};
    if (::fstat(descriptor, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size > limit) {
        ::close(descriptor);
        return {};
    }
    QFile file;
    if (!file.open(descriptor, QIODevice::ReadOnly, QFileDevice::AutoCloseHandle)) {
        ::close(descriptor);
        return {};
    }
    const QByteArray bytes = file.read(limit + 1);
    return bytes.size() <= limit ? bytes : QByteArray();
}

Values parseValues(const QByteArray &bytes)
{
    // Read scalar color keys, not arbitrary TOML/KConfig values. This matches
    // Omarchy's flat section/key theme format and KDE's serialized RGB roles.
    QStringDecoder decoder(QStringDecoder::Utf8);
    const QString text = decoder.decode(bytes);
    if (decoder.hasError()) {
        return {};
    }
    static const QRegularExpression section(QStringLiteral("^\\[([A-Za-z0-9_ :.-]+)\\]\\s*(?:#.*)?$"));
    static const QRegularExpression entry(QStringLiteral("^([A-Za-z0-9_-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^#;]*))\\s*(?:[#;].*)?$"));
    Values values;
    QString group;
    bool supportedGroup = true;
    for (const QString &raw : text.split('\n')) {
        const QString line = raw.trimmed();
        const auto heading = section.match(line);
        if (line.startsWith('[')) {
            supportedGroup = heading.hasMatch();
            group = supportedGroup ? heading.captured(1) + '.' : QString();
            continue;
        }
        const auto pair = entry.match(line);
        if (supportedGroup && pair.hasMatch()) {
            const QString value = pair.capturedStart(2) >= 0 ? pair.captured(2)
                : pair.capturedStart(3) >= 0 ? pair.captured(3) : pair.captured(4).trimmed();
            values.insert(group + pair.captured(1), value);
        }
    }
    return values;
}

Palette fromQt(const QPalette &palette, const QString &source)
{
    const QColor background = palette.color(QPalette::Window);
    const QColor foreground = palette.color(QPalette::WindowText);
    return {palette, QColor(QStringLiteral("#d34747")), alpha(foreground, 0.25), alpha(background, 0.5),
        palette.color(QPalette::Highlight), palette.color(QPalette::HighlightedText),
        palette.color(QPalette::ToolTipText), source};
}

Palette fallback(Qt::ColorScheme scheme)
{
    const bool dark = scheme == Qt::ColorScheme::Dark;
    return fromQt(basePalette(QColor(dark ? "#202228" : "#f4f5f7"), QColor(dark ? "#eceef4" : "#24262c"),
                             QColor(dark ? "#86a8ff" : "#3f6fd9")), QStringLiteral("builtin"));
}

QVariantMap Palette::colors() const
{
    return {{"background", qt.color(QPalette::Window)}, {"foreground", qt.color(QPalette::WindowText)},
        {"accent", qt.color(QPalette::Accent)}, {"urgent", urgent}, {"border", border}, {"scrim", scrim},
        {"selectedBackground", selectedBackground}, {"selectedText", selectedText}, {"popupText", popupText},
        {"base", qt.color(QPalette::Base)}, {"alternateBase", qt.color(QPalette::AlternateBase)},
        {"text", qt.color(QPalette::Text)},
        {"button", qt.color(QPalette::Button)}, {"buttonText", qt.color(QPalette::ButtonText)},
        {"highlight", qt.color(QPalette::Highlight)}, {"highlightedText", qt.color(QPalette::HighlightedText)},
        {"toolTipBase", qt.color(QPalette::ToolTipBase)}, {"toolTipText", qt.color(QPalette::ToolTipText)},
        {"link", qt.color(QPalette::Link)}, {"linkVisited", qt.color(QPalette::LinkVisited)},
        {"light", qt.color(QPalette::Light)}, {"midlight", qt.color(QPalette::Midlight)},
        {"mid", qt.color(QPalette::Mid)}, {"dark", qt.color(QPalette::Dark)}, {"shadow", qt.color(QPalette::Shadow)},
        {"disabledText", qt.color(QPalette::Disabled, QPalette::Text)},
        {"disabledWindowText", qt.color(QPalette::Disabled, QPalette::WindowText)},
        {"disabledButtonText", qt.color(QPalette::Disabled, QPalette::ButtonText)},
        {"placeholderText", qt.color(QPalette::PlaceholderText)}};
}

std::optional<Palette> omarchy(const Values &base, const Values &surfaces)
{
    const QColor background = tokenColor(base.value("background", base.value("color0")), base, {});
    const QColor foreground = tokenColor(base.value("foreground", base.value("color7")), base, {});
    if (!background.isValid() || !foreground.isValid()) {
        return std::nullopt;
    }
    const QColor accent = tokenColor(base.value("accent", base.value("color4")), base, foreground);
    const QColor urgent = tokenColor(base.value("red", base.value("color1")), base, QColor("#d34747"));
    Values roles = base;
    roles.insert("background", background.name());
    roles.insert("foreground", foreground.name());
    roles.insert("text", foreground.name());
    roles.insert("accent", accent.name());
    roles.insert("urgent", urgent.name());
    roles.insert("muted", base.value("muted", base.value("color8", foreground.name())));
    roles.insert(surfaces);
    const QColor window = surface(roles, "menu.background", background);
    const QColor ink = tokenColor(roles.value("menu.text"), roles, foreground);
    Palette result = fromQt(basePalette(window, ink, accent), QStringLiteral("omarchy"));
    result.urgent = urgent;
    result.border = surface(roles, "menu.border", foreground);
    result.scrim = surface(roles, "menu.scrim", background, 0.5);
    result.selectedBackground = surface(roles, "menu.selected-background", foreground, 0.08);
    result.selectedText = tokenColor(roles.value("menu.selected-text"), roles, accent);
    result.popupText = tokenColor(roles.value("popups.text"), roles, foreground);
    result.qt.setColor(QPalette::ToolTipBase, surface(roles, "tooltip.background", background));
    result.qt.setColor(QPalette::ToolTipText, tokenColor(roles.value("tooltip.text"), roles, foreground));
    return result;
}

std::optional<Palette> kde(const Values &values)
{
    const QColor background = kdeColor(values.value("Colors:Window.BackgroundNormal"));
    const QColor foreground = kdeColor(values.value("Colors:Window.ForegroundNormal"));
    const QColor accent = kdeColor(values.value("Colors:Selection.BackgroundNormal"));
    if (!background.isValid() || !foreground.isValid() || !accent.isValid()) {
        return std::nullopt;
    }
    Palette result = fromQt(basePalette(background, foreground, accent), QStringLiteral("kde"));
    const QMap<QString, QPalette::ColorRole> roles = {
        {"Colors:View.BackgroundNormal", QPalette::Base}, {"Colors:View.BackgroundAlternate", QPalette::AlternateBase},
        {"Colors:View.ForegroundNormal", QPalette::Text}, {"Colors:View.ForegroundLink", QPalette::Link},
        {"Colors:View.ForegroundVisited", QPalette::LinkVisited}, {"Colors:Button.BackgroundNormal", QPalette::Button},
        {"Colors:Button.ForegroundNormal", QPalette::ButtonText}, {"Colors:Selection.ForegroundNormal", QPalette::HighlightedText},
        {"Colors:Tooltip.BackgroundNormal", QPalette::ToolTipBase}, {"Colors:Tooltip.ForegroundNormal", QPalette::ToolTipText}};
    for (auto it = roles.cbegin(); it != roles.cend(); ++it) {
        const QColor color = kdeColor(values.value(it.key()));
        if (color.isValid()) {
            result.qt.setColor(it.value(), color);
        }
    }
    result.selectedText = result.qt.color(QPalette::HighlightedText);
    result.popupText = result.qt.color(QPalette::ToolTipText);
    const QColor urgent = kdeColor(values.value("Colors:View.ForegroundNegative"));
    if (urgent.isValid()) {
        result.urgent = urgent;
    }
    return result;
}

Palette resolve(const Environment &environment, const Appearance &appearance,
                const QPalette &systemPalette, Qt::ColorScheme systemScheme)
{
    if (environment.desktop == "omarchy" || environment.desktop == "hyprland") {
        for (const QString &directory : environment.omarchyDirectories()) {
            Values surfaces = parseValues(readThemeFile(directory + "/shell.toml"));
            surfaces.insert(parseValues(readThemeFile(environment.configHome + "/omarchy/shell.toml")));
            const auto palette = omarchy(parseValues(readThemeFile(directory + "/colors.toml")), surfaces);
            if (palette) {
                return *palette;
            }
        }
    }
    if (environment.desktop == "kde") {
        const auto palette = kde(parseValues(readThemeFile(environment.configHome + "/kdeglobals")));
        if (palette) {
            return *palette;
        }
    }
    const Qt::ColorScheme scheme = appearance.scheme != Qt::ColorScheme::Unknown ? appearance.scheme : systemScheme;
    const bool paletteDark = systemPalette.color(QPalette::Window).lightnessF() < 0.5;
    const bool schemeMatches = scheme == Qt::ColorScheme::Unknown || paletteDark == (scheme == Qt::ColorScheme::Dark);
    const bool qtIntegrated = environment.platformTheme != "generic"
        && (!environment.platformTheme.isEmpty() || systemScheme != Qt::ColorScheme::Unknown);
    Palette result = qtIntegrated && schemeMatches ? fromQt(systemPalette, QStringLiteral("qt")) : fallback(scheme);
    if (result.source == "builtin" && appearance.scheme != Qt::ColorScheme::Unknown) {
        result.source = QStringLiteral("portal");
    }
    if (appearance.accent.isValid()) {
        result.qt.setColor(QPalette::Accent, appearance.accent);
        result.qt.setColor(QPalette::Highlight, appearance.accent);
        result.qt.setColor(QPalette::HighlightedText, selectionText(appearance.accent));
        result.qt.setColor(QPalette::Link, appearance.accent);
        result.selectedBackground = appearance.accent;
        result.selectedText = result.qt.color(QPalette::HighlightedText);
        if (result.source == "builtin") {
            result.source = QStringLiteral("portal");
        }
    }
    return result;
}

}
