#include "runtime.h"

#include <QBuffer>
#include <QClipboard>
#include <QGuiApplication>
#include <QImage>
#include <QMimeData>

QString DesktopRuntime::env(const QString &name) const
{
    return qEnvironmentVariable(name.toUtf8().constData());
}

void DesktopRuntime::copyText(const QString &text)
{
    QGuiApplication::clipboard()->setText(text);
}

QVariantMap DesktopRuntime::clipboard(const QString &format) const
{
    constexpr qsizetype maxText = 4 * 1024 * 1024;
    constexpr qsizetype maxImage = 40 * 1024 * 1024;
    const QStringList types = {QStringLiteral("image/png"), QStringLiteral("image/jpeg"),
        QStringLiteral("image/gif"), QStringLiteral("image/bmp"), QStringLiteral("image/tiff")};
    const QMimeData *mime = QGuiApplication::clipboard()->mimeData();
    if (!mime) {
        return {};
    }
    if (format == QStringLiteral("types")) {
        bool hasImage = mime->hasImage();
        for (const QString &type : types) {
            hasImage = hasImage || mime->hasFormat(type);
        }
        return {{QStringLiteral("image"), hasImage}};
    }
    if (format == QStringLiteral("text") || format == QStringLiteral("html")) {
        const QString text = format == QStringLiteral("html") ? mime->html() : mime->text();
        if (text.toUtf8().size() > maxText) {
            return {{QStringLiteral("error"), QStringLiteral("the clipboard text is too large")}};
        }
        return {{format, text}};
    }
    if (format != QStringLiteral("image")) {
        return {};
    }
    for (const QString &type : types) {
        if (!mime->hasFormat(type)) {
            continue;
        }
        const QByteArray bytes = mime->data(type);
        if (bytes.size() > maxImage) {
            return {{QStringLiteral("error"), QStringLiteral("the clipboard image is too large")}};
        }
        return {{QStringLiteral("mime"), type}, {QStringLiteral("data"), QString::fromLatin1(bytes.toBase64())}};
    }
    QImage image = qvariant_cast<QImage>(mime->imageData());
    if (image.isNull()) {
        return {{QStringLiteral("error"), QStringLiteral("the clipboard holds no image")}};
    }
    if (qint64(image.width()) * image.height() > 50000000) {
        return {{QStringLiteral("error"), QStringLiteral("the clipboard image is too large")}};
    }
    if (image.width() > 1600 || image.height() > 1600) {
        image = image.scaled(1600, 1600, Qt::KeepAspectRatio, Qt::SmoothTransformation);
    }
    QByteArray bytes;
    QBuffer buffer(&bytes);
    buffer.open(QIODevice::WriteOnly);
    if (!image.save(&buffer, "PNG") || bytes.size() > maxImage) {
        return {{QStringLiteral("error"), QStringLiteral("could not encode the clipboard image")}};
    }
    return {{QStringLiteral("mime"), QStringLiteral("image/png")},
        {QStringLiteral("data"), QString::fromLatin1(bytes.toBase64())}};
}

void DesktopRuntime::activate()
{
    emit activationRequested();
}
