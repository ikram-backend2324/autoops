# Архитектурные решения (ADR-лог)

Короткие записи «что решили и почему». Новые решения — в конец файла.

## 1. Один и тот же compose-файл для сервера и ноутбука
`stacks/app/compose.yml` и `stacks/monitoring/compose.yml` полностью параметризованы переменными окружения.
Сервер получает `.env` от Ansible, ноутбук — `local/.env`. Локальные отличия (сборка образа из исходников,
tmpfs-«диск» для хаос-теста) вынесены в `local/overrides/*.yml` и подключаются через `include` в `local/compose.yml`.
**Почему:** демо показывает ровно то, что поедет в продакшен; нет двух конфигураций, которые расходятся.

## 2. Один compose-проект на приложение + общая сеть `autoops`
Каждое приложение — отдельный проект (`docker compose -p <app>`), Postgres/Redis сидят в его приватной сети.
Наружу, в общую сеть `autoops`, выходят только web и экспортёры, с алиасами `<app>-web`, `<app>-postgres-exporter`.
**Почему:** «один сервер — несколько проектов клиента» без конфликтов имён и без доступа одного приложения к БД другого.

## 3. Prometheus находит приложения через file_sd
Роль `app` пишет `targets/<app>-app.yml` и `targets/<app>-probe.yml`; Prometheus перечитывает их каждые 30 с.
**Почему:** добавление приложения не требует перезапуска мониторинга и правки `prometheus.yml`.

## 4. Grafana Alloy вместо Promtail
Promtail объявлен deprecated (EOL — 2026). Alloy — официальная замена с тем же функционалом (`loki.source.docker`).

## 5. cAdvisor 0.57 из ghcr.io
cAdvisor 0.52 (gcr.io) не умеет работать с containerd image store, который включён по умолчанию в Docker 29
(и в Docker Desktop). Метрики контейнеров пропадали полностью. 0.57.0 эту схему поддерживает.

## 6. Двухуровневые healthcheck: `/health/live/` и `/health/`
* Docker HEALTHCHECK → `/health/live/` (процесс жив, без зависимостей).
* blackbox, деплой, Traefik → `/health/` (БД + Redis).
**Почему:** если упала БД, перезапуск web её не починит — без разделения autoheal устраивал бы цикл рестартов web.

## 7. notify-relay — единая точка уведомлений
Маленький сервис на стандартной библиотеке Python: принимает webhook Alertmanager, сообщения autoheal, watchdog,
бэкапов и отчётов; пишет журнал событий (JSONL) и отправляет в Telegram, если задан токен.
**Почему:** (1) без Telegram всё видно в `docker compose logs notify-relay`; (2) chaos-скрипт и еженедельный
отчёт читают историю событий через `GET /events`; (3) у autoheal нет Telegram, только webhook.
Alertmanager при этом шлёт в Telegram **сам** (встроенный telegram receiver) — relay лишь ведёт аудит.

## 8. Конфиг Alertmanager выбирается при старте
`entrypoint.sh` берёт `alertmanager.yml` (Telegram + relay), если заданы `TELEGRAM_BOT_TOKEN` и `TELEGRAM_CHAT_ID`,
иначе `alertmanager.local.yml` (только relay). Токен кладётся в файл (`bot_token_file`), а не в конфиг.

## 9. Watchdog на Python (stdlib), systemd timer раз в минуту
Python читабельнее bash для логики «защита от бесконечного цикла» (состояние в JSON, лимит действий в час).
Без внешних зависимостей — работает на чистой Ubuntu. Локально тот же скрипт крутится в контейнере `--loop 20`.
* Остановленный контейнер лечится только после grace-периода (60 с), чтобы не мешать ручным операциям и деплою.
* Режим обслуживания: файл `/var/lib/autoops/maintenance` (его ставят `make update` и `restore.sh`).
* Очистка диска — `docker image/builder/container/network prune --filter until=72h` (без томов!), journald vacuum,
  удаление файлов по маскам. Локально prune **отключён**, чтобы не трогать образы разработчика.
* «Сдался» → одно critical-сообщение в час + метрика `autoops_watchdog_gave_up` → алерт `SelfHealGaveUp`.

