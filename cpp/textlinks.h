#pragma once

#include <QColor>
#include <QSyntaxHighlighter>
#include <QTextDocument>

// URL colour and underline are display-only. The document's text, character
// advances, anchor formats and undo history stay unchanged.
class TextLinks : public QSyntaxHighlighter
{
    Q_OBJECT

public:
    explicit TextLinks(QObject *parent = nullptr);
    void configure(const QColor &colour, bool plainText);
    QString linkAt(const QPointF &point) const;
    static void normalizeAnchors(QTextDocument *document);

signals:
    void linksChanged();

protected:
    void highlightBlock(const QString &text) override;

private:
    QColor m_colour;
    bool m_plainText = false;
};
