// The native text inspector: the one thing QML cannot ask a TextEdit —
// "what are your blocks, and what block format does each carry?"
//
// QML's TextEdit exposes the document only as serialised HTML
// (getFormattedText), so the editor's quote bars used to find quote blocks
// by scanning that HTML with a regex. This class reads the same answer from
// the QTextDocument itself, through the TextEdit's `textDocument` property.
// It is read-only: it never modifies the document, so it can never corrupt
// a note — the worst it can do is misplace a decoration.
//
// The module is OPTIONAL. It is built locally (`sh cpp/build.sh`) against
// the system Qt and loaded by a directory import (ui/NativeBlocks.qml);
// when the library is absent the editor falls back to the HTML scan
// (ui/QuoteBars.js). cpp/selftest.py asserts the two agree.
#pragma once

#include <QObject>
#include <QQmlEngine>
#include <QQuickTextDocument>
#include <QTextBlock>
#include <QTextBlockFormat>
#include <QTextDocument>
#include <QTextList>
#include <QVariantList>
#include <QVariantMap>

class TextBlocks : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QQuickTextDocument *document READ document WRITE setDocument NOTIFY documentChanged)

public:
    explicit TextBlocks(QObject *parent = nullptr) : QObject(parent) { }

    QQuickTextDocument *document() const { return m_document; }
    void setDocument(QQuickTextDocument *document)
    {
        if (document == m_document)
            return;
        m_document = document;
        emit documentChanged();
    }

    // Every block in document order — paragraphs, list items and table
    // cells alike, the same order the document's plain text walks them.
    // `position` is the block's first character, `end` its last (the
    // block separator's place), both valid for positionToRectangle.
    // The margins and the background are what the dialect stores meaning
    // in: the 40/40 margin pair is a quote, left-only steps are indents,
    // and a block background marks a code line (qthtml/dialect.py).
    // `list` says the block is an item of a QTextList, which is how the
    // editor knows a second Enter should leave the list.
    Q_INVOKABLE QVariantList blocks() const
    {
        QVariantList out;
        QTextDocument *doc = m_document ? m_document->textDocument() : nullptr;
        if (!doc)
            return out;
        for (QTextBlock block = doc->begin(); block.isValid(); block = block.next()) {
            const QTextBlockFormat format = block.blockFormat();
            QVariantMap entry;
            entry.insert(QStringLiteral("position"), block.position());
            entry.insert(QStringLiteral("end"), block.position() + qMax(0, block.length() - 1));
            entry.insert(QStringLiteral("marginLeft"), format.leftMargin());
            entry.insert(QStringLiteral("marginRight"), format.rightMargin());
            entry.insert(QStringLiteral("background"), format.background().style() != Qt::NoBrush);
            entry.insert(QStringLiteral("list"), block.textList() != nullptr);
            out.append(entry);
        }
        return out;
    }

    // Qt reads a list into canonical margins — 12 above the first item, 12
    // below the last, 0 between — but an item made by pressing Enter
    // inherits the split item's margins instead, so a growing list drifts
    // from the form a re-render would give it, and snaps there on the next
    // one. This restores the canonical form as the items change. It is the
    // one write in this class; the change joins the edit that caused it, so
    // undo stays one step, and it never reaches the note (the reader does
    // not look at an item's margins).
    Q_INVOKABLE void normalizeListMargins()
    {
        QTextDocument *doc = m_document ? m_document->textDocument() : nullptr;
        if (!doc)
            return;
        for (QTextBlock block = doc->begin(); block.isValid(); block = block.next()) {
            QTextList *list = block.textList();
            if (!list)
                continue;
            const int item = list->itemNumber(block);
            const qreal top = item == 0 ? 12 : 0;
            const qreal bottom = item == list->count() - 1 ? 12 : 0;
            QTextBlockFormat format = block.blockFormat();
            if (format.topMargin() == top && format.bottomMargin() == bottom)
                continue;
            format.setTopMargin(top);
            format.setBottomMargin(bottom);
            QTextCursor cursor(block);
            cursor.joinPreviousEditBlock();
            cursor.setBlockFormat(format);
            cursor.endEditBlock();
        }
    }

signals:
    void documentChanged();

private:
    QQuickTextDocument *m_document = nullptr;
};
