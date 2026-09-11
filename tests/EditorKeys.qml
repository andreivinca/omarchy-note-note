import QtQuick
import QtTest
import Quickshell
import "../ui" as Ui
import "../ui/editing/ToolbarSettings.js" as ToolbarSettings
import "../ui/editing/Calendar.js" as Calendar
import "../services/markdown" as Markdown
import "../services/notes" as Notes

// Real keys and the real converter, in the transition runner's isolated
// offscreen window. The optional desktop host check keeps this window shut.
Window {
  id: test
  property bool runKeys: true
  property var openedLinks: []
  property int editSignals: 0
  signal checked(string name, bool ok, string detail)
  signal finished()
  visible: runKeys
  width: 800
  height: 700

  Markdown.Markdown { id: converter }
  FontLoader { id: noteFont; source: "../assets/fonts/ia-writer-mono-s/iAWriterMonoS-Regular.ttf" }
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
    width: parent.width
    height: parent.height - viewBar.height
    hasNote: true
    markdown: converter
    clipboard: clip
    noteFontFamily: noteFont.name
    toolDirectory: Quickshell.env("NOTE_NOTE_TEST_TOOLS") || Qt.resolvedUrl("../ui/tools")
    onLinkOpenRequested: function(url) { test.openedLinks.push(url) }
    onEdited: test.editSignals++
  }
  Ui.ViewBar {
    id: viewBar
    anchors.bottom: parent.bottom
    width: parent.width
    sourceName: "Local"
    crumb: "Test notebook"
    storage: "links.md"
    statusText: "Saved"
    wordCount: editor.wordCount
    countVisible: true
    hoveredLink: editor.hoveredLink
  }
  TestCase { id: keys; name: "editor keys"; when: false }

  QtObject {
    id: mergeProvider
    property string name: "OneNote"
    property var saves: []
    function load(path, callback) {
      callback({ title: "Groceries", body: "original\n" })
    }
    function save(path, title, body, callback, options) {
      saves.push({ body: body, callback: callback, options: options })
    }
    function noteEdited(path) {}
  }
  Notes.NoteSession {
    id: mergeSession
    editor: editor
    providerFor: function(path) { return mergeProvider }
    versionFor: function(path) { return "1" }
    report: function(message) {}
  }

  function mergeSave() {
    keys.tryVerify(function() { return mergeProvider.saves.length > 0 }, 3000)
    require(mergeProvider.saves.length > 0, "conflict action did not request a save")
    return mergeProvider.saves.shift()
  }

  function conflictControl(name) {
    var control = keys.findChild(editor, name)
    require(control !== null, "missing conflict control: " + name)
    return control
  }

  function conflictPanel() {
    var conflict = { id: "first", parts: [
      { id: "body:0", field: "body", base: "original", local: "ours", remote: "theirs" }
    ] }
    mergeSession.selectPath("test:merge")
    keys.tryVerify(function() { return !mergeSession.loadingNote }, 3000)
    editor.restoreDocument({ title: "Groceries", body: "<p>ours</p>", base: "" })
    mergeSession.onEdited()
    mergeSession.flushSave()
    mergeSave().callback({ error: "conflict", conflict: conflict })
    keys.wait(50)
    var panel = conflictControl("mergeConflict")
    require(panel.conflict.id === "first", "editor opened the conflict without its data")
    ;["base", "local", "remote"].forEach(function(side) {
      var passage = conflictControl("conflict-body:0-" + side)
      require(passage.text === conflict.parts[0][side] && passage.width > 0 && passage.height > 0,
              side + " passage is not displayed")
    })
    require(!conflictControl("resolveConflict").enabled, "save enabled before making a choice")
    keys.mouseClick(conflictControl("continueEditing"))
    require(!editor.showingNotice && !editor.readOnly && mergeSession.dirty && editor.plainText() === "ours",
            "Continue editing did not return to the retained draft")

    mergeSession.flushSave()
    mergeSave().callback({ error: "conflict", conflict: conflict })
    keys.wait(50)
    keys.mouseClick(conflictControl("retryMerge"))
    var retry = mergeSave()
    require(!retry.options.resolution && retry.body.trim() === "ours", "retry used a resolution or lost the draft")
    retry.callback({ error: "conflict", conflict: conflict })
    keys.wait(50)
    keys.mouseClick(conflictControl("choose-body:0-both"))
    require(conflictControl("resolveConflict").enabled, "choosing a version did not enable save")

    var latest = { id: "latest", parts: [
      { id: "body:0", field: "body", base: "original", local: "ours", remote: "latest remote" }
    ] }
    mergeSession.showConflict("test:merge", latest)
    keys.wait(50)
    require(conflictControl("mergeConflict").conflict.id === "latest" &&
            conflictControl("conflict-body:0-remote").text === "latest remote" &&
            !conflictControl("resolveConflict").enabled,
            "reopening the same view retained stale content or choices")
    keys.mouseClick(conflictControl("choose-body:0-both"))
    keys.mouseClick(conflictControl("resolveConflict"))
    var resolved = mergeSave()
    require(resolved.options.resolution.id === "latest" &&
            resolved.options.resolution.choices["body:0"] === "both", "save did not submit the displayed resolution")
    resolved.callback({})
    require(!editor.showingNotice && !editor.readOnly && !mergeSession.dirty && !mergeSession.busy,
            "resolved save did not release the conflict")
  }

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
    // A native row starts with genuinely empty cells; imported Markdown
    // cells may carry the dialect's filler. Both must put the caret first.
    require(tail.replace(/\u00a0/g, "") === Array(data.columns).fill("").join("\uFDD0"),
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
    editor.tool("bold")
    require(read() === wrapped("**"), "bold did not type its stars: " + JSON.stringify(read()))
    editor.tool("bold")
    require(read() === source, "bold again did not take the stars off: " + JSON.stringify(read()))
    editor.tool("highlight")
    require(read() === wrapped("=="), "highlight did not type its marks: " + JSON.stringify(read()))
    editor.tool("highlight")
    editor.tool("code")
    require(read() === wrapped("`"), "inline code did not type its backticks: " + JSON.stringify(read()))
    editor.tool("code")
    require(editor.documentHtml() === original, "the toggles did not leave the block as it was")
    editor.setCursorPosition(code + 4)
    editor.tool("italic")
    keys.keyClick(Qt.Key_X)
    require(read() === source.replace("code", "code*x*"), "typing did not land between the pair: " + JSON.stringify(read()))
    editor.setCursorPosition(editor.plainText().length)
    for (var i = 0; i < editor.plainText().length; i++) {
      keys.keyClick(Qt.Key_Left, Qt.ShiftModifier)
    }
    var across = editor.documentHtml()
    editor.tool("bold")
    editor.tool("highlight")
    editor.tool("code")
    editor.tool("link")
    require(!editor.tools.find("link").panelOpen, "the link bar opened on a selection across the block")
    require(editor.documentHtml() === across, "a tool changed a selection across the block")
    load({ source: source })
    selectCode()
    editor.tool("link")
    require(editor.tools.find("link").panelOpen, "the link bar did not open inside the code block")
    editor.tools.find("link").submit()
    require(read() === source.replace("code", "[code](https://)"), "the link bar did not type the link: " + JSON.stringify(read()))
  }

  // From the title, Down lands the caret on the body's first line, and a
  // reload in place puts the caret and the scroll back where they were.
  function titleDownAndViewState() {
    var lines = []
    for (var i = 0; i < 80; i++) {
      lines.push("line " + i)
    }
    load({ source: lines.join("\n\n") + "\n" })
    editor.setCursorPosition(editor.plainText().length)
    var state = editor.viewState()
    require(state.cursor === editor.plainText().length && state.scroll > 0, "the caret at the end did not scroll the view")
    editor.focusTitle()
    keys.keyClick(Qt.Key_Down)
    require(editor.bodyFocused, "Down in the title did not focus the body")
    require(editor.cursorPosition() === 0, "Down in the title did not land on the first line: " + editor.cursorPosition())
    require(editor.viewState().scroll === 0, "the first line is not in view")
    editor.restoreViewState(state)
    var back = editor.viewState()
    require(back.cursor === state.cursor && back.scroll === state.scroll,
            "the view state did not come back: " + JSON.stringify(back) + " vs " + JSON.stringify(state))
  }

  // The session's own sequence — read-only while a note loads, released
  // once it is shown — leaves a long note at its top: Qt's readOnly
  // toggle would put the caret at the end and scroll the view after it.
  function releasedAtTop() {
    var lines = []
    for (var i = 0; i < 80; i++) {
      lines.push("line " + i)
    }
    editor.readOnly = true
    editor.setNote("", "")
    var shown = false
    editor.setNote("Long", lines.join("\n\n") + "\n", function(ok) {
      editor.readOnly = false
      shown = ok
    })
    keys.tryVerify(function() { return shown }, 3000)
    keys.wait(100)
    var view = editor.viewState()
    require(view.cursor === 0 && view.scroll === 0, "the released note is not at its top: " + JSON.stringify(view))
    // The caret stays through a toggle; the scroll may settle by the
    // toolbar's height, which leaves the pane while the note is read-only.
    editor.setCursorPosition(editor.plainText().length)
    editor.readOnly = true
    editor.readOnly = false
    require(editor.cursorPosition() === editor.plainText().length, "a read-only toggle moved the caret")
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

  function links() {
    var destination = "https://example.com/path?q=notes&lang=en#section"
    load({ source: "Before [Example link](" + destination + ") after\n" })
    test.openedLinks = []
    var body = keys.findChild(editor, "noteBody")
    var preview = keys.findChild(viewBar, "linkPreview")
    var start = body.positionToRectangle(9)
    var x = start.x + 2, y = start.y + start.height / 2
    var original = editor.documentHtml()
    keys.mouseMove(body, x, y)
    keys.wait(50)
    require(editor.hoveredLink === destination, "hover did not find the link: " + editor.hoveredLink)
    require(preview.visible && preview.text === destination, "the view bar did not show the hovered URL")
    require(test.openedLinks.length === 0, "hovering opened the link")
    keys.mouseClick(body, x, y)
    require(test.openedLinks.length === 1 && test.openedLinks[0] === destination, "a click did not request the exact URL once")
    require(editor.documentHtml() === original, "opening the link changed the note")

    keys.mouseMove(viewBar, 5, 5)
    keys.wait(50)
    require(editor.hoveredLink === "", "leaving the link kept the hovered URL")
    require(!preview.visible, "the view bar did not restore its note details after leaving the link")
    body.deselect()
    var end = body.positionToRectangle(17)
    keys.mouseDrag(body, x, y, end.x - x, 0, Qt.LeftButton)
    require(body.selectedText.length > 0 && test.openedLinks.length === 1, "dragging text opened the link or failed to select")
    require(editor.documentHtml() === original, "selecting the link changed the note")

    editor.readOnly = true
    keys.wait(50)
    keys.mouseClick(body, x, y)
    require(test.openedLinks.length === 2, "a read-only link could not be opened")
    editor.readOnly = false
    load({ source: "No links here\n" })
    keys.wait(50)
    require(editor.hoveredLink === "", "changing notes kept the hovered URL: " + editor.hoveredLink)
    require(!preview.visible, "changing notes left a stale URL in the view bar")
  }

  function typeText(text) {
    for (var i = 0; i < text.length; i++) {
      keys.keyClick(text.charAt(i))
    }
  }

  function linkInheritance() {
    load({ source: "- [First item](https://example.com/first)\n" })
    editor.setCursorPosition(editor.plainText().length)
    keys.keyClick(Qt.Key_Return)
    typeText("Next item")
    require(read() === "- [First item](https://example.com/first)\n- Next item\n",
            "the new list item inherited the previous link: " + read())
  }

  function typedLinks() {
    load({ source: "- [First item](https://example.com/first)\n" })
    editor.setCursorPosition(editor.plainText().length)
    keys.keyClick(Qt.Key_Return)
    var url = "https://example.org/second?q=one&n=2"
    typeText(url)
    var expected = "- [First item](https://example.com/first)\n- " + url + "\n"
    require(read() === expected, "a typed URL did not acquire its own target: " + read())
    var body = keys.findChild(editor, "noteBody")
    var position = body.positionToRectangle(body.length - 4)
    test.openedLinks = []
    keys.mouseMove(body, position.x + 2, position.y + position.height / 2)
    keys.wait(50)
    require(editor.hoveredLink === url, "the typed link's preview used an old target")
    var start = body.positionToRectangle(body.length - url.length + 2)
    keys.mouseDrag(body, start.x + 2, start.y + start.height / 2, position.x - start.x, 0, Qt.LeftButton)
    require(body.selectedText.length > 0 && test.openedLinks.length === 0,
            "selecting an automatic URL opened it or failed to select text")
    body.deselect()
    keys.mouseClick(body, position.x + 2, position.y + position.height / 2)
    require(test.openedLinks.length === 1 && test.openedLinks[0] === url, "the typed URL opened an old target")
    require(editor.bodyFocused, "clicking the URL took keyboard focus away from the editor")
    editor.setCursorPosition(body.length)
    typeText(" extra")
    require(read() === expected.replace(/\n$/, "") + " extra\n", "text after the URL stayed linked: " + read())
    keys.keyClick(Qt.Key_Return)
    typeText("www.example.net")
    position = body.positionToRectangle(body.length - 3)
    keys.mouseMove(body, position.x + 2, position.y + position.height / 2)
    keys.wait(50)
    require(editor.hoveredLink === "https://www.example.net", "a www address was not linked")

    load({ source: "https://example.com/path\n" })
    require(!body.canUndo, "loading URL formatting created an undo step")
    editor.setCursorPosition(body.length)
    typeText("x")
    require(read() === "https://example.com/pathx\n", "extending a loaded URL changed its text: " + read())
    position = body.positionToRectangle(body.length - 3)
    keys.mouseMove(body, position.x + 2, position.y + position.height / 2)
    keys.wait(50)
    require(editor.hoveredLink === "https://example.com/pathx", "extending a loaded URL kept its old target")
    editor.undo()
    require(read() === "https://example.com/path\n" && editor.hoveredLink === "https://example.com/path",
            "undo did not restore URL text and target together: " + read())
    editor.redo()
    require(read() === "https://example.com/pathx\n" && editor.hoveredLink === "https://example.com/pathx",
            "redo did not restore URL text and target together")
    keys.keyClick(Qt.Key_Home)
    keys.keyClick(Qt.Key_Delete)
    require(read() === "ttps://example.com/pathx\n", "an invalidated URL remained linked: " + read())
    require(editor.hoveredLink === "", "an invalidated URL kept its destination")
  }

  function linkBoundaries() {
    load({ source: "" })
    typeText("See (https://example.com/a(b)). Next")
    var body = keys.findChild(editor, "noteBody")
    var position = body.positionToRectangle(15)
    keys.mouseMove(body, position.x + 2, position.y + position.height / 2)
    keys.wait(50)
    require(editor.hoveredLink === "https://example.com/a(b)", "URL punctuation was included in the destination")
    require(read() === "See (https://example.com/a(b)). Next\n", "URL detection rewrote punctuation: " + read())
    load({ source: "```\n\n```\n" })
    editor.setCursorPosition(editor.plainText().length)
    typeText("https://example.com")
    require(read() === "```\nhttps://example.com\n```\n", "code block URLs became links")
    position = body.positionToRectangle(body.length - 3)
    keys.mouseMove(body, position.x + 2, position.y + position.height / 2)
    keys.wait(50)
    require(editor.hoveredLink === "", "a code block URL was made clickable")
    load({ source: "`https://example.com`\n" })
    require(read() === "`https://example.com`\n", "inline code URLs became links")
    position = body.positionToRectangle(5)
    keys.mouseMove(body, position.x + 2, position.y + position.height / 2)
    keys.wait(50)
    require(editor.hoveredLink === "", "an inline code URL was made clickable")
    load({ source: "[Different label](https://example.com)\n" })
    editor.setCursorPosition(5)
    typeText("x")
    require(read() === "[Diffexrent label](https://example.com)\n", "editing a named link changed its destination")
  }

  function plainLinks() {
    editor.plain = true
    try {
      editor.setNote("", "https://example.com")
      editor.focusEditor()
      editor.setCursorPosition(editor.plainText().length)
      typeText("/new")
      var body = keys.findChild(editor, "noteBody")
      var position = body.positionToRectangle(10)
      keys.mouseMove(body, position.x + 2, position.y + position.height / 2)
      keys.wait(50)
      require(editor.hoveredLink === "https://example.com/new",
              "a plain-text URL was not detected: " + editor.hoveredLink)
      require(editor.plainText() === "https://example.com/new", "URL detection added markup to a plain note")
    } finally {
      editor.plain = false
    }
  }

  function linkCaretEditing() {
    load({ source: "google.com\n" })
    var body = keys.findChild(editor, "noteBody")
    var before = body.positionToRectangle(body.length - 1)
    var after = body.positionToRectangle(body.length)
    var lastCharacterWidth = after.x - before.x

    var url = "http://google.com"
    load({ source: url + "\n" })
    keys.wait(50)
    before = body.positionToRectangle(body.length - 1)
    after = body.positionToRectangle(body.length)
    require(Math.abs(after.x - before.x - lastCharacterWidth) < 0.1,
            "URL highlighting enlarged the last character's cursor step")
    keys.mouseClick(body, after.x, after.y + after.height / 2)
    require(editor.cursorPosition() === url.length, "the caret could not be placed directly after the URL")
    keys.keyClick(Qt.Key_Delete)
    require(editor.plainText() === url, "Delete after the URL removed its last character")
    keys.keyClick(Qt.Key_Backspace)
    require(editor.plainText() === "http://google.co", "Backspace after the URL did not remove just the last character")
    editor.undo()
    require(editor.plainText() === url, "undo did not restore the last URL character")
    typeText("/path")
    require(editor.plainText() === url + "/path", "typing at the URL's end did not extend it normally")
    typeText(" more")
    require(read() === url + "/path more\n", "typing a space after the URL did not start ordinary text")
  }

  function linkPresentation() {
    var url = "https://example.com/path"
    var source = "See " + url + ", then carry on.\n"
    test.editSignals = 0
    load({ source: source })
    var body = keys.findChild(editor, "noteBody")
    keys.wait(50)
    require(test.editSignals === 0, "displaying a URL marked the note as edited")
    require(read() === source, "URL highlighting changed Markdown")
    body.select(4, 4 + url.length)
    require(body.selectedText === url, "URL highlighting changed selected text")
    keys.keyClick(Qt.Key_Delete)
    keys.wait(50)
    require(read() === "See , then carry on.\n", "deleting a URL removed surrounding text")
    editor.undo()
    require(read() === source, "undo did not restore the URL as plain Markdown text")

    var longUrl = "https://example.com/" + "path/".repeat(40)
    load({ source: longUrl + "\n" })
    keys.mouseMove(viewBar, 5, 5)
    editor.setCursorPosition(body.length)
    var point = body.positionToRectangle(body.length - 3)
    test.openedLinks = []
    keys.mouseClick(body, point.x + 2, point.y + point.height / 2)
    require(test.openedLinks.length === 1 && test.openedLinks[0] === longUrl,
            "clicking a wrapped URL did not open its complete destination")
    require(read() === longUrl + "\n", "highlighting a wrapped URL changed its text")

    var linked = "[https://example.com](https://example.com)\n"
    load({ source: linked })
    require(read() === linked, "an existing Markdown link was rewritten")

    var table = "| first | second |\n|---|---|\n| cell | " + url + " |\n"
    load({ source: table })
    point = body.positionToRectangle(body.getText(0, body.length).indexOf(url) + 10)
    test.openedLinks = []
    keys.mouseClick(body, point.x + 2, point.y + point.height / 2)
    require(test.openedLinks.length === 1 && test.openedLinks[0] === url,
            "clicking a URL in a table did not open its destination")
    require(read() === table, "highlighting a table URL changed the Markdown")
  }

  function selectText(text) {
    var start = editor.plainText().indexOf(text)
    require(start >= 0, "selection text not found: " + text)
    editor.setCursorPosition(start + text.length)
    for (var i = 0; i < text.length; i++) {
      keys.keyClick(Qt.Key_Left, Qt.ShiftModifier)
    }
  }

  function toolRoundTrip(data) {
    load({ source: data.source || "word\n" })
    if (data.select) {
      selectText(data.select)
    }
    if (data.cursorText) {
      editor.setCursorPosition(editor.plainText().indexOf(data.cursorText))
    }
    editor.updateInTable()
    editor.updateInList()
    var before = editor.documentHtml()
    var markdown = savedMarkdown()
    require(editor.tool(data.id), "tool was not executable")
    keys.tryVerify(function() { return editor.documentHtml() !== before }, 3000)
    require(savedMarkdown() === data.expected, "unexpected Markdown: " + JSON.stringify(savedMarkdown()))
    editor.undo()
    require(savedMarkdown() === markdown, "one undo did not restore the original note: " + JSON.stringify(savedMarkdown()))
    editor.redo()
    require(savedMarkdown() === data.expected, "redo changed the tool result")
  }

  function savedMarkdown() {
    var result = null
    editor.requestMarkdown(function(markdown, ok) {
      result = { markdown: markdown, ok: ok }
    })
    keys.tryVerify(function() { return result !== null }, 3000)
    require(result && result.ok, "note could not be serialized for saving")
    return result.markdown
  }

  function textColorTool() {
    load({ source: "- [x] **Mushrooms**\n- [ ] Milk\n" })
    selectText("Mushrooms")
    var tool = editor.tools.find("textColor")
    var original = savedMarkdown()
    var button = keys.findChild(editor, "editingTool-textColor")
    require(button && button.visible, "text color button missing")
    keys.mouseClick(button)
    keys.tryVerify(function() { return tool.panelOpen }, 1000)
    var holder = keys.findChild(editor, "editingPopupHolder-textColor")
    var popup = Array.from(holder.data).find(function(object) {
      return object.objectName === "editingPopup-textColor"
    })
    keys.tryVerify(function() { return popup && popup.opened }, 1000)
    var swatch = keys.findChild(popup.contentItem, "textColor-7")
    keys.tryVerify(function() { return swatch && swatch.visible }, 1000)
    require(swatch && swatch.visible, "palette did not open: " + swatch)
    keys.mouseClick(swatch)
    var colored = '- [x] <span style="color:#3dadff;">**Mushrooms**</span>\n- [ ] Milk\n'
    require(savedMarkdown() === colored, "color did not preserve the checklist and bold: " + savedMarkdown())
    editor.undo()
    require(savedMarkdown() === original, "color was not one undo step")
    editor.redo()
    require(savedMarkdown() === colored, "color redo failed")
    load({ source: colored })
    selectText("Mushrooms")
    editor.tool("textColor")
    keys.tryVerify(function() { return popup.opened }, 1000)
    var reset = keys.findChild(popup.contentItem, "textColor-reset")
    keys.waitForRendering(reset)
    keys.mouseClick(reset, reset.width / 2, reset.height / 2)
    require(savedMarkdown() === original, "reset removed other formatting: " + savedMarkdown())
    editor.undo()
    require(savedMarkdown() === colored, "reset was not one undo step")
    editor.redo()
    require(savedMarkdown() === original, "reset redo failed")

    load({ source: "start \n" })
    editor.setCursorPosition(editor.plainText().length)
    var beforeTyping = editor.plainText()
    editor.tool("textColor")
    tool.choose("#ff0000")
    keys.keyClick(Qt.Key_R)
    require(savedMarkdown().indexOf('<span style="color:#ff0000;">r</span>') >= 0,
            "color did not apply to newly typed text: " + savedMarkdown())
    editor.undo()
    require(editor.plainText() === beforeTyping, "typing color needs more than one undo: " + editor.plainText())
    require(savedMarkdown().indexOf("<span") < 0, "undo left colored typing behind")
    editor.redo()
    editor.tool("textColor")
    tool.choose("")
    keys.keyClick(Qt.Key_X)
    require(savedMarkdown().indexOf('</span>x') >= 0, "reset did not clear pending color: " + savedMarkdown())

    load({ source: "word\n" })
    selectText("word")
    editor.tool("textColor")
    editor.setCursorPosition(0)
    require(!tool.choose("#ff0000"), "a stale selection accepted color")
    require(savedMarkdown() === "word\n", "stale palette changed the document")
    editor.enabledTools = ["bold"]
    require(!editor.tool("textColor"), "unsupported provider accepted color")
    editor.enabledTools = null
    load({ source: "```\ncode\n```\n" })
    require(!editor.tool("textColor"), "color was offered in a code block")
  }

  function toolPermissions() {
    load({ source: "word\n" })
    selectText("word")
    editor.enabledTools = ["italic", "h2"]
    var before = editor.documentHtml()
    require(!editor.tool("bold"), "disabled tool ran through command dispatch")
    keys.keyClick(Qt.Key_B, Qt.ControlModifier)
    require(editor.documentHtml() === before, "disabled shortcut reached native formatting")
    require(editor.tools.toolbarTools.filter(function(tool) {
      return /^h[123]$/.test(tool.toolId)
    }).map(function(tool) { return tool.toolId }).join(",") === "h2", "provider heading restrictions were lost: " + editor.tools.toolbarTools.map(function(tool) { return tool.toolId }))
    var button = keys.findChild(editor, "editingTool-bold")
    require(!button || !button.visible, "disabled toolbar button remained visible")
    keys.keyClick(Qt.Key_I, Qt.ControlModifier)
    require(read() === "*word*\n", "enabled shortcut did not execute its tool")
    editor.readOnly = true
    before = editor.documentHtml()
    require(!editor.tool("italic"), "read-only command ran")
    keys.keyClick(Qt.Key_I, Qt.ControlModifier)
    require(editor.documentHtml() === before, "read-only shortcut changed the note")
    editor.readOnly = false
    editor.plain = true
    require(!editor.tool("italic"), "formatting ran on plain text")
    editor.plain = false
    editor.hasNote = false
    require(!editor.tool("italic"), "formatting ran without a note")
    editor.hasNote = true
    editor.showNotice("Notice", "No document here")
    require(!editor.tool("italic"), "formatting ran behind a notice")
    editor.clearNotice()
    require(!editor.tool("missing-tool"), "unknown tool was reported as successful")
  }

  function toolDiscovery() {
    load({ source: "word\n" })
    require(editor.tools.find("greeting") !== null, "new file was not discovered")
    selectText("word")
    var button = keys.findChild(editor, "editingTool-greeting")
    require(button && button.visible, "new file did not get a toolbar button")
    keys.mouseClick(button, button.width / 2, button.height / 2)
    require(read() === "Hello\n", "discovered button did not run its action")
    editor.undo()
    require(read() === "word\n", "extension edit was not one undo step")
    editor.focusEditor()
    selectText("word")
    keys.keyClick(Qt.Key_G, Qt.ControlModifier | Qt.ShiftModifier)
    require(read() === "Hello\n", "new file did not get its shortcut")
    require(editor.tools.shortcutActions.some(function(action) {
      return action.label === "ctrl+shift+g" && action.description === "Insert greeting"
    }), "new shortcut was missing from help")
  }

  function toolLinkPanel() {
    load({ source: "word\n" })
    selectText("word")
    var link = editor.tools.find("link")
    editor.tool("link")
    keys.wait(20)
    require(link.panelOpen && keys.findChild(editor, "linkUrl"), "tool-owned panel was not loaded")
    link.linkUrl = "https://example.com/?a=1&b=2"
    link.linkText = "A&B <word>"
    require(link.editor.current(link.panelContext), "link context changed while opening panel: " + JSON.stringify(link.panelContext) + " -> " + JSON.stringify(editor.editContext()))
    var insert = keys.findChild(editor, "insertLink")
    keys.mouseMove(insert, insert.width / 2, insert.height / 2)
    keys.waitForRendering(insert)
    keys.mouseClick(insert, insert.width / 2, insert.height / 2)
    require(read() === "[A&B \\<word>](https://example.com/?a=1&b=2)\n", "link text or URL was not escaped correctly: " + JSON.stringify(read()))
    editor.undo()
    require(read() === "word\n", "link insertion was not one undo step")
    selectText("word")
    editor.tool("link")
    load({ source: "different note\n" })
    require(!link.panelOpen, "link panel survived a note change")
    link.submit()
    require(read() === "different note\n", "old link panel changed the new note")
    editor.tool("link")
    editor.setCursorPosition(3)
    link.submit()
    require(read() === "different note\n", "link panel used a different selection")
    editor.tool("link")
    editor.enabledTools = []
    require(!link.panelOpen, "link panel survived losing provider support")
  }

  function toolRegistryValidation() {
    var original = editor.toolDirectory
    try {
      editor.toolDirectory = Quickshell.env("NOTE_NOTE_TEST_INVALID_TOOLS")
      keys.tryVerify(function() { return editor.tools.find("okay") !== null }, 3000)
      require(editor.tools.ready && editor.tools.tools.length === 1,
              "invalid definitions prevented a valid tool from loading")
      require(editor.tools.errors.length === 6, "invalid tool diagnostics were incomplete: " + editor.tools.errors)
      require(editor.tools.find("duplicate") === null, "a duplicate id won by discovery order")
      require(editor.tools.find("reserved") === null, "a tool took an app shortcut")
      require(editor.tools.find("undo") === null, "a tool took the editor's undo shortcut")
      require(editor.tools.find("menuShortcut") === null, "a dropdown took an executable shortcut")
    } finally {
      editor.toolDirectory = original
      keys.tryVerify(function() { return editor.tools.find("greeting") !== null }, 3000)
    }
    require(editor.tools.errors.length === 0, "reloading a valid directory retained old diagnostics")
  }

  function toolMenuAndTyping() {
    load({ source: "word\n" })
    editor.enabledTools = ["h2", "bold"]
    editor.toolbarLayout = [[{ dropdown: "insert", items: ["h1", "h2", "h3"] }], ["bold"]]
    require(editor.tools.menuTools("insert").map(function(tool) {
      return tool.toolId
    }).join(",") === "h2", "menu ignored provider capabilities")
    var button = keys.findChild(editor, "editingTool-insert")
    keys.waitForRendering(button)
    keys.mouseClick(button, button.width / 2, button.height / 2)
    keys.wait(20)
    var popup = Array.from(button.data).find(function(object) {
      return object.objectName === "editingPopup-insert"
    })
    require(popup && popup.opened, "Insert menu did not open")
    var row = keys.findChild(popup.contentItem, "editingMenu-h2")
    require(row && row.visible && row.width > 50, "discovered menu action has no usable row: "
            + (row ? JSON.stringify({ visible: row.visible, width: row.width }) : "missing"))
    var before = editor.documentHtml()
    keys.mouseClick(row, row.width / 2, row.height / 2)
    keys.tryVerify(function() { return editor.documentHtml() !== before }, 3000)
    require(read() === "## word\n", "menu action did not dispatch its heading tool")
    keys.mouseClick(button, button.width / 2, button.height / 2)
    keys.tryVerify(function() { return popup.opened }, 3000)
    editor.enabledTools = ["bold"]
    require(!button.enabled && !popup.opened, "dropdown remained open after losing all supported members")
    load({ source: "word\n" })
    editor.setCursorPosition(4)
    keys.keyClick(Qt.Key_B, Qt.ControlModifier)
    keys.keyClick(Qt.Key_X)
    require(read() === "word**x**\n", "pending formatting did not follow typing")
    keys.keyClick(Qt.Key_Left)
    keys.keyClick(Qt.Key_Left)
    keys.keyClick(Qt.Key_Y)
    require(read() === "woryd**x**\n", "moving the caret did not end pending formatting")
  }

  function toolLayout() {
    load({ source: "word\n" })
    require(editor.tools.menuTools("insert").map(function(tool) {
      return tool.toolId
    }).join(",") === "insertMonth", "default Insert menu does not group the month tools")
    require(editor.tools.menuTools("insertMonth").map(function(tool) {
      return tool.toolId
    }).join(",") === "currentMonth,nextMonth,customMonth", "Insert month does not contain the calendar tools in order")
    require(editor.tools.topLevelTools.length === editor.tools.tools.length - 4,
            "default layout should keep other tools directly on the toolbar")
    editor.toolbarLayout = [[{ dropdown: "insert", items: [] }]]
    var insert = keys.findChild(editor, "editingTool-insert")
    require(insert && insert.visible && !insert.enabled, "empty Insert should be visible and disabled")
    var originalBold = editor.tools.find("bold")
    var before = editor.documentHtml()
    editor.toolbarLayout = [["italic", "bold"], [{ dropdown: "insert", items: ["greeting", "table", "link"] }], ["h2"]]
    require(editor.tools.find("bold") === originalBold, "layout change recreated action instances")
    require(editor.documentHtml() === before, "layout change altered the document")
    require(editor.tools.topLevelTools.slice(0, 4).map(function(tool) {
      return tool.toolId
    }).join(",") === "italic,bold,insert,h2", "configured order did not reach the toolbar")
    require(editor.tools.groupFor("italic") === editor.tools.groupFor("bold")
            && editor.tools.groupFor("bold") !== editor.tools.groupFor("insert"), "configured grouping was lost")
    require(editor.tools.menuTools("insert").map(function(tool) {
      return tool.toolId
    }).join(",") === "greeting,table,link", "dropdown order was lost")
    require(!keys.findChild(editor, "editingTool-greeting"), "dropdown member also appears directly")
    var italic = keys.findChild(editor, "editingTool-italic")
    var bold = keys.findChild(editor, "editingTool-bold")
    keys.waitForRendering(bold)
    require(italic.mapToItem(editor, 0, 0).x < bold.mapToItem(editor, 0, 0).x,
            "visible buttons did not follow the configured order")
    selectText("word")
    keys.mouseClick(bold, bold.width / 2, bold.height / 2)
    require(read() === "**word**\n", "reordered button did not execute")
    editor.undo()
    selectText("word")
    keys.keyClick(Qt.Key_G, Qt.ControlModifier | Qt.ShiftModifier)
    require(read() === "Hello\n", "moving an extension into a dropdown broke its shortcut")
    editor.undo()
    selectText("word")
    editor.tool("link")
    require(editor.tools.find("link").panelOpen, "dropdown link tool did not open its panel")
    editor.toolbarLayout = []
    require(!editor.tools.find("link").panelOpen, "layout change left a stale panel open")
    editor.tools.find("link").submit()
    require(read() === "word\n", "stale panel changed the note after rearranging")
    var ids = editor.tools.topLevelTools.map(function(tool) { return tool.toolId })
    require(ids.length === editor.tools.tools.length
            && ids.join(",") === ids.slice().sort(function(a, b) { return a.localeCompare(b) }).join(","),
            "omitted tools did not all appear at the end in ID order")
  }

  function openInsertMenu() {
    var button = keys.findChild(editor, "editingTool-insert")
    require(button && button.enabled, "Insert is unavailable")
    keys.waitForRendering(button)
    keys.mouseClick(button, button.width / 2, button.height / 2)
    var popup = Array.from(button.data).find(function(object) {
      return object.objectName === "editingPopup-insert"
    })
    keys.tryVerify(function() { return popup && popup.opened }, 3000)
    require(popup && popup.opened, "Insert did not open")
    return popup
  }

  function openMonthMenu() {
    var popup = openInsertMenu()
    var row = keys.findChild(popup.contentItem, "editingMenu-insertMonth")
    require(row && row.visible && row.arrow.visible, "Insert month has no submenu arrow")
    require(popup.count === 1, "Insert should contain only the month group by default")
    keys.mouseClick(row, row.width / 2, row.height / 2)
    keys.tryVerify(function() { return row.subMenu.opened }, 3000)
    require(popup.opened && row.subMenu.opened, "month submenu did not open beside Insert")
    return row.subMenu
  }

  function toolSubmenus() {
    load({ source: "word\n" })
    var before = editor.documentHtml()
    var popup = openInsertMenu()
    var group = popup.itemAt(0)
    keys.mouseMove(group, group.width / 2, group.height / 2)
    keys.tryVerify(function() { return group.subMenu.opened }, 3000)
    require(popup.opened && group.subMenu.opened, "hover did not open the child menu")
    var child = group.subMenu
    var first = child.itemAt(0)
    keys.mouseMove(first, first.width / 2, first.height / 2)
    keys.wait(250)
    require(popup.opened && child.opened, "moving into the child closed the parent")
    keys.keyClick(Qt.Key_Left)
    require(popup.opened && !child.opened, "Left did not return to the parent menu")
    keys.keyClick(Qt.Key_Right)
    keys.tryVerify(function() { return child.opened }, 3000)
    require(child.opened, "Right did not reopen the submenu")
    keys.mouseClick(editor, editor.width / 2, editor.height - 30)
    require(!popup.opened && !child.opened, "outside click did not dismiss the menu tree")
    child = openMonthMenu()
    keys.keyClick(Qt.Key_Escape)
    require(!child.opened, "Escape did not close the submenu")
    keys.keyClick(Qt.Key_Escape)
    child = openMonthMenu()
    editor.enabledTools = []
    require(!child.opened && editor.tools.menuTools("insert").length === 0,
            "unsupported descendants left an empty submenu")
    editor.enabledTools = null
    child = openMonthMenu()
    editor.readOnly = true
    require(!child.opened, "submenu stayed open after the note became read-only")
    editor.readOnly = false
    child = openMonthMenu()
    editor.toolbarLayout = [[{ dropdown: "insert", items: ["currentMonth", "customMonth"] }]]
    require(editor.tools.menuTools("insert").map(function(tool) {
      return tool.toolId
    }).join(",") === "currentMonth,customMonth", "existing flat layouts stopped working")
    popup = openInsertMenu()
    require(popup.count === 2 && !popup.itemAt(0).subMenu, "layout change left the old submenu in place")
    popup.close()
    require(editor.documentHtml() === before, "navigating menus changed the document")
  }

  function calendarDates() {
    var cases = [
      { date: [2021, 1, 15], locale: "en_GB", first: 1, offset: 0, days: 28, weeks: 4 },
      { date: [2021, 1, 15], locale: "en_US", first: 0, offset: 1, days: 28, weeks: 5 },
      { date: [2024, 1, 29], locale: "ro_RO", first: 1, offset: 3, days: 29, weeks: 5 },
      { date: [2024, 1, 29], locale: "ar_EG", first: 6, offset: 5, days: 29, weeks: 5 },
      { date: [2026, 2, 8], locale: "en_GB", first: 1, offset: 6, days: 31, weeks: 6 },
      { date: [2026, 10, 1], locale: "en_US", first: 0, offset: 0, days: 30, weeks: 5 },
      { date: [2000, 1, 1], locale: "en_GB", first: 1, offset: 1, days: 29, weeks: 5 },
      { date: [2100, 1, 1], locale: "en_GB", first: 1, offset: 0, days: 28, weeks: 4 },
      { date: [2026, 11, 31], locale: "en_GB", first: 1, offset: 1, days: 31, weeks: 5 },
      { date: [2027, 0, 1], locale: "en_GB", first: 1, offset: 4, days: 31, weeks: 5 },
      { date: [1, 1, 1], locale: "en_GB", first: 1, offset: 3, days: 28, weeks: 5 },
      { date: [4, 1, 1], locale: "en_GB", first: 1, offset: 6, days: 29, weeks: 5 },
      { date: [99, 1, 1], locale: "en_GB", first: 1, offset: 6, days: 28, weeks: 5 },
      { date: [9999, 1, 1], locale: "en_GB", first: 1, offset: 0, days: 28, weeks: 4 }
    ]
    for (var i = 0; i < cases.length; i++) {
      var data = cases[i]
      var locale = Qt.locale(data.locale)
      require(locale.firstDayOfWeek === data.first, "unexpected first weekday for " + data.locale)
      var lines = Calendar.markdown(data.date[0], data.date[1], locale).split("\n")
      require(lines[0] === locale.standaloneMonthName(data.date[1], Locale.LongFormat) + " " + data.date[0],
              "calendar label lost its localized month or year")
      var headers = lines[2].split("|").slice(1, -1).map(function(cell) { return cell.trim() })
      for (var h = 0; h < 7; h++) {
        require(headers[h] === locale.standaloneDayName((data.first + h) % 7, Locale.ShortFormat),
                "weekday labels do not follow " + data.locale)
      }
      var rows = lines.slice(4)
      require(rows.length === data.weeks, "wrong week count for " + data.date)
      var cells = []
      for (var r = 0; r < rows.length; r++) {
        var row = rows[r].split("|").slice(1, -1).map(function(cell) { return cell.trim() })
        require(row.length === 7, "calendar week does not have seven days")
        cells = cells.concat(row)
      }
      require(cells.indexOf("1") === data.offset, "month starts under the wrong weekday for " + data.date)
      var dates = cells.filter(function(cell) { return cell !== "" })
      require(dates.length === data.days, "wrong day count for " + data.date)
      for (var d = 0; d < data.days; d++) {
        require(cells[data.offset + d] === String(d + 1), "missing or duplicate day for " + data.date)
      }
    }
  }

  function calendarInsertion(id) {
    load({ source: "Before\n\nAfter\n" })
    editor.enabledTools = ["table"]
    editor.setCursorPosition(0)
    var tool = editor.tools.find(id)
    var popup = openMonthMenu()
    var row = keys.findChild(popup.contentItem, "editingMenu-" + id)
    require(row && row.visible, id + " is missing from Insert month")
    var before = editor.documentHtml()
    var today = new Date()
    var month = today.getMonth() + (id === "nextMonth" ? 1 : 0)
    var year = today.getFullYear()
    if (month === 12) {
      month = 0
      year++
    }
    var expected = "Before\n\n" + Calendar.markdown(year, month, Qt.locale()) + "\n\nAfter\n"
    keys.mouseClick(row, row.width / 2, row.height / 2)
    keys.tryVerify(function() { return editor.documentHtml() !== before }, 3000)
    require(!popup.opened, "executing a month action left its submenu open")
    require(!tool.panel && !editor.tools.find("customMonth").panelOpen,
            id + " opened a picker instead of inserting immediately")
    require(savedMarkdown() === expected, "calendar did not save with the expected month and weekday order: " + savedMarkdown())
    editor.undo()
    require(savedMarkdown() === "Before\n\nAfter\n", "calendar insertion was not one undo step")
    editor.redo()
    require(savedMarkdown() === expected, "calendar redo changed the dates")
    load({ source: expected })
    require(savedMarkdown() === expected, "calendar changed after reloading saved Markdown")
    editor.setCursorPosition(editor.plainText().indexOf("15"))
    editor.updateInTable()
    require(editor.inTable && editor.tools.canExecute(tool), "calendar is unavailable inside another table")
    load({ source: "word\n" })
    editor.enabledTools = []
    require(!editor.tool(id) && editor.tools.menuTools("insert").length === 0,
            "calendar bypassed table capability restrictions")
    editor.enabledTools = ["table"]
    editor.readOnly = true
    require(!editor.tool(id), "calendar changed a read-only document")
  }

  function nestedTableInsertion(id) {
    var source = "| Parent | Neighbour |\n|---|---|\n| beforeafter | untouched |\n"
    load({ source: source })
    editor.enabledTools = ["table"]
    editor.setCursorPosition(editor.plainText().indexOf("beforeafter") + "before".length)
    editor.updateInTable()
    require(editor.inTable, "nested insertion fixture did not enter its cell")
    var before = editor.documentHtml()
    require(editor.tool(id), "table insertion is disabled inside a cell")
    keys.tryVerify(function() { return editor.documentHtml() !== before }, 3000)
    var saved = savedMarkdown()
    require((saved.match(/<table>/g) || []).length === 2, "inserted table did not stay nested: " + saved)
    require(saved.indexOf("before") >= 0 && saved.indexOf("after") >= 0 && saved.indexOf("untouched") >= 0,
            "nested insertion changed neighbouring text")
    editor.undo()
    require(savedMarkdown() === source, "nested insertion was not one undo step")
    editor.redo()
    require(savedMarkdown() === saved, "nested insertion redo changed its structure")
    load({ source: saved })
    require(savedMarkdown() === saved, "nested table did not survive saving and reloading")
    var marker = id === "currentMonth" ? "15" : "Column 1"
    editor.setCursorPosition(editor.plainText().indexOf(marker))
    editor.updateInTable()
    var inner = editor.tableContext()
    require(inner && inner.columns === (id === "currentMonth" ? 7 : 2), "caret is not in the inserted table")
    require(editor.tool("addRow"), "inner row tool is unavailable")
    require(editor.tableContext().rows === inner.rows + 1, "row was not added to the innermost table")
    editor.undo()
    require(savedMarkdown() === saved, "inner row undo changed the outer table")
    editor.setCursorPosition(editor.plainText().indexOf(marker))
    editor.updateInTable()
    require(editor.tool("addCol"), "inner column tool is unavailable")
    require(editor.tableContext().columns === inner.columns + 1, "column was not added to the innermost table")
    editor.setCursorPosition(editor.plainText().indexOf("untouched"))
    editor.updateInTable()
    require(editor.tableContext().columns === 2 && editor.tableContext().rows === 2,
            "editing an inner table resized the outer table")
    editor.undo()
    require(savedMarkdown() === saved, "inner column undo changed the outer table")
    editor.setCursorPosition(editor.plainText().indexOf(marker))
    editor.updateInTable()
    require(editor.tool("delCol"), "inner column deletion is unavailable")
    require(editor.tableContext().columns === inner.columns - 1, "column was deleted from the wrong table")
    editor.undo()
    require(savedMarkdown() === saved, "inner column deletion did not undo cleanly")
    if (id === "currentMonth") {
      editor.setCursorPosition(editor.plainText().indexOf("15"))
      editor.updateInTable()
      editor.tool("delRow")
      require(editor.tableContext().rows === inner.rows - 1, "row was deleted from the wrong table")
      editor.undo()
      require(savedMarkdown() === saved, "inner row deletion did not undo cleanly")
    }
    editor.setCursorPosition(editor.plainText().indexOf("untouched"))
    editor.updateInTable()
    editor.tool("addCol")
    require(editor.tableContext().columns === 3, "outer table cannot be edited around a nested table")
    require((savedMarkdown().match(/<table>/g) || []).length === 2, "editing the outer table lost its child")
    load({ source: saved })
    editor.setCursorPosition(editor.plainText().indexOf(marker))
    editor.updateInTable()
    before = editor.documentHtml()
    editor.tool("table")
    keys.tryVerify(function() { return editor.documentHtml() !== before }, 3000)
    var deep = savedMarkdown()
    require((deep.match(/<table>/g) || []).length === 3, "a third level of tables was flattened")
    load({ source: deep })
    require(savedMarkdown() === deep, "three table levels did not survive a reload")
  }

  function customMonthInsertion() {
    var source = "Before\n\nAfter\n"
    load({ source: source })
    editor.enabledTools = ["table"]
    editor.setCursorPosition(0)
    var tool = editor.tools.find("customMonth")
    var popup = openMonthMenu()
    var row = keys.findChild(popup.contentItem, "editingMenu-customMonth")
    require(row && row.visible, "custom month is missing from Insert")
    keys.mouseClick(row, row.width / 2, row.height / 2)
    var year = keys.findChild(editor, "customMonthYear")
    var month = keys.findChild(editor, "customMonthMonth")
    keys.tryVerify(function() { return tool.panelOpen && year.activeFocus }, 3000)
    var today = new Date()
    require(tool.yearText === String(today.getFullYear()) && tool.selectedMonth === today.getMonth(),
            "custom month did not default to the current local date")
    require(savedMarkdown() === source, "opening the picker changed the note")
    month.open()
    keys.tryVerify(function() { return month.popupOpen }, 3000)
    var direction = today.getMonth() > 1 ? Qt.Key_Up : Qt.Key_Down
    for (var i = 0; i < Math.abs(today.getMonth() - 1); i++) {
      keys.keyClick(direction)
    }
    keys.keyClick(Qt.Key_Return)
    require(tool.selectedMonth === 1 && !month.popupOpen, "month selection did not choose February")
    year.forceActiveFocus()
    keys.keyClick(Qt.Key_A, Qt.ControlModifier)
    typeText("2024")
    require(tool.yearText === "2024", "typed year did not reach the tool")
    var insert = keys.findChild(editor, "insertCustomMonth")
    keys.mouseClick(insert, insert.width / 2, insert.height / 2)
    keys.tryVerify(function() { return !tool.panelOpen }, 3000)
    var expected = "Before\n\n" + Calendar.markdown(2024, 1, Qt.locale()) + "\n\nAfter\n"
    keys.tryVerify(function() { return editor.plainText().indexOf("29") >= 0 }, 3000)
    require(savedMarkdown() === expected, "selected month or year was not inserted at the captured position")
    editor.undo()
    require(savedMarkdown() === source, "custom month was not one undo step")
    editor.redo()
    require(savedMarkdown() === expected, "custom month redo changed the calendar")
    load({ source: expected })
    require(savedMarkdown() === expected, "custom month changed after reloading")

    source = "| Parent | Neighbour |\n|---|---|\n| beforeafter | untouched |\n"
    load({ source: source })
    editor.setCursorPosition(editor.plainText().indexOf("beforeafter") + 6)
    editor.tool("customMonth")
    keys.tryVerify(function() { return tool.panelOpen && year.activeFocus }, 3000)
    year.selectAll()
    typeText("2024")
    tool.selectedMonth = 1
    keys.keyClick(Qt.Key_Return)
    keys.tryVerify(function() { return editor.plainText().indexOf("29") >= 0 }, 3000)
    var nested = savedMarkdown()
    require((nested.match(/<table>/g) || []).length === 2 && nested.indexOf("untouched") >= 0,
            "custom month did not insert inside its original cell")
    editor.undo()
    require(savedMarkdown() === source, "nested custom month did not undo cleanly")
    load({ source: nested })
    require(savedMarkdown() === nested, "nested custom month changed after reloading")
  }

  function customMonthPanelGuards() {
    var source = "Unchanged\n"
    load({ source: source })
    var tool = editor.tools.find("customMonth")
    editor.tool("customMonth")
    var year = keys.findChild(editor, "customMonthYear")
    var month = keys.findChild(editor, "customMonthMonth")
    var insert = keys.findChild(editor, "insertCustomMonth")
    keys.tryVerify(function() { return year.activeFocus }, 3000)
    keys.keyClick(Qt.Key_Backspace)
    require(!tool.valid && !insert.enabled && !tool.submit() && tool.panelOpen,
            "an empty year was inserted or closed the picker")
    typeText("0")
    require(!tool.valid && !insert.enabled, "year zero was accepted")
    year.selectAll()
    typeText("2024")
    keys.keyClick(Qt.Key_Escape)
    require(!tool.panelOpen && savedMarkdown() === source, "Escape did not cancel without editing")
    editor.tool("customMonth")
    var cancel = keys.findChild(editor, "cancelCustomMonth")
    keys.waitForRendering(cancel)
    keys.mouseClick(cancel, cancel.width / 2, cancel.height / 2)
    require(!tool.panelOpen && savedMarkdown() === source, "Cancel changed the document")
    editor.tool("customMonth")
    keys.tryVerify(function() { return year.activeFocus }, 3000)
    editor.setCursorPosition(3)
    require(!tool.submit() && savedMarkdown() === source, "picker submitted at a changed cursor")
    editor.tool("customMonth")
    month.open()
    keys.tryVerify(function() { return month.popupOpen }, 3000)
    load({ source: "Another note\n" })
    require(!tool.panelOpen && !month.popupOpen && !tool.submit(), "old picker survived a note change")
    require(savedMarkdown() === "Another note\n", "old picker edited the next note")
    editor.tool("customMonth")
    editor.tool("link")
    require(!tool.panelOpen && !tool.panelContext && editor.tools.find("link").panelOpen,
            "opening another tool kept a pending month picker")
    editor.tool("customMonth")
    editor.readOnly = true
    require(!tool.panelOpen && !tool.submit() && !editor.tool("customMonth"), "picker bypassed read-only mode")
    editor.readOnly = false
    editor.tool("customMonth")
    editor.enabledTools = []
    require(!tool.panelOpen && !tool.submit() && !editor.tool("customMonth"), "picker bypassed table capability")
  }

  function nestedTableEnter() {
    var source = "<table><tr><td><p>Parent</p></td><td><p>Neighbour</p></td></tr><tr><td><p>before</p>"
      + "<table><tr><td><p>Inner</p></td><td><p>Header</p></td></tr><tr><td><p>first</p></td><td><p>last</p></td></tr></table>"
      + "<p>after</p></td><td><p>untouched</p></td></tr></table>\n"
    load({ source: source })
    editor.setCursorPosition(editor.plainText().indexOf("last") + 4)
    keys.keyClick(Qt.Key_Return)
    keys.keyClick(Qt.Key_Return)
    var cell = editor.tableContext()
    require(cell && cell.rows === 3 && cell.row === 2 && cell.column === 0,
            "double Enter did not enter a new row of the inner table")
    require((savedMarkdown().match(/<table>/g) || []).length === 2, "double Enter flattened the table")
    editor.undo()
    editor.undo()
    require(savedMarkdown() === source, "undoing double Enter changed nested table contents")
    editor.setCursorPosition(editor.plainText().indexOf("after"))
    editor.updateInTable()
    require(editor.inTable && editor.tableContext().columns === 2 && editor.tableContext().row === 1,
            "the paragraph after a nested table lost its parent cell context")
  }

  function nestedTableEmptyCell() {
    var source = "| Parent | Neighbour |\n|---|---|\n|  | untouched |\n"
    var ids = ["table", "currentMonth"]
    for (var i = 0; i < ids.length; i++) {
      load({ source: source })
      editor.setCursorPosition(editor.plainText().indexOf("Neighbour") + "Neighbour".length + 1)
      editor.updateInTable()
      require(editor.inTable && editor.tableContext().row === 1, "empty cell fixture selected the wrong cell")
      var before = editor.documentHtml()
      editor.tool(ids[i])
      keys.tryVerify(function() { return editor.documentHtml() !== before }, 3000)
      var saved = savedMarkdown()
      require((saved.match(/<table>/g) || []).length === 2 && saved.indexOf("untouched") >= 0,
              "inserting into an empty cell lost a table or neighbour")
      editor.undo()
      require(savedMarkdown() === source, "empty-cell insertion did not undo cleanly")
      load({ source: saved })
      require(savedMarkdown() === saved, "empty-cell insertion gained or lost content when reloaded")
    }
  }

  function tableBackspace() {
    var table = "| A | B |\n|---|---|\n| one | two |\n"
    var nested = "<table><tr><td><p>Parent</p></td><td><p>Neighbour</p></td></tr><tr><td><p>before</p>"
      + "<table><tr><td><p>Inner</p></td></tr><tr><td><p>value</p></td></tr></table><p>after</p>"
      + "</td><td><p>untouched</p></td></tr></table>\n"
    var cases = [
      { name: "only table", source: table, expected: "" },
      { name: "surrounding paragraphs", source: "Before\n\n" + table + "\nAfter\n", expected: "Before\n\nAfter\n" },
      { name: "first of two tables", source: table + "\nBetween\n\n" + table, expected: "\u00a0\n\nBetween\n\n" + table },
      { name: "second of two tables", source: table + "\nBetween\n\n" + table, index: 1, expected: table + "\nBetween\n" },
      { name: "inner table", source: nested, expected: "| Parent | Neighbour |\n|---|---|\n| before after | untouched |\n" },
      { name: "parent with inner table", source: nested, index: 1, expected: "" }
    ]
    for (var i = 0; i < cases.length; i++) {
      var data = cases[i]
      load(data)
      var original = editor.plainText()
      editor.setCursorPosition(tableEnd(original, data.index || 0) + 1)
      keys.keyClick(Qt.Key_Backspace)
      var saved = savedMarkdown()
      require(saved === data.expected, data.name + ": Backspace did not remove exactly its table: " + saved)
      var deleted = editor.plainText()
      editor.undo()
      require(editor.plainText() === original && savedMarkdown() === data.source,
              data.name + ": one undo did not restore the complete table")
      editor.redo()
      require(editor.plainText() === deleted && savedMarkdown() === saved,
              data.name + ": redo did not restore the deletion")
      load({ source: saved })
      require(savedMarkdown() === saved, data.name + ": deletion changed after save/reload")
    }
  }

  function tableBackspaceBoundaries() {
    var source = "| A | B |\n|---|---|\n| one | two |\n\nAfter\n"
    load({ source: source })
    editor.setCursorPosition(editor.plainText().indexOf("one"))
    keys.keyClick(Qt.Key_Backspace)
    require(savedMarkdown() === source, "Backspace at the start of a cell removed its table")
    editor.setCursorPosition(editor.plainText().indexOf("After") + 1)
    keys.keyClick(Qt.Key_Backspace)
    require(savedMarkdown() === source.replace("After", "fter"), "ordinary Backspace after a table stopped deleting text")
    load({ source: source })
    selectText("After")
    keys.keyClick(Qt.Key_Backspace)
    require(editor.plainText().indexOf("After") < 0 && cells() === 4,
            "Backspace with a text selection removed the table")
    load({ source: source })
    editor.setCursorPosition(tableEnd(editor.plainText(), 0) + 1)
    editor.readOnly = true
    keys.keyClick(Qt.Key_Backspace)
    require(savedMarkdown() === source, "Backspace deleted a read-only table")
  }

  function modularToolCases() {
    var table = "| A | B |\n|---|---|\n| one | two |\n"
    var cases = [
      { id: "bold", select: "word", expected: "**word**\n" },
      { id: "italic", select: "word", expected: "*word*\n" },
      { id: "underline", select: "word", expected: "_word_\n" },
      { id: "strikeout", select: "word", expected: "~~word~~\n" },
      { id: "highlight", select: "word", expected: "==word==\n" },
      { id: "code", select: "word", expected: "`word`\n" },
      { id: "h1", expected: "# word\n" },
      { id: "h2", expected: "## word\n" },
      { id: "h3", expected: "### word\n" },
      { id: "p", source: "## word\n", expected: "word\n" },
      { id: "ul", source: "one\n\ntwo\n", select: "one\u2029two", expected: "- one\n- two\n" },
      { id: "ol", expected: "1. word\n" },
      { id: "todo", expected: "- [ ] word\n" },
      { id: "indent", expected: "\u00a0\u00a0\u00a0\u00a0word\n" },
      { id: "outdent", source: "\u00a0\u00a0\u00a0\u00a0word\n", expected: "word\n" },
      { id: "quote", expected: "> word\n" },
      { id: "codeblock", expected: "word\n\n```\n\n```\n" },
      { id: "codeblock", source: "```\nword\n```\n", expected: "word\n" },
      { id: "rule", expected: "word\n\n---\n\n" },
      { id: "table", expected: "word\n\n| Column 1 | Column 2 |\n|---|---|\n|  |  |\n\n" },
      { id: "addRow", source: table, cursorText: "one", expected: table + "|  |  |\n" },
      { id: "delRow", source: table, cursorText: "one", expected: "| A | B |\n|---|---|\n" },
      { id: "addCol", source: table, cursorText: "one", expected: "| A | B |  |\n|---|---|---|\n| one | two |  |\n" },
      { id: "delCol", source: table, cursorText: "two", expected: "| A |\n|---|\n| one |\n" }
    ]
    for (var i = 0; i < cases.length; i++) {
      try {
        toolRoundTrip(cases[i])
        test.checked("modular " + cases[i].id + " saves and undoes", true, "")
      } catch (error) {
        test.checked("modular " + cases[i].id + " saves and undoes", false, error.message)
      }
    }
    var behavior = [
      { name: "text color palette applies, resets, saves, undoes and rejects stale contexts", run: textColorTool },
      { name: "tools enforce provider and document permissions on every entry point", run: toolPermissions },
      { name: "one added file supplies its action, toolbar button, shortcut and help", run: toolDiscovery },
      { name: "tool-owned link panel preserves context and undo", run: toolLinkPanel },
      { name: "invalid tools are isolated and cannot take app shortcuts", run: toolRegistryValidation },
      { name: "configured dropdown actions and pending font styles work", run: toolMenuAndTyping },
      { name: "settings rearrange groups and dropdowns without changing actions or documents", run: toolLayout },
      { name: "nested menus support pointer and keyboard navigation and dismiss with editor changes", run: toolSubmenus },
      { name: "calendar dates follow locale, leap years and month boundaries", run: calendarDates },
      { name: "current month inserts through its menu, saves and restores with undo", run: function() { calendarInsertion("currentMonth") } },
      { name: "next month inserts through its menu, saves and restores with undo", run: function() { calendarInsertion("nextMonth") } },
      { name: "custom month collects input and inserts ordinary or nested calendars with undo", run: customMonthInsertion },
      { name: "custom month validates input, cancels and rejects changed editor contexts", run: customMonthPanelGuards },
      { name: "tables insert and edit inside another table without changing neighbouring cells", run: function() { nestedTableInsertion("table") } },
      { name: "calendar tables insert and edit inside another table without losing dates", run: function() { nestedTableInsertion("currentMonth") } },
      { name: "double Enter adds a row to the innermost table and undoes", run: nestedTableEnter },
      { name: "tables and calendars insert into empty cells and reload without extra content", run: nestedTableEmptyCell },
      { name: "Backspace after a table removes it, preserving neighbours and undo", run: tableBackspace },
      { name: "table Backspace respects cell boundaries, text selections and read-only notes", run: tableBackspaceBoundaries }
    ]
    for (var j = 0; j < behavior.length; j++) {
      try {
        behavior[j].run()
        test.checked(behavior[j].name, true, "")
      } catch (error) {
        test.checked(behavior[j].name, false, error.message)
      } finally {
        editor.toolbarLayout = ToolbarSettings.defaults()
        editor.enabledTools = null
        editor.plain = false
        editor.hasNote = true
        editor.readOnly = false
        editor.clearNotice()
      }
    }
  }

  function run() {
    keys.tryVerify(function() { return editor.tools.ready }, 3000)
    require(editor.tools.ready && editor.tools.errors.length === 0, "editing tools did not load: " + editor.tools.errors.join("; "))
    modularToolCases()
    if (Quickshell.env("NOTE_NOTE_TEST_TOOLS_ONLY")) {
      test.finished()
      return
    }
    var linkCases = [
      { name: "typed URLs track their own destination and undo together", run: typedLinks },
      { name: "URL detection respects punctuation, code and named links", run: linkBoundaries },
      { name: "plain-text notes detect URLs without adding markup", run: plainLinks },
      { name: "URL highlighting leaves cursor movement and editing unchanged", run: linkCaretEditing },
      { name: "URLs open in wrapped lines and tables without changing Markdown", run: linkPresentation }
    ]
    for (var l = 0; l < linkCases.length; l++) {
      try {
        linkCases[l].run()
        test.checked(linkCases[l].name, true, "")
      } catch (error) {
        test.checked(linkCases[l].name, false, error.message)
      }
    }
    try {
      linkInheritance()
      test.checked("new list items do not inherit a link", true, "")
    } catch (error) {
      test.checked("new list items do not inherit a link", false, error.message)
    }
    try {
      links()
      test.checked("links preview and open without editing or intercepting selection", true, "")
    } catch (error) {
      editor.readOnly = false
      test.checked("links preview and open without editing or intercepting selection", false, error.message)
    }
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
      releasedAtTop()
      test.checked("a note released from read-only stays at its top", true, "")
    } catch (error) {
      test.checked("a note released from read-only stays at its top", false, error.message)
    }
    try {
      titleDownAndViewState()
      test.checked("Down from the title lands on the first line; a reload keeps the view", true, "")
    } catch (error) {
      test.checked("Down from the title lands on the first line; a reload keeps the view", false, error.message)
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
    try {
      conflictPanel()
      test.checked("conflict passages and all actions work through the real editor", true, "")
    } catch (error) {
      test.checked("conflict passages and all actions work through the real editor", false, error.message)
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
