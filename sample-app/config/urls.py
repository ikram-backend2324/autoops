from django.contrib import admin
from django.urls import path

from core import views

urlpatterns = [
    path("", views.index, name="index"),
    path("health/", views.health, name="health"),
    path("health/live/", views.health_live, name="health-live"),
    path("metrics", views.metrics, name="metrics"),
    path("chaos/unhealthy/", views.chaos_unhealthy, name="chaos-unhealthy"),
    path("chaos/error/", views.chaos_error, name="chaos-error"),
    path("admin/", admin.site.urls),
]
