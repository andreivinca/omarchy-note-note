import Quickshell
import Quickshell.Io
import QtQuick

// A Microsoft sign-in for one provider: its own app registration, its own
// token file and its own scopes, so nothing about one provider's account
// touches another's. The code and the device-code flow are what they share.
Item {
  id: root

  readonly property string scriptDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string script: scriptDir + "/msgraph.py"

  // Who this sign-in belongs to (a provider id); names the token file, and
  // the entry in ~/.config/omarchy/note-note.json where a user may put a
  // registration of their own for this provider alone.
  property string owner: "default"
  readonly property string tokenPath: Quickshell.env("HOME") + "/.local/state/omarchy/note-note-ms-" + owner + ".json"
  // The provider's own app registration — the application (client) id of an
  // Entra public client that allows personal and work accounts. Every user
  // of the provider signs in through it; empty, and nobody can.
  property string clientId: ""
  // Space-separated Graph scopes to request at sign-in.
  property string scopes: "offline_access User.Read"
  // Environment for any process that uses msgraph.py on this account's behalf.
  readonly property var env: ({ NOTE_NOTE_MS_ACCOUNT: root.owner, NOTE_NOTE_MS_CLIENT_ID: root.clientId,
                                NOTE_NOTE_MS_SCOPES: root.scopes, NOTE_NOTE_MS_TOKEN: root.tokenPath })

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
    if (root.loggingIn) {
      return
    }
    root.loggingIn = true
    root.updated()
    loginProc.running = true
  }

  // Abandon an in-progress sign-in — the device code was lost (switching to
  // the browser to enter it can hide and reopen this app, which clears the
  // notice that showed it) or the user simply changed their mind.
  function cancelLogin() {
    if (!root.loggingIn) {
      return
    }
    root.reloginPending = false
    loginProc.running = false
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
        if (msg.userCode) {
          root.codeReceived(msg.userCode, msg.verificationUri)
        } else if (msg.ok) {
          root.loginSucceeded()
          root.refresh()
        } else if (msg.error) {
          root.loginFailed(msg.error)
        }
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
      if (root.reloginPending) {
        root.reloginPending = false
        root.login()
      }
    }
  }
}
