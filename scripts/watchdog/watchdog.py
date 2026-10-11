#!/usr/bin/env python3
"""AutoOps watchdog: the self-healing loop that complements Docker restart policies and autoheal.

Runs once per minute (systemd timer on a server, `--loop` in the laptop demo) and:
  1. Docker daemon unresponsive        -> systemctl restart docker
  2. Compose stack not fully running   -> docker compose up -d (or docker start when the
                                          compose files are not reachable, e.g. in a container)
  3. Disk usage above threshold        -> prune images/build cache/old containers, vacuum journald,
                                          delete known garbage; report how much was freed
  4. Exports Prometheus textfile metrics (container health, actions, last run, gave-up flag)
Every action is logged and sent to Telegram ("🔧 Автовосстановление: ...").
Loop protection: if the same action already ran WATCHDOG_MAX_ACTIONS times within an hour,
it stops trying and sends ONE critical "нужен человек" message per hour.

Configuration: environment variables (see DEFAULTS) - on a server /etc/autoops/watchdog.env.
Python standard library only.
"""

from __future__ import annotations

import argparse
import calendar
import glob
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

DEFAULTS = {
    "WATCHDOG_PROJECTS": "",  # comma list of compose projects to guard; empty = all compose projects
    "WATCHDOG_GRACE_SECONDS": "60",  # a container must be down this long before we act
    "WATCHDOG_DISK_PATHS": "/",
    "WATCHDOG_DISK_THRESHOLD": "85",
    "WATCHDOG_CLEAN_GLOBS": "/var/tmp/autoops-chaos-*,/var/log/*.gz,/var/log/*.[0-9],/var/log/**/*.gz",
    "WATCHDOG_MAX_ACTIONS": "3",  # per action per hour
    "WATCHDOG_STATE_FILE": "/var/lib/autoops/watchdog-state.json",
    "WATCHDOG_TEXTFILE_DIR": "/var/lib/node_exporter/textfile",
    "WATCHDOG_MAINTENANCE_FILE": "/var/lib/autoops/maintenance",
    "WATCHDOG_RESTART_DOCKER": "1",
    "WATCHDOG_PRUNE_UNTIL": "72h",
    "WATCHDOG_DOCKER_PRUNE": "1",
    "NOTIFY_URL": "http://127.0.0.1:9095/notify",
    "TELEGRAM_BOT_TOKEN": "",
    "TELEGRAM_CHAT_ID": "",
    "SERVER_NAME": os.uname().nodename if hasattr(os, "uname") else "server",
}


def cfg(name: str) -> str:
    return os.environ.get(name, DEFAULTS[name])


def log(msg: str) -> None:
    print(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} watchdog: {msg}", flush=True)


def run(cmd: list[str], timeout: int = 60) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=False)


# --------------------------------------------------------------------------- notifications
def notify(text: str, severity: str = "info") -> None:
    """Relay first (it also keeps the audit log), direct Telegram as fallback."""
    payload = json.dumps({"text": text, "severity": severity, "source": "watchdog"}).encode()
    url = cfg("NOTIFY_URL")
    if url:
        try:
            req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
            urllib.request.urlopen(req, timeout=5).close()
            return
        except Exception as exc:  # noqa: BLE001
            log(f"relay unreachable ({exc}); trying Telegram directly")
    token, chat = cfg("TELEGRAM_BOT_TOKEN"), cfg("TELEGRAM_CHAT_ID")
    if token and chat:
        data = urllib.parse.urlencode({"chat_id": chat, "text": f"{text}\n🖥 Сервер: {cfg('SERVER_NAME')}"}).encode()
        try:
            urllib.request.urlopen(f"https://api.telegram.org/bot{token}/sendMessage", data=data, timeout=10).close()
        except Exception as exc:  # noqa: BLE001
            log(f"telegram failed: {exc}")


