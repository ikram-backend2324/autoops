from datetime import timedelta

from celery import shared_task
from django.utils import timezone

from .models import Heartbeat


@shared_task
def heartbeat() -> int:
    """Record that the worker is alive and keep the table small."""
    Heartbeat.objects.create()
    cutoff = timezone.now() - timedelta(days=1)
    Heartbeat.objects.filter(created_at__lt=cutoff).delete()
    return Heartbeat.objects.count()
