import os

from prometheus_client import multiprocess

bind = "0.0.0.0:8000"
workers = int(os.environ.get("GUNICORN_WORKERS", "2"))
threads = int(os.environ.get("GUNICORN_THREADS", "2"))
timeout = 30
graceful_timeout = 20
accesslog = "-"
errorlog = "-"
# One JSON-ish line per request keeps Loki queries simple.
access_log_format = (
    '{"remote":"%(h)s","method":"%(m)s","path":"%(U)s",'
    '"status":%(s)s,"bytes":%(B)s,"duration_ms":%(M)s}'
)


def child_exit(server, worker):
    multiprocess.mark_process_dead(worker.pid)
