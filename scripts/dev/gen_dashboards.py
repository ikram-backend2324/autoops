#!/usr/bin/env python3
"""Generate the provisioned Grafana dashboards (JSON is committed to the repo).

    python3 scripts/dev/gen_dashboards.py

Editing compact panel specs here is far easier to review than hand-written
dashboard JSON; the output lands in stacks/monitoring/grafana/dashboards/.
"""

from __future__ import annotations

import json
from pathlib import Path

OUT = Path(__file__).resolve().parents[2] / "stacks/monitoring/grafana/dashboards"
PROM = {"type": "prometheus", "uid": "prometheus"}
LOKI = {"type": "loki", "uid": "loki"}


class Layout:
    """Places panels left-to-right on Grafana's 24-column grid."""

    def __init__(self) -> None:
        self.x = 0
        self.y = 0
        self.row_h = 0
        self.next_id = 1

    def place(self, w: int, h: int) -> dict:
        if self.x + w > 24:
            self.x, self.y, self.row_h = 0, self.y + self.row_h, 0
        pos = {"x": self.x, "y": self.y, "w": w, "h": h}
        self.x += w
        self.row_h = max(self.row_h, h)
        return pos

    def new_id(self) -> int:
        self.next_id += 1
        return self.next_id


def targets(exprs, ds=PROM):
    out = []
    for i, item in enumerate(exprs):
        expr, legend = item if isinstance(item, tuple) else (item, "")
        out.append({"datasource": ds, "expr": expr, "legendFormat": legend, "refId": chr(65 + i)})
    return out


def stat(lay, title, expr, unit="none", w=4, h=4, thresholds=None, decimals=None, mappings=None, desc=""):
    steps = [{"color": "green", "value": None}]
    for value, color in thresholds or []:
        steps.append({"color": color, "value": value})
    defaults = {"unit": unit, "thresholds": {"mode": "absolute", "steps": steps}, "mappings": mappings or []}
    if decimals is not None:
        defaults["decimals"] = decimals
    return {
        "id": lay.new_id(), "type": "stat", "title": title, "description": desc, "datasource": PROM,
        "gridPos": lay.place(w, h), "targets": targets([expr]),
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "options": {"colorMode": "background", "graphMode": "area", "reduceOptions": {"calcs": ["lastNotNull"]},
                    "textMode": "value_and_name" if "{{" in title else "auto"},
    }


def ts(lay, title, exprs, unit="none", w=12, h=8, stack=False, max_=None, desc=""):
    defaults = {"unit": unit, "custom": {"fillOpacity": 15, "lineWidth": 2, "showPoints": "never",
                                        "stacking": {"mode": "normal" if stack else "none"}}}
    if max_ is not None:
        defaults["max"] = max_
        defaults["min"] = 0
    return {
        "id": lay.new_id(), "type": "timeseries", "title": title, "description": desc, "datasource": PROM,
        "gridPos": lay.place(w, h), "targets": targets(exprs),
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "options": {"legend": {"displayMode": "table", "placement": "bottom", "calcs": ["lastNotNull", "max"]},
                    "tooltip": {"mode": "multi"}},
    }


def table(lay, title, exprs, w=24, h=8, unit="none"):
    tgts = targets(exprs)
    for t in tgts:
        t.update({"format": "table", "instant": True})
    return {
        "id": lay.new_id(), "type": "table", "title": title, "datasource": PROM, "gridPos": lay.place(w, h),
        "targets": tgts, "fieldConfig": {"defaults": {"unit": unit}, "overrides": []},
        "transformations": [{"id": "merge"}, {"id": "organize", "options": {"excludeByName": {"Time": True}}}],
    }


def logs(lay, title, expr, w=24, h=12):
    return {
        "id": lay.new_id(), "type": "logs", "title": title, "datasource": LOKI, "gridPos": lay.place(w, h),
        "targets": [{"datasource": LOKI, "expr": expr, "refId": "A"}],
        "options": {"showTime": True, "wrapLogMessage": True, "sortOrder": "Descending", "enableLogDetails": True},
    }


