"""Screen scenarios: local definitions + read-only fixture checks + native runner.

This module never invokes ensure/reset or any Notion write endpoint.
"""
import copy
import datetime
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

from .definitions import FixtureError, definitions, read_json
from .manager import Manager, State
from .ntn import APIError, Notion

class ScenarioError(FixtureError):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


ID = re.compile(r"^[a-z0-9][a-z0-9-]{0,79}$")
ITEMS = {"target", "window", "zoom", "sidebar", "scroll", "focus", "screenshot", "finalState"}


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".scenario-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2, allow_nan=False)
            handle.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def validate(value):
    if not isinstance(value, dict):
        raise FixtureError("Scenario must be a JSON object")
    if set(value) != {"schemaVersion", "id", "name", "version", "fixtureId", "fixtureVersion", "state"}:
        raise FixtureError("Scenario requires schemaVersion, id, name, version, fixtureId, fixtureVersion, state only")
    if value["schemaVersion"] != 1 or type(value["version"]) is not int or value["version"] < 1:
        raise FixtureError("Unsupported scenario schema or invalid version")
    if not all(isinstance(value[k], str) and ID.fullmatch(value[k]) for k in ("id", "fixtureId")):
        raise FixtureError("Scenario and fixture IDs must use lowercase letters, numbers and hyphens")
    if not isinstance(value["name"], str) or not value["name"].strip():
        raise FixtureError("Scenario name is required")
    if not isinstance(value["fixtureVersion"], str) or not re.fullmatch(r"[0-9a-f]{64}", value["fixtureVersion"]):
        raise FixtureError("fixtureVersion must be the fixture source SHA-256")
    state = value["state"]
    if not isinstance(state, dict) or set(state) - {"coordinateSystem", "window", "zoomPercent", "sidebarOpen", "scroll", "toggles", "focus", "required"}:
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
    if set(required) - valid_items:
        raise FixtureError("Unknown required item")
    fields = {"window": "window", "zoom": "zoomPercent", "sidebar": "sidebarOpen", "scroll": "scroll", "focus": "focus"}
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


def check_anchors(scenario, definition):
    # AX reads are navigation observations, never a new source-of-truth corpus.
    # v1 conservatively requires unique verbatim text in the existing local source.
    source = getattr(definition, "content", None)
    if source is None:
        source = json.dumps(definition.rows, ensure_ascii=False)
    state = scenario["state"]
    anchors = [t["anchor"] for t in state.get("toggles", [])]
    anchors += [v["anchor"] for k in ("scroll", "focus") if (v := state.get(k, {})).get("anchor")]
    for a in anchors:
        if source.count(a["text"]) != 1:
            raise FixtureError("Anchor must occur exactly once in the local fixture source; choose a different unique phrase")


def native_binary(root):
    configured = os.environ.get("NOTION_SCENARIO_EXECUTABLE")
    candidates = [Path(configured)] if configured else [root.parent / "dist/NotionScenarios.app/Contents/MacOS/NotionScenarios"]
    for path in candidates:
        if path.is_file() and os.access(path, os.X_OK):
            return path.resolve()
    raise FixtureError("Build the native app with scripts/package_notion_scenarios.sh, or set NOTION_SCENARIO_EXECUTABLE")


def find(root, identifier):
    return next((s for s in catalog(root) if s["id"] == identifier), None)


