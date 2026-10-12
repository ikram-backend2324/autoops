"""Docker HEALTHCHECK for the web role (python:slim has no curl)."""
import os
import sys
import urllib.request

PORT = os.environ.get("PORT", "8000")

try:
    with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/health/live/", timeout=4) as resp:
        sys.exit(0 if resp.status == 200 else 1)
except Exception:  # noqa: BLE001 - any failure means unhealthy
    sys.exit(1)
