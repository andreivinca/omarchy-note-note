#include "../hosts/standalone/runtime.h"

#include <QBuffer>
#include <QClipboard>
#include <QGuiApplication>
#include <QImage>
#include <QMimeData>
#include <QTest>

class NativeRuntimeTest : public QObject
{
    Q_OBJECT

private slots:
    void textAndHtml()
    {
        DesktopRuntime runtime;
        const QString text = QString::fromUtf8("Notes 📝\n漢字");
        runtime.copyText(text);
        QCOMPARE(runtime.clipboard("text").value("text").toString(), text);
        QVERIFY(!runtime.clipboard("types").value("image").toBool());

        auto *mime = new QMimeData;
        mime->setHtml(QStringLiteral("<p><b>Rich text</b></p>"));
        QGuiApplication::clipboard()->setMimeData(mime);
        QCOMPARE(runtime.clipboard("html").value("html").toString(), mime->html());
        mime->setText(QString(4 * 1024 * 1024, QChar(0x6f22)));
        QVERIFY(runtime.clipboard("text").contains("error"));
    }

    void encodedImage()
    {
        DesktopRuntime runtime;
        QImage image(8, 8, QImage::Format_ARGB32);
        image.fill(Qt::green);
        QByteArray bytes;
        QBuffer buffer(&bytes);
        QVERIFY(buffer.open(QIODevice::WriteOnly));
        QVERIFY(image.save(&buffer, "PNG"));
        auto *mime = new QMimeData;
        mime->setData(QStringLiteral("image/png"), bytes);
        QGuiApplication::clipboard()->setMimeData(mime);
        QVERIFY(runtime.clipboard("types").value("image").toBool());
        const auto result = runtime.clipboard("image");
        QCOMPARE(result.value("mime").toString(), QStringLiteral("image/png"));
        QCOMPARE(QByteArray::fromBase64(result.value("data").toByteArray()), bytes);
        mime->setData(QStringLiteral("image/png"), QByteArray(40 * 1024 * 1024 + 1, 'x'));
        QVERIFY(runtime.clipboard("image").contains("error"));
    }

    void nativeImage()
    {
        DesktopRuntime runtime;
        QImage image(2000, 1000, QImage::Format_RGB32);
        image.fill(Qt::blue);
        auto *mime = new QMimeData;
        mime->setImageData(image);
        QGuiApplication::clipboard()->setMimeData(mime);
        const auto result = runtime.clipboard("image");
        QVERIFY(!result.contains("error"));
        const auto decoded = QImage::fromData(QByteArray::fromBase64(result.value("data").toByteArray()), "PNG");
        QCOMPARE(decoded.size(), QSize(1600, 800));
        QGuiApplication::clipboard()->clear();
        QVERIFY(!runtime.clipboard("image").contains("data"));
        QVERIFY(!runtime.clipboard("types").value("image").toBool());
    }
};

QTEST_MAIN(NativeRuntimeTest)
#include "native_runtime_test.moc"
