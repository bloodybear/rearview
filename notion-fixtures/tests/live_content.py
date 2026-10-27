#!/usr/bin/env python3
"""Validate the Japanese corpus against the real Notion API.

Applies local definitions only inside the saved fixture root. Unlike live_smoke,
this does not intentionally damage/rebuild already current DBs. Never claims
pixel bounds or translation quality from an API-only check.
"""
import hashlib
import re
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from fixture_tool.definitions import definitions
from fixture_tool.manager import Manager, State
from live_smoke import ObservedNotion, check


def plain(parts):
    return "".join(p.get("plain_text", p.get("text", {}).get("content", "")) for p in parts)


def main():
    fixtures = {d.name: d for d in definitions(ROOT)}
    with State(ROOT) as state:
        api = ObservedNotion()
        manager = Manager(api, state)
        manager.initialize()
        for definition in fixtures.values():
            action, _ = manager.ensure(definition)
            print(definition.name, action, flush=True)
        for name, definition in fixtures.items():
            entry = state.data["fixtures"][name]
            if definition.kind != "document":
                continue
            response = api.request("GET", f"v1/pages/{entry['pageId']}/markdown", query={"markdown_version": "v2"})
            check(not response.get("truncated"), name + " markdown truncated")
            check(not response.get("unknown_block_ids"), name + " contains unknown blocks")
            markdown = response["markdown"]
            for marker in set(re.findall(r"(?:R|L|M|D|I)\d{2}(?:-[A-Z]+)?", definition.content)):
                check(marker in markdown, name + " missing case " + marker)
            blocks = api.all("GET", f"v1/blocks/{entry['pageId']}/children")
            types = {b["type"] for b in blocks}
            if name == "layout-stress":
                check({"column_list", "table", "code", "toggle", "tab"} <= types, "Layout types missing")
                lines = [plain(b["paragraph"].get("rich_text", [])) for b in blocks if b["type"] == "paragraph"]
                check(any("編集できる\nわけではありません" in s for s in lines), "Hard line breaks were lost")
            if name == "mixed-language":
                for sample in ("ガイド", "ｶﾞｲﾄﾞ", "👨‍👩‍👧‍👦", "👍🏽", "last_edited_time", "−5 °C"):
                    check(sample in markdown, "Mixed-language sequence changed: " + sample)
            if name == "long-reading":
                paragraphs = [plain(b["paragraph"].get("rich_text", [])) for b in blocks if b["type"] == "paragraph"]
                check(max(map(len, paragraphs)) >= 1000, "Large paragraph did not survive as one block")
            if name == "media-diagrams":
                images = [b for b in blocks if b["type"] == "image"]
                check(len(images) == len(definition.images), "Expected three native image blocks")
                check(sum(b["type"] == "code" and b["code"]["language"] == "mermaid" for b in blocks) == 2, "Expected two Mermaid blocks")
                for spec, block in zip(definition.images, images):
                    index = blocks.index(block)
                    check(index > 0 and blocks[index - 1]["type"] == "paragraph", "Image has no preceding anchor")
                    check(plain(blocks[index - 1]["paragraph"]["rich_text"]) == spec["after"], "Image in wrong position")
                    check(plain(block["image"].get("caption", [])) == spec.get("caption", ""), "Caption changed")
                    check(block["image"]["type"] == "file", "Expected Notion-hosted image")
                    # Signed URLs stay in memory; do not print or persist them.
                    url = block["image"]["file"]["url"]
                    with urllib.request.urlopen(url, timeout=30) as handle:
                        remote = handle.read(5 * 1024 * 1024 + 1)
                    check(hashlib.sha256(remote).digest() == hashlib.sha256(spec["data"]).digest(), "Uploaded image bytes differ")
                print("PASS: three original PNG hashes, image anchors/captions, two Mermaid blocks", flush=True)
            print("PASS:", name, "readback and native blocks", len(blocks), flush=True)
        definition = fixtures["project-database"]
        entry = state.data["fixtures"][definition.name]
        rows = api.all("POST", f"v1/data_sources/{entry['dataSourceId']}/query")
        check(len(rows) == len(definition.rows) == 18, "Expected 18 rows")
        by_order = {row["properties"]["見積時間"]["number"]: row for row in rows}
        for spec in definition.rows:
            expected = spec["properties"]
            actual = by_order[expected["見積時間"]["number"]]["properties"]
            for prop, field in [("件名", "title"), ("備考", "rich_text")]:
                check(plain(actual[prop][field]) == plain(expected[prop][field]), "Row text changed: " + prop)
        refs = api.all("GET", "v1/views", query={"database_id": entry["databaseId"]})
        views = [api.request("GET", f"v1/views/{v['id']}") for v in refs]
        check(len(views) == len(definition.views) == 5, "Expected five views")
        check({v["type"] for v in views} == {"table", "board", "gallery", "timeline"}, "View types differ")
        tables = [v for v in views if v["type"] == "table"]
        check({v["configuration"]["wrap_cells"] for v in tables} == {True, False}, "Both clipping/wrapping table presets required")
        print("PASS: all 18 Japanese rows, multiline notes, five views including clipped/wrapped tables", flush=True)
        writes = api.writes
        for definition in fixtures.values():
            check(manager.ensure(definition)[0] == "reused", "Updated fixture not reusable: " + definition.name)
        check(writes == api.writes, "Reuse wrote to server")
        print("PASS: all six fixtures reused without writes; API checks passed (UI geometry/translation not evaluated)", flush=True)


if __name__ == "__main__":
    main()
