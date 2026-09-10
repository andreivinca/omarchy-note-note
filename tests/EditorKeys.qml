import QtQuick
import QtTest
import "../ui" as Ui
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

  function run() {
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
