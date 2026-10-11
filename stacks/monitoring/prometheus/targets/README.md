# Prometheus file_sd targets

On a server the Ansible `app` role writes two files per application here:

* `<app>-app.yml` — web `/metrics`, postgres-exporter and redis-exporter of that app
* `<app>-probe.yml` — public URLs probed by blackbox-exporter (`https://<domain>/health/`)

Prometheus re-reads them every 30 s, no restart needed. The laptop demo uses
`local/targets/` instead (see `AUTOOPS_TARGETS_DIR`).
