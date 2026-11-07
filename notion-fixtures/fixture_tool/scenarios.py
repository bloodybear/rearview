"""Screen scenarios: local definitions + read-only fixture checks + native runner.

This module never invokes ensure/reset or any Notion write endpoint.
"""
import copy
import datetime
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

from .definitions import FixtureError, definitions, read_json
from .manager import Manager, State, same_id
from .ntn import APIError, Notion
from . import screen_state
from .baselines import publish_baseline, BaselineError

class ScenarioError(FixtureError):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


ID = re.compile(r"^[a-z0-9][a-z0-9-]{0,79}$")
ITEMS = {"target", "window", "zoom", "sidebar", "scroll", "focus", "screenshot", "finalState"}


def atomic_json(path, value, create_only=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".scenario-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2, allow_nan=False)
            handle.write("\n")
        if create_only:
            # A hard link publishes the fully written temp file without replacing
            # a scenario that appeared after the caller checked the ID.
            os.link(temporary, path)
        else:
            os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def validate(value):
    if not isinstance(value, dict):
        raise FixtureError("Scenario must be a JSON object")
    expected = {"schemaVersion", "id", "name", "version", "fixtureId", "fixtureVersion", "state"}
    if value.get("schemaVersion") == 2:
        expected.add("fixtureVersions")
    if set(value) != expected:
        raise FixtureError("Scenario requires schemaVersion, id, name, version, fixtureId, fixtureVersion, state only")
    if type(value["schemaVersion"]) is not int or value["schemaVersion"] not in (1, 2) or type(value["version"]) is not int or value["version"] < 1:
        raise FixtureError("Unsupported scenario schema or invalid version")
    if not all(isinstance(value[k], str) and ID.fullmatch(value[k]) for k in ("id", "fixtureId")):
        raise FixtureError("Scenario and fixture IDs must use lowercase letters, numbers and hyphens")
    if not isinstance(value["name"], str) or not value["name"].strip():
        raise FixtureError("Scenario name is required")
    if not isinstance(value["fixtureVersion"], str) or not re.fullmatch(r"[0-9a-f]{64}", value["fixtureVersion"]):
        raise FixtureError("fixtureVersion must be the fixture source SHA-256")
    state = value["state"]
    extra_fields = screen_state.FIELDS if value["schemaVersion"] == 2 else set()
    if not isinstance(state, dict) or set(state) - ({"coordinateSystem", "window", "zoomPercent", "sidebarOpen", "scroll", "toggles", "focus", "required"} | extra_fields):
        raise FixtureError("Unknown scenario state fields")
    if state.get("coordinateSystem") != "screen-top-left-points":
        raise FixtureError("coordinateSystem must be screen-top-left-points")
    required = state.get("required")
    if not isinstance(required, list) or any(not isinstance(k, str) for k in required) or len(set(required)) != len(required):
        raise FixtureError("required must be a list of distinct item names")
    toggles = state.get("toggles", [])
    if not isinstance(toggles, list):
        raise FixtureError("toggles must be an array")
    valid_items = ITEMS | {f"toggle.{i}" for i in range(len(toggles))}
    if value["schemaVersion"] == 2:
        screen_state.validate(value)
        valid_items |= screen_state.required_items(state)
    if set(required) - valid_items:
        raise FixtureError("Unknown required item")
    fields = {"window": "window", "zoom": "zoomPercent", "sidebar": ("sidebar" if "sidebar" in state else "sidebarOpen"), "scroll": "scroll", "focus": "focus"}
    if any(k in required and state.get(field) is None for k, field in fields.items()):
        raise FixtureError("A required item must have a requested value")
    if "target" not in required or "screenshot" not in required:
        raise FixtureError("target and screenshot must be required")
    if "window" in state:
        r = state["window"]
        if not isinstance(r, dict) or set(r) != {"x", "y", "width", "height"} or any(type(n) not in (int, float) or not (-100000 < n < 100000) for n in r.values()) or min(r["width"], r["height"]) <= 0:
            raise FixtureError("window must contain finite x, y, positive width and height in points")
    if "zoomPercent" in state and (type(state["zoomPercent"]) is not int or state["zoomPercent"] not in (100, 125)):
        raise FixtureError("Only 100 and 125 percent zoom requests are supported initially; numeric readback remains unsupported")
    if "sidebarOpen" in state and type(state["sidebarOpen"]) is not bool:
        raise FixtureError("sidebarOpen must be boolean")
    def anchor(a):
        if not isinstance(a, dict) or set(a) - {"text", "blockClass", "ancestorText"} or not isinstance(a.get("text"), str) or not a["text"].strip():
            raise FixtureError("An anchor needs nonempty source text and optional blockClass/ancestorText")
        if any(not isinstance(v, str) or not v for v in a.values()):
            raise FixtureError("Anchor fields must be nonempty strings")
    if "scroll" in state:
        s = state["scroll"]
        if not isinstance(s, dict) or set(s) - {"mode", "anchor", "offset"} or s.get("mode") not in ("top", "anchor"):
            raise FixtureError("scroll mode must be top or anchor")
        if s["mode"] == "anchor":
            anchor(s.get("anchor"))
            if type(s.get("offset")) not in (int, float) or not -10000 < s["offset"] < 10000:
                raise FixtureError("anchor scroll requires a finite viewport offset in points")
        elif set(s) != {"mode"}:
            raise FixtureError("top scroll accepts no anchor or offset")
    for toggle in toggles:
        if not isinstance(toggle, dict) or set(toggle) != {"anchor", "expanded"} or type(toggle["expanded"]) is not bool:
            raise FixtureError("Each toggle requires anchor and expanded boolean")
        anchor(toggle["anchor"])
    if "focus" in state:
        f = state["focus"]
        if not isinstance(f, dict) or f.get("mode") not in ("clear", "selection"):
            raise FixtureError("focus must use clear or selection mode")
        if f["mode"] == "clear" and set(f) != {"mode"}:
            raise FixtureError("clear focus accepts no selection")
        if f["mode"] == "selection":
            if set(f) != {"mode", "anchor", "location", "length"}:
                raise FixtureError("selection requires anchor, location and length")
            anchor(f["anchor"])
            if any(type(f[k]) is not int or f[k] < 0 for k in ("location", "length")) or f["location"] + f["length"] > len(f["anchor"]["text"].encode("utf-16-le")) // 2:
                raise FixtureError("Selection range must fit the source text in UTF-16 units")
    return value


def catalog(root):
    result = []
    known = set()
    for path in sorted((root / "scenarios").glob("*/*.json")):
        value = validate(read_json(path))
        if path.parent.name != value["fixtureId"] or path.stem != value["id"] or value["id"] in known:
            raise FixtureError(f"Scenario path/ID mismatch or duplicate ID: {path}")
        known.add(value["id"])
        result.append(value)
    return result


def anchor_source(definition):
    """Return fixture-authored text that can safely back navigation anchors."""
    parts = []
    page = getattr(definition, "page", None)
    if page is not None:
        parts.append(json.dumps(page, ensure_ascii=False))

    content = getattr(definition, "content", None)
    if content is not None:
        parts.append(content)
    else:
        manifest = getattr(definition, "manifest", {})
        database_title = manifest.get("databaseTitle") if isinstance(manifest, dict) else None
        if isinstance(database_title, str):
            parts.append(database_title)
        for name in ("schema", "views", "rows"):
            value = getattr(definition, name, None)
            if value is not None:
                parts.append(json.dumps(value, ensure_ascii=False))
    return "\n".join(parts)


def anchor_match_count(anchor, source):
    return source.count(anchor["text"])


def anchor_match_error(anchor, count):
    if count == 0:
        return f"Anchor {anchor['text']!r} is not present in the local fixture source"
    return f"Anchor {anchor['text']!r} appears {count} times in the local fixture source; choose a unique phrase"


def omit_unverifiable_optional_capture_anchors(state, definition, required):
    """Drop captured optional anchors that cannot be tied to fixture-authored text."""
    source = anchor_source(definition)
    warnings = []
    omitted = {}

    def can_keep(item, anchor, required_item=None):
        count = anchor_match_count(anchor, source)
        if count == 1:
            return True
        issue = anchor_match_error(anchor, count)
        if (required_item or item) in required:
            raise FixtureError(f"Required {item} state cannot be saved: {issue}")
        warning = f"Omitted optional {item} state: {issue}."
        warnings.append(warning)
        omitted.setdefault(item, []).append(issue)
        return False

    for item in ("scroll", "focus"):
        value = state.get(item)
        anchor = value.get("anchor") if isinstance(value, dict) else None
        if isinstance(anchor, dict) and not can_keep(item, anchor):
            state.pop(item, None)

    toggles = state.get("toggles")
    if isinstance(toggles, list):
        kept = []
        for index, toggle in enumerate(toggles):
            anchor = toggle.get("anchor") if isinstance(toggle, dict) else None
            if not isinstance(anchor, dict) or can_keep("toggles", anchor, f"toggle.{index}"):
                kept.append(toggle)
        state["toggles"] = kept

    return warnings, omitted


def check_anchors(scenario, definition):
    # AX reads navigate; only fixture-authored text can back persisted anchors.
    state = scenario["state"]
    source = anchor_source(definition)
    anchors = [t["anchor"] for t in state.get("toggles", [])]
    anchors += [v["anchor"] for k in ("scroll", "focus") if (v := state.get(k, {})).get("anchor")]
    for item in anchors:
        count = anchor_match_count(item, source)
        if count != 1:
            raise FixtureError(anchor_match_error(item, count))
    if scenario["schemaVersion"] == 1:
        return
    preview = state.get("presentation", {})
    preview_definition = definition
    if preview.get("fixtureId") and preview["fixtureId"] != definition.name:
        preview_definition = definitions(definition.directory.parent.parent, preview["fixtureId"])[0]
    if "rowIndex" in preview:
        rows = getattr(definition, "rows", [])
        if preview["rowIndex"] >= len(rows):
            raise FixtureError("Preview rowIndex exceeds Fixture rows")
        preview_source = json.dumps(rows[preview["rowIndex"]], ensure_ascii=False)
    else:
        preview_source = anchor_source(preview_definition)
    for key in ("scrolls", "tabs", "blockDisplays", "captureRegion"):
        values = [state[key]] if key == "captureRegion" and key in state else state.get(key, [])
        for item in values:
            item_source = preview_source if item.get("scope") == "preview" else source
            for field in ("anchor", "container", "contentAnchor"):
                if field in item:
                    count = anchor_match_count(item[field], item_source)
                    if item.get("scope") == "preview" and "rowIndex" in preview:
                        row = definition.rows[preview["rowIndex"]]
                        title = "".join(part.get("text", {}).get("content", "") for prop in row["properties"].values() for part in prop.get("title", []))
                        if item[field]["text"] == title:
                            count = 1
                    if definition.kind == "database" and item.get("scope") != "preview":
                        text = item[field]["text"]
                        if text in definition.schema["properties"]:
                            count = 1
                        else:
                            authored_values = ["".join(part.get("text", {}).get("content", "") for part in value[kind])
                                               for row in definition.rows for value in row["properties"].values()
                                               for kind in ("title", "rich_text") if kind in value]
                            if authored_values.count(text) == 1:
                                count = 1
                    if count != 1:
                        raise FixtureError(anchor_match_error(item[field], count))
            if key == "tabs" and item_source.count(item["selectedText"]) < 1:
                raise FixtureError("Tab label is not present in the Fixture")
    if "databaseView" in state:
        if state["databaseView"] not in [v["name"] for v in getattr(definition, "views", [])]:
            raise FixtureError("Database view is not defined by the host Fixture")


def check_source_versions(root, scenario):
    if scenario["schemaVersion"] == 1:
        return
    known = {d.name: d for d in definitions(root)}
    pinned = scenario["fixtureVersions"]
    for name, source_hash in pinned.items():
        if name not in known or known[name].source_hash != source_hash:
            raise ScenarioError("fixture_version_mismatch", "Participating local source differs: " + name)
    host = known[scenario["fixtureId"]]
    required = {host.name} | {link["fixtureId"] for link in host.page_links}
    if not required <= set(pinned):
        raise ScenarioError("fixture_version_mismatch", "Pin every linked Fixture displayed by the host")
    target = scenario["state"].get("presentation", {}).get("fixtureId")
    if target and target != host.name and target not in required:
        raise ScenarioError("invalid_preview_reference", "Preview is not linked by the host Fixture")


def participant_definitions(root, scenario, entries):
    """Validate all pinned sources before any UI input; retain v1 behavior."""
    if scenario["schemaVersion"] == 1:
        return {}
    check_source_versions(root, scenario)
    known = {d.name: d for d in definitions(root)}
    pinned = scenario["fixtureVersions"]
    result = {}
    for name, source_hash in pinned.items():
        definition = known.get(name)
        entry = entries.get(name)
        if definition is None or definition.source_hash != source_hash or not entry or entry.get("sourceHash") != source_hash:
            raise ScenarioError("fixture_version_mismatch", "Participating Fixture version differs: " + name)
        if entry.get("status") != "ready":
            raise ScenarioError("fixture_not_ready", "Participating Fixture is not ready: " + name)
        result[name] = definition
    host = known[scenario["fixtureId"]]
    preview = scenario["state"].get("presentation", {})
    target = preview.get("fixtureId")
    if target and target != host.name and target not in [link["fixtureId"] for link in host.page_links]:
        raise ScenarioError("invalid_preview_reference", "Preview target must be linked by the host Fixture")
    required = {host.name} | {link["fixtureId"] for link in host.page_links}
    if not required <= set(pinned):
        raise ScenarioError("fixture_version_mismatch", "Pin all linked Fixture versions displayed by the host")
    return result


def native_page_references(known, entries):
    result = []
    for name, definition in known.items():
        entry = entries.get(name, {})
        if entry.get("status") != "ready" or entry.get("sourceHash") != definition.source_hash:
            continue
        result.append(dict(fixtureId=name, pageId=entry["pageId"], title=fixture_title(definition)))
        for index, row in enumerate(getattr(definition, "rows", [])):
            ids = entry.get("rowIds", [])
            if index < len(ids):
                title = "".join(fragment.get("text", {}).get("content", "") for prop in row["properties"].values() for fragment in prop.get("title", []))
                notes = ["".join(fragment.get("text", {}).get("content", "") for fragment in prop['rich_text'])
                         for prop in row["properties"].values() if prop.get('rich_text')]
                reference = dict(fixtureId=name, rowIndex=index, pageId=ids[index], title=title)
                if notes:
                    reference['rowText'] = notes[0]
                result.append(reference)
    return result


def native_binary(root):
    configured = os.environ.get("NOTION_SCENARIO_EXECUTABLE")
    candidates = [Path(configured)] if configured else [root.parent / "dist/NotionScenarios.app/Contents/MacOS/NotionScenarios"]
    for path in candidates:
        if path.is_file() and os.access(path, os.X_OK):
            return path.resolve()
    raise FixtureError("Build the native app with scripts/package_notion_scenarios.sh, or set NOTION_SCENARIO_EXECUTABLE")


def native_command(executable, arguments):
    """Launch packaged apps as their own TCC principal, not the terminal's child."""
    executable = Path(executable)
    if sys.platform == "darwin" and len(executable.parents) > 2 and executable.parents[2].suffix == ".app":
        return ["/usr/bin/open", "-g", "-n", "-W", str(executable.parents[2]), "--args", *arguments]
    return [str(executable), *arguments]


def terminate_native_worker(directory, executable, run_id):
    """The LaunchServices launcher is not the worker. Kill only this run's proven process."""
    marker = Path(directory) / "native-process.json"
    if not marker.exists():
        return False
    identity = read_json(marker)
    pid = identity.get("pid")
    if identity.get("runId") != run_id or type(pid) is not int or pid <= 1:
        return False
    command = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True, timeout=2)
    expected_request = str(Path(directory) / "request.json")
    if str(executable) not in command.stdout or expected_request not in command.stdout:
        return False
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    return True