def row(lay, title):
    lay.x, lay.y, lay.row_h = 0, lay.y + lay.row_h, 0
    pos = lay.place(24, 1)
    lay.x, lay.row_h = 24, 1
    return {"id": lay.new_id(), "type": "row", "title": title, "gridPos": pos, "collapsed": False, "panels": []}


def query_var(name, label, query, include_all=True):
    return {
        "name": name, "label": label, "type": "query", "datasource": PROM,
        "query": {"query": query, "refId": "var"}, "definition": query,
        "refresh": 2, "includeAll": include_all, "multi": True, "allValue": ".*",
        "current": {"selected": True, "text": ["All"], "value": ["$__all"]} if include_all else {},
        "sort": 1,
    }


def dashboard(uid, title, panels, tags, variables=(), refresh="30s", time_from="now-6h"):
    return {
        "uid": uid, "title": title, "tags": ["autoops", *tags], "timezone": "browser", "editable": False,
        "schemaVersion": 39, "version": 1, "refresh": refresh,
        "time": {"from": time_from, "to": "now"},
        "templating": {"list": list(variables)},
        "annotations": {"list": [{
            "builtIn": 0, "datasource": PROM, "enable": True, "iconColor": "red", "name": "Алерты",
            "expr": 'ALERTS{alertstate="firing", severity=~"critical|warning"}', "step": "60s",
            "titleFormat": "{{alertname}}", "textFormat": "{{severity}}",
        }]},
        "links": [{"title": "AutoOps", "type": "dashboards", "tags": ["autoops"], "asDropdown": True}],
        "panels": panels,
    }


UP = [[0.5, "red"]]
CPU = '100 * (1 - avg(rate(node_cpu_seconds_total{mode="idle"}[2m])))'
MEM = "100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)"
DISK = '100 * (1 - node_filesystem_avail_bytes{job="node",fstype!=""} / node_filesystem_size_bytes{job="node",fstype!=""})'
DOWN_UP = [{"type": "value", "options": {"0": {"text": "DOWN", "color": "red"}, "1": {"text": "UP", "color": "green"}}}]


def server_overview():
    lay = Layout()
    p = [
        stat(lay, "Аптайм сервера", "time() - node_boot_time_seconds", "s", decimals=1),
        stat(lay, "CPU", CPU, "percent", thresholds=[(70, "orange"), (85, "red")], decimals=0),
        stat(lay, "RAM", MEM, "percent", thresholds=[(80, "orange"), (90, "red")], decimals=0),
        stat(lay, "Диск (макс.)", f"max({DISK})", "percent", thresholds=[(80, "orange"), (90, "red")], decimals=0),
        stat(lay, "Активные алерты", 'count(ALERTS{alertstate="firing",severity!="info"}) or vector(0)',
             thresholds=[(1, "red")]),
        stat(lay, "Контейнеры", 'count(container_last_seen{name!=""})'),
        ts(lay, "Загрузка CPU, %", [(CPU, "CPU")], "percent", max_=100),
        ts(lay, "Память", [("node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes", "занято"),
                           ("node_memory_MemTotal_bytes", "всего")], "bytes"),
        ts(lay, "Заполнение дисков, %", [(DISK, "{{mountpoint}}")], "percent", max_=100),
        ts(lay, "Load average", [("node_load1", "1m"), ("node_load5", "5m"), ("node_load15", "15m")]),
        ts(lay, "Сеть", [('sum(rate(node_network_receive_bytes_total{device!~"lo|veth.*|br.*|docker.*"}[2m]))', "приём"),
                         ('sum(rate(node_network_transmit_bytes_total{device!~"lo|veth.*|br.*|docker.*"}[2m]))', "передача")],
           "Bps"),
        ts(lay, "Диск I/O", [('sum(rate(node_disk_read_bytes_total[2m]))', "чтение"),
                             ('sum(rate(node_disk_written_bytes_total[2m]))', "запись")], "Bps"),
        table(lay, "Сейчас срабатывают", ['ALERTS{alertstate="firing"}']),
    ]
    return dashboard("autoops-server", "AutoOps · Обзор сервера", p, ["server"])


