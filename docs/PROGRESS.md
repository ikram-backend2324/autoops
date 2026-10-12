# Progress

Все этапы 1–12 из задания выполнены. Ниже — что проверено и где.

## Проверено локально (Windows 11 + Docker Desktop 29.8, 16 CPU, 12.10.2026)

| Проверка | Команда | Результат |
|---|---|---|
| Все линтеры (yamllint, ansible-lint production, syntax-check, shellcheck, ruff, promtool config/rules/tests, amtool, actionlint, compose config, дашборды актуальны) | `make lint` | 13/13 ✔ |
| Тесты sample-app (Django + ruff) | `make test-app` | 9 passed |
| Unit-тесты правил алертов | `make test-rules` | 9 тестов ✔ |
| Molecule: converge → idempotence (changed=0) → verify | `make molecule` | base, security, docker, selfheal, backup ✔ |
| CI-деплой: успех, сломанный релиз → автооткат, несуществующий тег → автооткат, ручной rollback, защита от инъекций | `make test-deploy` | 11/11 ✔ |
| Локальный стек с нуля | `make local-clean && make local-up` | 19 сервисов healthy |
| Бэкап в S3 + проверка восстановления | `make backup && make verify-restore` | ✔ (25 строк core_note) |
| Chaos, все 5 сценариев | `make chaos-auto` | 5/5 PASS → docs/chaos-report.md |
| Traefik: HTTPS, редирект 301, security headers, strict SNI, rate limit (429) | ручной тест, самоподписанный сертификат | ✔ |
| Скриншоты дашбордов и пример Telegram-алерта | `make screenshots` | docs/screenshots/ |
| Еженедельный отчёт | `make report` (`--dry-run`) | ✔ |

## Найдено и исправлено во время проверки
* cAdvisor 0.52 и Traefik 3.5 не работают с Docker 29 → cAdvisor 0.57.0, Traefik v3.7.12.
* Образы MinIO удалены с Docker Hub → Versity S3 Gateway для локального S3.
* autoheal шлёт JSON-ключ `content` → relay принимает `text/content/message`, ключ задан явно.
* Traefik health-probe отклонялся Django (Host = IP) → `loadbalancer.healthcheck.hostname`.
* `ci-deploy`: при ошибке pull/up `set -e` прерывал скрипт до отката → переключение внутри `if`, откат на любой сбой.
* Роль `app`: падение `up`/`pull` останавливало плейбук до отката → решает health-gate.
* Еженедельный отчёт: повторные уведомления Alertmanager считались новыми инцидентами; размер 42 КБ показывался как 0.0 МБ.
* Идемпотентность роли selfheal (копирование + chmod спорили) и `sshd -t` в контейнере (`/run/sshd`).
* Скриншоты: headless Chromium с локалью `en-US@posix` ломал Grafana → явная локаль.

## Не проверено (нужны реальные ресурсы)
* `make provision && make deploy` на реальном VPS, выпуск сертификата Let's Encrypt.
* Доставка сообщений в настоящий Telegram (шаблон проверен через `amtool template render`).
* Прогон GitHub Actions на github.com (синтаксис проверен actionlint, логика деплоя — `make test-deploy`).
* Роли traefik/monitoring/app в Molecule (требуют Docker внутри контейнера) — проверены lint + реальными стеками локально.

Что проверить на сервере: [PRODUCTION.md §1 — чек-лист go-live](PRODUCTION.md#1-чек-лист-перед-запуском-go-live).