def fixture_title(definition):
    properties = definition.manifest.get("page", {}).get("properties", {})
    title_property = properties.get("title", {}) if isinstance(properties, dict) else {}
    fragments = title_property.get("title", []) if isinstance(title_property, dict) else []
    parts = []
    for fragment in fragments:
        if not isinstance(fragment, dict):
            continue
        plain_text = fragment.get("plain_text")
        text = fragment.get("text")
        content = text.get("content", "") if isinstance(text, dict) else ""
        parts.append(plain_text if isinstance(plain_text, str) else content if isinstance(content, str) else "")
    title = "".join(parts).strip()
    title = re.sub(rf"\s*[|｜]\s*{re.escape(definition.name)}\s*$", "", title).strip()
    return title or definition.name


def fixture_for_page(definitions_list, fixture_entries, page_id):
    matches = [definition for definition in definitions_list
               if isinstance((entry := fixture_entries.get(definition.name)), dict)
               and isinstance(entry.get("pageId"), str)
               and (same_id(entry["pageId"], page_id) or
                    any(same_id(row_id, page_id) for row_id in entry.get("rowIds", [])))]
    if not matches:
        raise ScenarioError("current_page_unregistered", "The focused Notion page is not registered as a Fixture in this folder")
    if len(matches) != 1:
        names = ", ".join(sorted(definition.name for definition in matches))
        raise ScenarioError("current_page_ambiguous", f"The focused Notion page is registered to multiple Fixtures: {names}")
    definition = matches[0]
    entry = fixture_entries[definition.name]
    if entry.get("status") != "ready":
        raise ScenarioError("fixture_not_ready", f"Fixture '{definition.name}' is not ready; run fixture ensure separately")
    if entry.get("sourceHash") != definition.source_hash:
        raise ScenarioError("fixture_version_mismatch", f"Fixture '{definition.name}' changed; run fixture ensure and review its scenarios separately")
    return definition


