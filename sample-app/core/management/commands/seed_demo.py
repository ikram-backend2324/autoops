from django.core.management.base import BaseCommand

from core.models import Note


class Command(BaseCommand):
    help = "Create demo rows once so dashboards and restore checks have data."

    def handle(self, *args, **options):
        if Note.objects.exists():
            self.stdout.write("demo data already present")
            return
        Note.objects.bulk_create(Note(title=f"Demo note #{i}", body="AutoOps demo") for i in range(1, 26))
        self.stdout.write(self.style.SUCCESS("created 25 demo notes"))
