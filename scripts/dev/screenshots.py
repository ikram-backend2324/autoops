"""Take screenshots of the provisioned Grafana dashboards and an example Telegram alert.

Run through scripts/dev/screenshots.sh (Playwright container attached to the autoops network).
"""

from __future__ import annotations

import os
import pathlib
import time
import urllib.request

from playwright.sync_api import sync_playwright

# The browser runs in Grafana's network namespace (see screenshots.sh), so localhost:3000
# matches Grafana's root_url and all its asset URLs resolve.
GRAFANA = os.environ.get("GRAFANA_URL", "http://localhost:3000")
USER = os.environ.get("GRAFANA_USER", "admin")
PASSWORD = os.environ.get("GRAFANA_PASSWORD", "autoops")
OUT = pathlib.Path(os.environ.get("OUT_DIR", "/work/docs/screenshots"))
RANGE = os.environ.get("RANGE", "now-1h")

DASHBOARDS = {
    "server-overview": "autoops-server",
    "containers": "autoops-containers",
    "postgres": "autoops-postgres",
    "app": "autoops-app",
    "availability": "autoops-availability",
    "backups": "autoops-backups",
    "logs": "autoops-logs",
}

TELEGRAM_HTML = """<!doctype html><html><head><meta charset="utf-8"><style>
body {{ margin:0; background:#0e1621; font-family: -apple-system, Segoe UI, Roboto, sans-serif; }}
.chat {{ width: 560px; padding: 24px; }}
.head {{ color:#fff; font-weight:600; margin-bottom:14px; font-size:15px; }}
.head small {{ display:block; color:#6c7883; font-weight:400; }}
.msg {{ background:#182533; color:#e9eef3; border-radius:12px; padding:10px 14px 18px; margin-bottom:12px;
        font-size:14.5px; line-height:1.45; white-space:pre-wrap; position:relative; }}
.msg a {{ color:#6ab3f3; text-decoration:none; }} .msg code {{ font-family: Consolas, monospace; color:#e9eef3; }}
.time {{ position:absolute; right:10px; bottom:4px; color:#6c7883; font-size:11px; }}
</style></head><body><div class="chat"><div class="head">AutoOps Alerts<small>bot · rendered from stacks/monitoring/alertmanager/templates/telegram.tmpl</small></div>
{messages}</div></body></html>"""


def grafana_ready() -> None:
    for _ in range(60):
        try:
            urllib.request.urlopen(f"{GRAFANA}/api/health", timeout=3).close()
            return
        except Exception:  # noqa: BLE001
            time.sleep(2)
    raise SystemExit("grafana not reachable")


def telegram_page(messages: list[str]) -> str:
    bubbles = [f'<div class="msg">{text.strip()}</div>' for text in messages]
    return TELEGRAM_HTML.format(messages="\n".join(bubbles))


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    grafana_ready()
    with sync_playwright() as p:
        browser = p.chromium.launch()
        ctx = browser.new_context(
            viewport={"width": 1600, "height": 2200},  # tall: Grafana lazy-loads panels below the fold
            http_credentials={"username": USER, "password": PASSWORD},
            device_scale_factor=1,
            color_scheme="dark",
            locale="en-US",  # container default "en-US@posix" crashes Grafana's Intl code
            timezone_id="Asia/Tashkent",
        )
        page = ctx.new_page()
        page.goto(f"{GRAFANA}/login", wait_until="load")
        page.fill('input[name="user"]', USER)
        page.fill('input[name="password"]', PASSWORD)
        page.click('button[type="submit"]')
        page.wait_for_url(lambda url: "/login" not in url, timeout=30_000)
        for name, uid in DASHBOARDS.items():
            url = f"{GRAFANA}/d/{uid}?orgId=1&from={RANGE}&to=now&kiosk&theme=dark"
            page.goto(url, wait_until="load", timeout=90_000)
            try:
                page.wait_for_load_state("networkidle", timeout=30_000)
            except Exception:  # noqa: BLE001 - live dashboards keep polling; render anyway
                pass
            # Panels mount asynchronously; wait until they exist before taking the picture.
            page.wait_for_selector("section[data-testid^='data-testid Panel header']", timeout=60_000)
            time.sleep(8)  # let panels finish querying/rendering
            # Crop to the panels: the tall viewport would otherwise leave empty space below.
            bottom = page.evaluate(
                "Math.max(...[...document.querySelectorAll(\"section[data-testid^='data-testid Panel header']\")]"
                ".map(e => e.getBoundingClientRect().bottom + window.scrollY))"
            )
            page.screenshot(path=str(OUT / f"{name}.png"), clip={"x": 0, "y": 0, "width": 1600, "height": int(bottom) + 16})
            print("saved", OUT / f"{name}.png")

        rendered = [os.environ[k] for k in sorted(os.environ) if k.startswith("TELEGRAM_MSG_")]
        if rendered:
            page.set_viewport_size({"width": 620, "height": 400})
            page.set_content(telegram_page(rendered))
            page.screenshot(path=str(OUT / "telegram-alerts.png"), full_page=True)
            print("saved", OUT / "telegram-alerts.png")
        browser.close()


if __name__ == "__main__":
    main()