def resolve_current_page_id(root):
    try:
        executable = native_binary(root)
        command = native_command(executable, ["--resolve-current-page"])
        if command[0] == "/usr/bin/open":
            with tempfile.TemporaryDirectory(prefix="notion-page-") as temporary:
                output = Path(temporary) / "page.txt"
                process = subprocess.run(command + ["--output", str(output)], text=True, capture_output=True, timeout=10)
                page_output = output.read_text() if output.exists() else ""
        else:
            process = subprocess.run(command, text=True, capture_output=True, timeout=6)
            page_output = process.stdout
    except subprocess.TimeoutExpired as exc:
        raise ScenarioError("current_page_unavailable", "Could not determine the focused Notion page within 6 seconds") from exc
    except OSError as exc:
        raise ScenarioError("current_page_unavailable", f"Could not inspect the focused Notion page: {exc}") from exc
    if process.returncode != 0:
        message = process.stderr.strip() or "Could not determine the focused Notion page"
        code, separator, detail = message.partition(": ")
        if not separator or not re.fullmatch(r"[a-z_]+", code):
            code, detail = "current_page_unavailable", message
        raise ScenarioError(code, detail)
    page_id = page_output.strip()
    if not re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", page_id):
        raise ScenarioError("current_page_unavailable", "Native page resolver returned an invalid page ID")
    return page_id


