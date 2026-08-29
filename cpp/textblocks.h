// The native text inspector: the things QML cannot ask a TextEdit —
// "what are your blocks, and what block format does each carry?", "where
// are your images, and how large are they drawn?"
//
// QML's TextEdit exposes the document only as serialised HTML
// (getFormattedText), so the editor's quote bars used to find quote blocks
// by scanning that HTML with a regex. This class reads the same answers from
// the QTextDocument itself, through the TextEdit's `textDocument` property.
// It is inspection first: the only writes are format-only and never touch
// the text — canonical list margins (normalizeListMargins) and an image's
// display width (setImageWidth, the corner-handle resize) — so the worst a
// bug here can do is mis-size what is drawn, never lose a character.
//
// The module is OPTIONAL. It is built locally (`sh cpp/build.sh`) against
// the system Qt and loaded by a directory import (ui/NativeBlocks.qml);
// when the library is absent the editor falls back to the HTML scan
// (ui/QuoteBars.js) and images simply have no resize handle.
// cpp/selftest.py asserts the fallback and the inspector agree.
#pragma once

#include <QImage>
#include <QObject>
#include <QPixmap>
#include <QQmlEngine>
#include <QQuickTextDocument>
#include <QTextBlock>
#include <QTextBlockFormat>
#include <QTextCursor>
#include <QTextDocument>
#include <QTextImageFormat>
#include <QTextLayout>
#include <QTextList>
#include <QUrl>
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
    // editor knows a second Enter should leave the list. `marker` is the
    // item's task-list state — 0 none, 1 an unchecked box, 2 a checked one;
    // Qt Quick paints the marker as a raw ☐/☒ glyph hardcoded in its
    // renderer, so the editor covers it and draws its own box over the
    // glyph's cell (NoteEditor.qml, block decorations).
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
            const QTextBlockFormat::MarkerType marker = format.marker();
            entry.insert(QStringLiteral("marker"),
                         marker == QTextBlockFormat::MarkerType::Checked         ? 2
                                 : marker == QTextBlockFormat::MarkerType::Unchecked ? 1
                                                                                     : 0);
            out.append(entry);
        }
        return out;
    }

    // Every inline image in document order: where it sits (`position` is
    // its object-replacement character, valid for positionToRectangle),
    // what it names (`source`), the size it is drawn at (`width`/`height`,
    // resolved the way Qt's own image handler does: stated dimensions win,
    // one stated dimension scales the other by the aspect, none means
    // natural size), the file's own size (`naturalWidth`/`naturalHeight`,
    // 0 while the resource has not loaded), and `ascent` — the image's
    // baseline within its line, which is where its bottom edge sits, so the
    // editor can place the resize handle on the drawn corner exactly.
    Q_INVOKABLE QVariantList images() const
    {
        QVariantList out;
        QTextDocument *doc = m_document ? m_document->textDocument() : nullptr;
        if (!doc)
            return out;
        for (QTextBlock block = doc->begin(); block.isValid(); block = block.next()) {
            for (QTextBlock::iterator it = block.begin(); !it.atEnd(); ++it) {
                const QTextFragment fragment = it.fragment();
                if (!fragment.isValid() || !fragment.charFormat().isImageFormat())
                    continue;
                const QTextImageFormat format = fragment.charFormat().toImageFormat();
                const QSizeF natural = naturalSize(doc, format);
                qreal width = format.hasProperty(QTextFormat::ImageWidth) ? format.width() : 0;
                qreal height = format.hasProperty(QTextFormat::ImageHeight) ? format.height() : 0;
                if (width > 0 && height <= 0 && natural.width() > 0)
                    height = natural.height() * width / natural.width();
                else if (height > 0 && width <= 0 && natural.height() > 0)
                    width = natural.width() * height / natural.height();
                if (width <= 0 && height <= 0) {
                    width = natural.width();
                    height = natural.height();
                }
                const QTextLine line =
                        block.layout()->lineForTextPosition(fragment.position() - block.position());
                // A fragment can hold several adjacent copies of one image.
                for (int i = 0; i < fragment.length(); ++i) {
                    QVariantMap entry;
                    entry.insert(QStringLiteral("position"), fragment.position() + i);
                    entry.insert(QStringLiteral("source"), format.name());
                    entry.insert(QStringLiteral("width"), width);
                    entry.insert(QStringLiteral("height"), height);
                    entry.insert(QStringLiteral("naturalWidth"), natural.width());
                    entry.insert(QStringLiteral("naturalHeight"), natural.height());
                    entry.insert(QStringLiteral("ascent"), line.isValid() ? line.ascent() : height);
                    out.append(entry);
                }
            }
        }
        return out;
    }

    // The corner-handle resize: the image keeps its source and alignment and
    // gets a display width; the stored height is cleared so Qt scales it by
    // the aspect, and the same rule keeps `images()` above and Qt's painter
    // agreeing. One format-only edit — its own undo step, or joined to the
    // edit before it (`join`, for the paste that fits its fresh image so one
    // Ctrl+Z takes both). False when `position` does not hold an image.
    Q_INVOKABLE bool setImageWidth(int position, qreal width, bool join = false)
    {
        QTextDocument *doc = m_document ? m_document->textDocument() : nullptr;
        if (!doc || width <= 0 || position < 0 || position >= doc->characterCount())
            return false;
        QTextCursor cursor(doc);
        cursor.setPosition(position);
        cursor.setPosition(position + 1, QTextCursor::KeepAnchor);
        // charFormat() answers for the character before position(), which
        // with this selection is the image character itself.
        const QTextCharFormat current = cursor.charFormat();
        if (!current.isImageFormat())
            return false;
        QTextImageFormat format = current.toImageFormat();
        format.setWidth(width);
        format.clearProperty(QTextFormat::ImageHeight);
        if (join)
            cursor.joinPreviousEditBlock();
        else
            cursor.beginEditBlock();
        cursor.setCharFormat(format);
        cursor.endEditBlock();
        return true;
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
    // The image file's own size, from the resource the document already
    // loaded to paint it (the document caches these, so this is a lookup,
    // not a read). Empty while a resource has not loaded — `images()` then
    // reports natural 0 and the next pass sees it.
    static QSizeF naturalSize(QTextDocument *doc, const QTextImageFormat &format)
    {
        const QVariant resource =
                doc->resource(QTextDocument::ImageResource, QUrl(format.name()));
        if (resource.canConvert<QImage>())
            return resource.value<QImage>().size();
        if (resource.canConvert<QPixmap>())
            return resource.value<QPixmap>().size();
        return QSizeF();
    }

    QQuickTextDocument *m_document = nullptr;
};
