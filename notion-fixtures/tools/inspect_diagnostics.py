#!/usr/bin/env python3
"""Inspect a Rearview diagnostic ZIP or directory without running Rearview."""

import argparse
import json
from pathlib import Path, PurePosixPath
import shutil
import stat
import tempfile
import zipfile

MAX_BYTES = 160 * 1024 * 1024
MAX_ENTRIES = 20_000


def inspect(read, names):
    manifest = json.loads(read("manifest.json"))
    if manifest.get("schemaVersion") != 1:
        raise ValueError("Unsupported diagnostic schema")
    roles = {key: manifest.get(key) for key in ("current", "displayed", "failed")}
    counts = {}
    for line in read("events.jsonl").splitlines():
        if line.strip():
            event = json.loads(line)
            key = event.get("frame")
            counts.setdefault(key, {})
            name = event["name"]
            counts[key][name] = counts[key].get(name, 0) + 1
    frames = []
    wanted = {"manifest.json", "events.jsonl", "README.txt"} & names
    for frame in manifest["frames"]:
        frame_id = frame["id"]
        files = {f"{frame_id}/{name}" for name in frame["files"]}
        wanted.update(files & names)
        frames.append({
            **frame,
            "roles": [role for role, value in roles.items() if value == frame_id],
            "eventCounts": counts.get(frame_id, {}),
            "missingFiles": sorted(files - names),
        })
    summary = {key: manifest.get(key) for key in
               ("schemaVersion", "session", "symptom", "contentIncluded", "state", "omissions")}
    return dict(summary, roles=roles, frames=frames, unscopedEventCounts=counts.get(None, {})), wanted


def inspect_zip(path, extract):
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if len(entries) > MAX_ENTRIES or sum(entry.file_size for entry in entries) > MAX_BYTES:
            raise ValueError("Archive exceeds extraction limits")
        seen = set()
        files = {}
        for entry in entries:
            parts = PurePosixPath(entry.filename).parts
            canonical = "/".join(parts).casefold()
            kind = stat.S_IFMT(entry.external_attr >> 16)
            if (not parts or entry.filename.startswith("/") or
                    "\\" in entry.filename or ".." in parts or
                    kind not in (0, stat.S_IFREG, stat.S_IFDIR) or canonical in seen):
                raise ValueError(f"Unsafe or duplicate ZIP entry: {entry.filename!r}")
            seen.add(canonical)
            if not entry.is_dir():
                files["/".join(parts)] = entry
        roots = [name[:-len("manifest.json")] for name in files
                 if name == "manifest.json" or name.count("/") == 1 and name.endswith("/manifest.json")]
        if len(roots) != 1:
            raise ValueError("Expected one diagnostic manifest")
        prefix = roots[0]
        names = {name[len(prefix):] for name in files if name.startswith(prefix)}
        summary, wanted = inspect(lambda name: archive.read(files[prefix + name]), names)
        if extract:
            root = Path(tempfile.mkdtemp(prefix="rearview-diagnostics-"))
            try:
                for name in sorted(wanted):
                    destination = root / name
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    with archive.open(files[prefix + name]) as source, destination.open("xb") as output:
                        shutil.copyfileobj(source, output)
            except BaseException:
                shutil.rmtree(root)
                raise
            summary["root"] = str(root)
        return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("--extract", action="store_true", help="Extract listed evidence to a private temporary folder")
    args = parser.parse_args()
    try:
        if args.input.is_dir():
            root = args.input.resolve()
            candidates = list(root.iterdir())
            candidates += [file for folder in candidates if folder.is_dir() and not folder.is_symlink()
                           for file in folder.iterdir()]
            files = {file.relative_to(root).as_posix(): file for file in candidates
                     if file.is_file() and not file.is_symlink()}
            result, _ = inspect(lambda name: files[name].read_bytes(), set(files))
            result["root"] = str(root)
        else:
            result = inspect_zip(args.input, args.extract)
        print(json.dumps(result, ensure_ascii=False, indent=2))
    except (ValueError, TypeError, AttributeError, KeyError, OSError, RuntimeError, zipfile.BadZipFile) as error:
        parser.exit(1, f"Diagnostic inspection failed: {error}\n")


if __name__ == "__main__":
    main()
