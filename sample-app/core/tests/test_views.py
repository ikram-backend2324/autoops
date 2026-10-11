import pytest
from django.test import override_settings

from core.models import Heartbeat, Note
from core.tasks import heartbeat


@pytest.mark.django_db
def test_health_ok(client):
    resp = client.get("/health/")
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "ok"
    assert body["checks"]["database"] == "ok"


@pytest.mark.django_db
def test_health_fails_when_chaos_flag_set(client, tmp_path):
    flag = tmp_path / "unhealthy"
    flag.touch()
    with override_settings(CHAOS_FLAG_FILE=flag):
        resp = client.get("/health/")
    assert resp.status_code == 503
    assert resp.json()["checks"]["chaos"] == "forced unhealthy"


@pytest.mark.django_db
def test_health_reports_redis_failure(client):
    with override_settings(REDIS_URL="redis://127.0.0.1:1/0"):
        resp = client.get("/health/")
    assert resp.status_code == 503
    assert resp.json()["checks"]["redis"].startswith("error")


def test_metrics_exposes_prometheus_format(client):
    resp = client.get("/metrics")
    assert resp.status_code == 200
    assert b"python_info" in resp.content or b"django_http" in resp.content


def test_chaos_disabled_by_default(client):
    assert client.post("/chaos/unhealthy/").status_code == 404
    assert client.get("/chaos/error/").status_code == 404


@pytest.mark.django_db
def test_chaos_requires_token(client, tmp_path):
    flag = tmp_path / "unhealthy"
    with override_settings(CHAOS_ENABLED=True, CHAOS_TOKEN="secret", CHAOS_FLAG_FILE=flag):
        assert client.post("/chaos/unhealthy/").status_code == 404
        resp = client.post("/chaos/unhealthy/", headers={"X-Chaos-Token": "secret"})
        assert resp.status_code == 200
        assert flag.exists()
        assert client.get("/chaos/error/", headers={"X-Chaos-Token": "secret"}).status_code == 500


@pytest.mark.django_db
def test_index_lists_notes(client):
    Note.objects.create(title="hello autoops")
    resp = client.get("/")
    assert resp.status_code == 200
    assert b"hello autoops" in resp.content


@pytest.mark.django_db
def test_heartbeat_task_records_row():
    assert heartbeat() == 1
    assert Heartbeat.objects.count() == 1


def test_live_ignores_dependencies(client, tmp_path):
    assert client.get("/health/live/").status_code == 200
    flag = tmp_path / "unhealthy"
    flag.touch()
    with override_settings(CHAOS_FLAG_FILE=flag):
        assert client.get("/health/live/").status_code == 503
