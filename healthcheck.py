#!/usr/bin/env python3
"""Health check server for Runpod load balancing endpoints.

The Runpod load balancer polls HEALTH_CHECK_PATH on PORT_HEALTH and reads
200 as healthy, 204 as initializing, and anything else as unhealthy.

ComfyUI does not start until the model download finishes, so until then the
worker's port refuses connections and the load balancer drops the worker from
the routing pool. This server is started before the download begins and reports
204 so the load balancer knows the worker is still coming up.

It switches to 200 once ComfyUI's /system_stats responds.
"""

import os
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

COMFY_PORT = os.environ.get("COMFY_PORT", "8188")
HEALTH_PORT = int(os.environ.get("PORT_HEALTH", "8189"))
PROBE_URL = f"http://127.0.0.1:{COMFY_PORT}/system_stats"


def comfy_is_up() -> bool:
    try:
        with urllib.request.urlopen(PROBE_URL, timeout=2) as response:
            return response.status == 200
    except (urllib.error.URLError, OSError, ValueError):
        return False


class HealthHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802 (BaseHTTPRequestHandler naming)
        self.send_response(200 if comfy_is_up() else 204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *_args) -> None:
        """Silence per-poll logging so it does not flood the boot log."""


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", HEALTH_PORT), HealthHandler).serve_forever()
