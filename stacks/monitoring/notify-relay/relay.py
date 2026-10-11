"""AutoOps notify-relay: one small HTTP service every component can notify through.

Endpoints
  POST /alertmanager  Alertmanager webhook payload (audit log; Telegram is sent by Alertmanager itself)
  POST /notify        {"text": "...", "severity": "info|warning|critical", "source": "watchdog"}
                      Used by autoheal (WEBHOOK_URL), the watchdog, backups and reports.
                      Forwarded to Telegram when TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID are set.
  GET  /events        Recent events as JSON (?since=<unix ts>&limit=N) - used by chaos tests and reports.
  GET  /health        Liveness.
  GET  /metrics       Prometheus counters.

Without Telegram credentials everything is printed to stdout, so the whole pipeline can be
verified on a laptop with `docker compose logs notify-relay`.
Standard library only, so it also runs directly on a host if needed.
"""

from __future__ import annotations

import html
import json
import os
import sys
import threading
import time
import urllib.parse
import urllib.request
from collections import Counter, deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
CHAT_ID = os.environ.get("TELEGRAM_CHAT_ID", "").strip()
SERVER = os.environ.get("SERVER_NAME", "local")
EVENTS_FILE = os.environ.get("EVENTS_FILE", "/data/events.jsonl")
MAX_EVENTS = int(os.environ.get("MAX_EVENTS", "2000"))
LISTEN_PORT = int(os.environ.get("PORT", "9095"))

SEVERITY_ICON = {"critical": "🔴", "warning": "🟠", "info": "🔵", "resolved": "✅", "ok": "✅"}

_events: deque[dict] = deque(maxlen=MAX_EVENTS)
_lock = threading.Lock()
_counters: Counter[str] = Counter()


