import Quickshell
import Quickshell.Io
import QtQuick

// A Microsoft sign-in for one provider: its own token file and its own
// scopes, so signing out of one provider never touches another. The code,
// the app registration and the device-code flow are what they share.
Item {
  id: root

  readonly property string scriptDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string script: scriptDir + "/msgraph.py"
  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/note-note.json"

  // Who this sign-in belongs to (a provider id); names the token file.
  property string owner: "default"
  readonly property string tokenPath: Quickshell.env("HOME") + "/.local/state/omarchy/note-note-ms-" + owner + ".json"
  // Space-separated Graph scopes to request at sign-in.
  property string scopes: "offline_access User.Read"
  // Environment for any process that uses msgraph.py on this account's behalf.
  readonly property var env: ({ NOTE_NOTE_MS_SCOPES: root.scopes, NOTE_NOTE_MS_TOKEN: root.tokenPath })

  property bool configured: false
  property bool signedIn: false
  property string account: ""
  property string grantedScope: ""
  property bool loggingIn: false

  signal updated()
  signal codeReceived(string code, string uri)
  signal loginSucceeded()
  signal loginFailed(string error)

  function hasScope(s) { return (" " + root.grantedScope + " ").indexOf(" " + s + " ") >= 0 }

  function refresh() { statusProc.running = true }

  function login() {
    if (root.loggingIn) return
    root.loggingIn = true
    root.updated()
    loginProc.running = true
  }

  // Sign out, then sign in again — for a token that predates a provider's scope.
  property bool reloginPending: false
  function relogin() { root.reloginPending = true; logout() }

  function logout() { logoutProc.running = true }

  Process {
    id: statusProc
    command: ["python3", root.script, "status"]
    environment: root.env
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var st = JSON.parse(this.text)
          root.configured = st.configured === true
          root.signedIn = st.signedIn === true
          root.account = st.account || ""
          root.grantedScope = st.scope || ""
        } catch (e) { root.configured = false; root.signedIn = false; root.grantedScope = "" }
        root.updated()
      }
    }
  }

  Process {
    id: loginProc
    command: ["python3", root.script, "login"]
    environment: root.env
    stdout: SplitParser {
      onRead: function(line) {
        var msg
        try { msg = JSON.parse(line) } catch (e) { return }
        if (msg.userCode) root.codeReceived(msg.userCode, msg.verificationUri)
        else if (msg.ok) { root.loginSucceeded(); root.refresh() }
        else if (msg.error) root.loginFailed(msg.error)
      }
    }
    onExited: { root.loggingIn = false; root.updated() }
  }

  Process {
    id: logoutProc
    command: ["python3", root.script, "logout"]
    environment: root.env
    onExited: {
      root.signedIn = false; root.account = ""; root.grantedScope = ""
      root.updated()
      if (root.reloginPending) { root.reloginPending = false; root.login() }
    }
  }
}
