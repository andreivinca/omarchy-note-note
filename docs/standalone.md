# Shared application and Linux hosts

One repository builds two launchers around one application. The Omarchy
plugin uses the root manifest and `hosts/omarchy/Notes.qml` entry point. The standalone
executable creates a normal Qt window on Wayland or X11.

## Responsibilities

| Layer | Owns |
|---|---|
| `Workspace.qml` | Application state, provider lifecycle, note selection, autosave, settings, shortcuts and shared UI |
| `ui/`, `services/`, `providers/`, `lib/` | Editor, document conversion, request queues and backend behavior, shared by both hosts |
| `design/` | Shared color facade, dimensions and reusable controls |
| `services/theme/` | Standalone desktop detection, palette resolution, portal preferences and live theme updates |
| `services/platform/Platform.qml` | Host services, XDG paths, process creation, clipboard, external URLs and text inspector selection |
| `services/processes/` | Process lifecycle, stdin payloads, JSON parsing, streaming lines, timeouts, output limits and exactly-once completion |
| `hosts/omarchy/` | `Notes.qml` shell entry point, overlay and detached windows, Quickshell process transport and theme adapter |
| `hosts/standalone/` | Qt window, QProcess transport, QClipboard, activation socket and directly linked text inspector |

Shared code does not import `Quickshell`, `qs.Commons` or `qs.Ui`. Keep new
desktop-specific dependencies inside a host. `ui/NativeBlocks.qml` is the
optional native inspector import selected by the Omarchy adapter; the
standalone host selects its own directly linked implementation.

Each launcher calls `backend.install()` before `workspace.initialize()` and
`workspace.open()`. Initialization is explicit and idempotent: a workspace
must never read settings while the platform's paths are still unset. The
workspace can be parented into a shell card or filled into a desktop window.
Only the shell advertises `supportsOverlay`.

Processes receive argument arrays and optional stdin, never interpolated
commands or payload files. Both transports use `ProcessTask` for deadlines,
framing and completion. The native decoder preserves UTF-8 across reads;
Quickshell collects complete replies or emits complete streaming lines.
Cancellation settles the callback once and stops its child. Native child
processes are reaped asynchronously without blocking the UI.

An Omarchy dismiss hides the workspace while accepted writes drain in the
shell. A native close first flushes the editor, stops watchers and new reads,
and waits for conversions, writes, provider changes and state persistence.
Failure reopens the workspace with its draft and an error. Successful
drain emits `readyToClose`; only then does the launcher quit. OneNote content
indexing stops during native shutdown.
Closing drains accepted mutations rather than background listings or reads;
providers expose `writeBusy` separately from activity used for settings changes.
Remaining provider processes stop after writes finish, before the host exits.

## Build and run

Build dependencies: CMake 3.21+, C++17 compiler, Qt 6.8+ development files for
Quick, Quick Controls 2, Network and DBus. Tests additionally use Qt Test,
the QtTest QML module and `dbus-run-session`. Use `-DBUILD_TESTING=OFF` for a
production-only build.

Runtime dependencies: Qt Quick and Quick Controls 2 QML modules, Qt's
Wayland or X11 platform plugin, SVG image support, Python 3.9+ and
inotify-tools. ImageMagick is optional for scaling large pasted images.
Python libraries are vendored; no runtime pip installation is needed.
The bundled symbol font supplies toolbar icons on desktops without Nerd Fonts.

