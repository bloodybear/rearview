"""Small JSON subprocess boundary around the official ntn CLI."""
import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
import time

from .definitions import FixtureError

API_VERSION = "2026-03-11"


class APIError(FixtureError):
    def __init__(self, message, status=None, code=None):
        super().__init__(message)
        self.status = status
        self.code = code

    @property
    def definitive(self):
        # A rejected request can be retried by the next invocation. Transport and
        # server failures may have committed a write and must remain journaled.
        return self.status is not None and 400 <= self.status < 500 and self.status != 408


def decode_object(output):
    try:
        value = json.loads(output)
        return value if isinstance(value, dict) else None
    except ValueError:
        # Error JSON may follow ntn's textual diagnostic prefix.
        decoder = json.JSONDecoder()
        for match in re.finditer(r"\{", output):
            try:
                value, _ = decoder.raw_decode(output[match.start():])
                if isinstance(value, dict) and value.get("object") == "error":
                    return value
            except ValueError:
                pass
    return None


class Notion:
    def __init__(self):
        self.executable = shutil.which("ntn")
        if not self.executable:
            raise FixtureError("ntn is not installed. Install the official CLI: https://developers.notion.com/cli/get-started/overview")
        self.env = os.environ.copy()
        self.env["NO_COLOR"] = "1"
        self.last_call = 0.0

    def request(self, method, path, body=None, query=None):
        args = [self.executable, "api", path, "-X", method,
                "--notion-version", API_VERSION]
        args.extend(f"{key}=={value}" for key, value in (query or {}).items())
        for attempt in range(4):
            time.sleep(max(0, .35 - (time.monotonic() - self.last_call)))
            try:
                result = subprocess.run(args, input=json.dumps(body, ensure_ascii=False) if body is not None else "",
                                        text=True, capture_output=True, env=self.env, timeout=120)
            except (OSError, subprocess.TimeoutExpired) as exc:
                raise APIError(f"{method} {path}: transport failure ({type(exc).__name__}); write outcome may be unknown") from exc
            finally:
                self.last_call = time.monotonic()
            obj = decode_object(result.stdout) or decode_object(result.stderr)
            if result.returncode == 0 and obj and obj.get("object") != "error":
                if obj.get("object") == "async_task":
                    raise APIError(f"{path}: unexpected asynchronous response; inspect the remote result before retrying")
                return obj
            status = obj.get("status") if obj else None
            code = obj.get("code") if obj else None
            diagnostic = result.stderr + "\n" + result.stdout
            if status is None:
                match = re.search(r"\b(400|401|403|404|408|409|429|500|502|503|504|529)\b", diagnostic)
                status = int(match[1]) if match else None
            if not code:
                match = re.search(r"\b(validation_error|unauthorized|restricted_resource|object_not_found|rate_limited|conflict_error|internal_server_error|service_unavailable)\b", diagnostic)
                code = match[1] if match else None
            if status == 429 and attempt < 3:
                time.sleep(2 ** (attempt + 1))
                continue
            # Never echo raw subprocess diagnostics: they may contain credentials.
            message = f"{method} {path}: ntn request failed (status={status or 'unknown'}, code={code or 'unknown'})"
            if status in (401, 403):
                message += "; check ntn login and page permissions; no replacement was created"
            if status == 404:
                message += "; missing object and lost access cannot be distinguished; no replacement was created"
            raise APIError(message, status, code)

    def upload_png(self, filename, data):
        # ntn files create always uses multipart upload, unavailable on Free.
        # These committed PNGs fit the official single_part (<= 5 MB) flow.
        if len(data) > 5 * 1024 * 1024:
            raise FixtureError("Fixture PNG exceeds the single-part 5 MB limit")
        upload = self.request("POST", "v1/file_uploads", {
            "mode": "single_part", "filename": filename, "content_type": "image/png"
        })
        if not upload.get("id"):
            raise APIError("File upload creation did not return an id")
        with tempfile.TemporaryDirectory(prefix="notion-fixture-upload-") as directory:
            path = Path(directory) / filename
            path.write_bytes(data)
            args = [self.executable, "api", f"v1/file_uploads/{upload['id']}/send", "-X", "POST",
                    "--file", str(path), "--notion-version", API_VERSION]
            try:
                result = subprocess.run(args, capture_output=True, env=self.env, timeout=120)
            except (OSError, subprocess.TimeoutExpired) as exc:
                raise APIError("Image upload failed; fixture remains incomplete") from exc
        obj = decode_object(result.stdout.decode("utf-8", errors="replace"))
        if result.returncode or not obj or not obj.get("id") or obj.get("status") != "uploaded":
            raise APIError("ntn did not return a completed single-part upload; fixture remains incomplete")
        return obj

    def all(self, method, path, body=None, query=None):
        results, seen = [], set()
        body, query = dict(body or {}), dict(query or {})
        target = body if method == "POST" else query
        target["page_size"] = 100
        while True:
            obj = self.request(method, path, body if method == "POST" else None, query)
            if not isinstance(obj.get("results"), list):
                raise FixtureError(f"{path}: invalid list response")
            results.extend(obj["results"])
            if not obj.get("has_more"):
                return results
            cursor = obj.get("next_cursor")
            if not cursor or cursor in seen:
                raise FixtureError(f"{path}: invalid pagination cursor")
            seen.add(cursor)
            target["start_cursor"] = cursor
