import copy
import json
from pathlib import Path
from types import SimpleNamespace
import sys
import tempfile
import unittest
from unittest.mock import Mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from fixture_tool.definitions import Definition, FixtureError, definitions
from fixture_tool.manager import Manager


class PageLinkTests(unittest.TestCase):
    def test_navigation_references_existing_fixtures(self):
        items = {d.name: d for d in definitions(ROOT)}
        links = items["page-navigation"].page_links
        managed_content = {name for name, definition in items.items()
                           if name != "page-navigation" and not definition.mutable_presentation}
        self.assertEqual({v["fixtureId"] for v in links}, managed_content)

    def test_invalid_link_definitions(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp) / "host"
            folder.mkdir()
            (folder / "content.md").write_text("unique paragraph")
            base = dict(kind="document", page={"properties": {"title": {}}}, content="content.md")
            for links in ([{"after": "unique paragraph", "fixtureId": "host"}],
                          [{"after": "missing", "fixtureId": "other"}],
                          [{"after": "unique paragraph", "fixtureId": "other"}] * 2,
                          [{"after": "unique paragraph", "fixtureId": "other", "pageId": "remote"}]):
                (folder / "fixture.json").write_text(json.dumps(dict(base, pageLinks=links)))
                with self.assertRaises(FixtureError):
                    Definition(folder)

    def test_link_insertion_uses_resolved_id_and_exact_anchor(self):
        api = Mock()
        api.all.return_value = [{"id": "anchor-block", "type": "paragraph", "paragraph": {
            "rich_text": [{"plain_text": "anchor"}]}}]
        manager = Manager(api, SimpleNamespace(data={}))
        manager.managed_page = Mock()
        definition = SimpleNamespace(page_links=[{"after": "anchor", "fixtureId": "target"}])
        manager.install_page_links(definition, {"pageId": "host-id"}, {"target": "local-target-id"})
        body = api.request.call_args.args[2]
        self.assertEqual(body["position"]["after_block"]["id"], "anchor-block")
        mention = body["children"][0]["paragraph"]["rich_text"][0]
        self.assertEqual(mention["mention"]["page"]["id"], "local-target-id")
        api.all.return_value *= 2
        with self.assertRaises(FixtureError):
            manager.install_page_links(definition, {"pageId": "host-id"}, {"target": "id"})

    def test_snapshot_reads_actual_link_targets(self):
        api = Mock()
        api.all.return_value = [{"type": "paragraph", "paragraph": {"rich_text": [
            {"type": "mention", "mention": {"type": "page", "page": {"id": "actual"}}}
        ]}}]
        manager = Manager(api, SimpleNamespace(data={}))
        manager.managed_page = Mock(return_value={"id": "host", "last_edited_time": "1", "in_trash": False})
        result = manager.snapshot({"kind": "document", "pageId": "host", "resolvedLinks": {"target": "expected"}})
        self.assertEqual(result["pageLinks"], ["actual"])
