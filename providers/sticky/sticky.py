#!/usr/bin/env python3
"""Microsoft Sticky Notes provider script for Note Note.

Sticky Notes sync into the Outlook mailbox's "Notes" folder, which Microsoft
Graph exposes as a well-known mail folder.

  sticky.py list [--cached]   -> {"notes":[{id,title,body,modified}], "cached":bool}
  sticky.py update <id> <file> -> reads {"title","body"} from file, PATCHes the note
  sticky.py create             -> {"ok":true,"note":{...}}
  sticky.py delete <id>
"""
import json, os, sys, time, urllib.parse

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "services", "microsoft"))
from msgraph import graph, fail, out, load_json, save_private, CACHE_DIR  # noqa: E402

CACHE = os.path.join(CACHE_DIR, "note-note-sticky.json")
# This provider's limits: what it will read from Graph and keep around.
MAX_NOTES = 500                 # sticky notes listed
MAX_LIST_BODY = 4 * 1024 * 1024  # one page of the listing
MAX_NOTE_BODY = 256 * 1024      # a single note's text (longer is truncated)


def to_note(m):
    body = (m.get("body") or {}).get("content", "") or ""
    # Sticky Notes keep subject == first line of the body, so the title is
    # not a separate thing to show or edit; the body is the note.
    return {
        "id": m["id"],
        "title": "",
        "body": body.replace("\r\n", "\n").rstrip("\n")[:MAX_NOTE_BODY],
        "modified": m.get("lastModifiedDateTime", ""),
    }


def cmd_list(cached):
    if cached:
        c = load_json(CACHE, None)
        if c is not None:
            out({"notes": c.get("notes", []), "cached": True})
            return
        out({"notes": [], "cached": True})
        return
    notes = []
    url = ("/me/mailFolders/notes/messages?$select=id,subject,body,lastModifiedDateTime"
           "&$orderby=lastModifiedDateTime%20desc&$top=100")
    while url and len(notes) < MAX_NOTES:
        status, res = graph("GET", url, extra_headers={"Prefer": 'outlook.body-content-type="text"'}, max_bytes=MAX_LIST_BODY)
        if status != 200:
            fail((res.get("error") or {}).get("message", "Graph error %s" % status) if isinstance(res.get("error"), dict)
                 else str(res.get("error", status)))
        notes.extend(to_note(m) for m in res.get("value", []))
        url = res.get("@odata.nextLink")
    notes = notes[:MAX_NOTES]
    os.makedirs(CACHE_DIR, exist_ok=True)
    save_private(CACHE, {"notes": notes, "fetched": time.time()})
    out({"notes": notes, "cached": False})


def cmd_update(note_id, path):
    payload = load_json(path, None)
    if payload is None:
        fail("cannot read payload")
    body = payload.get("body", "")
    first = next((l.strip() for l in body.split("\n") if l.strip()), "")
    data = {"body": {"contentType": "text", "content": body}, "subject": first[:255]}
    status, res = graph("PATCH", "/me/messages/" + urllib.parse.quote(note_id, safe=""), data)
    if status not in (200, 201):
        fail((res.get("error") or {}).get("message", "Graph error %s" % status) if isinstance(res.get("error"), dict)
             else str(res.get("error", status)))
    # Keep the cache in step so a reopen shows the edit even before a refresh.
    c = load_json(CACHE, {"notes": []})
    for n in c.get("notes", []):
        if n["id"] == note_id:
            n["body"] = body
            n["modified"] = res.get("lastModifiedDateTime", n.get("modified", ""))
    save_private(CACHE, c)
    out({"ok": True})


def cmd_create():
    # A message in the Notes folder is only a sticky note if its MAPI message
    # class says so; PR_MESSAGE_CLASS is 0x001A.
    data = {"subject": "", "body": {"contentType": "text", "content": ""},
            "singleValueExtendedProperties": [{"id": "String 0x001A", "value": "IPM.StickyNote"}]}
    status, res = graph("POST", "/me/mailFolders/notes/messages", data)
    if status not in (200, 201) or "id" not in res:
        fail((res.get("error") or {}).get("message", "Graph error %s" % status) if isinstance(res.get("error"), dict)
             else str(res.get("error", status)))
    note = to_note(res)
    c = load_json(CACHE, {"notes": []})
    c["notes"] = [note] + [n for n in c.get("notes", []) if n["id"] != note["id"]]
    save_private(CACHE, c)
    out({"ok": True, "note": note})




def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "list":
        cmd_list("--cached" in argv[2:])
    elif cmd == "update" and len(argv) >= 4:
        cmd_update(argv[2], argv[3])
    elif cmd == "create":
        cmd_create()
    elif cmd == "delete" and len(argv) >= 3:
        cmd_delete(argv[2])
    elif cmd == "clear-cache":
        try:
            os.remove(CACHE)
        except OSError:
            pass
        out({"ok": True})
    else:
        fail("usage: sticky.py list [--cached]|update <id> <file>|create|delete <id>|clear-cache", 2)


if __name__ == "__main__":
    try:
        main(sys.argv)
    except SystemExit:
        raise
    except Exception as e:
        fail("%s: %s" % (type(e).__name__, e))
