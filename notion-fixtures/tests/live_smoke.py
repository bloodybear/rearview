#!/usr/bin/env python3
"""Explicit live smoke test: mutates ONLY this tool's recorded fixture objects.

Run after ntn login: python3 -u notion-fixtures/tests/live_smoke.py
Leaves both fixtures restored to their definitions; old DBs remain in trash.
"""
import copy
import json
import sys
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from fixture_tool.definitions import definitions
from fixture_tool.manager import Manager, State
from fixture_tool.ntn import APIError, Notion


class ObservedNotion(Notion):
    def __init__(self):
        super().__init__()
        self.writes = 0

    def request(self, method, path, body=None, query=None):
        if method != "GET" and not path.endswith("/query"):
            self.writes += 1
        return super().request(method, path, body, query)


def check(condition, message):
    if not condition:
        raise RuntimeError(message)


def main():
    fixtures = {d.name: d for d in definitions(ROOT)}
    with State(ROOT) as state:
        api = ObservedNotion()
        manager = Manager(api, state)
        manager.initialize()
        print("Live server connected; management root:", state.data["root"]["url"], flush=True)
        for definition in fixtures.values():
            action, _ = manager.ensure(definition)
            print(definition.name, action, flush=True)
        writes = api.writes
        for definition in fixtures.values():
            action, _ = manager.ensure(definition)
            check(action == "reused", "Unchanged fixture was not reused")
        check(api.writes == writes, "Unchanged reuse issued a write")
        print("PASS: both fixtures reused without writes", flush=True)

        doc = state.data["fixtures"]["rich-document"]
        doc_id = doc["pageId"]
        markdown = api.request("GET", f"v1/pages/{doc_id}/markdown", query={"markdown_version": "v2"})
        content = markdown.get("markdown", "")
        for marker in ("<tabs>", "<tab", "<columns>", "<column", "<callout", "<toggle"):
            check(marker in content, "Markdown readback is missing " + marker)
        check("| 項目 | 条件 | 説明 |" in content, "GFM table missing from readback")
        blocks = api.all("GET", f"v1/blocks/{doc_id}/children")
        block_types = {block["type"] for block in blocks}
        check({"tab", "column_list", "table", "toggle", "callout"} <= block_types, "Required native block types missing")
        check(not markdown.get("unknown_block_ids"), "Readback contains unsupported blocks")
        print("PASS: Markdown v2 tabs, columns, callout, toggle, table read back", flush=True)

        manager.managed_page(doc_id)
        api.request("PATCH", f"v1/pages/{doc_id}/markdown", {
            "type": "replace_content", "replace_content": {"new_str": "AX live smoke test: intentionally modified."},
            "markdown_version": "v2"
        })
        action, doc = manager.ensure(fixtures["rich-document"])
        check(action == "restored" and doc["pageId"] == doc_id, "Document edit recovery changed page ID")
        print("PASS: document edit restored with same page ID", flush=True)
        manager.managed_page(doc_id)
        api.request("PATCH", f"v1/pages/{doc_id}", {"in_trash": True})
        _, doc = manager.ensure(fixtures["rich-document"])
        check(doc["pageId"] == doc_id, "Document trash recovery changed ID")
        manager.ensure(fixtures["rich-document"], force=True)
        print("PASS: document trash recovery and forced reset", flush=True)

        db_definition = fixtures["project-database"]
        entry = state.data["fixtures"]["project-database"]
        wrapper = entry["pageId"]
        old_db = entry["databaseId"]
        row = entry["rowIds"][0]
        manager.database(old_db, wrapper)
        api.request("PATCH", f"v1/pages/{row}", {"properties": {"備考": {"rich_text": [{"text": {"content": "AX live smoke row change"}}]}}})
        _, entry = manager.ensure(db_definition)
        check(entry["pageId"] == wrapper and entry["databaseId"] != old_db, "Row edit was not repaired by DB replacement")
        print("PASS: row edit detected; DB replaced, wrapper ID retained", flush=True)

        old_db = entry["databaseId"]
        view = entry["viewIds"][0]
        manager.database(old_db, wrapper)
        api.request("PATCH", f"v1/views/{view}", {"name": "AX smoke modified view"})
        _, entry = manager.ensure(db_definition)
        check(entry["databaseId"] != old_db, "View edit was not detected")
        print("PASS: view edit detected and repaired", flush=True)

        old_db = entry["databaseId"]
        manager.database(old_db, wrapper)
        api.request("PATCH", f"v1/pages/{entry['rowIds'][0]}", {"in_trash": True})
        _, entry = manager.ensure(db_definition)
        check(entry["databaseId"] != old_db, "Trashed row was not detected")
        print("PASS: row removal detected and repaired", flush=True)

        old_db = entry["databaseId"]
        manager.database(old_db, wrapper)
        api.request("PATCH", f"v1/databases/{old_db}", {"in_trash": True})
        _, entry = manager.ensure(db_definition)
        check(entry["pageId"] == wrapper, "Database trash recovery changed wrapper ID")
        print("PASS: database trash recovery", flush=True)
        old_db = entry["databaseId"]
        _, entry = manager.ensure(db_definition, force=True)
        check(entry["databaseId"] != old_db, "Forced database reset did not replace DB")
        print("PASS: forced database reset", flush=True)
        writes = api.writes
        for definition in fixtures.values():
            check(manager.ensure(definition)[0] == "reused", "Final restored fixture was not reusable")
        check(writes == api.writes, "Final reuse wrote remote content")
        saved = copy.deepcopy(state.data["fixtures"]["rich-document"])
        writes = api.writes
        try:
            state.data["fixtures"]["rich-document"]["pageId"] = str(uuid.uuid4())
            try:
                manager.ensure(fixtures["rich-document"])
                raise RuntimeError("Missing fixture did not fail")
            except APIError as exc:
                check(exc.status == 404, "Expected real object_not_found")
                check(api.writes == writes, "404 triggered a replacement write")
        finally:
            state.data["fixtures"]["rich-document"] = saved
        print("PASS: real 404 stops without replacement writes", flush=True)
        print("PASS: final state is reusable; all live smoke checks passed", flush=True)
        print(json.dumps({name: {k: value[k] for k in ("pageId", "url")}
                          for name, value in state.data["fixtures"].items()}, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
