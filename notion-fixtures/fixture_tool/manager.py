"""Fixture lifecycle, ownership checks, and a small durable operation journal."""
import copy
import fcntl
import json
import os
import re
import tempfile
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.parse import unquote, urlparse

from .definitions import FixtureError, read_json
from .ntn import APIError


def page_id(value):
    if value.startswith(("https://", "http://")):
        url = urlparse(value)
        if url.hostname not in ("notion.so", "www.notion.so", "notion.com", "www.notion.com", "app.notion.com") and not (url.hostname or "").endswith(".notion.site"):
            raise FixtureError("Parent must be a Notion page URL or UUID")
        value = unquote(url.path).rstrip("/").split("/")[-1]
    match = re.search(r"([0-9a-fA-F]{32}|[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})$", value)
    if not match:
        raise FixtureError("Invalid parent page URL or UUID")
    return str(uuid.UUID(match[1]))


def same_id(a, b):
    return bool(a and b) and a.replace("-", "").lower() == b.replace("-", "").lower()


def parent_is(obj, kind, identifier):
    parent = obj.get("parent", {})
    return same_id(parent.get(kind), identifier)


def trashed(obj):
    return bool(obj.get("in_trash") or obj.get("archived"))


def stamp(obj):
    if not obj.get("id") or not obj.get("last_edited_time"):
        raise FixtureError("Notion returned an object without id or last_edited_time")
    return {"id": obj["id"], "lastEditedTime": obj["last_edited_time"], "inTrash": trashed(obj)}


