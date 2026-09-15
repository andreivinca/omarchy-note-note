#include "processbackend.h"

#include <QCoreApplication>
#include <QProcessEnvironment>

ProcessBackend::ProcessBackend(QObject *parent) : QObject(parent), m_process(new QProcess(this))
{
    m_process->setStandardErrorFile(QProcess::nullDevice());
    connect(m_process, &QProcess::started, this, &ProcessBackend::started);
    connect(m_process, &QProcess::readyReadStandardOutput, this, &ProcessBackend::drainOutput);
    connect(m_process, &QProcess::finished, this, [this](int code, QProcess::ExitStatus status) {
        drainOutput();
        if (!m_stopping) {
            emit exited(status == QProcess::NormalExit ? code : -1);
        }
    });
    connect(m_process, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
        if (m_stopping) {
            return;
        }
        if (error == QProcess::FailedToStart) {
            emit failed(QStringLiteral("could not start the process"));
        } else if (error == QProcess::ReadError || error == QProcess::WriteError) {
            emit failed(QStringLiteral("could not communicate with the process"));
        }
    });
}

ProcessBackend::~ProcessBackend()
{
    stop();
    if (m_process->state() != QProcess::NotRunning) {
        // Reap cancelled processes asynchronously, without blocking the UI
        // while the kernel acknowledges the kill.
        m_process->setParent(QCoreApplication::instance());
        connect(m_process, &QProcess::finished, m_process, &QObject::deleteLater);
    }
}

void ProcessBackend::start(const QStringList &command, const QVariantMap &environment, const QVariantMap &options)
{
    Q_UNUSED(options)
    if (command.isEmpty()) {
        emit failed(QStringLiteral("the process command is empty"));
        return;
    }
    auto childEnvironment = QProcessEnvironment::systemEnvironment();
    for (auto it = environment.cbegin(); it != environment.cend(); ++it) {
        childEnvironment.insert(it.key(), it.value().toString());
    }
    m_process->setProcessEnvironment(childEnvironment);
    m_process->start(command.first(), command.mid(1));
}

void ProcessBackend::write(const QString &text)
{
    m_process->write(text.toUtf8());
}

void ProcessBackend::closeInput()
{
    m_process->closeWriteChannel();
}

void ProcessBackend::stop()
{
    m_stopping = true;
    if (m_process->state() != QProcess::NotRunning) {
        m_process->kill();
    }
}

void ProcessBackend::drainOutput()
{
    while (!m_stopping && m_process->bytesAvailable() > 0) {
        const QByteArray bytes = m_process->read(64 * 1024);
        emit output(m_decoder.decode(bytes));
    }
}
