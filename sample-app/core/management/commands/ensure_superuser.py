import os

from django.contrib.auth import get_user_model
from django.core.management.base import BaseCommand


class Command(BaseCommand):
    help = (
        "Create the admin account from DJANGO_SUPERUSER_USERNAME / DJANGO_SUPERUSER_EMAIL / "
        "DJANGO_SUPERUSER_PASSWORD if it does not exist yet. Safe to run on every start: an "
        "existing account (and a password changed later in /admin/) is never overwritten."
    )

    def handle(self, *args, **options):
        username = os.environ.get("DJANGO_SUPERUSER_USERNAME", "").strip()
        password = os.environ.get("DJANGO_SUPERUSER_PASSWORD", "")
        email = os.environ.get("DJANGO_SUPERUSER_EMAIL", "").strip()
        if not username or not password:
            self.stdout.write("superuser: DJANGO_SUPERUSER_USERNAME/PASSWORD not set - skipped")
            return
        user_model = get_user_model()
        if user_model.objects.filter(username=username).exists():
            self.stdout.write(f"superuser: '{username}' already exists - unchanged")
            return
        user_model.objects.create_superuser(username=username, email=email, password=password)
        self.stdout.write(self.style.SUCCESS(f"superuser: created '{username}'"))