The standalone host uses the same 12-pixel base type scale and spacing as
the default Omarchy plugin. Qt applies the monitor's display scaling to
both. Custom shell font and spacing overrides continue to apply to the
plugin; standalone colors come from the system theme independently of
these default dimensions.

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
./build/note-note
ctest --test-dir build --output-on-failure
```

The native text inspector is compiled into the executable. `sh cpp/build.sh`
continues to build the optional QML module used by the Omarchy plugin.

## Install and package

```bash
cmake --install build --prefix "$HOME/.local"
```

CMake installs `bin/note-note`, application resources in
`share/note-note/`, a freedesktop desktop entry and an SVG icon. Keep the
resources with the executable: Python helpers and external QML providers
need real files. Installed executables find their resources relative to
their binary directory, including when the prefix contains spaces. Build
executables load the source tree; `--data-dir` selects an explicit resource
directory for development. `--qml` runs isolated test harnesses and bypasses
single-instance activation.

Distribution packagers can configure `CMAKE_INSTALL_PREFIX=/usr` and stage
the installation with `DESTDIR`. Package the runtime modules and image
plugins as dependencies. Deliverables include native and Omarchy release
archives and a [standalone Flatpak bundle](flatpak.md). Debian/RPM/Arch
packages and AppImage are separate follow-up work.

### Release archives

```bash
cmake -S . -B build/release -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
cmake --build build/release --parallel
ctest --test-dir build/release --output-on-failure
python3 packaging/package.py
```

The packaging step tests the installed, stripped executable and validates
the plugin manifest before creating `build/dist/<version>/`:

- `note-note-<version>-linux-<architecture>.tar.xz`: standalone `bin/` and
  `share/` directories, installation instructions and build metadata. Qt is
  supplied by the target system; the metadata records the actual build version.
- `note-note-<version>-omarchy.tar.xz`: shared QML/Python application, Omarchy
  entry point and optional text inspector sources. Run `sh cpp/build.sh`
  inside the extracted plugin to build the inspector against the shell's Qt.
  The script fallback remains available without that build.
- `SHA256SUMS` and `BUILD-INFO.json`: archive checksums and build provenance.

Archives contain no user settings, credentials or notebook contents. The
packager selects tracked source files for the plugin and CMake-installed
resources for the native application. It does not publish or install either
archive. Extract each into a fresh directory; installation instructions are
included in `INSTALL.md`.

For general Linux distribution, Flatpak is the recommended standalone
delivery format: the [KDE Flatpak runtime](https://docs.flatpak.org/en/latest/qt.html)
provides Qt independently of host packages. The Omarchy plugin stays a
separate archive or Git install. See the [Flatpak build and installation
guide](flatpak.md) for the manifest, notebook permissions, private storage
and theme integration.

Qt uses the desktop's windowing integration. A per-user local activation
socket brings an existing window forward when the executable is launched
again. It accepts no note contents or commands. Global shortcuts belong to
the desktop; users can bind `note-note` in their environment.

## System colors

The standalone host resolves colors before creating its window. The shared
UI and Qt Quick Controls receive the same palette. Desktop identity comes
from `XDG_CURRENT_DESKTOP`, then `XDG_SESSION_DESKTOP` and `DESKTOP_SESSION`;
unrelated theme files left by another installed desktop do not take priority.

| Desktop | Color sources, in priority order |
|---|---|
| Omarchy / Hyprland with an Omarchy theme | `~/.local/state/omarchy/current/theme/colors.toml`, theme `shell.toml`, then `~/.config/omarchy/shell.toml` overrides. The older `~/.config/omarchy/current/theme` location is also supported. |
| KDE Plasma | Color roles in `~/.config/kdeglobals`, then Qt's desktop palette and portal preferences |
| GNOME | Qt's desktop palette when its platform integration supplies one, plus portal light/dark and accent preferences |
| Other Hyprland sessions / other desktops | Qt's desktop palette and portal preferences, when available |
| No usable system palette | Built-in light or dark colors, honoring any available system appearance preference |

XDG state and config directory overrides also apply to theme paths. Omarchy
menu surfaces, alpha values, color references and the first gradient color
stop are resolved consistently with the shell. KDE window, view, button,
selection, tooltip, link and error colors are mapped to application roles.

The [desktop Settings portal](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.Settings.html)
provides light/dark and accent preferences, rather than a complete GTK
palette. On GNOME without a matching Qt palette, these preferences style
the built-in colors. Hyprland itself does not define an application palette;
an available theme integration or portal supplies that information.

Theme files and their parent directories are watched for edits, atomic
replacement and theme symlink switches. Qt palette changes and portal
signals update an open window without restarting. Portal reads are
asynchronous; missing services or invalid theme files fall back to the next
source. Theme sources are read only, and the resolver never changes the
desktop's settings or Qt's global palette.

The Omarchy plugin continues to receive the shell's live color objects
directly through the same shared facade.

## Storage

Paths below use XDG defaults. Absolute `XDG_CONFIG_HOME`, `XDG_STATE_HOME`
and `XDG_CACHE_HOME` overrides apply to both launchers.

| Data | Omarchy plugin | Standalone app |
|---|---|---|
| Local notes | `~/Notes` or configured directory | Same |
| Application settings | `~/.config/notenote/config.json` | Same |
| Layout and provider state | `~/.local/state/omarchy/note-note.json` | `~/.local/state/notenote/note-note.json` |
| Credentials and recovery drafts | `~/.local/state/omarchy/note-note-*` | `~/.local/state/notenote/note-note-*` |
| Caches, pasted images, rate state | `~/.cache/omarchy/note-note-*` | `~/.cache/notenote/note-note-*` |
| Microsoft registration overrides | `~/.config/omarchy/note-note.json` | `~/.config/notenote/accounts.json` |
| External providers | `~/.config/omarchy/note-note/providers/` | `~/.config/notenote/providers/` |

The standalone app does not copy credentials or recovery journals from the
plugin. Each signs in separately; settings and configured local notebooks
are shared. When both open the same local file, ordinary external-file
change detection applies; local Markdown has no cross-editor merge protocol.

`Platform.environment` passes `NOTE_NOTE_STATE_DIR`, `NOTE_NOTE_CACHE_DIR`,
`NOTE_NOTE_PASTE_DIR` and `NOTE_NOTE_ACCOUNT_CONFIG` to every child process.
Standalone provider scripts invoked by hand must receive these overrides if
they should use native storage; without them, legacy Omarchy defaults remain.
Existing more specific overrides such as `NOTE_NOTE_MS_TOKEN` still apply.

External providers can use standard Qt Quick Controls and the injected
`services.platform`, `services.style`, `services.colors` and
`services.processes`. See [the provider contract](../providers/PROVIDERS.md).
Providers importing shell modules themselves remain Omarchy-specific.

## Verification

`ctest` runs theme resolution and live-update tests, native clipboard tests, application startup and failed-save
shutdown checks, and the shared editor/controller transition suite through
the native transport. Fixtures have temporary homes, notes and XDG storage;
they make no requests to real accounts. Portal tests run against a fake
service on a private D-Bus session; other native suites disconnect from the
desktop's session bus. The production launcher and the
portable external example provider are instantiated as part of these tests.

```bash
python3 tests/selftest.py                      # Existing plugin/provider suites
python3 tests/transition_selftest.py --host    # Hidden Omarchy windows on Wayland
python3 tests/standalone_selftest.py build/note-note
python3 tests/transition_selftest.py --standalone
```

To test an installed layout, supply its binary and resource directory to
`tests/standalone_selftest.py` using `--resources <prefix>/share/note-note`.
These checks validate local behavior and scripted network responses. They
do not certify every Linux distribution or replace manual account sign-in
testing before a public release.