def containers():
    lay = Layout()
    name_var = query_var("container", "Контейнер", 'label_values(container_last_seen{name!=""}, name)')
    sel = 'name=~"$container",name!=""'
    p = [
        stat(lay, "Нездоровые контейнеры", "count(autoops_container_healthy == 0) or vector(0)", thresholds=[(1, "red")]),
        stat(lay, "Перезапуски за 1ч", f"sum(changes(container_start_time_seconds{{{sel}}}[1h])) or vector(0)",
             thresholds=[(1, "orange"), (4, "red")]),
        stat(lay, "Действия watchdog за 24ч", "sum(increase(autoops_watchdog_actions_total[24h])) or vector(0)",
             thresholds=[(1, "orange")]),
        stat(lay, "Watchdog: последний запуск", "time() - autoops_watchdog_last_run_timestamp_seconds", "s",
             thresholds=[(180, "orange"), (300, "red")]),
        stat(lay, "Watchdog сдался", "max(autoops_watchdog_gave_up) or vector(0)", thresholds=[(1, "red")],
             mappings=[{"type": "value", "options": {"0": {"text": "нет"}, "1": {"text": "НУЖЕН ЧЕЛОВЕК"}}}], w=8),
        ts(lay, "CPU по контейнерам, ядер", [(f"sum by (name) (rate(container_cpu_usage_seconds_total{{{sel}}}[2m]))", "{{name}}")]),
        ts(lay, "Память по контейнерам", [(f"sum by (name) (container_memory_working_set_bytes{{{sel}}})", "{{name}}")], "bytes"),
        ts(lay, "Перезапуски (15 мин окно)", [(f"changes(container_start_time_seconds{{{sel}}}[15m])", "{{name}}")]),
        ts(lay, "Healthcheck (1 = healthy)", [("autoops_container_healthy", "{{name}}")], max_=1),
        ts(lay, "Сеть контейнеров (приём)", [(f"sum by (name) (rate(container_network_receive_bytes_total{{{sel}}}[2m]))", "{{name}}")], "Bps"),
        ts(lay, "Действия watchdog", [("increase(autoops_watchdog_actions_total[10m])", "{{action}}")]),
    ]
    return dashboard("autoops-containers", "AutoOps · Контейнеры", p, ["containers"], [name_var])


def postgres():
    lay = Layout()
    app_var = query_var("app", "Приложение", "label_values(pg_up, app)")
    a = 'app=~"$app"'
    p = [
        stat(lay, "PostgreSQL", f"min(pg_up{{{a}}})", mappings=DOWN_UP, thresholds=None),
        stat(lay, "Соединения", f"sum(pg_stat_activity_count{{{a}}})"),
        stat(lay, "% от max_connections",
             f"100 * sum(pg_stat_activity_count{{{a}}}) / max(pg_settings_max_connections{{{a}}})",
             "percent", thresholds=[(70, "orange"), (80, "red")], decimals=0),
        stat(lay, "Размер БД", f"sum(pg_database_size_bytes{{{a},datname!~\"template.*|postgres\"}})", "bytes"),
        stat(lay, "Самая долгая транзакция", f"max(pg_stat_activity_max_tx_duration{{{a},state=\"active\"}})", "s",
             thresholds=[(60, "orange"), (300, "red")]),
        stat(lay, "Cache hit", f"100 * sum(pg_stat_database_blks_hit{{{a}}}) / clamp_min(sum(pg_stat_database_blks_hit{{{a}}}) + sum(pg_stat_database_blks_read{{{a}}}), 1)",
             "percent", decimals=1),
        ts(lay, "Соединения по состоянию", [(f"sum by (state) (pg_stat_activity_count{{{a}}})", "{{state}}")]),
        ts(lay, "Транзакции/с", [(f"sum by (app) (rate(pg_stat_database_xact_commit{{{a}}}[2m]))", "commit {{app}}"),
                                 (f"sum by (app) (rate(pg_stat_database_xact_rollback{{{a}}}[2m]))", "rollback {{app}}")]),
        ts(lay, "Строк в секунду", [(f"sum(rate(pg_stat_database_tup_fetched{{{a}}}[2m]))", "fetched"),
                                    (f"sum(rate(pg_stat_database_tup_inserted{{{a}}}[2m]))", "inserted"),
                                    (f"sum(rate(pg_stat_database_tup_updated{{{a}}}[2m]))", "updated"),
                                    (f"sum(rate(pg_stat_database_tup_deleted{{{a}}}[2m]))", "deleted")]),
        ts(lay, "Deadlocks и конфликты", [(f"sum(increase(pg_stat_database_deadlocks{{{a}}}[5m]))", "deadlocks"),
                                          (f"sum(increase(pg_stat_database_conflicts{{{a}}}[5m]))", "conflicts")]),
        ts(lay, "Redis: память", [('redis_memory_used_bytes{app=~"$app"}', "{{app}}")], "bytes"),
        ts(lay, "Redis: клиенты и ключи", [('redis_connected_clients{app=~"$app"}', "clients {{app}}"),
                                          ('sum by (app) (redis_db_keys{app=~"$app"})', "keys {{app}}")]),
    ]
    return dashboard("autoops-postgres", "AutoOps · PostgreSQL и Redis", p, ["postgres"], [app_var])