def execute(root, scenario, operation):
    start = time.monotonic()
    run_id = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:12]
    directory = root / "runs" / run_id
    directory.mkdir(parents=True)
    report = dict(runId=run_id, fixtureId=scenario.get("fixtureId"), fixtureVersion=scenario.get("fixtureVersion"),
                  scenarioId=scenario.get("id"), scenarioVersion=scenario.get("version"),
                  startedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(), status="running",
                  requested=scenario.get("state", {}), observed={}, steps=[])
    atomic_json(directory / "result.json", report)
    run_started_at = report["startedAt"]
    native = None
    api = None
    preflight_steps = []
    try:
        validate(scenario)
        with State(root) as state:
            definition = definitions(root, scenario["fixtureId"])[0]
            entry = state.data["fixtures"].get(definition.name)
            if not entry or entry.get("status") != "ready":
                raise ScenarioError("fixture_not_ready", "Fixture is not ready; run fixture ensure separately")
            if scenario["fixtureVersion"] != definition.source_hash or entry.get("sourceHash") != definition.source_hash:
                raise ScenarioError("fixture_version_mismatch", "Fixture version mismatch; review the scenario and ensure the document separately")
            check_anchors(scenario, definition)
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
            if before != entry.get("baseline"):
                raise ScenarioError("fixture_changed", "Document differs from fixture baseline; run ensure separately before replay")
            executable = native_binary(root)
            request = dict(runId=run_id, operation=operation, pageId=entry["pageId"], scenario=scenario,
                           timeoutSeconds=max(1, start + 112 - time.monotonic()))
            atomic_json(directory / "request.json", request)
            preflight_steps = [dict(item="preflight", status="verified", detail="Fixture version, managed scope, account and API baseline verified", durationMs=int((time.monotonic() - start) * 1000))]
            report["steps"] = preflight_steps.copy()
            print(json.dumps(preflight_steps[0]), file=sys.stderr, flush=True)
            atomic_json(directory / "result.json", report)
            try:
                process = subprocess.run([str(executable), "--request", str(directory / "request.json"), "--output", str(directory)],
                                         stdout=subprocess.DEVNULL, timeout=max(1, start + 115 - time.monotonic()))
                native = read_json(directory / "result.json")
                report.update(native)
                report["steps"] = preflight_steps + native.get("steps", [])
                if process.returncode not in (0, 2, 3):
                    raise FixtureError(f"Native runner exited with status {process.returncode}")
                if report.get("status") == "running":
                    raise FixtureError("Native runner did not complete its result")
            except subprocess.TimeoutExpired:
                native = read_json(directory / "result.json")
                report.update(native)
                report["steps"] = preflight_steps + [s for s in native.get("steps", []) if s["item"] != "preflight"]
                raise
            finally:
                integrity_start = time.monotonic()
                # Read-only postcondition, including failed/partial native runs.
                after = manager.snapshot(entry, parallel_views=True)
                report["documentAfter"] = after
                report["documentUnchanged"] = before == after
                report["steps"].append(dict(item="documentIntegrity", status="verified" if before == after else "failed",
                                            code=None if before == after else "document_changed",
                                            detail="Notion API timestamps and managed object inventory compared before/after; not a content equality proof", durationMs=int((time.monotonic() - integrity_start) * 1000)))
                if before != after:
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
        value = {"scenarios": items, "fixtures": [dict(id=d.name, version=d.source_hash) for d in definitions(root)]}
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
        existing = find(root, value["id"])
        if existing and existing["fixtureId"] != value["fixtureId"]:
            raise FixtureError("Scenario ID already belongs to another fixture")
        value["version"] = existing["version"] + 1 if existing else 1
        atomic_json(root / "scenarios" / value["fixtureId"] / f"{value['id']}.json", value)
        print(json.dumps(value, ensure_ascii=False))
        return 0
    if args.scenario_command == "delete":
        value = find(root, args.id)
        if value is None:
            raise FixtureError("Unknown scenario")
        (root / "scenarios" / value["fixtureId"] / f"{value['id']}.json").unlink()
        print(json.dumps({"deleted": args.id}))
        return 0
    if args.scenario_command == "capture":
        if not ID.fullmatch(args.id) or find(root, args.id):
            raise FixtureError("Capture requires a new, valid scenario ID; edit an existing scenario explicitly")
        definition = definitions(root, args.fixture_id)[0]
        value = dict(schemaVersion=1, id=args.id, name=args.name or args.id, version=1,
                     fixtureId=definition.name, fixtureVersion=definition.source_hash,
                     state=dict(coordinateSystem="screen-top-left-points", required=["target", "screenshot"]))
        report = execute(root, value, "capture")
        if report["status"] != "failed" and report.get("screenshot"):
            observed = {k: v for k, v in report["observed"].items() if k != "required" and v is not None}
            observed["required"] = ["target", "screenshot"] + [k for k in ("window", "scroll", "focus") if k in observed]
            if "sidebarOpen" in observed:
                observed["required"].append("sidebar")
            observed["required"] += [f"toggle.{i}" for i in range(len(observed.get("toggles", [])))]
            value["state"] = observed
            try:
                validate(value)
                check_anchors(value, definition)
                atomic_json(root / "scenarios" / value["fixtureId"] / f"{value['id']}.json", value)
                report["savedScenario"] = value["id"]
            except FixtureError as exc:
                report["captureSaveError"] = str(exc)
                report["status"] = "failed"
            atomic_json(Path(report["runDirectory"]) / "result.json", report)
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
    save = subs.add_parser("save", help="Validate/create/update a scenario JSON definition")
    save.add_argument("definition", type=Path)
    delete = subs.add_parser("delete")
    delete.add_argument("id")
