#!/bin/sh -e
# Builds the optional native text inspector against the system Qt.
# Needs cmake, a C++ compiler and the qt6-declarative package (on Arch the
# headers ship with it). The editor works without this — it falls back to
# scanning the document's HTML — so building is never required.
cd "$(dirname "$0")"
cmake -B build >/dev/null
cmake --build build --parallel
echo "built: cpp/build/NoteNoteText (restart the shell to pick it up)"
