#!/usr/bin/env python3
"""Probe: can OneDrive's own search narrow a OneNote content search to the
sections that hold the words, on a personal account, without downloading a
single page?

A one-off measurement tool for docs/future/onenote-content-search.md, not
part of the plugin. It signs in on its own — its own token file, its own
scopes (Files.Read for the drive search, Notes.Read for the checks), through
the OneNote provider's registration — so the app's OneNote sign-in is
untouched, and it only ever reads.

  probe-onedrive-search.py login
  probe-onedrive-search.py search <term> [<term>...] [--verify] [--raw]
  probe-onedrive-search.py logout

`search` runs each term through OneDrive's search endpoint and maps every
hit that is a OneNote section file back to a section in the plugin's own
listing cache (~/.cache/omarchy/note-note-onenote.json — open the app once
so it exists). `--verify` then reads the pages of each matched section and
says which of them really contain the term, which is what tells whether the
hit was the section or just its title. `--raw` prints the first hit whole,
for the fields this probe does not know to look at.

The mapping relies on one fact this probe checks first: a personal
account's section id, `0-<CID>!<n>`, is the OneDrive item id of the
section's `.one` file with `0-` in front — and a notebook id is the same
shape over the notebook's folder. Graph shows a notebook as one `package`
item and may or may not let its section files be addressed one by one; if
the drive search only ever names the notebook, the narrowing is to a
notebook, and the probe says so.
"""
import json, os, sys, urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "services", "microsoft"))
sys.path.insert(0, os.path.join(ROOT, "lib"))
sys.path.insert(0, os.path.join(ROOT, "providers", "onenote"))
import msgraph  # noqa: E402
import onenote  # noqa: E402  (sets the OneNote rate lane; nothing else runs on import)
import onenote_md  # noqa: E402

# The probe's own sign-in. Files.Read is the least the drive search accepts;
# it is also read access to the whole OneDrive, which is the price of this
# route and the reason the plugin does not ask for it today. The sign-in goes
# through the OneNote provider's own registration (microsoftClientId in
# providers/onenote/Provider.qml, repeated here because a QML property is out
# of Python's reach), the user's override for it included: it is OneNote's
# access that is being measured.
msgraph.TOKENS = os.path.join(msgraph.STATE_DIR, "note-note-ms-probe.json")
msgraph.SCOPES = "offline_access User.Read Files.Read Notes.Read"
msgraph.ACCOUNT = "onenote"
msgraph.CLIENT_ID = "1ed713b0-195a-4360-88b4-993f3aeaa262"

LISTING = onenote.ONENOTE_CACHE


def say(text=""):
    sys.stdout.write(text + "\n")
    sys.stdout.flush()


def listing():
    cache = msgraph.load_json(LISTING, None)
    if not cache or not cache.get("sections"):
        say("no OneNote listing at %s — open Note Note once, signed in to OneNote, so the cache exists" % LISTING)
        sys.exit(2)
    return cache


def drive_id_of(section_id):
    """The OneDrive item id a personal account's section id is built on."""
    if section_id.startswith("0-"):
        return section_id[2:]
    return ""


def drive_item(drive_id):
    status, item = msgraph.graph("GET", "/me/drive/items/%s?$select=id,name,file,package,parentReference"
                                 % urllib.parse.quote(drive_id, safe=""))
    if status != 200:
        return "%s %s" % (status, onenote.graph_err(item, status))
    kind = "package" if item.get("package") else ("file" if item.get("file") else "folder")
    return "%s %r in %s" % (kind, item.get("name"), (item.get("parentReference") or {}).get("path", "?"))


def check_mapping(sections):
    """Fetch one section's and its notebook's supposed drive items, and say
    what each turned out to be. Either being addressable is enough to go on."""
    first = next((s for s in sections if drive_id_of(s["id"])), None)
    if not first:
        say("mapping: no section id has the 0-<CID>!<n> shape — not a personal account?")
        return False
    section_item = drive_item(drive_id_of(first["id"]))
    notebook_item = drive_item(drive_id_of(first.get("notebookId", ""))) if drive_id_of(first.get("notebookId", "")) else "no id"
    say("mapping: section %r -> %s" % (first["name"], section_item))
    say("mapping: notebook %r -> %s" % (first.get("notebook", "?"), notebook_item))
    return True


def drive_search(term):
    """Every hit OneDrive's search returns for `term`, all pages of them."""
    quoted = urllib.parse.quote(term.replace("'", "''"), safe="")
    url = "/me/drive/root/search(q='%s')?$select=id,name,file,parentReference,webUrl&$top=200" % quoted
    hits = []
    while url:
        status, res = msgraph.graph("GET", url)
        if status != 200:
            say("  GET %s -> %s %s" % (url, status, onenote.graph_err(res, status)))
            return None
        hits.extend(res.get("value", []))
        url = res.get("@odata.nextLink")
    return hits