def failed_capture_report(root, scenario_id, name, error):
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    run_id = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:12]
    directory = root / "runs" / run_id
    directory.mkdir(parents=True)
    detail = str(error)
    report = dict(runId=run_id, fixtureId="", fixtureVersion="", scenarioId=scenario_id,
                  scenarioVersion=1, startedAt=started, finishedAt=started, durationMs=0,
                  status="failed", requested={}, observed={},
                  steps=[dict(item="preflight", status="failed", code=getattr(error, "code", "fixture_error"),
                              detail=detail, durationMs=0)], runDirectory=str(directory))
    atomic_json(directory / "request.json", dict(runId=run_id, operation="capture",
                pageId="", scenario=dict(id=scenario_id, name=name, fixtureId="", version=1)))
    atomic_json(directory / "result.json", report)
    return report


def capture_new_scenario(root, scenario_id, name, definition, expected_page_id=None):
    value = dict(schemaVersion=1, id=scenario_id, name=name, version=1,
                 fixtureId=definition.name, fixtureVersion=definition.source_hash,
                 state=dict(coordinateSystem="screen-top-left-points", required=["target", "screenshot"]))
    report = execute(root, value, "capture", expected_page_id=expected_page_id)
    if report["status"] != "failed" and report.get("screenshot"):
        try:
            observed = copy.deepcopy({k: v for k, v in report["observed"].items() if k != "required" and v is not None})
            initially_required = list(value["state"].get("required", []))
            if set(observed) & screen_state.FIELDS:
                value["schemaVersion"] = 2
                known = {d.name: d for d in definitions(root)}
                names = {definition.name} | {link["fixtureId"] for link in definition.page_links}
                preview_fixture = observed.get("presentation", {}).get("fixtureId")
                if preview_fixture:
                    names.add(preview_fixture)
                captured_versions = report.get("availableFixtureVersions", {name: known[name].source_hash for name in names})
                if any(captured_versions.get(name) != known[name].source_hash for name in names):
                    raise ScenarioError("fixture_version_mismatch", "Fixture sources changed during capture")
                value["fixtureVersions"] = {name: captured_versions[name] for name in names}
                initially_required += sorted(screen_state.required_items(observed))
            observed["required"] = initially_required
            value["state"] = observed
            validate(value)
            capture_warnings, omitted_items = omit_unverifiable_optional_capture_anchors(
                observed, definition, set(initially_required)
            )
            observed["required"] = initially_required + [k for k in ("window", "scroll", "focus") if k in observed]
            if "sidebarOpen" in observed or "sidebar" in observed:
                if "sidebar" not in observed["required"]:
                    observed["required"].append("sidebar")
            observed["required"] += [f"toggle.{i}" for i in range(len(observed.get("toggles", [])))]
            value["state"] = observed
            validate(value)
            check_anchors(value, definition)
            atomic_json(root / "scenarios" / value["fixtureId"] / f"{value['id']}.json", value, create_only=True)
            report["savedScenario"] = value["id"]
            if capture_warnings:
                report["captureWarnings"] = capture_warnings
                report["status"] = "partial"
                for item, issues in omitted_items.items():
                    step = next((step for step in report["steps"] if step["item"] == item), None)
                    if step:
                        step["status"] = "unsupported"
                        step["code"] = "optional_anchor_omitted"
                        step["detail"] = "Optional captured state omitted: " + "; ".join(issues)
            if report.get("savedScenario") and report.get("screenshot") and report.get("documentUnchanged") is True:
                try:
                    baseline = publish_baseline(
                        value, report, Path(report["runDirectory"]) / "screen.png", root / "captures"
                    )
                    report["savedBaseline"] = baseline
                except (BaselineError, OSError, ValueError) as exc:
                    report["baselineSaveError"] = str(exc)
                    report["status"] = "partial"
            elif report.get("savedScenario"):
                report["baselineSaveError"] = "Capture was not promoted because document integrity was not verified"
                report["status"] = "partial"
        except (FixtureError, OSError) as exc:
            report["captureSaveError"] = str(exc)
            report["status"] = "failed"
        atomic_json(Path(report["runDirectory"]) / "result.json", report)
    return report


