import os
import time

from django.conf import settings
from django.db import connection
from django.http import Http404, HttpResponse, JsonResponse
from django.shortcuts import render
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_POST
from prometheus_client import CONTENT_TYPE_LATEST, CollectorRegistry, generate_latest, multiprocess

from .models import Note


def index(request):
    return render(
        request,
        "core/index.html",
        {"notes": Note.objects.order_by("-created_at")[:10], "version": settings_version()},
    )


def settings_version() -> str:
    return os.environ.get("APP_VERSION", "dev")


def _check_db() -> str:
    with connection.cursor() as cursor:
        cursor.execute("SELECT 1")
        cursor.fetchone()
    return "ok"


def _check_redis() -> str:
    if not settings.REDIS_URL:
        return "skipped"
    import redis

    client = redis.Redis.from_url(settings.REDIS_URL, socket_timeout=2, socket_connect_timeout=2)
    client.ping()
    return "ok"


def health_live(request):
    """Liveness only (process answers). Used by the Docker HEALTHCHECK so a database
    outage does not make Docker/autoheal restart web in a loop - restarting web cannot fix the DB."""
    if settings.CHAOS_FLAG_FILE.exists():
        return JsonResponse({"status": "fail", "checks": {"chaos": "forced unhealthy"}}, status=503)
    return JsonResponse({"status": "ok", "version": settings_version()})


def health(request):
    """Liveness + dependency check used by Docker, Traefik, blackbox and CI deploys."""
    started = time.monotonic()
    checks: dict[str, str] = {}
    healthy = True

    for name, check in (("database", _check_db), ("redis", _check_redis)):
        try:
            checks[name] = check()
        except Exception as exc:  # noqa: BLE001 - report any dependency failure
            checks[name] = f"error: {exc.__class__.__name__}"
            healthy = False

    if settings.CHAOS_FLAG_FILE.exists():
        checks["chaos"] = "forced unhealthy"
        healthy = False

    payload = {
        "status": "ok" if healthy else "fail",
        "version": settings_version(),
        "checks": checks,
        "duration_ms": round((time.monotonic() - started) * 1000, 1),
    }
    return JsonResponse(payload, status=200 if healthy else 503)


def metrics(request):
    multiproc_dir = os.environ.get("PROMETHEUS_MULTIPROC_DIR")
    if multiproc_dir and os.path.isdir(multiproc_dir):
        registry = CollectorRegistry()
        multiprocess.MultiProcessCollector(registry)
        data = generate_latest(registry)
    else:
        data = generate_latest()
    return HttpResponse(data, content_type=CONTENT_TYPE_LATEST)


def _guard_chaos(request) -> None:
    if not settings.CHAOS_ENABLED:
        raise Http404
    if settings.CHAOS_TOKEN and request.headers.get("X-Chaos-Token") != settings.CHAOS_TOKEN:
        raise Http404


@csrf_exempt
@require_POST
def chaos_unhealthy(request):
    """Demo only: make /health/ fail until the container restarts (flag lives on tmpfs)."""
    _guard_chaos(request)
    settings.CHAOS_FLAG_FILE.touch()
    return JsonResponse({"status": "health check will now fail until restart"})


@csrf_exempt
def chaos_error(request):
    """Demo only: respond with HTTP 500 to drive the 5xx-rate alert."""
    _guard_chaos(request)
    return JsonResponse({"status": "simulated failure"}, status=500)
