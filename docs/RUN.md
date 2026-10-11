# Как запустить AutoOps

Содержание:
1. [Что установить](#1-что-установить)
2. [Локальное демо за 4 команды](#2-локальное-демо-за-4-команды)
3. [Chaos-демо](#3-chaos-демо)
4. [Бэкапы локально](#4-бэкапы-локально)
5. [Реальный сервер](#5-реальный-сервер)
6. [GitHub Actions](#6-github-actions)
7. [Подключение своего (клиентского) приложения](#7-подключение-своего-клиентского-приложения)
8. [Grafana и Prometheus через SSH-туннель](#8-grafana-и-prometheus-через-ssh-туннель)
9. [Частые ошибки](#9-частые-ошибки)

---

## 1. Что установить

| Что | Зачем | Linux / macOS | Windows |
|---|---|---|---|
| Docker + Compose v2 | всё работает в контейнерах | Docker Engine / Docker Desktop | Docker Desktop (WSL2 backend) |
| make | единая точка входа | `sudo apt install make` / Xcode CLT | внутри WSL2 Ubuntu |
| Python 3.10+ | генераторы (дашборды, демо-правила) | обычно уже есть | внутри WSL2 Ubuntu |
| git, curl | клонирование, проверки | есть | внутри WSL2 Ubuntu |
| Ansible | **не обязательно** | `pipx install ansible-core` | не нужно |

Ansible, ansible-lint, Molecule, shellcheck, promtool, amtool и actionlint уже собраны в **tools-образ**
(`tools/Dockerfile`). Если `ansible-playbook` не установлен, `make` сам запускает всё через этот образ.
Хотите Ansible локально: `pipx install ansible-core && ansible-galaxy collection install -r tools/requirements.yml`.

### Windows: пошагово через WSL2
1. PowerShell **от администратора**: `wsl --install -d Ubuntu-24.04` → перезагрузка → задайте имя/пароль Ubuntu.
2. Установите Docker Desktop → Settings → *Resources → WSL integration* → включите для Ubuntu.
3. Откройте Ubuntu (меню Пуск) и выполните:
   ```bash
   sudo apt update && sudo apt install -y make git curl python3
   docker version          # должен показать Server: Docker Desktop
   ```
4. Клонируйте проект **внутрь WSL** (`~/autoops`), а не на `C:` или `D:` — файловая система WSL в разы быстрее:
   ```bash
   cd ~ && git clone https://github.com/<you>/autoops.git && cd autoops
   ```
   Если проект уже лежит на диске D: — он доступен как `/mnt/d/start-up/autoops`, это тоже работает.

> Git Bash на Windows тоже подходит для `scripts/chaos/*.sh` и docker-команд, но `make` там нет.

---

## 2. Локальное демо за 4 команды

```bash
cd autoops
make local-up            # сборка + запуск ~20 контейнеров, ждёт пока все станут healthy (3–6 мин в первый раз)
make local-ps            # все контейнеры (healthy)
make local-alerts        # поток алертов и сообщений автовосстановления (Ctrl+C - выход)
```

Откройте:

| Что | Адрес | Логин |
|---|---|---|
| Приложение | http://localhost:8088 · http://localhost:8088/health/ | — |
| Grafana | http://localhost:3000 | `admin` / `autoops` (из `local/.env`) |
| Prometheus | http://localhost:9090 (Alerts, Targets) | — |
| Alertmanager | http://localhost:9093 | — |
| Журнал уведомлений | http://localhost:9095/events | — |

`make local-up` при первом запуске копирует `local/.env.example` → `local/.env`. Там же можно поменять порт
приложения (`LOCAL_WEB_PORT`) и пароль Grafana.

**Алерты в Telegram в локальном режиме** (необязательно): впишите в `local/.env`
`TELEGRAM_BOT_TOKEN=` и `TELEGRAM_CHAT_ID=` (как получить — [DATA.md](DATA.md#telegram)), затем
`docker compose -f local/compose.yml up -d alertmanager notify-relay`. Без токена все алерты печатает notify-relay.

Остановка: `make local-down` (данные сохраняются) или `make local-clean` (удалить и данные).

---

## 3. Chaos-демо

```bash
make chaos          # интерактивно: Enter перед каждым сценарием
make chaos-auto     # без пауз (для записи видео), ~12 минут
make chaos-db       # один сценарий: chaos-kill | chaos-unhealthy | chaos-db | chaos-disk | chaos-cpu
```

Сценарии: убийство web, зависание web (unhealthy), остановка Postgres, заполнение диска, нагрузка CPU.
Итоговая таблица печатается в терминал и сохраняется в `docs/chaos-report.md`.
Пока идёт тест, держите открытыми `make local-alerts` и Grafana → «AutoOps · Контейнеры».

> Нагрузка CPU занимает **все ядра** ноутбука на ~4 минуты. Длительность: `CHAOS_CPU_SECONDS=120 make chaos-cpu`.

---

## 4. Бэкапы локально

Локальный S3 (Versity S3 Gateway) уже запущен в стеке. Контейнер `ops` по расписанию делает бэкап в 03:00,
проверку восстановления по воскресеньям в 04:00 и отчёт по понедельникам в 09:00 (Asia/Tashkent). Вручную:

```bash
make backup            # pg_dump + медиа → restic → S3
make verify-restore    # восстановить последний бэкап во временный Postgres и проверить строки
make restore APP=sample   # интерактивное восстановление в работающую базу (с подтверждением)
make report            # еженедельный отчёт прямо сейчас
```

---

## 5. Реальный сервер

Нужны: VPS с Ubuntu 22.04/24.04, домен, Telegram-бот, S3-бакет. Как получить каждое — [DATA.md](DATA.md).

### 5.1 Inventory
```bash
cp ansible/inventory/hosts.example.yml ansible/inventory/hosts.yml
nano ansible/inventory/hosts.yml        # IP, домен, список приложений
```

### 5.2 Секреты (ansible-vault)
```bash
cp ansible/inventory/group_vars/all/vault.example.yml ansible/inventory/group_vars/all/vault.yml
nano ansible/inventory/group_vars/all/vault.yml           # впишите реальные значения
# зашифровать (пароль vault храните в менеджере паролей!)
docker run --rm -it -v "$PWD:/work" -w /work autoops/tools:local \
  ansible-vault encrypt ansible/inventory/group_vars/all/vault.yml
# дальше редактировать только так:
make vault-edit
```
Чтобы не вводить пароль vault каждый раз:
`echo 'пароль' > ~/.autoops-vault && chmod 600 ~/.autoops-vault && export ANSIBLE_VAULT_PASSWORD_FILE=~/.autoops-vault`
(Makefile сам пробросит файл в tools-контейнер). Без этой переменной `make` спросит пароль vault.

### 5.3 Первый запуск
```bash
make tools-image                                                   # один раз
make ping EXTRA="-e ansible_user=root"                             # SSH работает?
make provision LIMIT=client-shop-1 EXTRA="-e ansible_user=root"    # первый раз — под root провайдера
```

После provisioning вход под root и по паролю **закрыт**; заходите `ssh ops@IP`.
Поменяли `ssh_port`? Сначала provision откроет новый порт в ufw, затем обновите `ansible_port` в inventory.

### 5.4 DNS и деплой
1. A-записи `shop.example.uz` и `grafana.shop.example.uz` → IP сервера (проверка: `dig +short shop.example.uz`).
2. `make deploy` — приложение, HTTPS-сертификат выпустится автоматически за ~30 с.
3. Проверка: `curl -I https://shop.example.uz/health/` → `200`, Grafana: `https://grafana.shop.example.uz`.
4. `make server-backup RUN=1` — сразу сделать первый бэкап.

### 5.5 Повседневные команды
```bash
make deploy                       # выкатить версии из inventory
make deploy TAG=sha-3f2c1ab       # конкретная версия
make rollback APP=shop            # вернуть предыдущую
make monitoring                   # обновить правила алертов/дашборды
make update                       # обновить ОС и Docker (по одному серверу, с перезагрузкой при необходимости)
ssh ops@IP sudo /opt/autoops/bin/autoops-compose shop logs -f web   # логи приложения
```

---

## 6. GitHub Actions

Workflows: `ci.yml` (тесты + сборка на каждый push/PR), `infra-lint.yml` (все линтеры), `deploy.yml` (main → GHCR → сервер).

1. Сгенерируйте **отдельный** ключ для CI: `ssh-keygen -t ed25519 -f autoops-ci -C github-actions -N ""`.
2. Публичную часть (`autoops-ci.pub`) добавьте в vault: `vault_deploy_public_keys` → `make provision` (или `--tags security`).
3. GitHub → Settings → Secrets and variables → Actions:

| Тип | Имя | Значение |
|---|---|---|
| Secret | `SSH_PRIVATE_KEY` | содержимое файла `autoops-ci` |
| Secret | `SERVER_HOST` | IP сервера |
| Secret | `SERVER_PORT` | порт SSH (если не 22) |
| Secret | `SERVER_KNOWN_HOSTS` | вывод `ssh-keyscan -p 22 IP` (защита от MITM) |
| Secret | `TELEGRAM_BOT_TOKEN` | токен бота |
| Secret | `TELEGRAM_CHAT_ID` | id чата |
| Variable | `APP_NAME` | `shop` (как в inventory) |
| Variable | `APP_DOMAIN` | `shop.example.uz` |
| Variable | `DEPLOY_ENABLED` | `true` — включает job деплоя |

`GITHUB_TOKEN` для публикации в GHCR выдаётся автоматически (`permissions: packages: write`).
Если образ приватный — серверу нужен PAT с `read:packages` (`vault_registry_*`), или сделайте пакет публичным
(GitHub → Packages → autoops-sample-app → Package settings → Change visibility).

---

## 7. Подключение своего (клиентского) приложения

Требования к приложению (любой стек, не только Django):

| Требование | Зачем |
|---|---|
| Dockerfile, процесс слушает `:8000` | Traefik проксирует на 8000 |
| `GET /health/live/` → 200, если процесс жив | Docker HEALTHCHECK, autoheal |
| `GET /health/` → 200 и JSON `{"status": "ok"}`, проверяет БД/Redis | blackbox, деплой, откат |
| настройки через переменные окружения | `.env` рендерит Ansible |
| (желательно) `/metrics` в формате Prometheus | дашборд «Приложение» |
| миграции — командой `migrate` образа | one-shot контейнер перед стартом |

Ваш образ должен понимать команды `web`, `worker`, `migrate` (см. `sample-app/docker/entrypoint.sh`).
Если воркера нет — сделайте `worker` бесконечным `sleep` или уберите сервис в копии `stacks/app/compose.yml`.

Пример: интернет-магазин клиента на `ghcr.io/client/shop`:
```yaml
# ansible/inventory/hosts.yml → autoops_apps
- name: shop
  image: ghcr.io/client/shop
  tag: v1.4.2
  domain: shop.client.uz
  verify_tables: [orders_order, catalog_product]   # проверка восстановления бэкапа
  gunicorn_workers: 4
  web_memory: 1g
  env:
    PAYME_MERCHANT_ID: "..."
```
```yaml
# vault.yml
vault_app_secrets:
  shop:
    postgres_password: "<openssl rand -base64 32>"
    django_secret_key: "<openssl rand -base64 48>"
```
`make deploy` → готово: HTTPS, мониторинг, алерты, бэкапы и проверка восстановления подхватятся автоматически.
Миграция существующей базы: `pg_dump -Fc` со старого сервера → `scp` → `docker exec -i <shop-postgres> pg_restore ...`
(или сделайте restic-снапшот и `restore.sh`).

---

## 8. Grafana и Prometheus через SSH-туннель

Prometheus, Alertmanager, Loki и notify-relay слушают только `127.0.0.1` сервера — наружу не открыты.
```bash
ssh -N -L 9090:127.0.0.1:9090 -L 9093:127.0.0.1:9093 -L 3000:127.0.0.1:3000 ops@IP
# затем в браузере: http://localhost:9090, http://localhost:9093, http://localhost:3000
```
Grafana дополнительно опубликована через Traefik: `https://grafana.<домен>` (логин admin, пароль из vault).

---

## 9. Частые ошибки

| Симптом | Причина и решение |
|---|---|
| `ports are not available ... 8088` | порт занят: поменяйте `LOCAL_WEB_PORT` в `local/.env` |
| `bind: An attempt was made to access a socket in a way forbidden` (Windows) | порт в диапазоне Hyper-V: `netsh int ipv4 show excludedportrange protocol=tcp`, выберите другой |
| `network autoops ... not found` | `docker network create autoops` (make local-up делает сам) |
| контейнер `migrate` Exited (1) | Postgres ещё не готов или неверный пароль: `make local-logs SERVICE=migrate` |
| В Grafana пусто на «Контейнеры» | cAdvisor стартует ~30 с; проверьте http://localhost:9090/targets |
| Алерт `BackupNeverSucceeded` | ещё не было бэкапа: `make backup` |
| `SelfHealGaveUp` после экспериментов | watchdog исчерпал лимит действий: `docker compose -f local/compose.yml exec watchdog rm /state/watchdog-state.json` (на сервере `sudo rm /var/lib/autoops/watchdog-state.json`) |
| Let's Encrypt не выдаёт сертификат | DNS ещё не обновился (`dig`), порт 80 закрыт у провайдера, или лимит LE — используйте staging (`traefik_acme_ca_server`) |
| `Permission denied (publickey)` после provision | вход root закрыт: `ssh ops@IP`; ключ должен совпадать с `autoops_admin_keys` |
| `make` не найден на Windows | работайте из WSL2 Ubuntu (раздел 1) |
| Скрипты в Git Bash портят пути `/opt/...` | они уже ставят `MSYS_NO_PATHCONV=1`; в своих командах добавляйте его тоже |
