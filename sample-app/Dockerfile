# syntax=docker/dockerfile:1.7
# ---------- base: runtime dependencies ----------
FROM python:3.12-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt

# ---------- test: dev deps + source, runs linters and tests ----------
FROM base AS test
COPY requirements-dev.txt .
RUN pip install -r requirements-dev.txt
COPY . .
ENV DJANGO_SECRET_KEY=test-only DJANGO_DEBUG=0
CMD ["sh", "-c", "ruff check . && pytest -q"]

# ---------- runtime ----------
FROM base AS runtime
ARG GIT_SHA=dev
ENV APP_VERSION=${GIT_SHA} \
    PROMETHEUS_MULTIPROC_DIR=/tmp/prometheus

RUN groupadd --system app && useradd --system --gid app --home /app app \
    && mkdir -p /app/media /app/staticfiles \
    && chown -R app:app /app
COPY --chown=app:app . .
RUN DJANGO_SECRET_KEY=build-only python manage.py collectstatic --noinput >/dev/null

USER app
EXPOSE 8000

HEALTHCHECK --interval=10s --timeout=5s --start-period=20s --retries=3 \
    CMD python /app/docker/healthcheck.py

ENTRYPOINT ["/app/docker/entrypoint.sh"]
CMD ["web"]
