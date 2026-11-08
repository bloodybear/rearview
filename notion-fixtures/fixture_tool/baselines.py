"""Shared helpers for publishing versioned scenario screenshot baselines."""
import hashlib
import json
import os
import shutil
import struct
import tempfile
from pathlib import Path


class BaselineError(ValueError):
    pass


def fingerprint(value):
    encoded = json.dumps(value, sort_keys=True, ensure_ascii=False).encode()
    return hashlib.sha256(encoded).hexdigest()


def png_dimensions(path):
    with Path(path).open("rb") as stream:
        header = stream.read(24)
    if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise BaselineError(f"not a valid PNG: {path}")
    return struct.unpack(">II", header[16:24])


def atomic_copy(source, destination):
    source, destination = Path(source), Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".screen-", dir=destination.parent)
    try:
        with source.open("rb") as incoming, os.fdopen(fd, "wb") as outgoing:
            shutil.copyfileobj(incoming, outgoing)
        Path(temporary).replace(destination)
    finally:
        Path(temporary).unlink(missing_ok=True)


def publish_baseline(scenario, report, source, output_root, replace=False):
    """Publish verified evidence as screen.png and manifest.json; never writes an index."""
    destination = Path(output_root) / scenario["fixtureId"] / scenario["id"] / f"v{scenario['version']}"
    image_path = destination / "screen.png"
    manifest_path = destination / "manifest.json"
    if image_path.is_file() and manifest_path.is_file():
        return dict(directory=str(destination), alreadyRegistered=True)
    screenshot = report.get("screenshot") or {}
    if (report.get("scenarioId") != scenario.get("id")
            or report.get("fixtureId") != scenario.get("fixtureId")
            or report.get("scenarioVersion") != scenario.get("version")
            or report.get("fixtureVersion") != scenario.get("fixtureVersion")
            or report.get("documentUnchanged") is not True
            or report.get("status") not in ("verified", "partial", "success")
            or not screenshot.get("capturedAt")):
        raise BaselineError("run evidence does not qualify as a baseline")
    policy_path = Path(output_root).parent / "scenario-catalog.json"
    policy = json.loads(policy_path.read_text()).get("cases", {}).get(scenario["id"], {}) if policy_path.exists() else {}
    allowed = set(policy.get("allowedUnsupported", []))
    steps = {step.get("item"): step for step in report.get("steps", [])}
    required = set(scenario.get("state", {}).get("required", [])) | {"target", "preflight", "documentIntegrity", "screenshot"}
    for item in required:
        step = steps.get(item, {})
        if step.get("status") == "verified":
            continue
        if item in allowed and step.get("status") == "unsupported":
            if item == "zoom":
                expected = {100: "Actual Size", 125: "Actual Size;Zoom In"}.get(scenario.get("state", {}).get("zoomPercent"))
                if not expected or report.get("environment", {}).get("zoomCommandsApplied") != expected:
                    raise BaselineError("Missing zoom command evidence")
            continue
        raise BaselineError("Missing verified required state: " + item)
    source = Path(source)
    try:
        width, height = png_dimensions(source)
    except (OSError, struct.error) as exc:
        raise BaselineError(f"missing or invalid screenshot: {source}") from exc
    if (width, height) != (screenshot.get("pixelWidth"), screenshot.get("pixelHeight")):
        raise BaselineError("screenshot dimensions do not match run evidence")

    scenario_hash = fingerprint(scenario)
    image_hash = hashlib.sha256(source.read_bytes()).hexdigest()
    manifest = dict(
        schemaVersion=1,
        scenarioId=scenario["id"],
        fixtureId=scenario["fixtureId"],
        scenarioVersion=scenario["version"],
        fixtureVersion=scenario["fixtureVersion"],
        scenarioSHA256=scenario_hash,
        sourceRunId=report.get("runId"),
        capturedAt=screenshot["capturedAt"],
        frame=screenshot.get("frame"),
        pixelWidth=width,
        pixelHeight=height,
        imageSHA256=image_hash,
        replayStatus=report.get("status"),
        documentUnchanged=True,
    )
    atomic_copy(source, image_path)
    from .scenarios import atomic_json
    atomic_json(manifest_path, manifest)
    return dict(directory=str(destination), imageSHA256=image_hash, alreadyRegistered=False)