def app():
    lay = Layout()
    app_var = query_var("app", "Приложение", 'label_values(up{job="app-web"}, app)')
    a = 'app=~"$app"'
    req = f"django_http_responses_total_by_status_total{{{a}}}"
    req5 = f'django_http_responses_total_by_status_total{{{a},status=~"5.."}}'
    lat = f"django_http_requests_latency_seconds_by_view_method_bucket{{{a}}}"
    p = [
        stat(lay, "Запросов/с", f"sum(rate({req}[2m]))", "reqps", decimals=2),
        stat(lay, "Ошибки 5xx", f"100 * sum(rate({req5}[5m])) / clamp_min(sum(rate({req}[5m])), 0.0001)",
             "percent", thresholds=[(1, "orange"), (5, "red")], decimals=2),
        stat(lay, "Latency p95", f"histogram_quantile(0.95, sum by (le) (rate({lat}[5m])))", "s",
             thresholds=[(0.5, "orange"), (1, "red")]),
        stat(lay, "Web", f'min(up{{job="app-web",{a}}})', mappings=DOWN_UP),
        stat(lay, "Ответ /health/ извне", "max(probe_duration_seconds)", "s", thresholds=[(1, "orange"), (3, "red")]),
        stat(lay, "Внешняя проверка", "min(probe_success)", mappings=DOWN_UP),
        ts(lay, "Запросы по статусу", [(f"sum by (status) (rate({req}[2m]))", "{{status}}")], "reqps", stack=True),
        ts(lay, "Latency", [(f"histogram_quantile(0.5, sum by (le) (rate({lat}[5m])))", "p50"),
                            (f"histogram_quantile(0.95, sum by (le) (rate({lat}[5m])))", "p95"),
                            (f"histogram_quantile(0.99, sum by (le) (rate({lat}[5m])))", "p99")], "s"),
        ts(lay, "Запросы по view", [(f'topk(10, sum by (view) (rate(django_http_requests_total_by_view_transport_method_total{{{a}}}[5m])))', "{{view}}")], "reqps"),
        ts(lay, "Исключения", [(f"sum by (type) (rate(django_http_exceptions_total_by_type_total{{{a}}}[5m]))", "{{type}}")]),
        logs(lay, "Логи приложения (web + worker)", '{app=~"$app", service=~"web|worker"}'),
    ]
    return dashboard("autoops-app", "AutoOps · Приложение", p, ["app"], [app_var])


