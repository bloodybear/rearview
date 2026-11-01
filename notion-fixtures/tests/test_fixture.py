import copy
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from fixture_tool.definitions import Definition, FixtureError, definitions
from fixture_tool.manager import Manager, State, page_id, resolve_properties
from fixture_tool.ntn import APIError, Notion


class FastNotion(Notion):
    def request(self, *args, **kwargs):
        self.last_call = 0
        return super().request(*args, **kwargs)


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        fake = self.root / "ntn"
        fake.write_text((ROOT / "tests/fake_ntn.py").read_text())
        fake.chmod(0o755)
        self.remote_path = self.root / "remote.json"
        self.remote_path.write_text(json.dumps({"clock": 0, "objects": {}, "calls": []}))
        self.env = patch.dict(os.environ, {"PATH": str(self.root) + os.pathsep + os.environ["PATH"], "FAKE_NOTION_REMOTE": str(self.remote_path)})
        self.env.start()
        items = {item.name: item for item in definitions(ROOT)}
        self.doc, self.db = items["rich-document"], items["project-database"]

    def tearDown(self):
        self.env.stop()
        self.temp.cleanup()

    def remote(self, mutate=None):
        data = json.loads(self.remote_path.read_text())
        if mutate:
            mutate(data)
            self.remote_path.write_text(json.dumps(data))
        return data

    def run_fixture(self, definition=None, force=False, parent=None):
        with State(self.root) as state:
            manager = Manager(FastNotion(), state)
            manager.initialize(parent)
            if definition:
                action, entry = manager.ensure(definition, force)
                return action, copy.deepcopy(entry)
            return copy.deepcopy(state.data)

    def state(self):
        return json.loads((self.root / "state.json").read_text())

    def edit(self, identifier, **fields):
        def mutate(remote):
            remote["clock"] += 1
            remote["objects"][identifier].update(fields, last_edited_time=str(remote["clock"]))
        self.remote(mutate)

    def writes_since(self, count):
        return [c for c in self.remote()["calls"][count:] if c[0] != "GET" and not c[1].endswith("/query")]

    def test_document_create_reuse_edit_reset_and_local_change(self):
        action, entry = self.run_fixture(self.doc)
        self.assertEqual(action, "created")
        self.assertEqual(self.remote()["objects"][entry["pageId"]]["markdown"], self.doc.content)
        count = len(self.remote()["calls"])
        self.assertEqual(self.run_fixture(self.doc)[0], "reused")
        self.assertEqual(self.writes_since(count), [])
        self.edit(entry["pageId"], markdown="edited")
        self.assertEqual(self.run_fixture(self.doc)[1]["pageId"], entry["pageId"])
        self.assertEqual(self.remote()["objects"][entry["pageId"]]["markdown"], self.doc.content)
        count = len(self.remote()["calls"])
        self.run_fixture(self.doc, force=True)
        self.assertTrue(self.writes_since(count))
        changed = copy.deepcopy(self.doc)
        changed.content += "\nLocal edit"
        changed.source_hash = "new-source"
        self.run_fixture(changed)
        self.assertEqual(self.state()["fixtures"][self.doc.name]["sourceHash"], "new-source")

    def test_document_trash_preserves_id(self):
        _, entry = self.run_fixture(self.doc)
        self.edit(entry["pageId"], in_trash=True)
        _, repaired = self.run_fixture(self.doc)
        self.assertEqual(repaired["pageId"], entry["pageId"])
        self.assertFalse(self.remote()["objects"][entry["pageId"]]["in_trash"])

    def test_database_create_views_pagination_reuse_and_row_edit(self):
        _, entry = self.run_fixture(self.db)
        self.assertEqual(len(entry["rowIds"]), len(self.db.rows))
        self.assertEqual(len(entry["viewIds"]), len(self.db.views))
        remote = self.remote()
        board = next(v for v in remote["objects"].values() if v.get("type") == "board")
        self.assertEqual(board["configuration"]["group_by"]["property_id"], "prop-2")
        count = len(remote["calls"])
        self.assertEqual(self.run_fixture(self.db)[0], "reused")
        calls = self.remote()["calls"][count:]
        self.assertFalse(any(c[0] == "GET" and c[1] in {"v1/pages/" + row for row in entry["rowIds"]} for c in calls))
        queries = [c for c in calls if c[1].endswith("/query")]
        self.assertEqual(len(queries), (len(entry["rowIds"]) + 1) // 2)
        self.assertTrue(all(c[3].get("filter_properties") for c in queries))
        self.assertEqual(self.writes_since(count), [])
        self.edit(entry["rowIds"][0], markdown="changed")
        _, repaired = self.run_fixture(self.db)
        self.assertEqual(entry["pageId"], repaired["pageId"])
        self.assertNotEqual(entry["databaseId"], repaired["databaseId"])
        self.assertTrue(self.remote()["objects"][entry["databaseId"]]["in_trash"])
        self.assertEqual(self.run_fixture(self.db)[0], "reused")

    def test_database_row_trash_and_view_changes(self):
        _, entry = self.run_fixture(self.db)
        self.edit(entry["rowIds"][0], in_trash=True)
        _, entry = self.run_fixture(self.db)
        view = entry["viewIds"][0]
        self.remote(lambda r: r["objects"].pop(view))
        _, repaired = self.run_fixture(self.db)
        self.assertNotEqual(entry["databaseId"], repaired["databaseId"])
        self.edit(repaired["viewIds"][0], name="renamed")
        self.assertNotEqual(self.run_fixture(self.db)[1]["databaseId"], repaired["databaseId"])

    def test_extra_row_and_view_detected(self):
        _, entry = self.run_fixture(self.db)
        def add(remote):
            row = copy.deepcopy(remote["objects"][entry["rowIds"][0]])
            row["id"] = "extra-row"
            remote["objects"][row["id"]] = row
        self.remote(add)
        _, repaired = self.run_fixture(self.db)
        self.assertNotEqual(entry["databaseId"], repaired["databaseId"])
        def add_view(remote):
            view = copy.deepcopy(remote["objects"][repaired["viewIds"][0]])
            view["id"] = "extra-view"
            remote["objects"][view["id"]] = view
        self.remote(add_view)
        self.assertNotEqual(self.run_fixture(self.db)[1]["databaseId"], repaired["databaseId"])

    def test_db_trash_and_reset(self):
        _, entry = self.run_fixture(self.db)
        self.edit(entry["databaseId"], in_trash=True)
        _, repaired = self.run_fixture(self.db)
        self.assertEqual(entry["pageId"], repaired["pageId"])
        self.assertNotEqual(entry["databaseId"], repaired["databaseId"])
        self.assertNotEqual(self.run_fixture(self.db, force=True)[1]["databaseId"], repaired["databaseId"])

    def test_permissions_and_missing_objects_never_create_replacements(self):
        _, entry = self.run_fixture(self.doc)
        for status in (401, 403, 404):
            self.remote(lambda r: r.update(fault=["GET", "v1/pages/" + entry["pageId"], status]))
            count = len(self.remote()["calls"])
            before = self.state()["fixtures"]
            with self.assertRaises(APIError):
                self.run_fixture(self.doc, force=True)
            self.assertEqual(self.writes_since(count), [])
            self.assertEqual(self.state()["fixtures"], before)

    def test_missing_record_404_stops_without_rebuild(self):
        _, entry = self.run_fixture(self.db)
        self.remote(lambda r: r["objects"].pop(entry["rowIds"][0]))
        count = len(self.remote()["calls"])
        with self.assertRaises(APIError):
            self.run_fixture(self.db)
        self.assertEqual(self.writes_since(count), [])

    def test_query_omission_of_accessible_row_never_rebuilds(self):
        _, entry = self.run_fixture(self.db)
        self.remote(lambda r: r.update(omit_query_row=entry["rowIds"][0]))
        count = len(self.remote()["calls"])
        with self.assertRaisesRegex(FixtureError, "missing from the data source query"):
            self.run_fixture(self.db)
        calls = self.remote()["calls"][count:]
        self.assertTrue(any(c[0] == "GET" and c[1] == "v1/pages/" + entry["rowIds"][0] for c in calls))
        self.assertEqual(self.writes_since(count), [])

    def test_moved_page_db_row_and_account_block_writes(self):
        _, entry = self.run_fixture(self.db)
        for identifier, parent in [(entry["pageId"], {"page_id": "outside"}), (entry["databaseId"], {"page_id": "outside"}), (entry["rowIds"][0], {"data_source_id": "outside"})]:
            original = copy.deepcopy(self.remote()["objects"][identifier]["parent"])
            self.edit(identifier, parent=parent)
            count = len(self.remote()["calls"])
            with self.assertRaises(FixtureError):
                self.run_fixture(self.db, force=True)
            self.assertEqual(self.writes_since(count), [])
            self.edit(identifier, parent=original)
        self.remote(lambda r: r.update(user="another-user"))
        with self.assertRaisesRegex(FixtureError, "account/workspace"):
            self.run_fixture(self.db)

    def test_interrupted_database_resumes_returned_ids(self):
        original = FastNotion.request
        count = [0]
        def fail_row(api, method, path, body=None, query=None):
            if method == "POST" and path == "v1/pages" and body and "data_source_id" in body.get("parent", {}):
                count[0] += 1
                if count[0] == 2:
                    raise APIError("forbidden", 403)
            return original(api, method, path, body, query)
        with patch.object(FastNotion, "request", fail_row):
            with self.assertRaises(APIError):
                self.run_fixture(self.db)
        before = self.state()["fixtures"][self.db.name]
        self.assertEqual(len(before["pending"]["rows"]), 1)
        _, entry = self.run_fixture(self.db)
        self.assertEqual(entry["databaseId"], before["pending"]["databaseId"])
        self.assertEqual(entry["rowIds"][0], before["pending"]["rows"]["0"])
        self.assertEqual(self.run_fixture(self.db)[0], "reused")

    def test_unknown_create_outcome_is_not_replayed(self):
        self.remote(lambda r: r.update(timeout_after_create=True))
        with self.assertRaises(APIError):
            self.run_fixture(self.doc)
        self.assertIn("inFlightCreate", self.state())
        count = len(self.remote()["calls"])
        with self.assertRaisesRegex(FixtureError, "unknown outcome"):
            self.run_fixture(self.doc)
        self.assertEqual(len(self.remote()["calls"]), count)

    def test_parser_warning_does_not_replace_baseline(self):
        _, entry = self.run_fixture(self.doc)
        self.remote(lambda r: r.update(warning_next_update=True))
        with self.assertRaisesRegex(FixtureError, "parser warnings"):
            self.run_fixture(self.doc, force=True)
        saved = self.state()["fixtures"][self.doc.name]
        self.assertEqual(saved["baseline"], entry["baseline"])
        self.assertEqual(saved["status"], "incomplete")

    def test_explicit_parent_and_root_mismatch(self):
        root = self.run_fixture()["root"]
        self.assertEqual(self.run_fixture(parent=root["url"])["root"]["pageId"], root["pageId"])
        with self.assertRaisesRegex(FixtureError, "differs"):
            self.run_fixture(parent="11111111-1111-4111-8111-111111111111")
        # A fresh local state can select a dedicated existing page.
        (self.root / "state.json").unlink()
        count = len(self.remote()["calls"])
        self.assertEqual(self.run_fixture(parent=root["url"])["root"]["pageId"], root["pageId"])
        self.assertEqual(self.writes_since(count), [])

    def test_state_lock_corruption_and_atomic_save(self):
        with State(self.root) as state:
            state.save()
            with self.assertRaisesRegex(FixtureError, "lock"):
                with State(self.root):
                    pass
        self.assertEqual(list(self.root.glob(".state-*.tmp")), [])
        (self.root / "state.json").write_text("{broken")
        with self.assertRaises(FixtureError):
            with State(self.root):
                pass


class DefinitionTests(unittest.TestCase):
    def test_sources_load_and_hash_changes(self):
        import shutil
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "rich-document"
            shutil.copytree(ROOT / "fixtures/rich-document", path)
            first = Definition(path)
            (path / "content.md").write_text(first.content + "\nnew")
            self.assertNotEqual(first.source_hash, Definition(path).source_hash)
            manifest = first.manifest
            manifest["content"] = "../../outside.md"
            (path / "fixture.json").write_text(json.dumps(manifest))
            with self.assertRaisesRegex(FixtureError, "escapes"):
                Definition(path)

    def test_local_images_are_hashed_and_anchors_validated(self):
        import shutil
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "media-diagrams"
            shutil.copytree(ROOT / "fixtures/media-diagrams", path)
            original = Definition(path)
            self.assertEqual(len(original.images), 3)
            (path / "assets/approval-flow.png").write_bytes((path / "assets/comparison-chart.png").read_bytes())
            self.assertNotEqual(original.source_hash, Definition(path).source_hash)
            manifest = original.manifest
            manifest["images"][0]["after"] = "anchor not in document"
            (path / "fixture.json").write_text(json.dumps(manifest))
            with self.assertRaisesRegex(FixtureError, "unique"):
                Definition(path)
            manifest["images"][0]["after"] = original.images[0]["after"]
            manifest["images"][0]["file"] = "../outside.png"
            (path / "fixture.json").write_text(json.dumps(manifest))
            with self.assertRaisesRegex(FixtureError, "escapes"):
                Definition(path)

    def test_parent_parsing_and_property_resolution(self):
        identifier = "12345678-1234-4234-8234-123456789abc"
        self.assertEqual(page_id("https://www.notion.so/Test-" + identifier.replace("-", "") + "?v=test"), identifier)
        with self.assertRaises(FixtureError):
            page_id("https://example.com/" + identifier)
        self.assertEqual(resolve_properties({"date_property_id": "Schedule"}, {"Schedule": "abc"}), {"date_property_id": "abc"})
        with self.assertRaises(FixtureError):
            resolve_properties({"property_id": "Missing"}, {})


if __name__ == "__main__":
    unittest.main()