## 10. Метрики контейнерного health и бэкапов — через textfile collector
cAdvisor не экспортирует статус healthcheck, а бэкапы — это не сервис. Watchdog и скрипты бэкапа пишут
`*.prom` в `/var/lib/node_exporter/textfile`, node_exporter их отдаёт.

## 11. Бэкапы: restic, pg_dump через `docker exec`
* Учётные данные БД берутся из окружения самого контейнера Postgres — скрипту бэкапа их не нужно знать.
* Медиа — `tar` из web-контейнера в поток, без зависимости от пути тома на хосте.
* Перед дампом считаются строки ключевых таблиц (`VERIFY_TABLES_<APP>`) — эталон для проверки восстановления.
* `restic init` вместо `restic cat config` для проверки репозитория: последний бесконечно ретраит, если бакета нет.

## 12. MinIO заменён на Versity S3 Gateway в локальной среде
Образы `minio/minio` удалены с Docker Hub (MinIO прекратил публикацию community-образов в 2025).
`versity/versitygw` — S3-совместимый шлюз на POSIX-каталоге, restic с ним работает без изменений.
На сервере используется любой S3: Backblaze B2, Cloudflare R2, AWS, Hetzner Object Storage.

## 13. CI деплоит через forced command
Ключ GitHub Actions в `authorized_keys` пользователя `deploy` ограничен `command="/opt/autoops/bin/ci-deploy"`,
`no-pty`, без форвардингов. Ключ умеет только `deploy APP TAG`, `rollback APP`, `status APP`.
Health-check и откат выполняются на сервере (`ci-deploy`), workflow дополнительно проверяет `https://<домен>/health/`.
**Честно:** пользователь в группе `docker` фактически имеет root-доступ к хосту, поэтому ограничение —
именно forced command, а не группа.

## 14. Текущий тег образа хранится в `tag.env`, а не в `.env`
`.env` (секреты) принадлежит root и только читается deploy-пользователем; `tag.env` (APP_TAG, APP_PREVIOUS_TAG)
принадлежит deploy. `autoops-compose` подключает оба файла. Watchdog при лечении стека передаёт compose те же
env-файлы (метка `com.docker.compose.project.environment_file`), иначе `up -d` мог бы молча сменить версию.

## 15. Статическая конфигурация Traefik — флагами CLI
Traefik не поддерживает шаблоны в статическом конфиге и не смешивает файл с флагами. Флаги в `command:` позволяют
подставить `${ACME_EMAIL}` средствами compose. Динамика (middlewares, TLS) — файл `dynamic/middlewares.yml`.

## 16. Демо-правила алертов
Продакшен-правила (`for: 10m` у HighCPU и т.п.) не меняются. `scripts/dev/fast_rules.py` создаёт копию в
`local/generated/rules`, где все ожидания от 1 мин до 1 ч сокращены до 1 мин; ожидания > 1 ч (бэкап 26 ч)
оставлены — это смысл правила, а не задержка демо.

## 17. Диск в хаос-тесте на ноутбуке — tmpfs-том 300 МБ
На Docker Desktop «хост» — маленькая VM, заполнять её диск бессмысленно и опасно. node_exporter в локальном режиме
смотрит на том `autoops_chaosdisk` (tmpfs), его же чистит watchdog. На сервере `CHAOS_DISK_MODE=host` заполняет `/`.

## 18. Molecule: что не проверяется в контейнере
Задачи, требующие ядра/полноценного хоста, помечены тегом `molecule-notest` и пропускаются Molecule автоматически:
ufw и fail2ban (iptables), sysctl (read-only в контейнере), swap (`swapon` запрещён), timezone (нужен dbus),
chrony (CAP_SYS_TIME), запуск sshd/dockerd. Роли `traefik`, `monitoring`, `app` требуют работающего Docker
на хосте — они проверяются `ansible-lint`, `--syntax-check` и реальным прогоном на сервере.

## 19. Порт демо-приложения 8088
На машине разработки порт 8000 часто занят (у автора — другим проектом), а порт 7070 на Windows входит в
зарезервированный Hyper-V диапазон. Поэтому web публикуется на `LOCAL_WEB_PORT=8088`, а S3 не публикуется вовсе.
