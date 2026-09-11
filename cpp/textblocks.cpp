#include "textblocks.h"

int TextBlocks::deletePreviousTable(int position)
{
    QTextDocument *doc = m_document ? m_document->textDocument() : nullptr;
    if (!doc || position <= 0 || position >= doc->characterCount()) {
        return -1;
    }
    QTextCursor cursor(doc);
    cursor.setPosition(position - 1);
    QTextTable *table = cursor.currentTable();
    if (!table || table->lastPosition() != position - 1) {
        return -1;
    }
    // Include both frame boundaries so Qt removes the table itself, not
    // just its cell contents. The exact end check keeps parent tables safe.
    cursor.beginEditBlock();
    cursor.setPosition(table->firstPosition() - 1);
    cursor.setPosition(position, QTextCursor::KeepAnchor);
    cursor.removeSelectedText();
    cursor.endEditBlock();
    return cursor.position();
}

QVariantMap TextBlocks::tableInfo(int position) const
{
    QTextDocument *doc = m_document ? m_document->textDocument() : nullptr;
    if (!doc || position < 0 || position >= doc->characterCount()) {
        return {};
    }
    QTextCursor cursor(doc);
    cursor.setPosition(position);
    QTextTable *table = cursor.currentTable();
    if (!table) {
        return {};
    }
    const QTextTableCell cell = table->cellAt(cursor);
    return {{"row", cell.row()}, {"column", cell.column()},
            {"rows", table->rows()}, {"columns", table->columns()},
            {"cellStart", cell.firstCursorPosition().position()},
            {"cellEnd", cell.lastCursorPosition().position()}};
}

int TextBlocks::editTable(int position, const QString &operation, int index, int count)
{
    QTextDocument *doc = m_document ? m_document->textDocument() : nullptr;
    if (!doc || position < 0 || position >= doc->characterCount() || count < 1 || index < 0) {
        return -1;
    }
    QTextCursor cursor(doc);
    cursor.setPosition(position);
    QTextTable *table = cursor.currentTable();
    if (!table) {
        return -1;
    }
    const bool rows = operation == "insertRows" || operation == "removeRows";
    const bool columns = operation == "insertColumns" || operation == "removeColumns";
    const bool insert = operation == "insertRows" || operation == "insertColumns";
    const int size = rows ? table->rows() : table->columns();
    if ((!rows && !columns) || index > size || (!insert && (index + count > size || count >= size))) {
        return -1;
    }
    const QTextTableCell original = table->cellAt(cursor);
    const int originalRow = original.row();
    const int originalColumn = original.column();
    cursor.beginEditBlock();
    if (operation == "insertRows") {
        table->insertRows(index, count);
    } else if (operation == "removeRows") {
        table->removeRows(index, count);
    } else if (operation == "insertColumns") {
        table->insertColumns(index, count);
    } else {
        table->removeColumns(index, count);
    }
    cursor.endEditBlock();
    // Deleting the first cell can leave Qt's cursor just before the table,
    // which belongs to the parent cell in a nested table. Keep editing this
    // table by landing in the nearest surviving cell instead.
    if (cursor.currentTable() != table) {
        cursor = table->cellAt(qMin(originalRow, table->rows() - 1),
                               qMin(originalColumn, table->columns() - 1)).firstCursorPosition();
    }
    return cursor.position();
}

int TextBlocks::appendTableRow(int position)
{
    QTextDocument *doc = m_document ? m_document->textDocument() : nullptr;
    if (!doc || position < 0 || position >= doc->characterCount()) {
        return -1;
    }
    QTextCursor cursor(doc);
    cursor.setPosition(position);
    QTextTable *table = cursor.currentTable();
    if (!table) {
        return -1;
    }
    const QTextTableCell cell = table->cellAt(cursor);
    const QTextBlock block = cursor.block();
    // A second Enter in the final cell's empty continuation adds a row to
    // this table, regardless of how many enclosing or preceding tables exist.
    if (cell.row() != table->rows() - 1 || cell.column() != table->columns() - 1
        || block.position() <= cell.firstCursorPosition().position()
        || block.position() + block.length() - 1 != cell.lastCursorPosition().position()
        || !block.text().trimmed().isEmpty()) {
        return -1;
    }
    cursor.beginEditBlock();
    cursor.setPosition(block.position() - 1);
    cursor.setPosition(block.position() + block.length() - 1, QTextCursor::KeepAnchor);
    cursor.removeSelectedText();
    const int row = table->rows();
    table->insertRows(row, 1);
    const int target = table->cellAt(row, 0).firstCursorPosition().position();
    cursor.endEditBlock();
    return target;
}


bool TextBlocks::setTextColor(int from, int to, const QString &color)
{
    QTextDocument *doc = m_document ? m_document->textDocument() : nullptr;
    const QColor ink(color);
    if (!doc || from < 0 || from >= to || to >= doc->characterCount() || (!color.isEmpty() && !ink.isValid())) {
        return false;
    }
    struct Run {
        int from;
        int to;
        QTextCharFormat format;
    };
    QVector<Run> runs;
    for (QTextBlock block = doc->findBlock(from); block.isValid() && block.position() < to; block = block.next()) {
        for (auto it = block.begin(); !it.atEnd(); ++it) {
            const QTextFragment fragment = it.fragment();
            const int start = qMax(from, fragment.position());
            const int end = qMin(to, fragment.position() + fragment.length());
            if (start >= end || fragment.charFormat().isImageFormat()) {
                continue;
            }
            QTextCharFormat format = fragment.charFormat();
            if (color.isEmpty()) {
                format.clearForeground();
            } else {
                format.setForeground(ink);
            }
            runs.append({start, end, format});
        }
    }
    QTextCursor cursor(doc);
    cursor.beginEditBlock();
    for (const Run &run : runs) {
        cursor.setPosition(run.from);
        cursor.setPosition(run.to, QTextCursor::KeepAnchor);
        cursor.setCharFormat(run.format);
    }
    cursor.endEditBlock();
    return !runs.isEmpty();
}


int TextBlocks::insertFormattedText(int from, int to, const QString &text, const QVariantMap &styles)
{
    QTextDocument *doc = m_document ? m_document->textDocument() : nullptr;
    if (!doc || from < 0 || from > to || to >= doc->characterCount()) {
        return -1;
    }
    QTextCursor cursor(doc);
    cursor.setPosition(from);
    cursor.setPosition(to, QTextCursor::KeepAnchor);
    QTextCharFormat format = cursor.charFormat();
    if (styles.contains("bold")) {
        format.setFontWeight(styles.value("bold").toBool() ? QFont::Bold : QFont::Normal);
    }
    if (styles.contains("italic")) {
        format.setFontItalic(styles.value("italic").toBool());
    }
    if (styles.contains("underline")) {
        format.setFontUnderline(styles.value("underline").toBool());
    }
    if (styles.contains("strikeout")) {
        format.setFontStrikeOut(styles.value("strikeout").toBool());
    }
    if (styles.contains("color")) {
        const QString color = styles.value("color").toString();
        if (color.isEmpty()) {
            format.clearForeground();
        } else {
            const QColor ink(color);
            if (!ink.isValid()) {
                return -1;
            }
            format.setForeground(ink);
        }
    }
    cursor.beginEditBlock();
    cursor.insertText(text, format);
    cursor.endEditBlock();
    return cursor.position();
}
