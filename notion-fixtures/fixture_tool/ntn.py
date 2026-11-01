"""Small JSON subprocess boundary around the official ntn CLI."""
import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
import time
import threading

from .definitions import FixtureError

API_VERSION = "2026-03-11"


def metric_endpoint(path):
    parts = path.split("/")
    return "/".join("{id}" if i > 1 and parts[i - 1] in ("pages", "databases", "data_sources", "views", "blocks") else part
                    for i, part in enumerate(parts))


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
        self.request_timeout = 120
        self.deadline = None
        self.metrics = []
        self._condition = threading.Condition()
        self._next_start = 0.0
        self._cooldown_until = 0.0

    def remaining_timeout(self):
        remaining = self.request_timeout if self.deadline is None else min(self.request_timeout, self.deadline - time.monotonic())
        if remaining <= 0:
            raise APIError("Notion read deadline exceeded", code="timeout")
        return remaining

    def request(self, method, path, body=None, query=None):
        args = [self.executable, "api", path, "-X", method,
                "--notion-version", API_VERSION]
        args.extend(f"{key}=={value}" for key, value in (query or {}).items())
        for attempt in range(4):
            queued = time.monotonic()
            with self._condition:
                while True:
                    wait = max(self._next_start, self._cooldown_until) - time.monotonic()
                    if wait <= 0:
                        self._next_start = time.monotonic() + .35
                        break
                    if wait >= self.remaining_timeout():
                        raise APIError("Notion read deadline exceeded while queued", code="timeout")
                    self._condition.wait(timeout=wait)
            waited = time.monotonic() - queued
            started = time.monotonic()
            try:
                result = subprocess.run(args, input=json.dumps(body, ensure_ascii=False) if body is not None else "",
                                        text=True, capture_output=True, env=self.env, timeout=self.remaining_timeout())
            except (OSError, subprocess.TimeoutExpired) as exc:
                metric = {"endpoint": metric_endpoint(path), "method": method, "attempt": attempt + 1,
                                     "processMs": int((time.monotonic() - started) * 1000), "queueMs": int(waited * 1000),
                                     "status": None, "error": "timeout" if isinstance(exc, subprocess.TimeoutExpired) else "transport_error"}
                with self._condition:
                    self.metrics.append(metric)
                write_note = "; write outcome may be unknown" if method != "GET" else ""
                raise APIError(f"{method} {path}: transport failure ({type(exc).__name__}){write_note}",
                               code="timeout" if isinstance(exc, subprocess.TimeoutExpired) else "transport_error") from exc
            finally:
                self.last_call = time.monotonic()
            obj = decode_object(result.stdout) or decode_object(result.stderr)
            metric = {"endpoint": metric_endpoint(path), "method": method,
                                 "attempt": attempt + 1, "processMs": int((self.last_call - started) * 1000), "queueMs": int(waited * 1000),
                                 "status": (obj or {}).get("status", 200 if result.returncode == 0 else None)}
            with self._condition:
                self.metrics.append(metric)
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
            if status in (429, 529) and attempt < 3 and (obj or {}).get("additional_data", {}).get("rate_limit_reason") != "public_api_request_blocked":
                retry_after = (obj or {}).get("additional_data", {}).get("retry_after")
                delay = float(retry_after) if str(retry_after).isdigit() else 2 ** (attempt + 1)
                metric["retryWaitMs"] = int(delay * 1000)
                if delay >= self.remaining_timeout():
                    raise APIError("Notion read deadline exceeded during rate limit retry", code="timeout")
                with self._condition:
                    self._cooldown_until = max(self._cooldown_until, time.monotonic() + delay)
                    self._condition.notify_all()
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
            if obj.get("request_status", {}).get("type") == "incomplete":
                raise FixtureError(f"{path}: incomplete query result")
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
