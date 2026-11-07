"""Local definitions only; no Notion access or export logic."""
import hashlib
import json
from pathlib import Path


class FixtureError(Exception):
    pass


def read_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise FixtureError(f"Cannot read {path}: {exc}") from exc


class Definition:
    def __init__(self, directory):
        self.name = directory.name
        self.files = {}
        self.directory = directory.resolve()
        self.manifest = self.load("fixture.json")
        if not isinstance(self.manifest, dict):
            raise FixtureError(f"{self.name}: fixture.json must be an object")
        self.kind = self.manifest.get("kind")
        if self.kind not in ("document", "database"):
            raise FixtureError(f"{self.name}: kind must be document or database")
        self.mutable_presentation = self.manifest.get("mutablePresentation", False)
        if type(self.mutable_presentation) is not bool:
            raise FixtureError(f"{self.name}: mutablePresentation must be a boolean")
        self.page = self.manifest.get("page")
        if not isinstance(self.page, dict) or not self.page.get("properties"):
            raise FixtureError(f"{self.name}: page.properties is required")
        if set(self.page) - {"properties", "icon", "cover"}:
            raise FixtureError(f"{self.name}: page accepts properties, icon, cover only")
        self.images = []
        if self.kind == "document":
            self.content = self.load(self.manifest["content"], markdown=True)
            images = self.manifest.get("images", [])
            if not isinstance(images, list):
                raise FixtureError(f"{self.name}: images must be an array")
            anchors = set()
            for image in images:
                if not isinstance(image, dict) or set(image) - {"file", "after", "caption"}:
                    raise FixtureError(f"{self.name}: image requires file, after, optional caption")
                anchor = image.get("after")
                if not isinstance(anchor, str) or anchor in anchors or self.content.split("\n\n").count(anchor) != 1:
                    raise FixtureError(f"{self.name}: image after must name one unique top-level paragraph")
                if not isinstance(image.get("file"), str) or not image["file"].endswith(".png"):
                    raise FixtureError(f"{self.name}: local image must be a PNG file")
                caption = image.get("caption", "")
                if not isinstance(caption, str) or len(caption) > 2000:
                    raise FixtureError(f"{self.name}: image caption must be at most 2000 characters")
                data = self.load(image["file"], binary=True)
                if len(data) > 5 * 1024 * 1024:
                    raise FixtureError(f"{self.name}: PNG exceeds the single-part 5 MB limit")
                if not data.startswith(b"\x89PNG\r\n\x1a\n"):
                    raise FixtureError(f"{self.name}: invalid PNG file")
                anchors.add(anchor)
                self.images.append(dict(image, data=data))
        else:
            self.schema = self.load(self.manifest["schema"])
            self.rows = self.load(self.manifest["rows"])
            self.views = self.load(self.manifest["views"])
            if not isinstance(self.schema, dict) or not self.schema.get("properties"):
                raise FixtureError(f"{self.name}: schema must contain properties")
            if not isinstance(self.rows, list) or not isinstance(self.views, list):
                raise FixtureError(f"{self.name}: rows and views must be arrays")
            for row in self.rows:
                if not isinstance(row, dict) or "properties" not in row:
                    raise FixtureError(f"{self.name}: each row needs properties")
                if set(row) - {"properties", "markdown", "markdown_version", "icon", "cover"}:
                    raise FixtureError(f"{self.name}: unsupported row request fields")
            names = []
            for view in self.views:
                if not isinstance(view, dict) or not view.get("name") or not view.get("type"):
                    raise FixtureError(f"{self.name}: each view needs name and type")
                if set(view) & {"database_id", "data_source_id", "view_id", "create_database"}:
                    raise FixtureError(f"{self.name}: view targets are assigned by the tool")
                names.append(view["name"])
            if len(names) != len(set(names)):
                raise FixtureError(f"{self.name}: view names must be unique")
        self.page_links = self.manifest.get("pageLinks", [])
        if not isinstance(self.page_links, list) or (self.page_links and self.kind != "document"):
            raise FixtureError(f"{self.name}: pageLinks requires a document and an array")
        seen = set()
        for link in self.page_links:
            if not isinstance(link, dict) or set(link) != {"after", "fixtureId"}:
                raise FixtureError("pageLinks entries require after and fixtureId")
            target, after = link["fixtureId"], link["after"]
            if not isinstance(target, str) or not target or target == self.name:
                raise FixtureError("Invalid pageLinks fixture reference")
            if not isinstance(after, str) or not after or after in seen or self.content.split("\n\n").count(after) != 1:
                raise FixtureError("pageLinks after must identify one unique paragraph")
            seen.add(after)
        digest = hashlib.sha256()
        for name, data in sorted(self.files.items()):
            digest.update(name.encode() + b"\0" + str(len(data)).encode() + b"\0" + data)
        self.source_hash = digest.hexdigest()

    def load(self, name, markdown=False, binary=False):
        if not isinstance(name, str):
            raise FixtureError(f"{self.name}: file references must be strings")
        path = (self.directory / name).resolve()
        if not path.is_relative_to(self.directory):
            raise FixtureError(f"{self.name}: file escapes fixture directory: {name}")
        try:
            data = path.read_bytes()
            self.files[path.relative_to(self.directory).as_posix()] = data
            return data if binary else (data.decode("utf-8") if markdown else json.loads(data))
        except (OSError, ValueError) as exc:
            raise FixtureError(f"{path}: {exc}") from exc


def definitions(root, name=None):
    items = [Definition(p.parent) for p in sorted((root / "fixtures").glob("*/fixture.json"))
             if name is None or p.parent.name == name]
    if not items:
        raise FixtureError(f"No fixture definitions found{': ' + name if name else ''}")
    if name is not None:
        return items
    by_name = {item.name: item for item in items}
    ordered, active, done = [], set(), set()
    def visit(item):
        if item.name in active:
            raise FixtureError("Circular Fixture pageLinks: " + item.name)
        if item.name in done:
            return
        active.add(item.name)
        for link in item.page_links:
            target = by_name.get(link["fixtureId"])
            if target is None:
                raise FixtureError("Unknown linked Fixture: " + link["fixtureId"])
            visit(target)
        active.remove(item.name)
        done.add(item.name)
        ordered.append(item)
    for item in items:
        visit(item)
    return ordered
