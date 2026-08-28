#!/usr/bin/env python3
"""Health check server for Runpod load balancing endpoints.

The Runpod load balancer polls HEALTH_CHECK_PATH on PORT_HEALTH and reads
200 as healthy, 204 as initializing, and anything else as unhealthy.

ComfyUI does not start until the model download finishes, so until then the
worker's port refuses connections and the load balancer drops the worker from
the routing pool. This server is started before the download begins and reports
204 so the load balancer knows the worker is still coming up.

It switches to 200 once ComfyUI's /system_stats responds.

The probe runs on its own thread rather than inside the request handler. A
probe against a port nobody is listening on does not always fail fast -- it can
block for the full timeout -- and that is exactly the state we are in for the
whole download. Answering from a cached flag keeps every response immediate, so
the load balancer's own timeout can never be the reason it misses the 204.
"""

import os
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

COMFY_PORT = os.environ.get("COMFY_PORT", "8188")
HEALTH_PORT = int(os.environ.get("PORT_HEALTH", "8189"))
PROBE_URL = f"http://127.0.0.1:{COMFY_PORT}/system_stats"
PROBE_INTERVAL_SECONDS = 2.0
PROBE_TIMEOUT_SECONDS = 2.0

# Written by the probe thread, read by request handlers. Plain bool assignment
# is atomic under CPython, so this needs no lock.
_comfy_is_up = False


def probe_once() -> bool:
    try:
        with urllib.request.urlopen(PROBE_URL, timeout=PROBE_TIMEOUT_SECONDS) as response:
            return response.status == 200
    except (urllib.error.URLError, OSError, ValueError):
        return False


def probe_forever() -> None:
    global _comfy_is_up
    while True:
        _comfy_is_up = probe_once()
        time.sleep(PROBE_INTERVAL_SECONDS)


class HealthHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:  # noqa: N802 (BaseHTTPRequestHandler naming)
        if _comfy_is_up:
            self.send_response(200)
            self.send_header("Content-Length", "0")
        else:
            # A 204 must not carry content, so it gets no Content-Length either.
            # Some proxies treat the pair as a framing error and drop the
            # response, which the load balancer would read as unhealthy.
            self.send_response(204)
        self.end_headers()

    def log_message(self, *_args) -> None:
        """Silence per-poll logging so it does not flood the boot log."""


if __name__ == "__main__":
    threading.Thread(target=probe_forever, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", HEALTH_PORT), HealthHandler).serve_forever()