def microsoft_search(term):
    """The Microsoft Search API, for the record: expected to refuse a personal account."""
    status, res = msgraph.graph("POST", "/search/query", {
        "requests": [{"entityTypes": ["driveItem"], "query": {"queryString": term}, "from": 0, "size": 25}]})
    if status != 200:
        return "%s %s" % (status, onenote.graph_err(res, status))
    found = []
    for answer in res.get("value", []):
        for container in answer.get("hitsContainers", []):
            for hit in container.get("hits", []):
                resource = hit.get("resource") or {}
                found.append("%s (%s)" % (resource.get("name", "?"), resource.get("webUrl", "")))
    return "%d hit(s): %s" % (len(found), "; ".join(found[:10]))


def page_text(page_id):
    status, html = onenote.graph_raw("GET", "/me/onenote/pages/%s/content" % urllib.parse.quote(page_id, safe=""))
    if status != 200:
        return None
    converted = onenote_md.html_to_markdown(html)
    return (converted.get("title", "") + "\n" + converted.get("body", "")).lower()


def section_pages(section_id):
    found, url = [], onenote.section_pages_url(section_id)
    while url:
        status, res = msgraph.graph("GET", url)
        if status != 200:
            say("  pages of %s -> %s %s" % (section_id, status, onenote.graph_err(res, status)))
            break
        found.extend(res.get("value", []))
        url = res.get("@odata.nextLink")
    return found


def verify(term, section):
    """Which pages of a matched section really hold the term."""
    pages = section_pages(section["id"])
    holding = []
    for page in pages:
        text = page_text(page["id"])
        if text is not None and term.lower() in text:
            holding.append(page.get("title") or "(untitled)")
    return len(pages), holding


def cmd_search(terms, do_verify, do_raw):
    if not os.path.exists(msgraph.TOKENS):
        say("not signed in — run `%s login` first" % os.path.basename(__file__))
        sys.exit(2)
    cache = listing()
    sections = cache["sections"]
    by_drive_id = dict((drive_id_of(s["id"]), s) for s in sections if drive_id_of(s["id"]))
    notebooks = dict((drive_id_of(s["notebookId"]), s.get("notebook", "?")) for s in sections if drive_id_of(s.get("notebookId", "")))
    if not check_mapping(sections):
        say("stopping: without the mapping, drive hits cannot be read back as sections")
        sys.exit(1)
    for term in terms:
        say()
        say("== %r" % term)
        hits = drive_search(term)
        if hits is None:
            continue
        matched, books, loose, other = [], [], [], 0
        for hit in hits:
            section = by_drive_id.get(hit.get("id", ""))
            if section:
                matched.append(section)
            elif hit.get("id", "") in notebooks:
                books.append(notebooks[hit["id"]])
            elif hit.get("name", "").lower().endswith(".one"):
                loose.append(hit)
            else:
                other += 1
        say("  OneDrive search: %d hit(s) — %d section(s) and %d notebook(s) in the listing, %d other .one file(s), %d non-OneNote"
            % (len(hits), len(matched), len(books), len(loose), other))
        for name in books:
            say("    notebook %s" % name)
        for section in matched:
            line = "    %s › %s" % (section.get("notebook", "?"), section.get("name", "?"))
            if do_verify:
                total, holding = verify(term, section)
                line += "  — %d of %d page(s) hold it: %s" % (len(holding), total, ", ".join(holding) or "none")
            say(line)
        for hit in loose:
            say("    (not in listing) %s in %s" % (hit.get("name"), (hit.get("parentReference") or {}).get("path", "?")))
        if do_raw and hits:
            say("  first hit as returned:")
            say("    " + json.dumps(hits[0], indent=2).replace("\n", "\n    "))
        say("  Microsoft Search API: %s" % microsoft_search(term))


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "login":
        msgraph.cmd_login()
    elif cmd == "logout":
        msgraph.cmd_logout()
    elif cmd == "search" and len(argv) > 2:
        flags = ("--verify", "--raw")
        args = [a for a in argv[2:] if a not in flags]
        cmd_search(args, "--verify" in argv[2:], "--raw" in argv[2:])
    else:
        say(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    try:
        main(sys.argv)
    except msgraph.ratelimit.Throttled as throttled:
        say("throttled — try again in %ds" % max(1, round(throttled.retry_after)))
        sys.exit(1)
