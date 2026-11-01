#!/usr/bin/env python3
"""Disk-backed fake ntn; exercises the actual subprocess/JSON boundary."""
import json
import os
import sys
from pathlib import Path

path = Path(os.environ["FAKE_NOTION_REMOTE"])
remote = json.loads(path.read_text())
args = sys.argv[1:]
endpoint = args[1]
method = args[args.index("-X") + 1]
body = json.loads(sys.stdin.read() or "{}")
query = dict(arg.split("==", 1) for arg in args if "==" in arg)
remote["calls"].append([method, endpoint, body, query])


def save():
    path.write_text(json.dumps(remote))


def fail(status):
    save()
    print(json.dumps({"object": "error", "status": status, "code": {404: "object_not_found", 403: "restricted_resource", 401: "unauthorized"}.get(status, "validation_error")}))
    sys.exit(1)


def touch(obj):
    remote["clock"] += 1
    obj["last_edited_time"] = str(remote["clock"])


def new(kind, parent):
    remote["clock"] += 1
    identifier = f"00000000-0000-4000-8000-{remote['clock']:012d}"
    obj = {"object": kind, "id": identifier, "parent": parent,
           "last_edited_time": str(remote["clock"]), "in_trash": False,
           "url": "https://www.notion.so/" + identifier.replace("-", "")}
    remote["objects"][identifier] = obj
    return obj


fault = remote.get("fault")
if fault and method == fault[0] and endpoint == fault[1]:
    remote.pop("fault")
    fail(fault[2])
parts = endpoint.split("/")
objects = remote["objects"]
if endpoint == "v1/users/me":
    result = {"object": "user", "id": remote.get("user", "test-user"), "bot": {"workspace_id": "test-workspace"}}
elif method == "POST" and endpoint in ("v1/pages", "v1/databases", "v1/views"):
    if endpoint == "v1/views":
        result = new("view", {"database_id": body["database_id"]})
        result.update(body)
    else:
        kind = "page" if endpoint == "v1/pages" else "database"
        result = new(kind, body["parent"])
        result.update(body)
        if kind == "database":
            ds = new("data_source", {"database_id": result["id"]})
            ds["properties"] = {name: dict(value, id="prop-" + str(i)) for i, (name, value) in enumerate(body["initial_data_source"]["properties"].items())}
            result["data_sources"] = [{"id": ds["id"]}]
            new("view", {"database_id": result["id"]})
        else:
            if "data_source_id" in body["parent"]:
                touch(objects[body["parent"]["data_source_id"]])
    if remote.pop("warning_next_create", False):
        result["warnings"] = [{"message": "parser changed content"}]
    if remote.pop("timeout_after_create", False):
        save()
        sys.exit(1)
elif method == "GET" and endpoint == "v1/views":
    result = [v for v in objects.values() if v["object"] == "view" and v["parent"].get("database_id") == query["database_id"]]
elif method == "POST" and len(parts) == 4 and parts[1] == "data_sources":
    result = [v for v in objects.values() if v["object"] == "page" and v["parent"].get("data_source_id") == parts[2] and not v["in_trash"]]
    result = [v for v in result if v["id"] != remote.get("omit_query_row")]
elif len(parts) >= 3:
    identifier = parts[2]
    if identifier not in objects:
        fail(404)
    obj = objects[identifier]
    if len(parts) == 4 and parts[3] == "children":
        # Inline child database blocks share their database ID.
        result = []
        for v in objects.values():
            if v["in_trash"] or v["parent"].get("page_id") != identifier:
                continue
            if v["object"] == "database":
                result.append(dict(v, type="child_database"))
            elif v["object"] == "block":
                result.append(v)
            elif v["object"] == "page":
                result.append(dict(v, type="child_page"))
    elif len(parts) == 4 and parts[3] == "markdown":
        obj["markdown"] = body["replace_content"]["new_str"]
        touch(obj)
        result = {"object": "page_markdown", "markdown": obj["markdown"]}
        if remote.pop("warning_next_update", False):
            result["warnings"] = [{"message": "parser changed content"}]
    elif method == "GET":
        result = obj
    elif method == "PATCH":
        obj.update(body)
        touch(obj)
        result = obj
    elif method == "DELETE":
        obj["in_trash"] = True
        if obj["object"] == "view":
            del objects[identifier]
        result = obj
    else:
        fail(400)
else:
    fail(400)
if isinstance(result, list):
    # Force pagination even though callers request 100 items.
    source = body if method == "POST" else query
    start = int(source.get("start_cursor", 0))
    items = result[start:start + 2]
    more = start + 2 < len(result)
    result = {"object": "list", "results": items, "has_more": more,
              "next_cursor": str(start + 2) if more else None}
save()
print(json.dumps(result))
