"""OneNote merge integration, with a scripted server and private temporary state."""
import contextlib
import html
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
import urllib.error
from unittest.mock import patch
from xml.etree import ElementTree as ET

WORK = tempfile.TemporaryDirectory(prefix="note-note-onenote-merges-")
for variable, subdir in (("XDG_STATE_HOME", "state"), ("XDG_CACHE_HOME", "cache"),
                         ("XDG_CONFIG_HOME", "config"), ("NOTE_NOTE_RATE_DIR", "rate")):
    os.environ[variable] = str(Path(WORK.name) / subdir)
os.environ["NOTE_NOTE_MS_TOKEN"] = str(Path(WORK.name) / "token.json")
sys.path.insert(0, str(Path(__file__).resolve().parent))
import onenote  # noqa: E402
from notemerge import MergeStore, StaleRemote  # noqa: E402


def note(body, title="Title"):
    return {"title": title, "body": body}


def page_html(value):
    source = ('<html><head><title>' + html.escape(value["title"]) + '</title></head><body><div>'
              + onenote.onenote_md.markdown_to_onenote_html(value["body"]) + '</div></body></html>')
    tree = ET.fromstring(source)
    for index, node in enumerate(tree.iter()):
        if node.tag in onenote.onenote_patch.REPLACEABLE or node.tag == "div":
            node.set("id", "%s:fixture%d" % (node.tag, index))
    return ET.tostring(tree, encoding="unicode")