def availability():
    lay = Layout()
    p = [
        stat(lay, "Сейчас", "min(probe_success)", mappings=DOWN_UP, w=6),
        stat(lay, "Доступность 24ч", "100 * avg(avg_over_time(probe_success[24h]))", "percent", decimals=3, w=6,
             thresholds=None),
        stat(lay, "Доступность 7д", "100 * avg(avg_over_time(probe_success[7d]))", "percent", decimals=3, w=6),
        stat(lay, "SSL: дней до истечения", "min((probe_ssl_earliest_cert_expiry - time()) / 86400)", "none",
             decimals=0, w=6, desc="Пусто для http:// (локальный режим)"),
        ts(lay, "Проверка по URL (1 = ok)", [("probe_success", "{{instance}}")], max_=1),
        ts(lay, "Время ответа", [("probe_duration_seconds", "{{instance}}")], "s"),
        ts(lay, "HTTP-код", [("probe_http_status_code", "{{instance}}")]),
        ts(lay, "SSL: дней до истечения", [("(probe_ssl_earliest_cert_expiry - time()) / 86400", "{{instance}}")]),
    ]
    return dashboard("autoops-availability", "AutoOps · Доступность и SSL", p, ["availability"], time_from="now-24h")


def backups():
    lay = Layout()
    p = [
        stat(lay, "С последнего бэкапа", "time() - max(autoops_backup_last_success_timestamp_seconds)", "s",
             thresholds=[(26 * 3600, "red")], w=6),
        stat(lay, "Последний бэкап", "min(autoops_backup_last_run_success)", w=6,
             mappings=[{"type": "value", "options": {"0": {"text": "ОШИБКА", "color": "red"}, "1": {"text": "OK", "color": "green"}}}]),
        stat(lay, "Проверка восстановления", "min(autoops_restore_verify_success)", w=6,
             mappings=[{"type": "value", "options": {"0": {"text": "ПРОВАЛ", "color": "red"}, "1": {"text": "OK", "color": "green"}}}]),
        stat(lay, "Снапшотов в репозитории", "max(autoops_backup_snapshots_total)", w=6),
        ts(lay, "Размер данных бэкапа", [("autoops_backup_size_bytes", "{{app}}")], "bytes"),
        ts(lay, "Длительность бэкапа", [("autoops_backup_duration_seconds", "бэкап"),
                                        ("autoops_restore_verify_duration_seconds", "проверка {{app}}")], "s"),
        ts(lay, "Строк восстановлено при проверке", [("autoops_restore_verify_rows", "{{app}} {{table}}")]),
        ts(lay, "Возраст последней проверки", [("time() - autoops_restore_verify_last_run_timestamp_seconds", "{{app}}")], "s"),
    ]
    return dashboard("autoops-backups", "AutoOps · Бэкапы", p, ["backups"], time_from="now-7d")


def logs_dash():
    lay = Layout()
    variables = [
        {"name": "service", "label": "Сервис", "type": "query", "datasource": LOKI,
         "query": {"label": "service", "refId": "LokiVariableQueryEditor-VariableQuery", "stream": "", "type": 1},
         "refresh": 2, "includeAll": True, "multi": True, "allValue": ".+",
         "current": {"selected": True, "text": ["All"], "value": ["$__all"]}},
        {"name": "search", "label": "Поиск", "type": "textbox", "query": "", "current": {"text": "", "value": ""}},
    ]
    p = [
        {
            "id": lay.new_id(), "type": "timeseries", "title": "Ошибки в логах", "datasource": LOKI,
            "gridPos": lay.place(24, 7),
            "targets": [{"datasource": LOKI, "refId": "A", "legendFormat": "{{service}}",
                         "expr": 'sum by (service) (count_over_time({service=~"$service"} |~ "(?i)error|exception|traceback" [1m]))'}],
            "fieldConfig": {"defaults": {"custom": {"drawStyle": "bars", "fillOpacity": 60}}, "overrides": []},
        },
        logs(lay, "Логи", '{service=~"$service"} |~ "(?i)$search"', h=18),
    ]
    return dashboard("autoops-logs", "AutoOps · Логи", p, ["logs"], variables, time_from="now-1h")


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    boards = {
        "server-overview.json": server_overview(),
        "containers.json": containers(),
        "postgres.json": postgres(),
        "app.json": app(),
        "availability.json": availability(),
        "backups.json": backups(),
        "logs.json": logs_dash(),
    }
    for name, board in boards.items():
        with open(OUT / name, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(json.dumps(board, ensure_ascii=False, indent=2) + "\n")
        print(f"wrote {OUT / name}")


if __name__ == "__main__":
    main()
