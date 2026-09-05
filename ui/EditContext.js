.pragma library

// An asynchronous edit may apply only to the document and selection it read.
function capture(note, revision, start, end, cursor, base) {
  return { note: note, revision: revision, start: start, end: end,
           cursor: cursor, base: base }
}

function matches(before, now) {
  return before.note === now.note && before.revision === now.revision
      && before.start === now.start && before.end === now.end
      && before.cursor === now.cursor && before.base === now.base
}