# --------------------------------------------------------------------------- state / loop guard
class State:
    def __init__(self, path: Path):
        self.path = path
        try:
            self.data = json.loads(path.read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            self.data = {}
        self.data.setdefault("actions", {})  # action -> [timestamps]
        self.data.setdefault("gave_up", {})  # action -> last "need a human" notification ts
        self.data.setdefault("totals", {})  # action -> lifetime counter (for metrics)

    def recent(self, action: str) -> int:
        cutoff = time.time() - 3600
        stamps = [t for t in self.data["actions"].get(action, []) if t > cutoff]
        self.data["actions"][action] = stamps
        return len(stamps)

    def allow(self, action: str, why: str) -> bool:
        """True if the action may run; otherwise escalate once per hour."""
        limit = int(cfg("WATCHDOG_MAX_ACTIONS"))
        recent = self.recent(action)
        if recent < limit:
            if recent == 0:
                self.data["gave_up"].pop(action, None)  # an hour of calm resets the escalation
            return True
        if time.time() - self.data["gave_up"].get(action, 0) > 3600:
            self.data["gave_up"][action] = time.time()
            msg = (f"🆘 Автовосстановление сдалось — нужен человек.\nДействие «{action}» уже выполнялось "
                   f"{limit} раз за час и не помогло.\nПричина: {why}\n"
                   f"Что делать: journalctl -u autoops-watchdog -n 100; после исправления удалите {self.path}")
            log(msg.replace("\n", " | "))
            notify(msg, "critical")
        return False

    def record(self, action: str) -> None:
        self.data["actions"].setdefault(action, []).append(time.time())
        self.data["totals"][action] = self.data["totals"].get(action, 0) + 1

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.data, indent=1))
        tmp.replace(self.path)


# --------------------------------------------------------------------------- checks
def docker_responsive() -> bool:
    try:
        return run(["docker", "info", "--format", "{{.ServerVersion}}"], timeout=20).returncode == 0
    except subprocess.TimeoutExpired:
        return False


def heal_docker(state: State) -> bool:
    if docker_responsive():
        return True
    action = "restart-docker"
    log("docker daemon is not responding")
    if cfg("WATCHDOG_RESTART_DOCKER") != "1" or not shutil.which("systemctl"):
        notify("⚠️ Docker daemon не отвечает, но перезапуск отключён на этом хосте.", "critical")
        return False
    if not state.allow(action, "Docker daemon не отвечает"):
        return False
    state.record(action)
    result = run(["systemctl", "restart", "docker"], timeout=180)
    ok = result.returncode == 0 and docker_responsive()
    notify(f"🔧 Автовосстановление: Docker daemon не отвечал → выполнен перезапуск сервиса docker. "
           f"Результат: {'✅ OK' if ok else '❌ не помогло'}", "warning" if ok else "critical")
    return ok


def list_containers() -> list[dict]:
    out = run(["docker", "ps", "-a", "--no-trunc", "--format", "{{.ID}}"]).stdout.split()
    if not out:
        return []
    res = run(["docker", "inspect", *out], timeout=60)
    return json.loads(res.stdout or "[]")


def parse_docker_time(value: str) -> float:
    # 2026-10-11T18:30:00.123456789Z -> epoch seconds (no external deps)
    if not value or value.startswith("0001-"):
        return 0.0
    base = value.split(".")[0].rstrip("Z")
    return float(calendar.timegm(time.strptime(base, "%Y-%m-%dT%H:%M:%S")))


