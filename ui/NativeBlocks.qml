import "../cpp/build/NoteNoteText"

// The native text inspector (cpp/textblocks.h). This file exists so that
// import is *optional*: NoteEditor loads it through a Loader, and when the
// library has not been built (`sh cpp/build.sh`) the import fails, the
// Loader errors, and the editor falls back to scanning the document's HTML
// (QuoteBars.js). Nothing else notices.
TextBlocks {}