def log(msg: str) -> None:
    print(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {msg}", flush=True)


def load_events() -> None:
    try:
        with open(EVENTS_FILE, encoding="utf-8") as fh:
            for line in fh:
                if line.strip():
                    _events.append(json.loads(line))
    except FileNotFoundError:
        pass
    except Exception as exc:  # noqa: BLE001 - a corrupt log must not stop the relay
        log(f"WARN cannot read {EVENTS_FILE}: {exc}")


def store(event: dict) -> None:
    event.setdefault("ts", time.time())
    with _lock:
        _events.append(event)
        _counters[f'{event["kind"]}|{event.get("severity", "")}'] += 1
        try:
            os.makedirs(os.path.dirname(EVENTS_FILE), exist_ok=True)
            with open(EVENTS_FILE, "a", encoding="utf-8") as fh:
                fh.write(json.dumps(event, ensure_ascii=False) + "\n")
            # keep the file bounded
            if _counters["writes"] % 500 == 499:
                with open(EVENTS_FILE, "w", encoding="utf-8") as fh:
                    fh.writelines(json.dumps(e, ensure_ascii=False) + "\n" for e in _events)
            _counters["writes"] += 1
        except OSError as exc:
            log(f"WARN cannot persist event: {exc}")


def send_telegram(text: str, silent: bool = False) -> bool:
    if not (TOKEN and CHAT_ID):
        return False
    data = urllib.parse.urlencode(
        {
            "chat_id": CHAT_ID,
            "text": text[:4000],
            "parse_mode": "HTML",
            "disable_web_page_preview": "true",
            "disable_notification": "true" if silent else "false",
        }
    ).encode()
    try:
        req = urllib.request.Request(f"https://api.telegram.org/bot{TOKEN}/sendMessage", data=data)
        with urllib.request.urlopen(req, timeout=10) as resp:
            ok = resp.status == 200
    except Exception as exc:  # noqa: BLE001
        log(f"ERROR telegram send failed: {exc}")
        ok = False
    _counters["telegram_ok" if ok else "telegram_failed"] += 1
    return ok


def handle_alertmanager(payload: dict) -> None:
    for alert in payload.get("alerts", []):
        labels = alert.get("labels", {})
        ann = alert.get("annotations", {})
        status = alert.get("status", "firing")
        severity = labels.get("severity", "info")
        event = {
            "kind": "alert",
            "status": status,
            "alertname": labels.get("alertname", "?"),
            "severity": severity,
            "summary": ann.get("summary", ""),
            "labels": labels,
            "startsAt": alert.get("startsAt"),
            "endsAt": alert.get("endsAt"),
        }
        store(event)
        icon = SEVERITY_ICON["resolved"] if status == "resolved" else SEVERITY_ICON.get(severity, "⚪")
        log(f"ALERT {icon} [{status.upper()}] {event['alertname']} ({severity}) {event['summary']}")


def handle_notify(payload: dict) -> None:
    # "text" is ours; "content"/"message" cover autoheal's and other tools' defaults.
    text = str(payload.get("text") or payload.get("content") or payload.get("message") or "").strip()
    if not text:
        raise ValueError("text is required")
    severity = payload.get("severity", "info")
    source = payload.get("source", "autoheal" if "container" in text.lower() else "external")
    # autoheal posts plain English; give it the same Russian framing as our own actions.
    if source == "autoheal":
        text = f"🔧 Автовосстановление (autoheal): {text}"
    store({"kind": "notify", "severity": severity, "source": source, "text": text})
    log(f"NOTIFY [{severity}] {source}: {text}")
    icon = SEVERITY_ICON.get(severity, "")
    message = f"{icon} {html.escape(text)}\n🖥 Сервер: <code>{html.escape(SERVER)}</code>".strip()
    send_telegram(message, silent=severity == "info" and source != "report")


class Handler(BaseHTTPRequestHandler):
    server_version = "autoops-notify-relay/1.0"

    def _json(self, code: int, body: object) -> None:
        raw = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, *_args) -> None:  # silence default access log
        return

    def do_GET(self) -> None:  # noqa: N802
        url = urllib.parse.urlparse(self.path)
        if url.path == "/health":
            self._json(200, {"status": "ok", "telegram": bool(TOKEN and CHAT_ID)})
        elif url.path == "/events":
            qs = urllib.parse.parse_qs(url.query)
            since = float(qs.get("since", ["0"])[0])
            limit = int(qs.get("limit", ["500"])[0])
            with _lock:
                items = [e for e in _events if e.get("ts", 0) >= since][-limit:]
            self._json(200, items)
        elif url.path == "/metrics":
            lines = [
                "# HELP autoops_relay_events_total Events received by the relay.",
                "# TYPE autoops_relay_events_total counter",
            ]
            for key, value in sorted(_counters.items()):
                if "|" in key:
                    kind, severity = key.split("|", 1)
                    lines.append(f'autoops_relay_events_total{{kind="{kind}",severity="{severity}"}} {value}')
            lines += [
                "# TYPE autoops_relay_telegram_sent_total counter",
                f'autoops_relay_telegram_sent_total{{result="ok"}} {_counters["telegram_ok"]}',
                f'autoops_relay_telegram_sent_total{{result="failed"}} {_counters["telegram_failed"]}',
            ]
            raw = ("\n".join(lines) + "\n").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.end_headers()
            self.wfile.write(raw)
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) or b"{}"
        try:
            payload = json.loads(raw)
            if self.path.startswith("/alertmanager"):
                handle_alertmanager(payload)
            elif self.path.startswith("/notify"):
                handle_notify(payload)
            else:
                self._json(404, {"error": "not found"})
                return
        except (ValueError, json.JSONDecodeError) as exc:
            log(f"WARN rejected {self.path}: {exc}; body={raw[:300]!r}")
            self._json(400, {"error": str(exc)})
            return
        self._json(200, {"status": "ok"})


def main() -> int:
    load_events()
    mode = "telegram + log" if TOKEN and CHAT_ID else "log only (TELEGRAM_BOT_TOKEN not set)"
    log(f"notify-relay listening on :{LISTEN_PORT}, mode: {mode}")
    ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler).serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
