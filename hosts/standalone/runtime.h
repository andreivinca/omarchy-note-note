#pragma once

#include <QObject>
#include <QVariantMap>

class DesktopRuntime : public QObject
{
    Q_OBJECT

public:
    explicit DesktopRuntime(QObject *parent = nullptr) : QObject(parent) {}
    Q_INVOKABLE QString env(const QString &name) const;
    Q_INVOKABLE void copyText(const QString &text);
    Q_INVOKABLE QVariantMap clipboard(const QString &format) const;
    void activate();

signals:
    void activationRequested();
};
