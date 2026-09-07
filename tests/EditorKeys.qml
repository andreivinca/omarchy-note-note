import QtQuick
import QtTest
import "../ui" as Ui
import "../services/markdown" as Markdown

// Real keys and the real converter, in the transition runner's isolated
// offscreen window. The optional desktop host check keeps this window shut.
Window {
  id: test
  property bool runKeys: true
  signal checked(string name, bool ok, string detail)
  signal finished()
  visible: runKeys
  width: 800
  height: 700

  Markdown.Markdown { id: converter }
  // The clipboard as the editor asks it (services/clipboard/Clipboard.qml):
  // a text and an HTML flavour each case sets, never an image.
  QtObject {
    id: clip
    property string html: ""
    property string text: ""
    function hasImage(done) { done(false) }
    function takeImage(done) { done(null) }
    function takeHtml(done) { done(clip.html) }
    function takeText(done) { done(clip.text) }
  }
  Ui.NoteEditor {
    id: editor
    anchors.fill: parent
    hasNote: true
    markdown: converter
    clipboard: clip
  }
  TestCase { id: keys; name: "editor keys"; when: false }

  function require(ok, message) {
    if (!ok) {
      throw new Error(message)
    }
  }

  function load(data) {
    var ready = false, rendered = false
    if (data.html) {
      editor.restoreDocument({ title: "", body: data.html, base: "" })
      ready = true
      rendered = true
    } else {
      converter.toHtml(data.source, function(html, ok) {
        editor.restoreDocument({ title: "", body: html, base: "" })
        rendered = ok
        ready = true
      })
    }
    keys.tryVerify(function() { return ready }, 3000)
    require(rendered, "fixture did not render")
    editor.focusEditor()
  }

  function read() {
    var result = null
    converter.toMarkdown(editor.documentHtml(), function(markdown, map) {
      result = { markdown: markdown, map: map }
    })
    keys.tryVerify(function() { return result !== null }, 3000)
    require(result.map.ok, "document did not convert")
    return result.markdown
  }

  function tableEnd(text, index) {
    var end = -1
    for (var i = 0; i <= index; i++) {
      end = text.indexOf("\uFDD1", end + 1)
    }
    return end
  }

  function cells() { return editor.plainText().split("\uFDD0").length - 1 }

  function addRow(data) {
    load(data)
    var originalCells = cells()
    var index = data.tableIndex || 0
    var end = tableEnd(editor.plainText(), index)
    editor.setCursorPosition(end - (data.beforeFiller ? 1 : 0))
    var key = data.key || Qt.Key_Return
    keys.keyClick(key)
    var first = editor.plainText()
    require(cells() === originalCells, "first Enter added a row")
    require(first.substring(editor.cursorPosition() - 1, editor.cursorPosition()) === "\u2029",
            "first Enter did not start a paragraph in the cell")
    read()
    keys.keyClick(key)
    keys.tryVerify(function() { return cells() === originalCells + data.columns }, 3000)
    var after = editor.plainText()
    var tail = after.substring(editor.cursorPosition(), tableEnd(after, index))
    require(tail === Array(data.columns).fill("\u00a0").join("\uFDD0"),
            "caret did not land in the new row's first cell")
    require(read() === data.expected, "new row changed other table or note content")
    editor.undo()
    require(editor.plainText() === first, "one undo did not restore the extra line")
    editor.redo()
    require(editor.plainText() === after, "redo did not restore the new row")
  }

  function ordinaryEnter(data) {
    load(data)
    var before = cells()
    editor.setCursorPosition(editor.plainText().indexOf(data.cellText) + data.cellText.length)
    keys.keyClick(Qt.Key_Return, data.modifiers || Qt.NoModifier)
    keys.keyClick(Qt.Key_Return, data.modifiers || Qt.NoModifier)
    keys.wait(150)
    require(cells() === before, "Enter added a row outside the final empty paragraph")
  }

  function escapeBlock(data) {
    load(data)
    var original = editor.plainText()
    editor.setCursorPosition(original.length)
    // Enter first continues the block with the empty line the second Enter
    // leaves from — unless the block is that one empty line already (direct)
    if (data.key === Qt.Key_Return && !data.direct) {
      keys.keyClick(Qt.Key_Return)
    }
    var before = editor.plainText()
    var beforeKind = editor.blockInfoAt(editor.cursorPosition()).kind
    keys.keyClick(data.key || Qt.Key_Right)
    keys.tryVerify(function() { return editor.blockInfoAt(editor.cursorPosition()).kind === "" }, 3000)
    var after = editor.plainText()
    require(after === original + "\u2029", "leaving the block added a space: " + JSON.stringify(after))
    var context = editor.editContext()
    require(context.start === context.end && context.cursor === after.length, "caret did not land in an empty paragraph")
    keys.keyClick(Qt.Key_Right)
    keys.keyClick(Qt.Key_Right)
    require(editor.plainText() === after, "repeated Right changed the empty paragraph")
    keys.keyClick(Qt.Key_X)
    require(editor.plainText() === after + "x", "typing after Right added whitespace")
    require(read() === data.source + "\nx\n", "typing after Right inherited the block's formatting")
    editor.undo()
    require(editor.plainText() === after, "undo typing did not restore the empty paragraph")
    editor.undo()
    require(editor.plainText() === before, "one undo did not restore the block")
    require(editor.blockInfoAt(editor.cursorPosition()).kind === beforeKind, "undo did not restore the block's format")
    editor.redo()
    require(editor.plainText() === after, "redo restored a placeholder space")
    editor.redo()
    require(editor.plainText() === after + "x", "redo typing changed the paragraph")
  }

  // A paste inside a code block is the plain paste, whichever flavour the
  // clipboard offers: the text as it is, a line per block in the block's
  // monospace, the caret after it, one undo taking it back; `leave` then
  // presses the second Enter and types, to see the block still leaves
  // whole and the caret lands on the new paragraph.
  function pasteIntoCode(data) {
    load({ source: data.source })
    var text = editor.plainText()
    editor.setCursorPosition(data.cursor === undefined ? text.length : data.cursor)
    for (var i = 0; i < (data.selectBack || 0); i++) {
      keys.keyClick(Qt.Key_Left, Qt.ShiftModifier)
    }
    clip.html = data.html || ""
    clip.text = data.text
    if (data.plain) {
      editor.pastePlain()
    } else {
      editor.paste()
    }
    keys.tryVerify(function() { return editor.plainText() !== text }, 3000)
    var pasted = editor.plainText()
    require(read() === data.expected, "the paste did not land as code lines: " + JSON.stringify(read()))
    require(editor.cursorPosition() === data.caret, "the caret did not follow the pasted text: " + editor.cursorPosition())
    editor.undo()
    require(editor.plainText() === text, "one undo did not take the paste back")
    editor.redo()
    require(editor.plainText() === pasted, "redo did not restore the paste")
    if (!data.leave) {
      return
    }
    editor.setCursorPosition(data.caret)
    keys.keyClick(Qt.Key_Return)
    keys.keyClick(Qt.Key_Return)
    keys.tryVerify(function() { return editor.blockInfoAt(editor.cursorPosition()).kind === "" }, 3000)
    keys.keyClick(Qt.Key_X)
    require(read() === data.expected + "\nx\n", "the second Enter did not leave the pasted block whole: " + JSON.stringify(read()))
  }

  // Deleting a code line's characters and typing again keeps it code: the
  // paragraph's own character format is monospace (qthtml/writer.code).
  function retypeCodeLine() {
    load({ source: "```\ncode\n```\n" })
    editor.setCursorPosition(editor.plainText().length)
    for (var i = 0; i < 4; i++) {
      keys.keyClick(Qt.Key_Backspace)
    }
    keys.keyClick(Qt.Key_X)
    require(read() === "```\nx\n```\n", "retyped text left the code block: " + JSON.stringify(read()))
  }

  // Inside a code block the inline tools type their Markdown: the marker
  // pair around the selection, and the same tool again takes it off; with
  // the caret alone the pair goes in and typing lands between; the link
  // bar types the link's Markdown. A selection reaching across the block
  // from the prose around it is refused, the document untouched.
  function formatInCode() {
    var source = "before\n\n```\ncode\n```\n\nafter\n"
    load({ source: source })
    var original = editor.documentHtml()
    var code = editor.plainText().indexOf("code")
    var selectCode = function() {
      editor.setCursorPosition(code + 4)
      for (var i = 0; i < 4; i++) {
        keys.keyClick(Qt.Key_Left, Qt.ShiftModifier)
      }
    }
    var wrapped = function(marker) { return source.replace("code", marker + "code" + marker) }
    selectCode()
    editor.toggleFormat("bold")
    require(read() === wrapped("**"), "bold did not type its stars: " + JSON.stringify(read()))
    editor.toggleFormat("bold")
    require(read() === source, "bold again did not take the stars off: " + JSON.stringify(read()))
    editor.highlightSelection()
    require(read() === wrapped("=="), "highlight did not type its marks: " + JSON.stringify(read()))
    editor.highlightSelection()
    editor.toggleCode()
    require(read() === wrapped("`"), "inline code did not type its backticks: " + JSON.stringify(read()))
    editor.toggleCode()
    require(editor.documentHtml() === original, "the toggles did not leave the block as it was")
    editor.setCursorPosition(code + 4)
    editor.toggleFormat("italic")
    keys.keyClick(Qt.Key_X)
    require(read() === source.replace("code", "code*x*"), "typing did not land between the pair: " + JSON.stringify(read()))
    editor.setCursorPosition(editor.plainText().length)
    for (var i = 0; i < editor.plainText().length; i++) {
      keys.keyClick(Qt.Key_Left, Qt.ShiftModifier)
    }
    var across = editor.documentHtml()
    editor.toggleFormat("bold")
    editor.highlightSelection()
    editor.toggleCode()
    editor.openLinkBar()
    require(!editor.linkBarOpen, "the link bar opened on a selection across the block")
    require(editor.documentHtml() === across, "a tool changed a selection across the block")
    load({ source: source })
    selectCode()
    editor.openLinkBar()
    require(editor.linkBarOpen, "the link bar did not open inside the code block")
    editor.insertLink()
    require(read() === source.replace("code", "[code](https://)"), "the link bar did not type the link: " + JSON.stringify(read()))
  }

  function typeAfterRule() {
    load({ source: "---\n" })
    var original = editor.plainText()
    editor.setCursorPosition(original.length)
    keys.keyClick(Qt.Key_X)
    keys.tryVerify(function() { return editor.plainText() === original + "\u2029x" }, 3000)
    require(read() === "---\n\nx\n", "typing on a rule did not create plain text below it")
    editor.undo()
    require(editor.plainText() === original, "typing on a rule required more than one undo")
    editor.redo()
    require(editor.plainText() === original + "\u2029x", "redo typing on a rule changed the landing")
  }

  function deleteParagraph(data) {
    load(data)
    editor.setCursorPosition(data.cursor || 0)
    var original = editor.documentHtml()
    keys.keyClick(Qt.Key_Delete)
    var deleted = editor.documentHtml()
    if (data.expected) {
      require(read() === data.expected, "Delete changed the following paragraph: " + JSON.stringify(read()))
      require(editor.cursorPosition() === 0, "Delete did not keep the caret at the following paragraph's start")
    }
    for (var i = 0; i < 2; i++) {
      if (data.api) {
        editor.undo()
      } else {
        keys.keyClick(Qt.Key_Z, Qt.ControlModifier)
      }
      require(editor.documentHtml() === original, "undo did not restore the complete paragraph and list formats")
      if (data.api) {
        editor.redo()
      } else {
        keys.keyClick(Qt.Key_Z, Qt.ControlModifier | Qt.ShiftModifier)
      }
      require(editor.documentHtml() === deleted, "redo did not restore the complete deletion")
    }
  }

  function run() {
    var table = "| a | b |\n|---|---|\n| 1 | 2 |\n"
    var blank = "|  |  |\n"
    var cases = [
      { name: "table ends the note", source: table, expected: table + blank, columns: 2 },
      { name: "paragraph follows the table", source: table + "\nAfter\n",
        expected: table + blank + "\nAfter\n", columns: 2 },
      { name: "blank landing follows the table", source: table + "\n\u00a0\n",
        expected: table + blank + "\n\u00a0\n", columns: 2 },
      { name: "first of two tables", source: table + "\nBetween\n\n" + table,
        expected: table + blank + "\nBetween\n\n" + table, columns: 2 },
      { name: "second of two tables", source: table + "\nBetween\n\n" + table + "\nAfter\n",
        expected: table + "\nBetween\n\n" + table + blank + "\nAfter\n", columns: 2, tableIndex: 1 },
      { name: "header-only table", source: "| a | b |\n|---|---|\n\nAfter\n",
        expected: "| a | b |\n|---|---|\n" + blank + "\nAfter\n", columns: 2 },
      { name: "one column", source: "| a |\n|---|\n| 1 |\n\nAfter\n",
        expected: "| a |\n|---|\n| 1 |\n|  |\n\nAfter\n", columns: 1 },
      { name: "empty cell before its filler", source: "| a | b |\n|---|---|\n| 1 |  |\n\nAfter\n",
        expected: "| a | b |\n|---|---|\n| 1 |  |\n" + blank + "\nAfter\n", columns: 2, beforeFiller: true },
      { name: "empty cell after its filler", source: "| a | b |\n|---|---|\n| 1 |  |\n\nAfter\n",
        expected: "| a | b |\n|---|---|\n| 1 |  |\n" + blank + "\nAfter\n", columns: 2 },
      { name: "table-shaped code before the table", source: "```\n" + table + "```\n\n" + table + "\nAfter\n",
        expected: "```\n" + table + "```\n\n" + table + blank + "\nAfter\n", columns: 2 },
      { name: "empty paragraph in an earlier table",
        html: "<p>Before</p><table><tr><td><p>a</p><p></p><p>b</p></td></tr></table>"
            + "<p>Between</p><table><tr><td><p>c</p></td></tr></table><p>After</p>",
        expected: "Before\n\n| a b |\n|---|\n\nBetween\n\n| c |\n|---|\n|  |\n\nAfter\n",
        columns: 1, tableIndex: 1 },
      { name: "keypad Enter", source: table + "\nAfter\n",
        expected: table + blank + "\nAfter\n", columns: 2, key: Qt.Key_Enter },
      { name: "several paragraphs in earlier cells",
        html: "<p>Before</p><table><tr><td><p>a</p><p>more</p></td><td><p>b</p></td></tr>"
            + "<tr><td><p>1</p><p>extra</p></td><td><p>2</p></td></tr></table><p>After</p>",
        expected: "Before\n\n| a more | b |\n|---|---|\n| 1 extra | 2 |\n" + blank + "\nAfter\n", columns: 2 }
    ]
    for (var i = 0; i < cases.length; i++) {
      try {
        addRow(cases[i])
        test.checked(cases[i].name, true, "")
      } catch (error) {
        test.checked(cases[i].name, false, error.message)
      }
    }
    var ordinary = [
      { name: "last cell of an earlier row", source: table, cellText: "b" },
      { name: "earlier cell of the last row", source: table, cellText: "1" },
      { name: "Shift+Enter stays inside the last cell", source: table, cellText: "2", modifiers: Qt.ShiftModifier }
    ]
    for (var j = 0; j < ordinary.length; j++) {
      try {
        ordinaryEnter(ordinary[j])
        test.checked(ordinary[j].name, true, "")
      } catch (error) {
        test.checked(ordinary[j].name, false, error.message)
      }
    }
    var escapes = [
      { name: "Right leaves code without a space", source: "```\ncode\n```\n" },
      { name: "Right leaves multiline code without a space", source: "Before\n\n```\nfirst\nsecond\n```\n" },
      { name: "Right leaves empty code without a space", source: "```\n\n```\n" },
      { name: "Right leaves a rule without a space", source: "---\n" },
      { name: "Enter leaves code without a space", source: "```\ncode\n```\n", key: Qt.Key_Return },
      { name: "Enter leaves an empty code block from its only line", source: "```\n\n```\n",
        key: Qt.Key_Return, direct: true }
    ]
    for (var k = 0; k < escapes.length; k++) {
      try {
        escapeBlock(escapes[k])
        test.checked(escapes[k].name, true, "")
      } catch (error) {
        test.checked(escapes[k].name, false, error.message)
      }
    }
    var code = "```\ncode\n```\n"
    var pastes = [
      { name: "paste lands as code and the block still leaves", source: code,
        html: "<span style=\"font-family:'Nimbus Sans';\">function void test() {</span>",
        text: "function void test() {", expected: "```\ncodefunction void test() {\n```\n", caret: 26, leave: true },
      { name: "paste of several lines adds code lines", source: code,
        html: "<p>function void test() {</p><p>}</p>", text: "function void test() {\n}",
        expected: "```\ncodefunction void test() {\n}\n```\n", caret: 28, leave: true },
      { name: "plain paste lands as code", source: code, plain: true, text: "a\nb",
        expected: "```\ncodea\nb\n```\n", caret: 7 },
      { name: "paste replaces the selection", source: code, selectBack: 2, text: "X",
        expected: "```\ncoX\n```\n", caret: 3 },
      { name: "paste into an empty code line", source: "```\n\n```\n", text: "x",
        expected: "```\nx\n```\n", caret: 2 },
      { name: "paste in prose is Qt's own", source: "para\n", html: "<b>bold</b>", text: "bold",
        expected: "para**bold**\n", caret: 8 }
    ]
    for (var p = 0; p < pastes.length; p++) {
      try {
        pasteIntoCode(pastes[p])
        test.checked(pastes[p].name, true, "")
      } catch (error) {
        test.checked(pastes[p].name, false, error.message)
      }
    }
    try {
      retypeCodeLine()
      test.checked("retyping an emptied code line keeps it code", true, "")
    } catch (error) {
      test.checked("retyping an emptied code line keeps it code", false, error.message)
    }
    try {
      formatInCode()
      test.checked("the inline tools type their Markdown inside a code block", true, "")
    } catch (error) {
      test.checked("the inline tools type their Markdown inside a code block", false, error.message)
    }
    try {
      typeAfterRule()
      test.checked("typing on a rule creates one undo step", true, "")
    } catch (error) {
      test.checked("typing on a rule creates one undo step", false, error.message)
    }
    var ordered = "1. **one**\n2. two\n"
    var listHtml = "<ol><li><b>one</b></li><li>two</li></ol>"
    var deletions = [
      { name: "Delete before a blank filler preserves numbering", source: "\u00a0\n\n" + ordered, expected: ordered },
      { name: "Delete after a blank filler preserves numbering", source: "\u00a0\n\n" + ordered, cursor: 1, expected: ordered },
      { name: "Delete an empty heading preserves list text styles",
        html: '<h1 style="-qt-paragraph-type:empty;"><br /></h1>' + listHtml, expected: ordered },
      { name: "Delete a heading filler preserves list text styles",
        html: '<h1><span style="font-size:xx-large; font-weight:700;">\u00a0</span></h1>' + listHtml,
        cursor: 1, expected: ordered },
      { name: "Delete before a single-item list preserves its marker",
        source: "\u00a0\n\n1. one\n", expected: "1. one\n" },
      { name: "Delete before a bullet list preserves its markers",
        source: "\u00a0\n\n- one\n- two\n", expected: "- one\n- two\n" },
      { name: "Delete before a checklist preserves check states",
        source: "\u00a0\n\n- [x] one\n- [ ] two\n", expected: "- [x] one\n- [ ] two\n" },
      { name: "Delete before a numbered list preserves its start",
        html: '<p>\u00a0</p><ol start="7"><li>one</li><li>two</li></ol>', expected: "7. one\n8. two\n" },
      { name: "Delete before a list preserves nested code",
        source: "\u00a0\n\n1. Run\n\n   ```\n   command\n   ```\n2. Done\n",
        expected: "1. Run\n\n   ```\n   command\n   ```\n2. Done\n" },
      { name: "keyboard undo replays list formatting without edits", source: "Lead\n\n" + ordered, cursor: 4 },
      { name: "API undo replays list formatting without edits", source: "Lead\n\n" + ordered, cursor: 4, api: true }
    ]
    for (var d = 0; d < deletions.length; d++) {
      try {
        deleteParagraph(deletions[d])
        test.checked(deletions[d].name, true, "")
      } catch (error) {
        test.checked(deletions[d].name, false, error.message)
      }
    }
    test.finished()
  }

  Timer {
    interval: 100
    running: true
    onTriggered: {
      if (test.runKeys) {
        test.run()
      } else {
        test.finished()
      }
    }
  }
}
