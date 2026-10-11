"""Docker HEALTHCHECK for the web role (python:slim has no curl)."""
import sys
import urllib.request

try:
    with urllib.request.urlopen("http://127.0.0.1:8000/health/live/", timeout=4) as resp:
        sys.exit(0 if resp.status == 200 else 1)
except Exception:  # noqa: BLE001 - any failure means unhealthy
    sys.exit(1)
