#include "processbackend.h"
#include "runtime.h"
#include "../../cpp/textblocks.h"
#include "../../services/theme/desktoptheme.h"

#include <QCommandLineParser>
#include <QDir>
#include <QFileInfo>
#include <QFontDatabase>
#include <QGuiApplication>
#include <QImageReader>
#include <QLocalServer>
#include <QLocalSocket>
#include <QLockFile>
#include <QQmlApplicationEngine>
#include <QQuickStyle>
#include <QStandardPaths>
#include <QTimer>

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    QCoreApplication::setApplicationName(QStringLiteral("note-note"));
    QCoreApplication::setOrganizationDomain(QStringLiteral("andreivinca.github.io"));
    QCoreApplication::setApplicationVersion(QStringLiteral(NOTE_NOTE_VERSION));
    QGuiApplication::setDesktopFileName(QStringLiteral("io.github.andreivinca.note-note"));
    QGuiApplication::setQuitOnLastWindowClosed(false);
    QImageReader::setAllocationLimit(128);
    QQuickStyle::setStyle(QStringLiteral("Basic"));

    QCommandLineParser parser;
    parser.setApplicationDescription(QStringLiteral("Local Markdown, OneNote, Sticky Notes and Notion in one workspace."));
    parser.addHelpOption();
    parser.addVersionOption();
    parser.addOption({QStringLiteral("data-dir"), QStringLiteral("Application resources directory."), QStringLiteral("directory")});
    parser.addOption({QStringLiteral("qml"), QStringLiteral("Run a QML test harness instead of the application."), QStringLiteral("file")});
    parser.process(app);

    QString dataDir = parser.value(QStringLiteral("data-dir"));
    if (dataDir.isEmpty()) {
        if (QCoreApplication::applicationDirPath() == QStringLiteral(NOTE_NOTE_BUILD_DIR)) {
            dataDir = QStringLiteral(NOTE_NOTE_SOURCE_DIR);
        } else {
            dataDir = QDir(QCoreApplication::applicationDirPath()).absoluteFilePath(QStringLiteral(NOTE_NOTE_DATA_FROM_BIN));
            if (!QFileInfo::exists(dataDir + QStringLiteral("/Workspace.qml"))) {
                dataDir = QStringLiteral(NOTE_NOTE_INSTALL_DATA_DIR);
            }
        }
    }
    if (!QFileInfo::exists(dataDir + QStringLiteral("/Workspace.qml"))) {
        qCritical("The Note Note application resources could not be found.");
        return 1;
    }

    DesktopRuntime runtime;
    const int symbols = QFontDatabase::addApplicationFont(dataDir + QStringLiteral("/assets/fonts/nerd-symbols/SymbolsNerdFont-Regular.ttf"));
    for (const QString &family : QFontDatabase::applicationFontFamilies(symbols)) {
        QFontDatabase::addApplicationFallbackFontFamily(QChar::Script_Common, family);
    }
    QLocalServer server;
    const QString instancePath = QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation) + QStringLiteral("/note-note");
    QLockFile instanceLock(instancePath + QStringLiteral(".lock"));
    if (!parser.isSet(QStringLiteral("qml"))) {
        if (!instanceLock.tryLock()) {
            QLocalSocket client;
            client.connectToServer(instancePath);
            if (!client.waitForConnected(2000)) {
                qCritical("The running Note Note instance could not be reached.");
                return 1;
            }
            return 0;
        }
        QLocalServer::removeServer(instancePath);
        server.setSocketOptions(QLocalServer::UserAccessOption);
        if (!server.listen(instancePath)) {
            qCritical("Could not create the application activation socket.");
            return 1;
        }
        QObject::connect(&server, &QLocalServer::newConnection, &runtime, [&server, &runtime]() {
            while (server.hasPendingConnections()) {
                QLocalSocket *connection = server.nextPendingConnection();
                connection->disconnectFromServer();
                connection->deleteLater();
            }
            runtime.activate();
        });
    }

    DesktopTheme theme;
    qmlRegisterSingletonInstance("NoteNote.Native", 1, 0, "SystemTheme", &theme);
    qmlRegisterType<ProcessBackend>("NoteNote.Native", 1, 0, "NativeProcess");
    qmlRegisterType<TextBlocks>("NoteNote.Native", 1, 0, "TextBlocks");
    qmlRegisterSingletonInstance("NoteNote.Native", 1, 0, "Desktop", &runtime);
    QQmlApplicationEngine engine;
    QObject::connect(&engine, &QQmlApplicationEngine::exit, &app, &QCoreApplication::exit);
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app, []() {
        QCoreApplication::exit(1);
    }, Qt::QueuedConnection);
    const QString entry = parser.isSet(QStringLiteral("qml")) ? parser.value(QStringLiteral("qml"))
        : dataDir + QStringLiteral("/hosts/standalone/Main.qml");
    engine.load(QUrl::fromLocalFile(QFileInfo(entry).absoluteFilePath()));
    const int result = app.exec();
    qDeleteAll(engine.rootObjects());
    // Only cancelled transports are reparented to the application. Reap any
    // final acknowledgements after the UI event loop has already stopped.
    for (QProcess *process : app.findChildren<QProcess *>(Qt::FindDirectChildrenOnly)) {
        if (process->state() != QProcess::NotRunning) {
            process->waitForFinished(1000);
        }
    }
    return result;
}
