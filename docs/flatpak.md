# Standalone Flatpak

The Flatpak packages the standalone Qt application. The Omarchy plugin
continues to use its own archive or Git installation; it runs in the shell.
Both use the shared workspace and providers in this repository.

## Install and run

With Flatpak installed, install the local 1.0.21 x86_64 bundle:

```bash
flatpak install --user ./note-note-1.0.21-x86_64.flatpak
flatpak run io.github.andreivinca.note-note
```

The bundle records Flathub as its runtime source. Flatpak downloads the
matching KDE runtime if needed; the SDK and builder are only needed for
building. Note Note appears in your desktop launcher after installation.
This is a local bundle, not a published Flathub listing. Install a newer
bundle with the same command to update the application.

## Build

The [manifest](../packaging/io.github.andreivinca.note-note.json) uses
`org.kde.Platform` and `org.kde.Sdk` 6.11. Qt and Python come from the
runtime; the manifest builds a pinned, checksum-verified inotify-tools
source archive and then the application using CMake. Host Qt packages
are not used. The Qt text inspector is compiled into the executable.

Set up the build tools once:

```bash
flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install --user flathub org.flatpak.Builder org.kde.Sdk//6.11 org.kde.Platform//6.11
```

From the repository root, build the current working tree and export it:

```bash
flatpak run org.flatpak.Builder --user --force-clean \
  --state-dir=build/flatpak/cache --repo=build/flatpak/repo \
  build/flatpak/app packaging/io.github.andreivinca.note-note.json
mkdir -p build/dist/1.0.21
flatpak build-bundle --runtime-repo=https://flathub.org/repo/flathub.flatpakrepo \
  build/flatpak/repo build/dist/1.0.21/note-note-1.0.21-x86_64.flatpak \
  io.github.andreivinca.note-note stable
```

These commands target the builder's default architecture; the filename
above is for x86_64. Check `flatpak --default-arch` when building elsewhere.
The runtime is downloaded separately rather than embedded in the bundle.
Keep `manifest.json`, the CMake project version and the AppStream release
metadata in sync when changing versions.

Create a checksum next to the bundle:

```bash
cd build/dist/1.0.21
sha256sum note-note-1.0.21-x86_64.flatpak > note-note-1.0.21-x86_64.flatpak.sha256
sha256sum --check note-note-1.0.21-x86_64.flatpak.sha256
```

Build caches and the local OSTree repository stay under `build/flatpak/`.
No command above publishes a release or uploads to Flathub.

## Storage and permissions

| Data | Default location |
|---|---|
| Settings | `~/.var/app/io.github.andreivinca.note-note/config/notenote/config.json` |
| Sessions and sign-ins | `~/.var/app/io.github.andreivinca.note-note/.local/state/notenote/` |
| Caches | `~/.var/app/io.github.andreivinca.note-note/cache/notenote/` |
| External providers | `~/.var/app/io.github.andreivinca.note-note/config/notenote/providers/` |
| Local notebooks | `~/Notes/`, shared with the native app and plugin |

Sign in separately in the Flatpak. Settings and tokens are not copied
from the native app or Omarchy. External providers execute inside the
same sandbox and have the same permissions as the application.

The manifest grants read/write access to `~/Notes`, network access for
connected providers, Wayland with an X11 fallback, and graphics acceleration.
Qt handles clipboard access and opens external URLs through the desktop
portal. Theme files have narrowly scoped read-only permissions; there is
no blanket home-directory or session-bus access.

For notes elsewhere, grant that directory explicitly and set
`providers.local.notesDir` in the app's Settings to the same path:

```bash
flatpak override --user --filesystem=/absolute/path/to/notebooks io.github.andreivinca.note-note
```

Linked notes and images must also be inside an accessible directory.
ImageMagick is optional and is not bundled: images within the normal
size limits work, but automatic scaling of oversized pasted images is
unavailable.

## System colors

The Flatpak reads the host's Omarchy theme and KDE `kdeglobals` using
read-only grants. The theme resolver uses `HOST_XDG_CONFIG_HOME` and
`HOST_XDG_STATE_HOME` inside Flatpak, while application storage continues
to use the sandbox's private XDG directories. Desktop portal preferences
and the built-in palette remain available when theme files cannot be read.

The manifest covers Omarchy's standard current-theme directories. A custom
`XDG_STATE_HOME`, or a theme symlink pointing outside the granted directories,
needs an additional read-only filesystem override for that location.
GNOME's portal supplies appearance preferences and an accent when supported;
it does not expose every GNOME theme color.

## Verify the installed bundle

Close any running Note Note Flatpak, then run the integration tests from
the repository root:

```bash
python3 tests/flatpak_selftest.py
```

The script runs against the installed app and platform runtime, with the
repository available read-only and networking disabled. It creates
temporary notes, settings and test credentials, and checks the packaged
process transport, clipboard, editor, saves, providers, system theme
fixture and window shutdown. It also checks activation across two separate
Flatpak launches. It does not use your notebooks or account tokens.

See Flatpak's official documentation for [Qt runtimes](https://docs.flatpak.org/en/latest/qt.html),
[single-file bundles](https://docs.flatpak.org/en/latest/single-file-bundles.html)
and [sandbox permissions](https://docs.flatpak.org/en/latest/sandbox-permissions.html).