def heal_stacks(state: State, containers: list[dict]) -> None:
    guarded = {p.strip() for p in cfg("WATCHDOG_PROJECTS").split(",") if p.strip()}
    grace = int(cfg("WATCHDOG_GRACE_SECONDS"))
    broken: dict[str, list[dict]] = {}
    for c in containers:
        labels = c["Config"].get("Labels") or {}
        project = labels.get("com.docker.compose.project")
        if not project or (guarded and project not in guarded):
            continue
        if labels.get("autoops.oneshot") == "true" or c["HostConfig"]["RestartPolicy"]["Name"] in ("", "no"):
            continue  # migrations and other one-shot jobs are expected to exit
        st = c["State"]
        if st["Running"] or st.get("Restarting"):
            continue
        down_for = time.time() - parse_docker_time(st.get("FinishedAt", ""))
        if down_for < grace:
            continue
        broken.setdefault(project, []).append(c)

    for project, items in broken.items():
        names = ", ".join(i["Name"].lstrip("/") for i in items)
        action = f"start:{project}"
        why = f"стек {project} запущен не полностью (остановлены: {names})"
        log(why)
        if not state.allow(action, why):
            continue
        state.record(action)
        labels = items[0]["Config"]["Labels"]
        files = [f for f in labels.get("com.docker.compose.project.config_files", "").split(",") if f]
        workdir = labels.get("com.docker.compose.project.working_dir", "")
        if files and all(os.path.exists(f) for f in files):
            cmd = ["docker", "compose", "-p", project]
            for f in files:
                cmd += ["-f", f]
            env_file = os.path.join(workdir, ".env")
            if os.path.exists(env_file):
                cmd += ["--env-file", env_file]
            cmd += ["up", "-d"]
            how = "docker compose up -d"
        else:
            cmd = ["docker", "start", *[i["Id"] for i in items]]
            how = "docker start"
        result = run(cmd, timeout=300)
        ok = result.returncode == 0
        if not ok:
            log(f"{how} failed: {result.stderr.strip()[:500]}")
        notify(f"🔧 Автовосстановление: {why}.\nВыполнено: {how}. Результат: "
               f"{'✅ OK' if ok else '❌ ошибка: ' + result.stderr.strip()[:300]}", "warning" if ok else "critical")


def disk_usage_percent(path: str) -> float:
    usage = shutil.disk_usage(path)
    return 100.0 * (usage.total - usage.free) / usage.total if usage.total else 0.0


def free_bytes(paths: list[str]) -> int:
    return sum(shutil.disk_usage(p).free for p in paths)


def heal_disk(state: State) -> None:
    paths = [p.strip() for p in cfg("WATCHDOG_DISK_PATHS").split(",") if p.strip() and os.path.exists(p.strip())]
    threshold = float(cfg("WATCHDOG_DISK_THRESHOLD"))
    full = [(p, disk_usage_percent(p)) for p in paths if disk_usage_percent(p) > threshold]
    if not full:
        return
    desc = ", ".join(f"{p} {pct:.0f}%" for p, pct in full)
    action = "disk-cleanup"
    why = f"диск заполнен выше {threshold:.0f}% ({desc})"
    log(why)
    if not state.allow(action, why):
        return
    state.record(action)
    before = free_bytes(paths)
    until = cfg("WATCHDOG_PRUNE_UNTIL")
    steps = []
    # Equivalent of `docker system prune` WITHOUT volumes, limited to old objects so a
    # container that was stopped a minute ago (and the healer is about to restart) survives.
    prune_cmds = (["docker", "image", "prune", "-af", "--filter", f"until={until}"],
                  ["docker", "builder", "prune", "-af", "--filter", f"until={until}"],
                  ["docker", "container", "prune", "-f", "--filter", f"until={until}"],
                  ["docker", "network", "prune", "-f", "--filter", f"until={until}"])
    for cmd in prune_cmds if cfg("WATCHDOG_DOCKER_PRUNE") == "1" else ():
        if run(cmd, timeout=600).returncode == 0:
            steps.append(" ".join(cmd[1:3]))
    if shutil.which("journalctl"):
        if run(["journalctl", "--vacuum-size=200M"], timeout=120).returncode == 0:
            steps.append("journalctl --vacuum-size=200M")
    removed = 0
    for pattern in [g.strip() for g in cfg("WATCHDOG_CLEAN_GLOBS").split(",") if g.strip()]:
        for f in glob.glob(pattern, recursive=True):
            try:
                if os.path.isfile(f):
                    os.remove(f)
                    removed += 1
            except OSError as exc:
                log(f"cannot remove {f}: {exc}")
    if removed:
        steps.append(f"удалено мусорных файлов: {removed}")
    freed = max(0, free_bytes(paths) - before)
    after = ", ".join(f"{p} {disk_usage_percent(p):.0f}%" for p, _ in full)
    still_full = any(disk_usage_percent(p) > threshold for p, _ in full)
    notify(f"🔧 Автовосстановление: {why}.\nВыполнено: {'; '.join(steps) or 'нечего чистить'}.\n"
           f"Освобождено: {freed / 1024 / 1024:.0f} МБ, сейчас: {after}"
           + ("\n⚠️ Места всё ещё мало — нужна ручная проверка." if still_full else ""),
           "critical" if still_full else "warning")


