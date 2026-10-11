FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1
WORKDIR /app
COPY relay.py .
RUN useradd --system --uid 10001 relay && mkdir /data && chown relay /data
USER relay
EXPOSE 9095
HEALTHCHECK --interval=15s --timeout=3s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:9095/health',timeout=2).status==200 else 1)"
CMD ["python", "relay.py"]