def find(root, identifier):
    return next((s for s in catalog(root) if s["id"] == identifier), None)


def execute(root, scenario, operation, expected_page_id=None):
    start = time.monotonic()
    run_id = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:12]
    directory = root / "runs" / run_id
    directory.mkdir(parents=True)
    report = dict(runId=run_id, fixtureId=scenario.get("fixtureId"), fixtureVersion=scenario.get("fixtureVersion"),
                  scenarioId=scenario.get("id"), scenarioVersion=scenario.get("version"),
                  startedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(), status="running",
                  requested=scenario.get("state", {}), observed={}, steps=[], nativeInvoked=False)
    atomic_json(directory / "result.json", report)
    run_started_at = report["startedAt"]
    native = None
    api = None
    preflight_steps = []
    try:
        validate(scenario)
        from .replay_policy import rejection
        definition = definitions(root, scenario['fixtureId'])[0]
        if operation == 'apply' and (reason := rejection(scenario, definition)):
            raise ScenarioError('persistent_presentation_unsupported', reason)
        with State(root) as state:
            if expected_page_id is not None:
                mapped_definition = fixture_for_page(definitions(root), state.data["fixtures"], expected_page_id)
                if mapped_definition.name != scenario["fixtureId"]:
                    raise ScenarioError("current_page_changed", "Focused page Fixture mapping changed before capture")
            entry = state.data["fixtures"].get(definition.name)
            if not entry or entry.get("status") != "ready":
                raise ScenarioError("fixture_not_ready", "Fixture is not ready; run fixture ensure separately")
            if scenario["fixtureVersion"] != definition.source_hash or entry.get("sourceHash") != definition.source_hash:
                raise ScenarioError("fixture_version_mismatch", "Fixture version mismatch; review the scenario and ensure the document separately")
            check_anchors(scenario, definition)
            participants = participant_definitions(root, scenario, state.data["fixtures"])
            api = Notion()
            api.request_timeout = 10
            api.deadline = start + 120
            identity = api.request("GET", "v1/users/me")
            if identity.get("id") != state.data.get("identity", {}).get("userId"):
                raise ScenarioError("account_mismatch", "Notion account differs from fixture state")
            workspace = state.data.get("identity", {}).get("workspaceId")
            if workspace:
                api.env["NOTION_WORKSPACE_ID"] = workspace
            manager = Manager(api, state)
            before = manager.snapshot(entry, parallel_views=True)
            report["documentBefore"] = before
            if not manager.matches_baseline(definition, before, entry.get("baseline")):
                raise ScenarioError("fixture_changed", "Document differs from fixture baseline; run ensure separately before replay")
            related_before = {}
            preview = scenario["state"].get("presentation", {})
            preview_fixture = preview.get("fixtureId")
            related_names = {preview_fixture} if preview_fixture and preview_fixture != definition.name else set()
            if operation == "capture":
                related_names.update(link['fixtureId'] for link in definition.page_links)
            for related_name in sorted(related_names):
                related_definition = definitions(root, related_name)[0]
                related_entry = state.data["fixtures"].get(related_name, {})
                if related_entry.get('status') != 'ready' or related_entry.get('sourceHash') != related_definition.source_hash:
                    raise ScenarioError('fixture_not_ready', 'Participating capture document is not ready: ' + related_name)
                related_before[related_name] = manager.snapshot(related_entry, parallel_views=True)
                related_definition = definitions(root, related_name)[0]
                if not manager.matches_baseline(related_definition, related_before[related_name], related_entry.get("baseline")):
                    raise ScenarioError("fixture_changed", "Preview document differs from its baseline")
            report["relatedDocumentsBefore"] = related_before
            executable = native_binary(root)
            capture_page_id = expected_page_id if operation == "capture" and expected_page_id else entry["pageId"]
            request = dict(runId=run_id, operation=operation, pageId=capture_page_id, scenario=scenario,
                           allowPersistentPresentation=definition.mutable_presentation,
                           timeoutSeconds=max(1, start + 112 - time.monotonic()))
            if scenario["schemaVersion"] == 2 or operation == "capture":
                known = {d.name: d for d in definitions(root)}
                request["pageReferences"] = native_page_references(known, state.data["fixtures"])
                if operation == "capture":
                    candidates = [screen_state.capture_candidates(d, 'main' if d.name == definition.name else 'preview')
                                  for d in known.values() if d.name == definition.name or d.name in [link['fixtureId'] for link in definition.page_links]]
                    request["captureTabs"] = [tab for tabs, _ in candidates for tab in tabs]
                    request["captureBlockDisplays"] = [display for _, displays in candidates for display in displays]
                report["availableFixtureVersions"] = {name: d.source_hash for name, d in known.items() if state.data["fixtures"].get(name, {}).get("sourceHash") == d.source_hash}
            if definition.kind == "database" and same_id(capture_page_id, entry["pageId"]):
                request["databaseViewNames"] = [view["name"] for view in definition.views]
                request["databaseViewTypes"] = {view['name']: view['type'] for view in definition.views}
                request["databasePropertyNames"] = list(definition.schema["properties"])
            if preview_fixture:
                reference = next((ref for ref in request.get("pageReferences", [])
                                  if ref["fixtureId"] == preview_fixture and ref.get("rowIndex") == preview.get("rowIndex")), None)
                if reference is None:
                    raise ScenarioError("invalid_preview_reference", "Preview page could not be resolved")
                request["previewPageId"] = reference["pageId"]
                request["previewTitle"] = reference["title"]
                if "rowText" in reference:
                    request["previewRowText"] = reference["rowText"]
            if expected_page_id is not None:
                request["requireFocusedPage"] = True
            atomic_json(directory / "request.json", request)
            preflight_steps = [dict(item="preflight", status="verified", detail="Fixture version, managed scope, account and API baseline verified", durationMs=int((time.monotonic() - start) * 1000))]
            report["steps"] = preflight_steps.copy()
            print(json.dumps(preflight_steps[0]), file=sys.stderr, flush=True)
            atomic_json(directory / "result.json", report)
            try:
                report["nativeInvoked"] = True
                atomic_json(directory / "result.json", report)
                process = subprocess.run(native_command(executable, ["--request", str(directory / "request.json"), "--output", str(directory)]),
                                         stdout=subprocess.DEVNULL, timeout=max(1, start + 115 - time.monotonic()))
                native = read_json(directory / "result.json")
                report.update(native)
                report["steps"] = preflight_steps + native.get("steps", [])
                if process.returncode not in (0, 2, 3):
                    raise FixtureError(f"Native runner exited with status {process.returncode}")
                if report.get("status") == "running":
                    raise FixtureError("Native runner did not complete its result")
            except subprocess.TimeoutExpired:
                report["nativeWorkerTerminated"] = terminate_native_worker(directory, executable, run_id)
                native = read_json(directory / "result.json")
                report.update(native)
                report["steps"] = preflight_steps + [s for s in native.get("steps", []) if s["item"] != "preflight"]
                raise
            finally:
                integrity_start = time.monotonic()
                # Read-only postcondition, including failed/partial native runs.
                after = manager.snapshot(entry, parallel_views=True)
                report["documentAfter"] = after
                related_after = {name: manager.snapshot(state.data["fixtures"][name], parallel_views=True) for name in related_before}
                report["relatedDocumentsAfter"] = related_after
                unchanged = manager.matches_baseline(definition, after, before) and all(
                    manager.matches_baseline(definitions(root, name)[0], related_after[name], related_before[name])
                    for name in related_before)
                report["documentUnchanged"] = unchanged
                report["steps"].append(dict(item="documentIntegrity", status="verified" if unchanged else "failed",
                                            code=None if unchanged else "document_changed",
                                            detail=("Sandbox presentation may change; managed IDs and inventory compared before/after; not a content equality proof"
                                                    if definition.mutable_presentation else
                                                    "Notion API timestamps and managed object inventory compared before/after; not a content equality proof"),
                                            durationMs=int((time.monotonic() - integrity_start) * 1000)))
                if not unchanged:
                    report["status"] = "failed"
    except (FixtureError, OSError, ValueError, subprocess.TimeoutExpired) as exc:
        report["status"] = "failed"
        report["steps"].append(dict(item="preflight" if native is None else "execution", status="failed",
                                    code=("timeout" if isinstance(exc, subprocess.TimeoutExpired) else
                                          "access_denied" if isinstance(exc, APIError) and exc.status in (401, 403) else
                                          "missing_or_inaccessible" if isinstance(exc, APIError) and exc.status == 404 else
                                          getattr(exc, "code", None) or "fixture_error"),
                                    detail=str(exc), durationMs=int((time.monotonic() - start) * 1000)))
    report["apiRequests"] = api.metrics if api is not None else []
    report["startedAt"] = run_started_at
    report["durationMs"] = int((time.monotonic() - start) * 1000)
    report["finishedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    report["runDirectory"] = str(directory)
    atomic_json(directory / "result.json", report)
    return report


def dispatch(root, args):
    if args.scenario_command == "list":
        items = catalog(root)
        value = {"scenarios": items, "fixtures": [dict(id=d.name, title=fixture_title(d), version=d.source_hash) for d in definitions(root)]}
        if args.json:
            print(json.dumps(value, ensure_ascii=False))
        else:
            for s in items:
                print(f"{s['fixtureId']}\t{s['id']}\tv{s['version']}\t{s['name']}")
        return 0
    if args.scenario_command == "save":
        value = validate(json.loads(args.definition.read_text(encoding="utf-8")))
        definition = definitions(root, value["fixtureId"])[0]
        if value["fixtureVersion"] != definition.source_hash:
            raise FixtureError("Scenario fixtureVersion must match the current local source hash")
        check_anchors(value, definition)
        check_source_versions(root, value)
        existing = find(root, value["id"])
        source = find(root, args.replace_id) if args.replace_id else None
        if args.replace_id:
            if source is None:
                raise FixtureError("Original scenario no longer exists")
            if source["fixtureId"] != value["fixtureId"]:
                raise FixtureError("Cannot change a scenario's fixture while renaming it")
            if existing:
                raise FixtureError("Scenario ID already exists")
        if existing and existing["fixtureId"] != value["fixtureId"]:
            raise FixtureError("Scenario ID already belongs to another fixture")
        if args.create_only and existing:
            raise FixtureError("Scenario ID already exists")
        value["version"] = (source or existing)["version"] + 1 if source or existing else 1
        target_path = root / "scenarios" / value["fixtureId"] / f"{value['id']}.json"
        try:
            atomic_json(target_path, value, create_only=args.create_only or bool(source))
        except FileExistsError as exc:
            raise FixtureError("Scenario ID already exists") from exc
        if source:
            source_path = root / "scenarios" / source["fixtureId"] / f"{source['id']}.json"
            try:
                source_path.unlink()
            except OSError:
                target_path.unlink()
                raise
        print(json.dumps(value, ensure_ascii=False))
        return 0
    if args.scenario_command == "delete":
        value = find(root, args.id)
        if value is None:
            raise FixtureError("Unknown scenario")
        (root / "scenarios" / value["fixtureId"] / f"{value['id']}.json").unlink()
        print(json.dumps({"deleted": args.id}))
        return 0
    if args.scenario_command in ("capture", "capture-current"):
        if not ID.fullmatch(args.id) or find(root, args.id):
            raise FixtureError("Capture requires a new, valid scenario ID; edit an existing scenario explicitly")
        name = args.name or args.id
        if args.scenario_command == "capture":
            definition = definitions(root, args.fixture_id)[0]
            report = capture_new_scenario(root, args.id, name, definition)
        else:
            try:
                page_id = resolve_current_page_id(root)
                fixture_definitions = definitions(root)
                with State(root) as state:
                    definition = fixture_for_page(fixture_definitions, state.data["fixtures"], page_id)
            except (FixtureError, OSError, KeyError, TypeError, ValueError) as exc:
                error = exc if isinstance(exc, ScenarioError) else ScenarioError("fixture_error", str(exc))
                report = failed_capture_report(root, args.id, name, error)
            else:
                report = capture_new_scenario(root, args.id, name, definition, expected_page_id=page_id)
    else:
        value = find(root, args.id)
        if value is None:
            raise FixtureError("Unknown scenario")
        report = execute(root, value, "apply")
    if args.json:
        print(json.dumps(report, ensure_ascii=False))
    else:
        print(f"{report['runId']}\t{report['status']}\t{report['runDirectory']}")
        for step in report["steps"]:
            print(f"  {step['item']}: {step['status']} — {step['detail']}")
    return {"verified": 0, "partial": 2, "failed": 3}[report["status"]]


def add_parser(commands):
    scenario = commands.add_parser("scenario", help="Manage/replay Notion desktop screen scenarios")
    subs = scenario.add_subparsers(dest="scenario_command", required=True)
    listing = subs.add_parser("list")
    listing.add_argument("--json", action="store_true")
    apply = subs.add_parser("apply")
    apply.add_argument("id")
    apply.add_argument("--json", action="store_true")
    capture = subs.add_parser("capture")
    capture.add_argument("fixture_id")
    capture.add_argument("--id", required=True)
    capture.add_argument("--name")
    capture.add_argument("--json", action="store_true")
    capture_current = subs.add_parser("capture-current", help="Capture the focused Notion page when it maps to one ready Fixture")
    capture_current.add_argument("--id", required=True)
    capture_current.add_argument("--name")
    capture_current.add_argument("--json", action="store_true")
    save = subs.add_parser("save", help="Validate/create/update a scenario JSON definition")
    save.add_argument("definition", type=Path)
    save.add_argument("--create-only", action="store_true", help="Fail if the scenario ID already exists")
    save.add_argument("--replace-id", help="Rename this existing scenario to the ID in the JSON")
    delete = subs.add_parser("delete")
    delete.add_argument("id")