# --------------------------------------------------------------------------- metrics
def write_metrics(state: State, containers: list[dict]) -> None:
    directory = Path(cfg("WATCHDOG_TEXTFILE_DIR"))
    if not directory.is_dir():
        return
    lines = [
        "# HELP autoops_watchdog_last_run_timestamp_seconds Last watchdog run.",
        "# TYPE autoops_watchdog_last_run_timestamp_seconds gauge",
        f"autoops_watchdog_last_run_timestamp_seconds {time.time():.0f}",
        "# HELP autoops_watchdog_actions_total Self-healing actions performed.",
        "# TYPE autoops_watchdog_actions_total counter",
    ]
    lines += [f'autoops_watchdog_actions_total{{action="{a}"}} {n}' for a, n in sorted(state.data["totals"].items())]
    lines += ["# HELP autoops_watchdog_gave_up 1 if the watchdog stopped retrying an action.",
              "# TYPE autoops_watchdog_gave_up gauge"]
    known = set(state.data["totals"]) | set(state.data["gave_up"])
    for action in sorted(known):
        gave_up = 1 if action in state.data["gave_up"] and state.recent(action) >= int(cfg("WATCHDOG_MAX_ACTIONS")) else 0
        lines.append(f'autoops_watchdog_gave_up{{action="{action}"}} {gave_up}')
    lines += ["# HELP autoops_container_healthy Docker healthcheck status (1 healthy, 0 unhealthy).",
              "# TYPE autoops_container_healthy gauge"]
    for c in containers:
        health = (c["State"].get("Health") or {}).get("Status")
        if c["State"]["Running"] and health in ("healthy", "unhealthy"):
            name = c["Name"].lstrip("/")
            app = (c["Config"].get("Labels") or {}).get("autoops.app", "")
            lines.append(f'autoops_container_healthy{{name="{name}",app="{app}"}} {1 if health == "healthy" else 0}')
    tmp = directory / "autoops_watchdog.prom.tmp"
    tmp.write_text("\n".join(lines) + "\n")
    tmp.replace(directory / "autoops_watchdog.prom")


# --------------------------------------------------------------------------- main
def run_once() -> int:
    state = State(Path(cfg("WATCHDOG_STATE_FILE")))
    if os.path.exists(cfg("WATCHDOG_MAINTENANCE_FILE")):
        log(f"maintenance mode ({cfg('WATCHDOG_MAINTENANCE_FILE')} exists) - only exporting metrics")
        write_metrics(state, list_containers() if docker_responsive() else [])
        return 0
    containers: list[dict] = []
    try:
        if heal_docker(state):
            heal_stacks(state, list_containers())
            containers = list_containers()
        heal_disk(state)
    finally:
        write_metrics(state, containers)
        state.save()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--loop", type=int, default=0, help="run forever, sleeping N seconds between runs")
    args = parser.parse_args()
    if not args.loop:
        return run_once()
    log(f"loop mode, every {args.loop}s")
    while True:
        try:
            run_once()
        except Exception as exc:  # noqa: BLE001 - never let the healer die
            log(f"ERROR {exc!r}")
        time.sleep(args.loop)


if __name__ == "__main__":
    sys.exit(main())