class SaveTests(unittest.TestCase):
    def test_edit_beside_normalized_layout_preserves_original_elements(self):
        image = Path(onenote.ONENOTE_IMG_DIR) / "layout-image"
        image.parent.mkdir(parents=True, exist_ok=True)
        image.write_bytes(b"synthetic image")
        patch.object(onenote, "cached_image", return_value=image.as_uri()).start()
        src = "https://graph.microsoft.com/v1.0/me/onenote/resources/layout/$value"
        layout = ('<img id="img:banner" src="' + src + '" alt="Generated description:&#10;&#10;" width="400"/>'
                  '<table id="table:ideas"><tr><td><ul id="ul:ideas">'
                  '<li id="li:first">First idea</li>\n<br/>\n<li id="li:second">Second idea</li>'
                  '</ul></td></tr></table>')
        photos = ('<table id="table:photos"><tr><td><p id="p:caption">Caption</p></td></tr>'
                  '<tr><td><img id="img:photo" src="' + src + '" alt="Photo" width="100"/></td></tr></table>')
        heading = ('<table id="table:heading"><tr><td><p id="p:left">Left</p></td>'
                   '<td><p id="p:middle"></p></td><td><p id="p:right">Right</p></td></tr></table>')
        self.remote = ('<html><head><title>Title</title></head><body><div id="div:layout">'
                       + layout + heading + photos + '<p id="p:end">End</p></div></body></html>')
        original = ET.fromstring(self.remote)
        loaded = self.load()
        desired = loaded["body"].replace('| Left |  | Right |', r'| Left | \| | Right |')
        desired = desired.replace('End', 'Edited ending')
        self.assertNotEqual(desired, loaded["body"])
        result = self.save(note(desired), loaded["view"])
        self.assertTrue(result.get("ok"), result)
        operations = [op for method, _, data in self.calls if method == "PATCH" for op in json.loads(data)]
        self.assertEqual([op["target"] for op in operations], ["p:middle", "p:end"])
        current = ET.fromstring(self.remote)
        for identifier in ("img:banner", "table:ideas", "table:photos", "p:left", "p:right"):
            before = next(node for node in original.iter() if node.get("id") == identifier)
            after = next(node for node in current.iter() if node.get("id") == identifier)
            self.assertEqual(ET.tostring(after), ET.tostring(before))
        self.assertEqual(self.load()["body"], result["body"])

    def test_inline_table_cell_edit_preserves_layout_and_nearby_targets(self):
        self.remote = ('<html><head><title>Title</title></head><body><div>'
                       '<p id="p:before">Before</p><table id="table:legacy" style="border:0px;width:400px">'
                       '<tr><td style="width:190px"><span style="color:#3f3f3f;font-weight:bold">Left</span></td>'
                       '<td style="width:20px"><br/></td><td style="width:190px"><b>Right</b></td></tr></table>'
                       '<p id="p:after">After</p></div></body></html>')
        original = ET.fromstring(self.remote)
        loaded = self.load()
        changed = loaded["body"].replace(' |  | ', r' | \| | ')
        result = self.save(note(changed), loaded["view"])
        self.assertTrue(result.get("ok"), result)
        operations = [op for method, _, data in self.calls if method == "PATCH" for op in json.loads(data)]
        self.assertEqual([op["target"] for op in operations], ["table:legacy"])
        content = ET.fromstring(operations[0]["content"])
        old_table = next(original.iter("table"))
        self.assertEqual(content.attrib, {key: value for key, value in old_table.attrib.items() if key != "id"})
        old_cells, new_cells = list(old_table.iter("td")), list(content.iter("td"))
        for index in (0, 2):
            self.assertEqual(ET.tostring(new_cells[index]), ET.tostring(old_cells[index]))
        identifiers = {node.get("id") for node in ET.fromstring(self.remote).iter()}
        self.assertTrue({"p:before", "p:after"}.issubset(identifiers))
        self.assertEqual(self.load()["body"], result["body"])

    def test_untargetable_cell_does_not_replace_nested_editable_content(self):
        self.remote = ('<html><head><title>Title</title></head><body><div><table id="table:mixed">'
                       '<tr><td><p id="p:keep">Keep</p></td><td><br/></td></tr></table></div></body></html>')
        loaded = self.load()
        result = self.save(note(loaded["body"].replace('| Keep |  |', '| Keep | Added |')), loaded["view"])
        self.assertIn("no editable paragraph", result.get("error", ""))
        self.assertFalse(any(method == "PATCH" for method, *_ in self.calls))
        self.assertIn('id="p:keep"', self.remote)

    def test_color_conversion_and_reset_preserve_checkboxes_and_neighbours(self):
        self.remote = ('<html><head><title>Title</title></head><body><div id="div:food">'
                       '<p id="p:mushrooms" data-tag="to-do:completed"><span style="color:#0070c0">Mushrooms</span></p>'
                       '<p id="p:milk" data-tag="to-do">Milk</p></div></body></html>')
        loaded = self.load()
        self.assertIn('<span style="color:#0070c0;">Mushrooms</span>', loaded["body"])
        changed = loaded["body"].replace("#0070c0", "#ff0000")
        result = self.save(note(changed), loaded["view"])
        self.assertTrue(result.get("ok"), result)
        self.assertIn("#ff0000", self.remote)
        self.assertIn('data-tag="to-do:completed"', self.remote)
        self.assertIn('id="p:milk"', self.remote)
        loaded = self.load()
        reset = loaded["body"].replace('<span style="color:#ff0000;">Mushrooms</span>', 'Mushrooms')
        result = self.save(note(reset), loaded["view"])
        self.assertTrue(result.get("ok"), result)
        self.assertNotIn("color:", self.remote)
        self.assertIn('data-tag="to-do:completed"', self.remote)


    def test_nested_table_conversion_preserves_cell_blocks(self):
        source = ('<table><tr><td><p>Parent</p></td><td><p>Neighbour</p></td></tr><tr><td>'
                  '<p><strong>before</strong></p><table><tr><td><p>Inner</p></td></tr>'
                  '<tr><td><p>one</p></td></tr></table><p>after</p></td><td><p>untouched</p></td></tr></table>')
        rendered = onenote.onenote_md.markdown_to_onenote_html(source)
        actual = onenote.onenote_md.html_to_markdown(rendered)
        self.assertTrue(actual["editable"])
        self.assertEqual(actual["body"], source)

    def test_table_export_uses_onenote_border_attribute(self):
        cases = [
            "| Item | Quantity |\n|---|---|\n| Apples | 2 |",
            "|  |  |\n|---|---|\n|  |  |",
            '<table><tr><td><p>Parent</p><table><tr><td><p>Inner</p></td></tr></table>'
            '</td></tr></table>',
        ]
        for source in cases:
            with self.subTest(source=source):
                rendered = onenote.onenote_md.markdown_to_onenote_html(source)
                tables = list(ET.fromstring("<root>" + rendered + "</root>").iter("table"))
                self.assertTrue(tables)
                for table in tables:
                    self.assertEqual(table.get("border"), "1")
                    self.assertNotIn("border:", table.get("style", ""))

    def test_literal_pipes_in_table_cells_survive_save_and_reload(self):
        self.remote = ('<html><head><title>Title</title></head><body><div><table id="table:pipes">'
                       '<tr><td><p id="p:head1"></p></td><td><p id="p:head2"></p></td></tr>'
                       '<tr><td><p id="p:cell1"></p></td><td><p id="p:cell2"></p></td></tr>'
                       '</table></div></body></html>')
        loaded = self.load()
        cases = [
            ("|", r"\|"),
            ("left|right", r"left\|right"),
            (r"\|", r"\\\|"),
            (r"\\|", r"\\\\\|"),
            ("bold|pipe", r"**bold\|pipe**"),
        ]
        for text, markdown in cases:
            with self.subTest(text=text):
                row = "| " + markdown + " | " + markdown + " |"
                desired = row + "\n|---|---|\n" + row
                result = self.save(note(desired), loaded["view"])
                self.assertTrue(result.get("ok"), result)
                current = ET.fromstring(self.remote)
                tables = list(current.iter("table"))
                self.assertEqual(len(tables), 1)
                rows = list(tables[0].iter("tr"))
                self.assertEqual(len(rows), 2)
                for row in rows:
                    self.assertEqual(["".join(cell.itertext()) for cell in row], [text, text])
                loaded = self.load()
                self.assertEqual(loaded["body"], desired)

    def test_appending_calendar_with_repeated_heading_preserves_existing_page(self):
        self.remote = ('<html><head><title>Title</title></head><body><div id="div:main">'
                       '<p id="p:item" data-tag="to-do">Apples</p><br/>'
                       '<p id="p:month">September 2026</p></div></body></html>')
        loaded = self.load()
        table = "| Mon | Tue | Wed | Thu | Fri | Sat | Sun |\n|---|---|---|---|---|---|---|"
        table += "\n|  |  |  |  |  |  |  |" * 5
        desired = loaded["body"] + "\n\n\u00a0\n\nSeptember 2026\n\n" + table
        saved = self.save(note(desired), loaded["view"])
        self.assertTrue(saved.get("ok"), saved)
        self.assertEqual(self.load()["body"], desired)
        operations = [op for method, _, data in self.calls if method == "PATCH" for op in json.loads(data)]
        self.assertEqual([(op["target"], op["action"], op.get("position")) for op in operations],
                         [("p:month", "insert", "after")])
        current = ET.fromstring(self.remote)
        paragraphs = {node.get("id"): node for node in current.iter("p")}
        self.assertEqual(paragraphs["p:month"].text, "September 2026")
        self.assertEqual(paragraphs["p:item"].get("data-tag"), "to-do")
        rows = list(next(current.iter("table")).iter("tr"))
        self.assertEqual(len(rows), 6)
        self.assertEqual([cell.text for cell in rows[0]], ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"])
        self.assertTrue(all(not "".join(cell.itertext()).strip() for row in rows[1:] for cell in row))
        with self.store() as journal:
            self.assertIsNone(journal.recover())

    def test_clearing_table_body_preserves_header_cells_and_structure(self):
        self.remote = ('<html><head><title>Title</title></head><body><div>'
                       '<p id="p:before">Before</p><table id="table:calendar">'
                       '<tr id="tr:head"><td id="td:mon"><p id="p:mon">Mon</p></td>'
                       '<td id="td:tue"><p id="p:tue">Tue</p></td></tr>'
                       '<tr id="tr:one"><td id="td:empty"><br/></td>'
                       '<td id="td:one"><p id="p:one">1</p></td></tr>'
                       '<tr id="tr:two"><td id="td:two"><p id="p:two">2</p></td>'
                       '<td id="td:three"><p id="p:three">3</p></td></tr>'
                       '</table><p id="p:after">After</p></div></body></html>')
        original = ET.fromstring(self.remote)
        loaded = self.load()
        desired = loaded["body"].replace("|  | 1 |", "|  |  |")
        desired = desired.replace("| 2 | 3 |", "|  |  |")
        saved = self.save(note(desired), loaded["view"])
        self.assertTrue(saved.get("ok"), saved)
        self.assertEqual(self.load()["body"], desired)
        current = ET.fromstring(self.remote)
        kept = {node.get("id"): node for node in current.iter()}
        for node in original.iter():
            identifier = node.get("id")
            if identifier and identifier not in {"p:one", "p:two", "p:three"}:
                self.assertIn(identifier, kept)
                self.assertEqual(kept[identifier].attrib, node.attrib)
                if identifier in {"p:before", "p:after", "tr:head", "td:empty"}:
                    self.assertEqual(ET.tostring(kept[identifier]), ET.tostring(node))
        operations = [op for method, _, data in self.calls if method == "PATCH" for op in json.loads(data)]
        self.assertEqual([op["target"] for op in operations], ["p:one", "p:two", "p:three"])
        self.assertTrue(all(op["content"] == "<p><br/></p>" for op in operations))

    def test_partial_deletion_of_repeated_entries_still_preserves_draft(self):
        self.remote = ('<html><head><title>Title</title></head><body><div>'
                       '<p id="p:first" data-tag="to-do">Same</p>'
                       '<p id="p:second" data-tag="to-do">Same</p></div></body></html>')
        loaded = self.load()
        saved = self.save(note("- [ ] Same"), loaded["view"])
        self.assertIn("repeated entry", saved.get("error", ""))
        self.assertFalse(any(method == "PATCH" for method, *_ in self.calls))
        with self.store() as journal:
            self.assertEqual(journal.recover()["body"], "- [ ] Same")

    def test_nested_table_insertion_preserves_parent_and_neighbour_ids(self):
        self.remote = ('<html><head><title>Title</title></head><body><table id="table:outer">'
                       '<tr><td><p id="p:head1">Parent</p></td><td><p id="p:head2">Neighbour</p></td></tr>'
                       '<tr><td><p id="p:before">before</p></td><td><p id="p:neighbour">untouched</p></td></tr>'
                       '</table></body></html>')
        loaded = self.load()
        nested = ('<table><tr><td><p>Parent</p></td><td><p>Neighbour</p></td></tr><tr><td>'
                  '<p>before</p><table><tr><td><p>Inner</p></td></tr><tr><td><p>one</p></td></tr></table>'
                  '</td><td><p>untouched</p></td></tr></table>')
        result = self.save(note(nested), loaded["view"])
        self.assertTrue(result.get("ok"), result)
        current = ET.fromstring(self.remote)
        self.assertEqual(len(list(current.iter("table"))), 2)
        identifiers = {node.get("id") for node in current.iter()}
        self.assertTrue({"table:outer", "p:head1", "p:head2", "p:before", "p:neighbour"}.issubset(identifiers))
        operations = [op for method, _, data in self.calls if method == "PATCH" for op in json.loads(data)]
        self.assertEqual([(op["target"], op["action"]) for op in operations], [("p:before", "insert")])
        reloaded = self.load()
        self.assertEqual(reloaded["body"], nested)
        self.calls.clear()
        result = self.save(note(nested.replace("<p>one</p>", "<p>edited</p>")), reloaded["view"])
        self.assertTrue(result.get("ok"), result)
        edited = ET.fromstring(self.remote)
        self.assertEqual(len(list(edited.iter("table"))), 2)
        self.assertTrue(identifiers - {node.get("id") for node in current.iter("p") if node.text == "one"}
                        <= {node.get("id") for node in edited.iter()})
        targets = [op["target"] for method, _, data in self.calls if method == "PATCH" for op in json.loads(data)]
        self.assertEqual(len(targets), 1)
        self.assertTrue(targets[0].startswith("p:"))

    def test_nested_table_insertion_into_empty_cell(self):
        self.remote = ('<html><head><title>Title</title></head><body><table id="table:outer">'
                       '<tr><td><p id="p:head1">Parent</p></td><td><p id="p:head2">Neighbour</p></td></tr>'
                       '<tr><td><p id="p:empty"><br/></p></td><td><p id="p:neighbour">untouched</p></td></tr>'
                       '</table></body></html>')
        loaded = self.load()
        nested = ('<table><tr><td><p>Parent</p></td><td><p>Neighbour</p></td></tr><tr><td>'
                  '<table><tr><td><p>Inner</p></td></tr><tr><td><p>one</p></td></tr></table>'
                  '</td><td><p>untouched</p></td></tr></table>')
        result = self.save(note(nested), loaded["view"])
        self.assertTrue(result.get("ok"), result)
        current = ET.fromstring(self.remote)
        self.assertEqual(len(list(current.iter("table"))), 2)
        identifiers = {node.get("id") for node in current.iter()}
        self.assertTrue({"table:outer", "p:head1", "p:head2", "p:neighbour"}.issubset(identifiers))
        self.assertEqual(self.load()["body"], nested)

    def test_table_deletion_preserves_surrounding_content(self):
        nested = ('<table><tr><td><p>Parent</p></td><td><p>Neighbour</p></td></tr><tr><td>'
                  '<table><tr><td><p>Inner</p></td></tr><tr><td><p>value</p></td></tr></table>'
                  '</td><td><p>untouched</p></td></tr></table>')
        cases = [
            ("entire table", "Before\n\n" + nested + "\n\nAfter", "Before\n\nAfter", 0),
            ("inner table", nested, "| Parent | Neighbour |\n|---|---|\n|  | untouched |", 1),
        ]
        for name, source, expected, tables in cases:
            with self.subTest(name=name):
                self.remote = page_html(note(source))
                tree = ET.fromstring(self.remote)
                labels = {"Parent", "Neighbour", "untouched"} if tables else {"Before", "After"}
                neighbours = {node.get("id") for node in tree.iter("p")
                              if node.text in labels}
                if tables:
                    neighbours.add(next(tree.iter("table")).get("id"))
                loaded = self.load()
                result = self.save(note(expected), loaded["view"])
                self.assertTrue(result.get("ok"), result)
                current = ET.fromstring(self.remote)
                self.assertEqual(len(list(current.iter("table"))), tables)
                self.assertTrue(neighbours <= {node.get("id") for node in current.iter()})
                reloaded = self.load()
                self.assertEqual(onenote.normalize_note(reloaded), onenote.normalize_note(note(expected)))
                if tables:
                    refilled = expected.replace("|  | untouched |", "| new text | untouched |")
                    result = self.save(note(refilled), reloaded["view"])
                    self.assertTrue(result.get("ok"), result)
                    self.assertEqual(onenote.normalize_note(self.load()), onenote.normalize_note(note(refilled)))

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=WORK.name)
        self.addCleanup(self.temp.cleanup)
        self.remote = page_html(note("one\n\nmiddle\n\nthree"))
        self.calls = []
        self.refuse_title = False
        self.refuse_body = False
        self.refuse_paragraphs = False
        self.write_ids = 0
        self.addCleanup(patch.stopall)
        self.raw_transport = onenote.graph_raw
        patch.object(onenote, "merge_store", self.store).start()
        patch.object(onenote, "graph_raw", self.graph).start()
        patch.object(onenote, "graph", side_effect=AssertionError("unexpected network request")).start()

    def store(self, page_id="page"):
        return MergeStore(self.temp.name, "onenote", "test-account", page_id,
                          normalize=onenote.normalize_note, stale_seconds=120)

    def graph(self, method, path, data=None, content_type=None, **options):
        self.calls.append((method, path, data))
        if method == "GET":
            return 200, self.remote
        if method == "PATCH":
            operations = json.loads(data)
            current = ET.fromstring(self.remote)
            for operation in operations:
                if operation["target"] == "title":
                    if self.refuse_title:
                        return 500, '{"error":{"message":"title refused"}}'
                    current.find("./head/title").text = html.unescape(operation["content"])
                else:
                    if self.refuse_body:
                        return 400, '{"error":{"message":"body refused"}}'
                    if self.refuse_paragraphs and operation["target"].startswith("p:"):
                        return 400, '{"error":{"message":"The PATCH target P for action replace is not supported"}}'
                    replacements = list(ET.fromstring("<root>" + operation["content"] + "</root>"))
                    for replacement in replacements:
                        for child in replacement.iter():
                            self.write_ids += 1
                            child.set("id", "%s:written%d" % (child.tag, self.write_ids))
                    if operation["target"] == "body":
                        self.assertEqual(operation["action"], "append", "a save must never replace the page body")
                        body = current.find("body")
                        outer = body.find("div")
                        (outer if outer is not None else body).extend(replacements)
                        continue
                    found = [(parent, child) for parent in current.iter() for child in parent
                             if child.get("id") == operation["target"]]
                    self.assertEqual(len(found), 1, "PATCH targeted a missing or repeated generated ID")
                    parent, child = found[0]
                    index = list(parent).index(child)
                    if operation["action"] == "replace":
                        parent[index:index + 1] = replacements
                    elif operation["action"] == "append":
                        child.extend(replacements)
                    else:
                        self.assertEqual(operation["action"], "insert")
                        index += int(operation.get("position", "after") == "after")
                        parent[index:index] = replacements
            self.remote = ET.tostring(current, encoding="unicode")
            return 204, ""
        raise AssertionError("unexpected request " + method)

    def invoke(self, function, *args):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            try:
                function(*args)
            except SystemExit:
                pass
        return json.loads(output.getvalue())

    def load(self):
        return self.invoke(onenote.cmd_onenote_page, "page")

    def save(self, value, view, resolution=None):
        path = Path(self.temp.name) / "payload.json"
        path.write_text(json.dumps(dict(value, view=view, resolution=resolution)))
        return self.invoke(onenote.cmd_onenote_update, "page", str(path))

    @contextlib.contextmanager
    def http_transport(self, endpoint):
        """Use the actual authentication wrapper, HTTP handling and retry loop."""
        with (patch.object(onenote, "graph_raw", self.raw_transport),
              patch.object(onenote, "access_token", return_value="synthetic-token"),
              patch.object(onenote.msgraph, "RATE_KEY", None),
              patch.object(onenote.msgraph.urllib.request, "urlopen", side_effect=endpoint)):
            yield

    def response(self, request):
        status, content = self.graph(request.get_method(), request.full_url.removeprefix(onenote.GRAPH), request.data)
        response = io.BytesIO(content.encode())
        response.status = status
        return response

    def test_uncertain_insertion_is_reconciled_before_an_explicit_retry(self):
        loaded = self.load()
        local = note("one\n\nadded\n\nmiddle\n\nthree")
        failed = False

        def endpoint(request, **options):
            nonlocal failed
            response = self.response(request)
            if request.get_method() == "PATCH" and not failed:
                # The service applied the insertion but returned an error.
                failed = True
                raise urllib.error.HTTPError(request.full_url, 503, "uncertain", {"Retry-After": "0"}, io.BytesIO(b"{}"))
            return response

        with self.http_transport(endpoint):
            result = self.save(local, loaded["view"])
            self.assertIn("error", result)
            self.assertNotIn("kind", result)
            self.assertEqual([method for method, _, _ in self.calls], ["GET", "GET", "PATCH"])
            with self.store() as store:
                self.assertEqual(store.recover()["body"], onenote.normalize_note(local)["body"])
            # A deliberate retry observes that the content already landed.
            result = self.save(local, loaded["view"])
            self.assertTrue(result.get("ok"), result)
            self.assertEqual([method for method, _, _ in self.calls], ["GET", "GET", "PATCH", "GET"])
            self.assertEqual(onenote.normalize_note(onenote.onenote_md.html_to_markdown(self.remote)), onenote.normalize_note(local))

    def test_503_replacement_restarts_with_a_fresh_merge(self):
        loaded = self.load()
        local = note("APP\n\nmiddle\n\nthree")
        failed = False

        def endpoint(request, **options):
            nonlocal failed
            if request.get_method() == "PATCH" and not failed:
                failed = True
                self.calls.append(("PATCH", request.full_url, request.data))
                raise urllib.error.HTTPError(request.full_url, 503, "uncertain", {"Retry-After": "0"}, io.BytesIO(b"{}"))
            return self.response(request)

        with self.http_transport(endpoint):
            with self.assertRaises(onenote.msgraph.ratelimit.Throttled):
                self.save(local, loaded["view"])
            self.remote = page_html(note("one\n\nmiddle\n\nPHONE"))
            result = self.save(local, loaded["view"])
        self.assertTrue(result.get("ok"), result)
        self.assertEqual(result["body"], onenote.normalize_note(note("APP\n\nmiddle\n\nPHONE"))["body"])
        self.assertEqual([method for method, _, _ in self.calls], ["GET", "GET", "PATCH", "GET", "PATCH"])

    def test_fetch_merge_write_and_next_edit(self):
        loaded = self.load()
        self.remote = page_html(note("one\n\nmiddle\n\nPHONE"))
        first = self.save(note("APP\n\nmiddle\n\nthree"), loaded["view"])
        self.assertTrue(first["ok"])
        self.assertTrue(first["merged"])
        self.assertEqual(first["body"], onenote.normalize_note(note("APP\n\nmiddle\n\nPHONE"))["body"])
        self.assertEqual([call[0] for call in self.calls], ["GET", "GET", "PATCH"])
        # The editor still shows its old third paragraph while this save runs.
        second = self.save(note("APP AGAIN\n\nmiddle\n\nthree"), loaded["view"])
        self.assertEqual(second["body"], onenote.normalize_note(note("APP AGAIN\n\nmiddle\n\nPHONE"))["body"])

    def test_different_checkboxes_on_phone_and_app_merge(self):
        original = note("- [ ] Apples\n- [ ] Bread\n- [ ] Coffee")
        self.remote = page_html(original)
        loaded = self.load()
        self.remote = page_html(note(original["body"].replace("[ ] Apples", "[x] Apples")))
        ours = note(original["body"].replace("[ ] Bread", "[x] Bread"))
        result = self.save(ours, loaded["view"])
        self.assertTrue(result.get("ok"), result)
        expected = note(original["body"].replace("[ ] Apples", "[x] Apples").replace("[ ] Bread", "[x] Bread"))
        self.assertEqual(result["body"], onenote.normalize_note(expected)["body"])
        stored = onenote.onenote_md.html_to_markdown(self.remote)
        self.assertEqual(onenote.normalize_note(stored), onenote.normalize_note(expected))
        operations = [operation for method, _, data in self.calls if method == "PATCH" for operation in json.loads(data)]
        self.assertEqual(len(operations), 1)
        self.assertTrue(operations[0]["target"].startswith("p:"))
        self.assertNotIn("Apples", operations[0]["content"])

    def test_late_phone_checkbox_edit_still_targets_the_same_item(self):
        self.remote = page_html(note("- [ ] Apples\n- [ ] Bread\n- [ ] Coffee"))
        phone = ET.fromstring(self.remote)
        phone_item = next(node for node in phone.iter("p") if node.text == "Apples")
        phone_id = phone_item.get("id")
        loaded = self.load()
        saved = self.save(note(loaded["body"].replace("[ ] Bread", "[x] Bread")), loaded["view"])
        self.assertTrue(saved.get("ok"), saved)
        # A phone syncs its earlier view after the app's write. Its original
        # item must still exist, otherwise OneNote can resurrect it elsewhere.
        current = ET.fromstring(self.remote)
        targets = [node for node in current.iter("p") if node.get("id") == phone_id]
        self.assertEqual(len(targets), 1)
        targets[0].set("data-tag", "to-do:completed")
        self.remote = ET.tostring(current, encoding="unicode")
        reloaded = self.load()
        self.assertEqual(reloaded["body"], "- [x] Apples\n- [x] Bread\n- [ ] Coffee")
        self.assertEqual(len(list(current.iter("p"))), 3)

    def test_rejected_item_update_never_falls_back_to_replacing_the_list(self):
        self.remote = page_html(note("- [ ] Apples\n- [ ] Bread"))
        before = self.remote
        loaded = self.load()
        self.refuse_paragraphs = True
        result = self.save(note("- [ ] Apples\n- [x] Bread"), loaded["view"])
        self.assertIn("not supported", result["error"])
        self.assertEqual(self.remote, before)
        operations = [operation for method, _, data in self.calls if method == "PATCH" for operation in json.loads(data)]
        self.assertEqual(len(operations), 1)
        self.assertNotEqual(operations[0]["target"], "body")
        self.assertTrue(self.load()["recovered"])

    def test_uncertain_insertion_is_not_automatically_repeated(self):
        operations = [
            {"target": "p:anchor", "action": "replace", "content": "<p>edited</p>"},
            {"target": "p:anchor", "action": "insert", "content": "<p>new</p>"},
            {"target": "body", "action": "append", "content": "<p>new</p>"},
        ]
        for operation in operations:
            with self.subTest(action=operation["action"]):
                with patch.object(onenote, "graph_raw", return_value=(500, "uncertain")) as request:
                    onenote.patch_page("/page/content", [operation], [])
                expected = onenote.msgraph.RetryPolicy.RESTART if operation["action"] == "replace" else onenote.msgraph.RetryPolicy.NEVER
                self.assertEqual(request.call_args.kwargs["retry_policy"], expected)

    def test_checkbox_state_preserves_native_inline_formatting(self):
        cases = (("ul", "Intro"), ("ol", "Intro"), ("ol", '<span data-tag="to-do">Intro</span>'))
        for index, (container, intro) in enumerate(cases):
            for state, updated in (("to-do", "to-do:completed"), ("to-do:completed", "to-do")):
                with self.subTest(container=container, state=state):
                    self.remote = ('<html><head><title>Title</title></head><body><div id="div:root">'
                                   '<%s id="%s:list"><li id="li:intro">%s</li>'
                                   '<li id="li:task" style="margin-left:8px"><span data-tag="%s" data-id="task">'
                                   '<span style="color:red;font-family:Arial">Task</span></span></li>'
                                   '</%s></div></body></html>') % (container, container, intro, state, container)
                    # Each representation has a separate editing baseline.
                    with patch.object(onenote, "merge_store", side_effect=lambda page: self.store(str(index) + state)):
                        loaded = self.load()
                        before = "[x]" if state.endswith(":completed") else "[ ]"
                        after = "[x]" if updated.endswith(":completed") else "[ ]"
                        result = self.save(note(loaded["body"].replace(before + ' <span style="color:#ff0000;">Task</span>', after + ' <span style="color:#ff0000;">Task</span>')), loaded["view"])
                    self.assertTrue(result.get("ok"), result)
                    tree = ET.fromstring(self.remote)
                    carrier = next(node for node in tree.iter("span") if node.get("data-id") == "task")
                    self.assertEqual(carrier.get("data-tag"), updated)
                    self.assertEqual(carrier.find("span").get("style"), "color:red;font-family:Arial")
                    self.assertEqual(list(tree.iter("li"))[1].get("style"), "margin-left:8px")
                    self.assertEqual(list(tree.iter("li"))[0].get("id"), "li:intro")
                    self.assertEqual(tree.find(".//" + container).get("id"), container + ":list")

    def assert_paragraph_edit_preserves_neighbours(self, body):
        original = note("one\n\nmiddle\n\nlast")
        self.remote = page_html(original)
        loaded = self.load()
        anchor = next(node.get("id") for node in ET.fromstring(self.remote).iter("p") if node.text == "one")
        self.calls = []
        result = self.save(note(body), loaded["view"])
        self.assertTrue(result.get("ok"), result)
        current = ET.fromstring(self.remote)
        self.assertEqual(next(node.get("id") for node in current.iter("p") if node.text == "one"), anchor)
        self.assertEqual(onenote.normalize_note(onenote.onenote_md.html_to_markdown(self.remote)),
                         onenote.normalize_note(note(body)))
        self.assertTrue(all(operation["target"] != "body" for method, _, data in self.calls if method == "PATCH"
                            for operation in json.loads(data)))

    def test_inserted_paragraph_preserves_neighbours(self):
        self.assert_paragraph_edit_preserves_neighbours("one\n\nadded\n\nmiddle\n\nlast")

    def test_deleted_paragraph_preserves_neighbours(self):
        self.assert_paragraph_edit_preserves_neighbours("one\n\nlast")

    def test_expanded_final_paragraph_preserves_neighbours(self):
        self.assert_paragraph_edit_preserves_neighbours("one\n\nmiddle\n\nLAST\n\nextra")

    def test_identical_item_names_keep_positions_and_inline_formatting(self):
        self.remote = ('<html><head><title>Title</title></head><body><div>'
                       '<p id="p:first" data-tag="to-do"><span style="color:#123456">Same</span></p>'
                       '<p id="p:second" data-tag="to-do"><span style="color:#abcdef">Same</span></p>'
                       '</div></body></html>')
        loaded = self.load()
        result = self.save(note(loaded["body"].replace('[ ] <span style="color:#abcdef;">', '[x] <span style="color:#abcdef;">')), loaded["view"])
        self.assertTrue(result.get("ok"), result)
        operations = [operation for method, _, data in self.calls if method == "PATCH" for operation in json.loads(data)]
        self.assertEqual(len(operations), 1)
        self.assertEqual(operations[0]["target"], "p:second")
        self.assertIn('style="color:#abcdef"', operations[0]["content"])

    def test_repeated_checkbox_and_prose_edits_keep_both_devices_changes(self):
        self.remote = page_html(note("- [ ] Same\n- [ ] Same\n- [x] Same\n\nFooter"))
        loaded = self.load()
        self.remote = page_html(note("- [ ] Same\n- [ ] Same\n- [ ] Same\n\nFooter"))
        result = self.save(note("- [ ] Same\n- [x] Same\n- [x] Same\n\nNew footer"), loaded["view"])
        self.assertTrue(result.get("ok"), result)
        self.assertEqual(self.load()["body"], "- [ ] Same\n- [x] Same\n- [ ] Same\n\nNew footer")

    def test_repeated_labels_and_footer_edit_preserve_the_untouched_item(self):
        self.remote = ('<html><head><title>Title</title></head><body><div>'
                       '<p id="p:first" data-tag="to-do">Same</p>'
                       '<p id="p:second" data-tag="to-do"><span style="color:#abcdef">Same</span></p>'
                       '<p id="p:footer">Footer</p></div></body></html>')
        loaded = self.load()
        result = self.save(note(loaded["body"].replace("[ ] Same", "[x] Same").replace("Footer", "New footer")), loaded["view"])
        self.assertTrue(result.get("ok"), result)
        kept = next(node for node in ET.fromstring(self.remote).iter("p") if node.get("id") == "p:second")
        self.assertEqual(kept.get("data-tag"), "to-do")
        self.assertEqual(kept.find("span").get("style"), "color:#abcdef")
        targets = [op["target"] for method, _, data in self.calls if method == "PATCH" for op in json.loads(data)]
        self.assertEqual(targets, ["p:first", "p:footer"])

    def test_blank_line_does_not_turn_a_checkbox_edit_into_a_page_replacement(self):
        self.remote = ('<html><head><title>Title</title></head><body><div>'
                       '<p id="p:first" data-tag="to-do">Apples</p><br/>'
                       '<p id="p:second" data-tag="to-do">Bread</p></div></body></html>')
        loaded = self.load()
        result = self.save(note(loaded["body"].replace("[ ] Bread", "[x] Bread")), loaded["view"])
        self.assertTrue(result.get("ok"), result)
        operations = [op for method, _, data in self.calls if method == "PATCH" for op in json.loads(data)]
        self.assertEqual([op["target"] for op in operations], ["p:second"])
        self.assertEqual(len(list(ET.fromstring(self.remote).iter("br"))), 1)

    def test_mobile_table_and_boundary_breaks_do_not_block_pending_save(self):
        self.remote = ('<html><head><title>Title</title></head><body><div id="div:main">'
                       '<p id="p:first" data-tag="to-do">Apples</p>'
                       '<p id="p:remove">Remove this heading</p>'
                       '<p id="p:second" data-tag="to-do">Bread</p></div></body></html>')
        loaded = self.load()
        local = loaded["body"].replace("\n\nRemove this heading\n", "")
        table = ('<table id="table:mobile" style="border:1px solid;border-collapse:collapse">'
                 '<tr id="tr:first"><td id="td:first" style="border:1px solid"><br/></td>'
                 '<td id="td:second" style="border:1px solid"><br/></td></tr>'
                 '<tr id="tr:second"><td id="td:third" style="border:1px solid"><br/></td>'
                 '<td id="td:fourth" style="border:1px solid"><br/></td></tr></table>')
        self.remote = self.remote.replace('<p id="p:first"', '<br/><br/><p id="p:first"')
        self.remote = self.remote.replace('</div></body>', '<br/><br/>' + table + '</div>'
                                          '<div id="div:empty"><br/><br/></div></body>')
        result = self.save(note(local), loaded["view"])
        self.assertTrue(result.get("ok"), result)
        self.assertTrue(result.get("merged"), result)
        self.assertNotIn("Remove this heading", result["body"])
        self.assertIn("|  |  |\n|---|---|\n|  |  |", result["body"])
        operations = [op for method, _, data in self.calls if method == "PATCH" for op in json.loads(data)]
        self.assertEqual(operations, [{"target": "p:remove", "action": "replace", "content": "<div></div>"}])
        current = ET.fromstring(self.remote)
        self.assertEqual(ET.tostring(next(current.iter("table"))), ET.tostring(ET.fromstring(table)))
        self.assertEqual(len(list(current.iter("br"))), 10)
        self.assertEqual(self.load()["body"], result["body"])
        with self.store() as journal:
            self.assertIsNone(journal.recover())

    def test_append_after_table_keeps_ignored_trailing_breaks(self):
        self.remote = ('<html><head><title>Title</title></head><body><div>'
                       '<table id="table:mobile"><tr><td><br/></td></tr></table><br/>'
                       '</div><div id="div:empty"><br/></div></body></html>')
        loaded = self.load()
        result = self.save(note(loaded["body"] + "\n\nAfter table"), loaded["view"])
        self.assertTrue(result.get("ok"), result)
        operations = [op for method, _, data in self.calls if method == "PATCH" for op in json.loads(data)]
        self.assertEqual([(op["target"], op["action"], op.get("position")) for op in operations],
                         [("table:mobile", "insert", "after")])
        self.assertEqual(len(list(ET.fromstring(self.remote).iter("br"))), 3)
        self.assertEqual(self.load()["body"], result["body"])

    def test_deletion_can_turn_internal_breaks_into_boundary_breaks(self):
        table = ('<table id="table:remove"><tr><td><p id="p:cell">Heading</p></td></tr>'
                 '<tr><td><br/></td></tr></table>')
        kept = '<p id="p:keep" data-tag="to-do">Keep this</p>'
        cases = [
            ("last table", kept + '<br/><br/>' + table, "- [ ] Keep this", ["table:remove"]),
            ("first table", table + '<br/><br/>' + kept, "- [ ] Keep this", ["table:remove"]),
            ("whole page", kept + '<br/>' + table, "", ["p:keep", "table:remove"]),
            ("last paragraph", kept + '<br/><p id="p:remove">Remove this</p>',
             "- [ ] Keep this", ["p:remove"]),
        ]
        for name, content, desired, targets in cases:
            with self.subTest(name=name):
                with self.store() as journal:
                    journal.discard()
                self.remote = ('<html><head><title>Title</title></head><body>'
                               '<div id="div:main">' + content + '</div></body></html>')
                breaks = len(list(ET.fromstring(self.remote).iter("br")))
                loaded = self.load()
                self.calls.clear()
                result = self.save(note(desired), loaded["view"])
                self.assertTrue(result.get("ok"), result)
                self.assertEqual(self.load()["body"], desired)
                operations = [op for method, _, data in self.calls if method == "PATCH" for op in json.loads(data)]
                self.assertEqual([op["target"] for op in operations], targets)
                current = ET.fromstring(self.remote)
                self.assertEqual(len(list(current.iter("table"))), 0)
                self.assertEqual(len(list(current.iter("br"))), breaks - int("table:remove" in targets))
                if desired:
                    remaining = next(node for node in current.iter("p") if node.get("id") == "p:keep")
                    self.assertEqual(ET.tostring(remaining), ET.tostring(ET.fromstring(kept)))
                with self.store() as journal:
                    self.assertIsNone(journal.recover())

    def test_table_deletion_merges_with_remote_spacing_change(self):
        table = ('<table id="table:mobile"><tr><td><br/></td><td><br/></td></tr>'
                 '<tr><td><br/></td><td><br/></td></tr></table>')
        self.remote = ('<html><head><title>Title</title></head><body><div>'
                       '<p id="p:keep" data-tag="to-do">Apples</p><br/><br/><br/>'
                       + table + '</div></body></html>')
        loaded = self.load()
        self.remote = self.remote.replace('</p><br/><br/><br/>', '</p><br/>')
        result = self.save(note("- [ ] Apples"), loaded["view"])
        self.assertTrue(result.get("ok"), result)
        self.assertNotIn("conflict", result)
        self.assertEqual(self.load()["body"], "- [ ] Apples")
        operations = [op for method, _, data in self.calls if method == "PATCH" for op in json.loads(data)]
        self.assertEqual(operations, [{"target": "table:mobile", "action": "replace", "content": "<div></div>"}])

    def test_deleting_an_internal_untargetable_break_still_preserves_draft(self):
        self.remote = ('<html><head><title>Title</title></head><body><div>'
                       '<p id="p:first">Before</p><br/><p id="p:second">After</p>'
                       '</div></body></html>')
        loaded = self.load()
        result = self.save(note("Before\n\nAfter"), loaded["view"])
        self.assertIn("no editable target", result.get("error", ""))
        self.assertFalse(any(method == "PATCH" for method, *_ in self.calls))
        with self.store() as journal:
            self.assertEqual(journal.recover()["body"], onenote.normalize_note(note("Before\n\nAfter"))["body"])

    def test_inserting_a_blank_line_preserves_existing_elements(self):
        self.remote = ('<html><head><title>Title</title></head><body><div>'
                       '<p id="p:first" data-tag="to-do">Apples</p><br/>'
                       '<p id="p:second" data-tag="to-do">Bread</p></div></body></html>')
        loaded = self.load()
        result = self.save(note(loaded["body"].replace("\u00a0", "\u00a0\n\n\u00a0")), loaded["view"])
        self.assertTrue(result.get("ok"), result)
        current = ET.fromstring(self.remote)
        self.assertEqual(len(list(current.iter("br"))), 2)
        self.assertTrue({"p:first", "p:second"}.issubset({node.get("id") for node in current.iter()}))

    def test_unchanged_content_needs_no_patch_target(self):
        self.remote = ('<html><head><title>Title</title></head><body><div>'
                       '<cite>Keep this</cite><p id="p:edit">Original</p></div></body></html>')
        loaded = self.load()
        result = self.save(note(loaded["body"].replace("Original", "Edited")), loaded["view"])
        self.assertTrue(result.get("ok"), result)
        self.assertEqual(next(ET.fromstring(self.remote).iter("cite")).text, "Keep this")

    def test_ordinary_list_item_edit_preserves_list_and_neighbour(self):
        self.remote = ('<html><head><title>Title</title></head><body><div>'
                       '<ul id="ul:list"><li id="li:first">Apples</li><li id="li:second">Bread</li></ul>'
                       '<p id="p:footer">Footer</p></div></body></html>')
        loaded = self.load()
        result = self.save(note(loaded["body"].replace("Bread", "Coffee")), loaded["view"])
        self.assertTrue(result.get("ok"), result)
        identifiers = {node.get("id") for node in ET.fromstring(self.remote).iter()}
        self.assertTrue({"ul:list", "li:first", "p:footer"}.issubset(identifiers))
        operations = [op for method, _, data in self.calls if method == "PATCH" for op in json.loads(data)]
        self.assertEqual([op["target"] for op in operations], ["li:second"])

    def test_nested_list_item_edit_preserves_its_ancestors(self):
        self.remote = page_html(note("- Parent\n  - Apples\n  - Bread\n- Other"))
        loaded = self.load()
        original = ET.fromstring(self.remote)
        parent_id = next(node.get("id") for node in original.iter("li") if node.text == "Parent")
        result = self.save(note(loaded["body"].replace("Bread", "Coffee")), loaded["view"])
        self.assertTrue(result.get("ok"), result)
        self.assertIn(parent_id, {node.get("id") for node in ET.fromstring(self.remote).iter("li")})

    def test_table_cell_edit_preserves_other_cells(self):
        self.remote = ('<html><head><title>Title</title></head><body><div><table id="table:one">'
                       '<tr><td><p id="p:apple">Apples</p></td><td><p id="p:bread">Bread</p></td></tr>'
                       '</table></div></body></html>')
        loaded = self.load()
        result = self.save(note(loaded["body"].replace("Bread", "**Coffee**")), loaded["view"])
        self.assertTrue(result.get("ok"), result)
        identifiers = {node.get("id") for node in ET.fromstring(self.remote).iter()}
        self.assertTrue({"table:one", "p:apple"}.issubset(identifiers))
        self.assertIn("**Coffee**", self.load()["body"])

    def test_missing_target_keeps_the_draft_without_replacing_the_page(self):
        self.remote = '<html><head><title>Title</title></head><body><div><p>Original</p></div></body></html>'
        loaded = self.load()
        result = self.save(note("Edited"), loaded["view"])
        self.assertIn("no editable target", result["error"])
        self.assertFalse(any(method == "PATCH" for method, _, _ in self.calls))
        self.assertEqual(self.load()["body"], "Edited")

    def test_invalid_simulation_keeps_the_draft_without_writing(self):
        loaded = self.load()
        invalid = onenote.onenote_patch.Plan((), "<body><p>Wrong</p></body>", frozenset())
        with patch.object(onenote.onenote_patch, "plan", return_value=invalid):
            result = self.save(note("Edited"), loaded["view"])
        self.assertIn("could not preserve", result["error"])
        self.assertFalse(any(method == "PATCH" for method, _, _ in self.calls))
        self.assertEqual(self.load()["body"], "Edited")

    def test_simulation_checks_unchanged_identity_as_well_as_text(self):
        loaded = self.load()
        real_simulate = onenote.onenote_patch.simulate

        def lose_identity(tree, commands):
            simulated = real_simulate(tree, commands)
            for node in onenote.onenote_patch.walk(simulated):
                if node.tag == "p" and onenote.onenote_patch.text(node) == "three":
                    node.attrs.pop("id")
            return simulated

        with patch.object(onenote.onenote_patch, "simulate", side_effect=lose_identity):
            result = self.save(note(loaded["body"].replace("one", "Edited")), loaded["view"])
        self.assertIn("lost its identity", result["error"])
        self.assertFalse(any(method == "PATCH" for method, _, _ in self.calls))

    def test_empty_page_is_populated_by_appending(self):
        self.remote = '<html><head><title>Title</title></head><body><div/></body></html>'
        loaded = self.load()
        result = self.save(note("First paragraph"), loaded["view"])
        self.assertTrue(result.get("ok"), result)
        self.assertEqual(self.load()["body"], "First paragraph")

    def test_conflict_never_writes_and_recovery_can_be_resolved(self):
        loaded = self.load()
        self.remote = page_html(note("PHONE\n\nmiddle\n\nthree"))
        ours = note("APP\n\nmiddle\n\nthree")
        result = self.save(ours, loaded["view"])
        self.assertTrue(result["conflict"])
        self.assertEqual([call[0] for call in self.calls], ["GET", "GET"])
        recovered = self.load()
        self.assertTrue(recovered["recovered"])
        self.assertEqual(recovered["body"], onenote.normalize_note(ours)["body"])
        resolution = {"id": result["conflict"]["id"], "choices": {
            part["id"]: "both" for part in result["conflict"]["parts"]}}
        saved = self.save(ours, loaded["view"], resolution)
        self.assertTrue(saved["ok"])
        self.assertIn("APP", saved["body"])
        self.assertIn("PHONE", saved["body"])

    def test_remote_changes_during_conflict_review_require_another_review(self):
        loaded = self.load()
        self.remote = page_html(note("phone"))
        result = self.save(note("app"), loaded["view"])
        resolution = {"id": result["conflict"]["id"], "choices": {
            part["id"]: "local" for part in result["conflict"]["parts"]}}
        self.remote = page_html(note("new phone changes"))
        result = self.save(note("app"), loaded["view"], resolution)
        self.assertTrue(result["conflict"])
        self.assertFalse(any(call[0] == "PATCH" for call in self.calls))

    def test_no_change_has_no_write(self):
        loaded = self.load()
        result = self.save(loaded, loaded["view"])
        self.assertTrue(result["ok"])
        self.assertFalse(any(call[0] == "PATCH" for call in self.calls))

    def test_remote_only_title_change_survives_local_body_save(self):
        loaded = self.load()
        self.remote = page_html(note(loaded["body"], "Phone title"))
        saved = self.save(note("app body"), loaded["view"])
        self.assertEqual(saved["title"], "Phone title")
        operations = [json.loads(call[2]) for call in self.calls if call[0] == "PATCH"]
        self.assertTrue(all(operation["target"] != "title" for batch in operations for operation in batch))

    def test_failed_title_retains_draft_and_correct_next_merge_base(self):
        loaded = self.load()
        self.refuse_title = True
        result = self.save(note("first", "New title"), loaded["view"])
        self.assertIn("title", result["error"])
        self.assertEqual(self.load()["body"], "first")
        self.refuse_title = False
        result = self.save(note("second", "New title"), loaded["view"])
        self.assertEqual(result["body"], "second")
        self.assertEqual(result["title"], "New title")

    def test_missing_base_and_unrepresentable_remote_do_not_write(self):
        with self.assertRaises(ValueError):
            self.save(note("app"), "missing")
        self.assertEqual(self.calls, [])
        loaded = self.load()
        self.remote = '<html><head><title>Title</title></head><body><object data="ink"/></body></html>'
        result = self.save(note("app"), loaded["view"])
        self.assertIn("cannot be saved safely", result["error"])
        self.assertFalse(any(call[0] == "PATCH" for call in self.calls))

    def test_stale_read_does_not_revert_previous_merge(self):
        old = self.remote
        loaded = self.load()
        self.save(note("first"), loaded["view"])
        self.remote = old
        count = len(self.calls)
        with self.assertRaises(StaleRemote):
            self.save(note("second"), loaded["view"])
        self.assertEqual([call[0] for call in self.calls[count:]], ["GET"])
        self.assertEqual(self.load()["body"], "second")

    def test_failed_body_save_retains_local_and_observed_remote(self):
        loaded = self.load()
        self.refuse_body = True
        result = self.save(note("app"), loaded["view"])
        self.assertIn("body refused", result["error"])
        with self.store() as store:
            self.assertEqual(store._state["draft"]["local"]["body"], "app")
            self.assertEqual(store._state["draft"]["remote"]["body"], loaded["body"])

    def test_poll_does_not_replace_an_editing_baseline_or_recover_a_draft(self):
        loaded = self.load()
        with self.store() as store:
            store.stage(loaded["view"], note("unsaved"))
        checked = self.invoke(onenote.cmd_onenote_page, "page", True)
        self.assertEqual(checked["body"], loaded["body"])
        self.assertNotIn("view", checked)
        with self.store() as store:
            self.assertEqual(store._state["views"][loaded["view"]]["body"], loaded["body"])

    def test_remote_image_added_during_local_edit_is_kept_without_upload(self):
        loaded = self.load()
        src = "https://graph.microsoft.com/v1.0/me/onenote/resources/new/$value"
        path = str(Path(onenote.ONENOTE_IMG_DIR) / "new-image")
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        Path(path).write_bytes(b"synthetic image")
        patch.object(onenote, "cached_image", return_value="file://" + path).start()
        self.remote = ('<html><head><title>Title</title></head><body><div>'
                       '<div id="div:text"><p id="p:one">one</p><p id="p:middle">middle</p><p id="p:three">three</p></div>'
                       '<img id="img:new" src="' + src + '" alt="Phone photo"/>'
                       '</div></body></html>')
        writes = []

        def record_patch(url, commands, parts):
            writes.extend(commands)
            self.assertEqual(parts, [])
            return 204, ""

        patch.object(onenote, "patch_page", record_patch).start()
        result = self.save(note("APP\n\nmiddle\n\nthree"), loaded["view"])
        self.assertTrue(result.get("ok"), result)
        self.assertIn("Phone photo", result["body"])
        self.assertTrue(writes)
        self.assertTrue(all(command["target"] != "img:new" for command in writes))
        self.assertTrue(all("<img" not in command.get("content", "") for command in writes))

    def test_page_read_keeps_alias_for_a_previously_uploaded_paste(self):
        paste = Path(self.temp.name) / "paste.png"
        paste.write_bytes(b"synthetic image")
        entry = {"src": "https://graph.microsoft.com/v1.0/me/onenote/resources/paste/$value", "width": 200}
        onenote.save_private(onenote.IMAGE_INDEX, {"staged": {str(paste): entry}})
        self.load()
        self.assertEqual(onenote.known_image(paste.as_uri()), entry)

    def test_upload_aliases_follow_markers_instead_of_document_order(self):
        uploads = onenote.Uploads()
        files = [Path(self.temp.name) / (name + ".png") for name in ("first", "second")]
        references = []
        for index, path in enumerate(files):
            path.write_bytes(b"synthetic image " + bytes([index]))
            references.append(uploads.ref(path.as_uri(), "")[0])
        first, second = list(uploads.staged.values())
        source = "https://graph.microsoft.com/v1.0/me/onenote/resources/"
        html = ('<body><div><div><img data-id="' + second["dataId"] + '" src="' + source + 'second/$value"/>'
                '<img data-id="' + first["dataId"] + '" src="' + source + 'first/$value"/></div></div></body>')
        rendered = uploads.render_uploads("".join('<img src="' + reference + '"/>' for reference in references))
        self.assertIn(first["dataId"], rendered)
        self.assertIn(second["dataId"], rendered)
        onenote.remember_staged(uploads.staged, html)
        self.assertEqual(onenote.known_image(files[0].as_uri())["src"], source + "first/$value")
        self.assertEqual(onenote.known_image(files[1].as_uri())["src"], source + "second/$value")

    def test_only_a_changed_existing_image_is_materialized(self):
        path = Path(self.temp.name) / "photo.png"
        path.write_bytes(b"synthetic image")
        source = "https://graph.microsoft.com/v1.0/me/onenote/resources/photo/$value"
        onenote.save_private(onenote.IMAGE_INDEX, {"staged": {str(path): {"src": source, "width": 100}}})
        uploads = onenote.Uploads()
        uploads.ref(path.as_uri(), "")
        unchanged = uploads.materialize([{"target": "p:text", "action": "replace", "content": "<p>New text</p>"}])
        self.assertEqual(uploads.parts, [])
        self.assertNotIn("<img", unchanged[0]["content"])
        resized = uploads.materialize([{"target": "img:photo", "action": "replace",
                                        "content": '<img src="' + source + '" width="200"/>'}])
        self.assertEqual(len(uploads.parts), 1)
        self.assertIn('src="name:' + uploads.parts[0][0] + '"', resized[0]["content"])
        self.assertNotIn(source, resized[0]["content"])
        self.assertEqual(next(iter(uploads.staged.values()))["width"], 200)

    def test_no_longer_readable_image_blocks_write(self):
        loaded = self.load()
        patch.object(onenote, "cached_image", return_value=None).start()
        self.remote = ('<html><body><p>one</p><img src="https://example.invalid/picture"/></body></html>')
        result = self.save(note("app"), loaded["view"])
        self.assertIn("cannot be saved safely", result["error"])
        self.assertFalse(any(call[0] == "PATCH" for call in self.calls))

    def test_markdown_structure_is_preserved_when_sections_change_independently(self):
        original = note("# Shopping\n\n- [ ] Milk\n\n## Notes\n\n**Remember**")
        self.remote = page_html(original)
        loaded = self.load()
        self.remote = page_html(note(original["body"].replace("Remember", "Phone reminder")))
        result = self.save(note(original["body"].replace("Milk", "Bread")), loaded["view"])
        self.assertTrue(result.get("ok"), result)
        self.assertIn("# Shopping", result["body"])
        self.assertIn("[ ] Bread", result["body"])
        self.assertIn("**Phone reminder**", result["body"])


if __name__ == "__main__":
    try:
        unittest.main()
    finally:
        WORK.cleanup()
