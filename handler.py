#!/usr/bin/env python3
"""Runpod Serverless handler for the ACE-Step ComfyUI worker.

ComfyUI runs alongside this process and keeps serving its web UI, so the same
image works as a Pod. This handler adds the queue API that Serverless and the
Hub's own test both speak.

The job contract has two shapes, and both are real:

    {"health_check": true}  -> ComfyUI's /system_stats, for a liveness or
                               capability check that costs nothing
    {"workflow": {...}}     -> run the workflow and return its outputs

Anything without a "workflow" key takes the first path, so the exact probe key
does not matter -- but it cannot be empty. Runpod drops an empty `input` from
the job it hands the SDK, which then rejects the job before this code runs:

    Job has missing field(s): id or input.

The first path is what the Hub's build-time test uses. It is not a
validation-only back door: reporting server status is a reasonable thing for
the API to do, and anyone deploying this as an endpoint gets the same answer.
"""

import base64
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request

import runpod

COMFY_PORT = os.environ.get("COMFY_PORT") or os.environ.get("PORT") or "8188"
COMFY_HOST = f"127.0.0.1:{COMFY_PORT}"

# ComfyUI is started just before this process and has to load torch and its
# nodes first, so the first job can arrive well before the server answers.
STARTUP_TIMEOUT_S = int(os.environ.get("COMFY_STARTUP_TIMEOUT", "900"))
# Generating audio takes far longer than queueing it, so the ceiling here is
# about catching a wedged job rather than bounding normal work.
WORKFLOW_TIMEOUT_S = int(os.environ.get("COMFY_WORKFLOW_TIMEOUT", "1800"))
POLL_INTERVAL_S = 1.0
# Outputs come back inline as base64. Anything larger is reported by name
# instead of inflating the response past what the queue will carry.
MAX_INLINE_BYTES = int(os.environ.get("COMFY_MAX_INLINE_BYTES", str(48 * 1024 * 1024)))


def _get(path, timeout=30):
    with urllib.request.urlopen(f"http://{COMFY_HOST}{path}", timeout=timeout) as r:
        return r.read()


def _get_json(path, timeout=30):
    return json.loads(_get(path, timeout))


def wait_for_comfy(timeout_s=STARTUP_TIMEOUT_S):
    """Block until ComfyUI answers, or give up and say how long we waited."""
    deadline = time.time() + timeout_s
    last_error = None
    while time.time() < deadline:
        try:
            _get_json("/system_stats", timeout=5)
            return True, None
        except (urllib.error.URLError, OSError, ValueError) as exc:
            last_error = exc
            time.sleep(POLL_INTERVAL_S)
    return False, f"ComfyUI did not respond within {timeout_s}s ({last_error})"


def queue_workflow(workflow, client_id):
    payload = json.dumps({"prompt": workflow, "client_id": client_id}).encode()
    req = urllib.request.Request(
        f"http://{COMFY_HOST}/prompt",
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as exc:
        # ComfyUI reports node and input level validation errors in the body,
        # which is the only place the actual reason appears.
        detail = exc.read().decode("utf-8", "replace")
        raise ValueError(f"ComfyUI rejected the workflow: {detail}") from exc


def collect_outputs(node_outputs):
    """Pull every file ComfyUI produced, whatever node kind emitted it.

    Node outputs are keyed by kind -- 'audio' for ACE-Step, 'images' for a
    diffusion workflow, 'gifs' for video -- so match on the shape of the
    entries rather than on any single expected key.
    """
    files = []
    for node_id, output in (node_outputs or {}).items():
        for kind, entries in (output or {}).items():
            if not isinstance(entries, list):
                continue
            for entry in entries:
                if not isinstance(entry, dict) or "filename" not in entry:
                    continue
                query = urllib.parse.urlencode(
                    {
                        "filename": entry.get("filename", ""),
                        "subfolder": entry.get("subfolder", ""),
                        "type": entry.get("type", "output"),
                    }
                )
                record = {
                    "node_id": node_id,
                    "kind": kind,
                    "filename": entry.get("filename"),
                    "subfolder": entry.get("subfolder", ""),
                    "type": entry.get("type", "output"),
                }
                try:
                    blob = _get(f"/view?{query}", timeout=120)
                except (urllib.error.URLError, OSError) as exc:
                    record["error"] = f"could not fetch: {exc}"
                    files.append(record)
                    continue
                record["size_bytes"] = len(blob)
                if len(blob) <= MAX_INLINE_BYTES:
                    record["data"] = base64.b64encode(blob).decode()
                else:
                    record["error"] = (
                        f"{len(blob)} bytes exceeds COMFY_MAX_INLINE_BYTES "
                        f"({MAX_INLINE_BYTES}); returned by name only"
                    )
                files.append(record)
    return files


def run_workflow(workflow):
    client_id = str(int(time.time() * 1000))
    queued = queue_workflow(workflow, client_id)
    prompt_id = queued.get("prompt_id")
    if not prompt_id:
        return {"error": f"ComfyUI returned no prompt_id: {queued}"}

    deadline = time.time() + WORKFLOW_TIMEOUT_S
    while time.time() < deadline:
        history = _get_json(f"/history/{prompt_id}")
        entry = history.get(prompt_id)
        if entry:
            status = (entry.get("status") or {}).get("status_str")
            if status == "error":
                return {"prompt_id": prompt_id, "error": "workflow failed",
                        "status": entry.get("status")}
            # 'outputs' is only populated once execution finishes.
            if entry.get("outputs"):
                return {
                    "prompt_id": prompt_id,
                    "files": collect_outputs(entry["outputs"]),
                }
        time.sleep(POLL_INTERVAL_S)
    return {"prompt_id": prompt_id,
            "error": f"workflow did not finish within {WORKFLOW_TIMEOUT_S}s"}


def handler(job):
    job_input = job.get("input") or {}

    ready, error = wait_for_comfy()
    if not ready:
        return {"error": error}

    workflow = job_input.get("workflow")
    if not workflow:
        # No workflow: report what the server is, which is what the Hub's test
        # asks for and a useful probe for anyone else.
        return {
            "status": "ready",
            "comfyui": _get_json("/system_stats"),
            "usage": "POST {\"input\": {\"workflow\": <ComfyUI API-format workflow>}}",
        }

    if not isinstance(workflow, dict):
        return {"error": "workflow must be a ComfyUI API-format object"}

    try:
        return run_workflow(workflow)
    except ValueError as exc:
        return {"error": str(exc)}


if __name__ == "__main__":
    runpod.serverless.start({"handler": handler})
