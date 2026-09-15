#pragma once

#include <QObject>
#include <QProcess>
#include <QStringDecoder>
#include <QVariantMap>

class ProcessBackend : public QObject
{
    Q_OBJECT

public:
    explicit ProcessBackend(QObject *parent = nullptr);
    ~ProcessBackend() override;
    Q_INVOKABLE void start(const QStringList &command, const QVariantMap &environment, const QVariantMap &options);
    Q_INVOKABLE void write(const QString &text);
    Q_INVOKABLE void closeInput();
    Q_INVOKABLE void stop();

signals:
    void started();
    void output(const QString &chunk);
    void exited(int code);
    void failed(const QString &message);

private:
    void drainOutput();
    QProcess *m_process;
    QStringDecoder m_decoder{QStringDecoder::Utf8};
    bool m_stopping = false;
};