class State:
    def __init__(self, root):
        self.path = root / "state.json"
        self.lock = None
        self.data = None

    def __enter__(self):
        self.lock = (self.path.parent / "state.json.lock").open("a+")
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.data = read_json(self.path) if self.path.exists() else {"version": 1, "fixtures": {}}
            if not isinstance(self.data, dict) or self.data.get("version") != 1 or not isinstance(self.data.get("fixtures"), dict):
                raise FixtureError("Unsupported or damaged state.json; preserve it and resolve manually")
            return self
        except BlockingIOError as exc:
            self.lock.close()
            raise FixtureError("Another fixture command holds the state lock") from exc
        except Exception:
            self.lock.close()
            raise

    def __exit__(self, *args):
        self.lock.close()

    def save(self):
        fd, name = tempfile.mkstemp(prefix=".state-", suffix=".tmp", dir=self.path.parent)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(self.data, handle, ensure_ascii=False, indent=2)
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(name, self.path)
            directory = os.open(self.path.parent, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            if os.path.exists(name):
                os.unlink(name)


class Manager:
    def __init__(self, notion, state):
        self.api = notion
        self.state = state
        self.data = state.data

    def create(self, path, body, destination, key):
        # Persist intent BEFORE POST. A process crash at any point is conservative:
        # unresolved intent is never silently replayed, even if nothing was sent.
        self.data["inFlightCreate"] = {"path": path, "target": key}
        self.state.save()
        try:
            result = self.api.request("POST", path, body)
        except APIError as exc:
            if exc.definitive:
                self.data.pop("inFlightCreate", None)
                self.state.save()
            raise
        if not result.get("id"):
            raise FixtureError(f"{path}: create response missing id; inspect inFlightCreate manually")
        destination[key] = result["id"]
        if key == "pageId":
            destination["url"] = result.get("url", "")
            if destination is self.data.get("root"):
                destination["parent"] = result["parent"]
        self.data.pop("inFlightCreate", None)
        if result.get("warnings"):
            self.data["createWarnings"] = {"path": path, "id": result["id"], "warnings": result["warnings"]}
        self.state.save()
        self.check_warnings(result)
        return result

    @staticmethod
    def check_warnings(result):
        if result.get("warnings"):
            raise FixtureError("Notion returned parser warnings: " + json.dumps(result["warnings"], ensure_ascii=False))

    def initialize(self, parent=None):
        if self.data.get("createWarnings"):
            raise FixtureError("A previous create returned parser warnings. Inspect state.json createWarnings and the recorded object before resuming; see README")
        if self.data.get("inFlightCreate"):
            raise FixtureError("A previous create has an unknown outcome. Inspect state.json inFlightCreate and Notion before retrying; see README recovery instructions")
        me = self.api.request("GET", "v1/users/me")
        if not me.get("id"):
            raise FixtureError("Unable to identify authenticated Notion user")
        identity = {"userId": me["id"], "workspaceId": me.get("bot", {}).get("workspace_id")}
        if self.data.get("identity") and self.data["identity"] != identity:
            raise FixtureError("Notion account/workspace differs from state.json; switch back to the original ntn login")
        self.data["identity"] = identity
        if identity["workspaceId"] and hasattr(self.api, "env"):
            self.api.env["NOTION_WORKSPACE_ID"] = identity["workspaceId"]
        root = self.data.get("root")
        if root:
            if parent and not same_id(page_id(parent), root["pageId"]):
                raise FixtureError("--parent differs from saved management root; implicit root changes are forbidden")
            obj = self.api.request("GET", f"v1/pages/{root['pageId']}")
            if obj.get("parent") != root["parent"]:
                raise FixtureError("Management root was moved; restore its original parent before retrying")
            if trashed(obj):
                self.api.request("PATCH", f"v1/pages/{root['pageId']}", {"in_trash": False})
        else:
            root = {}
            self.data["root"] = root
            if parent:
                identifier = page_id(parent)
                obj = self.api.request("GET", f"v1/pages/{identifier}")
                if trashed(obj):
                    raise FixtureError("Explicit test parent is in trash; restore it before setup")
                root["pageId"] = obj["id"]
            else:
                obj = self.create("v1/pages", {
                    "parent": {"type": "workspace", "workspace": True},
                    "properties": {"title": {"title": [{"text": {"content": "Notion AX Fixtures"}}]}}
                }, root, "pageId")
            root.update(parent=obj["parent"], url=obj.get("url", ""))
        self.state.save()

    def managed_page(self, identifier):
        obj = self.api.request("GET", f"v1/pages/{identifier}")
        if not parent_is(obj, "page_id", self.data["root"]["pageId"]):
            raise FixtureError(f"Fixture page {identifier} moved outside management root; refusing to modify it")
        return obj

    def database(self, identifier, page):
        obj = self.api.request("GET", f"v1/databases/{identifier}")
        if not (parent_is(obj, "page_id", page) or parent_is(obj, "block_id", page)):
            raise FixtureError(f"Database {identifier} moved outside its fixture page")
        return obj

    def source(self, identifier, database):
        obj = self.api.request("GET", f"v1/data_sources/{identifier}")
        if not parent_is(obj, "database_id", database):
            raise FixtureError(f"Data source {identifier} moved outside its managed database")
        return obj

    def snapshot(self, entry, restore=False, parallel_views=False):
        page = self.managed_page(entry["pageId"])
        was_restored = False
        if restore and trashed(page):
            self.api.request("PATCH", f"v1/pages/{page['id']}", {"in_trash": False})
            page = self.managed_page(page["id"])
            was_restored = True
        result = {"page": stamp(page)}
        if entry["kind"] == "document":
            return result
        db = self.database(entry["databaseId"], page["id"])
        if restore and trashed(db):
            self.api.request("PATCH", f"v1/databases/{db['id']}", {"in_trash": False})
            db = self.database(db["id"], page["id"])
            was_restored = True
        ds = self.source(entry["dataSourceId"], db["id"])
        result.update(database=stamp(db), dataSource=stamp(ds))
        result["dataSourceIds"] = sorted(x["id"] for x in db.get("data_sources", []))
        title = next((value["id"] for value in ds.get("properties", {}).values() if value.get("type") == "title" or "title" in value), None)
        rows = self.api.all("POST", f"v1/data_sources/{ds['id']}/query", query={"filter_properties": title} if title else None)
        listed = {row["id"] for row in rows}
        recorded = entry.get("rowIds", entry.get("baseline", {}).get("rows", {}))
        for identifier in recorded:
            if identifier in listed:
                continue
            row = self.api.request("GET", f"v1/pages/{identifier}", query={"filter_properties": title} if title else None)
            if not parent_is(row, "data_source_id", ds["id"]):
                raise FixtureError(f"Row {identifier} moved outside its managed data source")
            if trashed(row):
                continue
            raise FixtureError(f"Row {identifier} is missing from the data source query; cannot verify fixture baseline")
        for row in rows:
            if not parent_is(row, "data_source_id", ds["id"]):
                raise FixtureError("Query returned a row outside its managed data source")
        result["rows"] = {row["id"]: stamp(row) for row in rows}
        # List endpoints return references, so retrieve each view for timestamps.
        refs = self.api.all("GET", "v1/views", query={"database_id": db["id"]})
        result["views"] = {}
        def retrieve_view(ref):
            return self.api.request("GET", f"v1/views/{ref['id']}")
        if parallel_views and len(refs) > 1:
            with ThreadPoolExecutor(max_workers=3) as pool:
                views = list(pool.map(retrieve_view, refs))
        else:
            views = [retrieve_view(ref) for ref in refs]
        for view in views:
            if not parent_is(view, "database_id", db["id"]):
                raise FixtureError("View belongs to another database")
            result["views"][view["id"]] = stamp(view)
        if was_restored:
            result["restored"] = True
        return result

    def ensure(self, definition, force=False):
        entry = self.data["fixtures"].setdefault(definition.name, {"kind": definition.kind})
        if entry["kind"] != definition.kind:
            raise FixtureError(f"{definition.name}: changing fixture kind requires manual state migration")
        baseline = entry.get("baseline")
        restored = False
        if entry.get("pageId"):
            page = self.managed_page(entry["pageId"])
            if trashed(page):
                self.api.request("PATCH", f"v1/pages/{page['id']}", {"in_trash": False})
                restored = True
        if baseline and not entry.get("pending"):
            snapshot = self.snapshot(entry, restore=True)
            if not force and not restored and entry.get("status") == "ready" and entry.get("sourceHash") == definition.source_hash and snapshot == baseline:
                return "reused", entry
        entry["status"] = "incomplete"
        self.state.save()
        if not entry.get("pageId"):
            # Create an empty shell first: its ID survives Markdown parser errors.
            page = self.create("v1/pages", dict(copy.deepcopy(definition.page),
                parent={"type": "page_id", "page_id": self.data["root"]["pageId"]}), entry, "pageId")
            entry["url"] = page.get("url", "")
            self.state.save()
        if definition.kind == "document":
            self.managed_page(entry["pageId"])
            self.api.request("PATCH", f"v1/pages/{entry['pageId']}", definition.page)
            self.managed_page(entry["pageId"])
            result = self.api.request("PATCH", f"v1/pages/{entry['pageId']}/markdown", {
                "type": "replace_content", "replace_content": {"new_str": definition.content},
                "markdown_version": "v2", "allow_async": False
            })
            self.check_warnings(result)
            self.install_images(definition, entry)
        else:
            self.rebuild_database(definition, entry)
        new_baseline = self.snapshot(entry)
        entry.pop("pending", None)
        entry["baseline"] = new_baseline
        entry["sourceHash"] = definition.source_hash
        entry["status"] = "ready"
        self.state.save()
        return ("created" if baseline is None else "restored"), entry

    def install_images(self, definition, entry):
        # Markdown owns the text; official image blocks insert local PNGs after
        # exact paragraph anchors. A retry first replaces the entire document,
        # so a lost append response cannot duplicate images on the next run.
        if not definition.images:
            if "imageIds" in entry or "fileUploadIds" in entry:
                entry.pop("imageIds", None)
                entry.pop("fileUploadIds", None)
                self.state.save()
            return
        children = self.api.all("GET", f"v1/blocks/{entry['pageId']}/children")
        entry["imageIds"] = []
        entry["fileUploadIds"] = []
        self.state.save()
        for image in definition.images:
            matches = []
            for block in children:
                if block.get("type") != "paragraph":
                    continue
                text = "".join(part.get("plain_text", part.get("text", {}).get("content", ""))
                               for part in block["paragraph"].get("rich_text", []))
                if text == image["after"]:
                    matches.append(block)
            if len(matches) != 1:
                raise FixtureError(f"Image anchor not found uniquely: {image['after']}")
            self.managed_page(entry["pageId"])
            upload = self.api.upload_png(Path(image["file"]).name, image["data"])
            entry["fileUploadIds"].append(upload["id"])
            self.state.save()
            self.managed_page(entry["pageId"])
            anchor = self.api.request("GET", f"v1/blocks/{matches[0]['id']}")
            if not (parent_is(anchor, "page_id", entry["pageId"]) or parent_is(anchor, "block_id", entry["pageId"])):
                raise FixtureError("Image anchor moved outside fixture page")
            caption = image.get("caption", "")
            result = self.api.request("PATCH", f"v1/blocks/{entry['pageId']}/children", {
                "position": {"type": "after_block", "after_block": {"id": anchor["id"]}},
                "children": [{"object": "block", "type": "image", "image": {
                    "type": "file_upload", "file_upload": {"id": upload["id"]},
                    "caption": [{"type": "text", "text": {"content": caption}}] if caption else []
                }}]
            })
            images = [block for block in result.get("results", []) if block.get("type") == "image"]
            if len(images) != 1:
                raise FixtureError("Image append did not return exactly one image block")
            entry["imageIds"].append(images[0]["id"])
            self.state.save()

    def clean_wrapper(self, entry, keep_database):
        self.managed_page(entry["pageId"])
        children = self.api.all("GET", f"v1/blocks/{entry['pageId']}/children")
        for block in children:
            if block["type"] == "child_database" and same_id(block["id"], keep_database):
                continue
            if block["type"] in ("child_page", "child_database"):
                raise FixtureError("Unexpected child page/database in database fixture; move it out manually before reset")
            self.managed_page(entry["pageId"])
            current = self.api.request("GET", f"v1/blocks/{block['id']}")
            if not (parent_is(current, "page_id", entry["pageId"]) or parent_is(current, "block_id", entry["pageId"])):
                raise FixtureError("Wrapper block moved; refusing to delete it")
            self.api.request("DELETE", f"v1/blocks/{block['id']}")

    def rebuild_database(self, definition, entry):
        pending = entry.get("pending")
        if pending and pending["sourceHash"] != definition.source_hash:
            raise FixtureError("Fixture files changed during an incomplete database build; restore the previous files and finish recovery first")
        if not pending:
            pending = {"sourceHash": definition.source_hash, "rows": {}, "views": {}}
            if entry.get("databaseId"):
                pending["oldDatabaseId"] = entry["databaseId"]
            entry["pending"] = pending
            self.state.save()
        self.managed_page(entry["pageId"])
        if not pending.get("databaseId"):
            self.create("v1/databases", {
                "parent": {"type": "page_id", "page_id": entry["pageId"]},
                "title": [{"text": {"content": definition.manifest.get("databaseTitle", definition.name)}}],
                "is_inline": True, "initial_data_source": definition.schema
            }, pending, "databaseId")
        db = self.database(pending["databaseId"], entry["pageId"])
        if trashed(db):
            self.api.request("PATCH", f"v1/databases/{db['id']}", {"in_trash": False})
        sources = db.get("data_sources", [])
        if len(sources) != 1:
            raise FixtureError("Pending database must contain exactly its initial data source")
        pending["dataSourceId"] = sources[0]["id"]
        ds = self.source(pending["dataSourceId"], db["id"])
        self.state.save()
        for index, body in enumerate(definition.rows):
            if str(index) not in pending["rows"]:
                self.managed_page(entry["pageId"])
                self.database(db["id"], entry["pageId"])
                self.source(ds["id"], db["id"])
                self.create("v1/pages", dict(copy.deepcopy(body),
                    parent={"type": "data_source_id", "data_source_id": ds["id"]}), pending["rows"], str(index))
        properties = {name: value["id"] for name, value in ds["properties"].items()}
        for index, body in enumerate(definition.views):
            if str(index) not in pending["views"]:
                self.managed_page(entry["pageId"])
                self.database(db["id"], entry["pageId"])
                self.create("v1/views", dict(resolve_properties(body, properties),
                    database_id=db["id"], data_source_id=ds["id"]), pending["views"], str(index))
        # A newly created DB has an automatic table view. Remove only defaults
        # from this recorded candidate, after all requested views exist.
        for view in self.api.all("GET", "v1/views", query={"database_id": db["id"]}):
            if view["id"] not in pending["views"].values():
                current = self.api.request("GET", f"v1/views/{view['id']}")
                if not parent_is(current, "database_id", db["id"]):
                    raise FixtureError("Candidate view moved outside managed database")
                self.database(db["id"], entry["pageId"])
                self.api.request("DELETE", f"v1/views/{view['id']}")
        if pending.get("oldDatabaseId"):
            old = self.database(pending["oldDatabaseId"], entry["pageId"])
            if not trashed(old):
                self.managed_page(entry["pageId"])
                self.api.request("PATCH", f"v1/databases/{old['id']}", {"in_trash": True})
        self.clean_wrapper(entry, db["id"])
        self.managed_page(entry["pageId"])
        self.api.request("PATCH", f"v1/pages/{entry['pageId']}", definition.page)
        entry.update(databaseId=db["id"], dataSourceId=ds["id"],
                     rowIds=list(pending["rows"].values()), viewIds=list(pending["views"].values()))
        self.state.save()


def resolve_properties(value, properties, key=""):
    if isinstance(value, dict):
        return {k: resolve_properties(v, properties, k) for k, v in value.items()}
    if isinstance(value, list):
        return [resolve_properties(v, properties, key) for v in value]
    if key in ("property_id", "date_property_id", "end_date_property_id") and isinstance(value, str):
        if value in properties:
            return properties[value]
        if value not in properties.values():
            raise FixtureError(f"Unknown view property: {value}")
    return value
