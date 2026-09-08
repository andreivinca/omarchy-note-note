#include "textlinks.h"

#include <QAbstractTextDocumentLayout>
#include <QRegularExpression>
#include <QTextBlock>
#include <QTextCursor>
#include <QTextFragment>
#include <QUrl>
#include <QVector>
#include <algorithm>

namespace {
struct Link {
    int start;
    int end;
    QString href;
};

struct Change {
    int position;
    QTextCharFormat format;
};

QTextCharFormat withoutLink(QTextCharFormat format)
{
    format.clearProperty(QTextFormat::IsAnchor);
    format.clearProperty(QTextFormat::AnchorHref);
    format.clearProperty(QTextFormat::AnchorName);
    format.clearProperty(QTextFormat::ForegroundBrush);
    format.clearProperty(QTextFormat::FontUnderline);
    format.clearProperty(QTextFormat::TextUnderlineStyle);
    return format;
}

bool isCode(const QTextBlock &block, const QTextCharFormat &format)
{
    const auto paragraph = block.blockFormat();
    if (paragraph.background().style() != Qt::NoBrush
        && !(paragraph.leftMargin() >= 40 && paragraph.rightMargin() >= 40)) {
        return true;
    }
    for (const QString &family : format.font().families()) {
        // The dialect explicitly names this generic family for inline code.
        // The normal note face is iA Writer Mono S, which is ordinary prose.
        if (family.compare(QStringLiteral("monospace"), Qt::CaseInsensitive) == 0) {
            return true;
        }
    }
    return false;
}

QVector<Link> anchors(const QTextBlock &block)
{
    QVector<Link> result;
    for (auto it = block.begin(); !it.atEnd(); ++it) {
        const QTextFragment fragment = it.fragment();
        const QString href = fragment.charFormat().anchorHref();
        if (href.isEmpty() || fragment.charFormat().isImageFormat() || isCode(block, fragment.charFormat())) {
            continue;
        }
        if (!result.isEmpty() && result.last().end == fragment.position() && result.last().href == href) {
            result.last().end += fragment.length();
        } else {
            result.append({fragment.position(), fragment.position() + fragment.length(), href});
        }
    }
    return result;
}

QVector<Link> detect(const QTextBlock &block, bool plainText)
{
    static const QRegularExpression expression(
        QStringLiteral(R"((?<![\p{L}\p{N}_@])(?:https?://|www\.)[^\s<>"{}]+)"),
        QRegularExpression::CaseInsensitiveOption);
    const QString text = block.text();
    // Qt can retain character formats when a rich document becomes plain
    // text. Plain notes have no anchor or code semantics to interpret.
    QVector<Link> result = plainText ? QVector<Link>{} : anchors(block);
    auto matches = expression.globalMatch(text);
    while (matches.hasNext()) {
        const auto match = matches.next();
        QString label = match.captured();
        while (!label.isEmpty()) {
            const QChar last = label.back();
            const bool punctuation = QStringLiteral(".,;:!?'\"").contains(last);
            const bool closing = (last == ')' && label.count(')') > label.count('('))
                || (last == ']' && label.count(']') > label.count('['));
            if (!punctuation && !closing) {
                break;
            }
            label.chop(1);
        }
        const QString href = label.startsWith(QStringLiteral("www."), Qt::CaseInsensitive)
            ? QStringLiteral("https://") + label : label;
        const QUrl url(href, QUrl::StrictMode);
        if (!url.isValid() || url.host().isEmpty() || url.host().endsWith('.')) {
            continue;
        }
        const Link link{block.position() + int(match.capturedStart()),
                        block.position() + int(match.capturedStart()) + int(label.size()), href};
        bool allowed = true;
        for (auto it = block.begin(); !plainText && !it.atEnd(); ++it) {
            const QTextFragment fragment = it.fragment();
            if (fragment.position() >= link.end || fragment.position() + fragment.length() <= link.start) {
                continue;
            }
            const auto format = fragment.charFormat();
            if (format.isImageFormat() || isCode(block, format)) {
                allowed = false;
                break;
            }
            if (format.anchorHref().isEmpty()) {
                continue;
            }
            // Explicit anchors keep both their label and destination, even
            // when the label happens to be a different URL.
            allowed = false;
            break;
        }
        if (allowed) {
            result.append(link);
        }
    }
    std::sort(result.begin(), result.end(), [](const Link &left, const Link &right) {
        return left.start < right.start;
    });
    return result;
}
}

void TextLinks::normalizeAnchors(QTextDocument *document)
{
    if (!document) {
        return;
    }
    QVector<Change> changes;
    for (QTextBlock block = document->begin(); block.isValid(); block = block.next()) {
        if (!block.text().isEmpty()) {
            continue;
        }
        const QTextCharFormat format = QTextCursor(block).blockCharFormat();
        if (format.isAnchor()) {
            changes.append({block.position(), withoutLink(format)});
        }
    }
    if (changes.isEmpty()) {
        return;
    }
    QTextCursor cursor(document);
    cursor.joinPreviousEditBlock();
    for (const Change &change : changes) {
        cursor.setPosition(change.position);
        cursor.setBlockCharFormat(change.format);
        cursor.setCharFormat(change.format);
    }
    cursor.endEditBlock();
}

TextLinks::TextLinks(QObject *parent) : QSyntaxHighlighter(parent)
{
}

void TextLinks::configure(const QColor &colour, bool plainText)
{
    m_colour = colour;
    m_plainText = plainText;
    // Also completes the highlighter's initial delayed pass while the editor
    // is loading, so display setup cannot be mistaken for a later text edit.
    rehighlight();
}

void TextLinks::highlightBlock(const QString &)
{
    QTextCharFormat appearance;
    appearance.setForeground(m_colour);
    appearance.setFontUnderline(true);
    for (const Link &link : detect(currentBlock(), m_plainText)) {
        setFormat(link.start - currentBlock().position(), link.end - link.start, appearance);
    }
    emit linksChanged();
}

QString TextLinks::linkAt(const QPointF &point) const
{
    if (!document()) {
        return {};
    }
    const int position = document()->documentLayout()->hitTest(point, Qt::ExactHit);
    if (position < 0) {
        return {};
    }
    for (const Link &link : detect(document()->findBlock(position), m_plainText)) {
        if (link.start <= position && position < link.end) {
            return link.href;
        }
    }
    return {};
}
