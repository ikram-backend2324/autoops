#!/usr/bin/env python3
"""Weekly health report -> Telegram (via notify-relay).

Pulls from Prometheus: uptime of every probed URL, backups, restore checks, disk,
pending security updates, reboot flag; and from notify-relay: incidents and
self-healing actions of the last 7 days.

    PROMETHEUS_URL=http://127.0.0.1:9090 RELAY_URL=http://127.0.0.1:9095 weekly_report.py [--dry-run]
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.parse
import urllib.request
from collections import Counter

PROM = os.environ.get("PROMETHEUS_URL", "http://127.0.0.1:9090")
RELAY = os.environ.get("RELAY_URL", "http://127.0.0.1:9095")
SERVER = os.environ.get("SERVER_NAME", "server")
WEEK = 7 * 86400


def prom(query: str) -> list[dict]:
    url = f"{PROM}/api/v1/query?" + urllib.parse.urlencode({"query": query})
    try:
        with urllib.request.urlopen(url, timeout=15) as resp:
            return json.load(resp)["data"]["result"]
    except Exception as exc:  # noqa: BLE001
        print(f"prometheus query failed: {query}: {exc}", file=sys.stderr)
        return []


def scalar(query: str) -> float | None:
    result = prom(query)
    return float(result[0]["value"][1]) if result else None


def human_age(seconds: float | None) -> str:
    if seconds is None:
        return "нет данных"
    if seconds < 3600:
        return f"{seconds / 60:.0f} мин назад"
    if seconds < 86400 * 2:
        return f"{seconds / 3600:.0f} ч назад"
    return f"{seconds / 86400:.0f} дн назад"


def human_size(num: float) -> str:
    for unit in ("Б", "КБ", "МБ", "ГБ"):
        if num < 1024:
            return f"{num:.0f} {unit}" if unit == "Б" else f"{num:.1f} {unit}"
        num /= 1024
    return f"{num:.1f} ТБ"


def relay_events() -> list[dict]:
    try:
        with urllib.request.urlopen(f"{RELAY}/events?since={time.time() - WEEK}&limit=2000", timeout=10) as resp:
            return json.load(resp)
    except Exception as exc:  # noqa: BLE001
        print(f"relay unavailable: {exc}", file=sys.stderr)
        return []


def build_report() -> str:
    lines = [f"📋 Еженедельный отчёт AutoOps · {SERVER}", ""]

    lines.append("🌐 Доступность за 7 дней:")
    uptime = prom("avg_over_time(probe_success[7d]) * 100")
    for item in sorted(uptime, key=lambda r: r["metric"].get("instance", "")):
        value = float(item["value"][1])
        icon = "✅" if value >= 99.9 else "🟠" if value >= 99 else "🔴"
        lines.append(f"  {icon} {item['metric'].get('instance')}: {value:.3f}%")
    if not uptime:
        lines.append("  нет данных blackbox")

    events = relay_events()
    # Alertmanager re-sends a firing group every group_interval: one incident = one
    # (alertname, labels, startsAt) combination.
    incidents = {}
    for e in events:
        if e.get("kind") == "alert" and e.get("status") == "firing" and e.get("severity") in ("critical", "warning"):
            key = (e["alertname"], json.dumps(e.get("labels", {}), sort_keys=True), e.get("startsAt"))
            incidents[key] = e
    alerts = list(incidents.values())
    by_name = Counter(e["alertname"] for e in alerts)
    heals = [e for e in events if e.get("kind") == "notify" and e.get("source") in ("watchdog", "autoheal")]
    lines += ["", f"🚨 Инцидентов (critical/warning): {len(alerts)}"]
    lines += [f"  • {name}: {count}" for name, count in by_name.most_common(8)]
    lines.append(f"🔧 Действий автовосстановления: {len(heals)}")

    backup_age = scalar("time() - max(autoops_backup_last_success_timestamp_seconds)")
    verify = prom("autoops_restore_verify_success")
    size = scalar("max(autoops_backup_size_bytes)")
    lines += ["", f"💾 Последний бэкап: {human_age(backup_age)}"
              + (f", {human_size(size)}" if size else "")]
    for item in verify:
        ok = item["value"][1] == "1"
        lines.append(f"  {'✅' if ok else '❌'} проверка восстановления {item['metric'].get('app', '')}")
    if not verify:
        lines.append("  ⚠️ проверка восстановления ещё не выполнялась")

    disks = prom('100 * (1 - node_filesystem_avail_bytes{job="node",fstype!=""} / node_filesystem_size_bytes{job="node",fstype!=""})')
    lines += ["", "🗄 Диски:"]
    for item in disks:
        value = float(item["value"][1])
        icon = "✅" if value < 80 else "🟠" if value < 90 else "🔴"
        lines.append(f"  {icon} {item['metric'].get('mountpoint')}: {value:.0f}%")

    updates = scalar("max(autoops_apt_security_updates_pending)")
    reboot = scalar("max(autoops_reboot_required)")
    lines += ["", f"🛡 Ожидают обновления безопасности: {int(updates) if updates is not None else 'нет данных'}"]
    if reboot:
        lines.append("🔁 Требуется перезагрузка сервера")

    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true", help="print instead of sending")
    args = parser.parse_args()
    report = build_report()
    print(report)
    if args.dry_run:
        return 0
    payload = json.dumps({"text": report, "severity": "info", "source": "report"}).encode()
    req = urllib.request.Request(f"{RELAY}/notify", data=payload, headers={"Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=10).close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
