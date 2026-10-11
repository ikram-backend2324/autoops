# Эксплуатация AutoOps в продакшене

## 1. Чек-лист перед запуском (go-live)

- [ ] **DNS:** `dig +short <домен>` и `dig +short grafana.<домен>` возвращают IP сервера.
- [ ] **HTTPS:** `curl -I https://<домен>/health/` → `200`; редирект `http://` → `https://`; https://www.ssllabs.com/ssltest/ — оценка A.
- [ ] **Безопасность:** `ssh root@IP` — отказ; `ssh -o PubkeyAuthentication=no ops@IP` — отказ; `sudo ufw status` — открыты только SSH, 80, 443;
      снаружи `nc -zv IP 5432 9090 3000` — всё закрыто.
- [ ] **Бэкап сделан и восстановлен:** `make server-backup RUN=1`, затем `sudo systemctl start autoops-verify-restore` → в Telegram «🧪 … прошла успешно».
- [ ] **Алерты доходят:** тестовый алерт (ниже) пришёл в Telegram и потом «✅ РЕШЕНО».
- [ ] **Self-healing:** на тестовом окне `CHAOS_APP=<app> APP_HEALTH_URL=https://<домен>/health/ CHAOS_ONLY="1 2" /opt/autoops/scripts/chaos/run_all.sh` (только с `chaos_enabled: true` у приложения!) или хотя бы `docker restart <app>-web-1`.
- [ ] **Ресурсы:** лимиты CPU/RAM в inventory соответствуют серверу; `docker stats --no-stream` — запас ≥ 30 % RAM.
- [ ] **Секреты не в git:** `git ls-files | grep -E 'vault.yml|hosts.yml|\.env$'` — пусто или только зашифрованный vault (`head -1` → `$ANSIBLE_VAULT`).
- [ ] **Пароль restic** сохранён в менеджере паролей и передан клиенту.
- [ ] **CI/CD:** тестовый коммит в main → «✅ Деплой sha-… успешен» в Telegram.
- [ ] **Документация клиенту:** URL-ы, кто получает алерты, SLA, как связаться.

Тестовый алерт через Alertmanager API (на сервере):
```bash
curl -s -XPOST http://127.0.0.1:9093/api/v2/alerts -H 'Content-Type: application/json' -d '[{
  "labels": {"alertname":"GoLiveTest","severity":"warning","server":"'"$(hostname)"'"},
  "annotations": {"summary":"Тестовый алерт перед запуском","description":"Если вы это видите — алерты работают.","runbook":"Ничего делать не нужно."}
}]'
```

## 2. Регламенты

| Когда | Что делать | Команда / где смотреть | Время |
|---|---|---|---|
| **Ежедневно** | просмотреть Telegram-группу; всё ли критичное закрыто «✅ РЕШЕНО» | Telegram | 2 мин |
| **Еженедельно** (пн) | прочитать автоматический отчёт; проверить, что «🧪 проверка восстановления» прошла в воскресенье | Telegram, Grafana «Бэкапы» | 10 мин |
| **Ежемесячно** | `make update` в согласованное окно; ротация части секретов; ревизия места (`DiskWillFillIn24h`, тренд в Grafana); срок домена у регистратора; актуальность контактов клиента | | 30–60 мин |
| **Ежеквартально** | полный DR-тест (ниже); ревизия правил алертов (что шумит, что пропустили); обновление образов стека мониторинга | | 1–2 ч |

### DR-тест: восстановление на новом сервере с нуля
Цели: **RPO ≤ 24 ч** (ежедневный бэкап; для критичных клиентов — чаще, см. §6), **RTO ≤ 1 ч**.

1. Создайте новый VPS (тот же размер), добавьте его в inventory как `client-shop-dr` с теми же `autoops_apps`.
2. `make provision LIMIT=client-shop-dr EXTRA="-e ansible_user=root"` — ~10 мин.
3. `make deploy LIMIT=client-shop-dr` — поднимется пустое приложение (~3 мин).
4. На новом сервере восстановите данные из бэкапа **старого** хоста:
   ```bash
   sudo -i
   set -a; . /etc/autoops/backup.env; set +a
   /opt/autoops/scripts/backup/restore.sh --host client-shop-1 --app shop --snapshot latest --yes
   ```
5. Проверьте приложение по IP: `curl -k --resolve shop.example.uz:443:<NEW_IP> https://shop.example.uz/health/`.
6. (Реальная авария) переключите A-запись на новый IP; TTL заранее держите 300 с.
7. Запишите фактическое время каждого шага в журнал DR-тестов; удалите тестовый сервер.

## 3. Runbook на каждый алерт

Общий порядок: открыть ссылку «📊 Открыть дашборд» из сообщения → понять масштаб → действовать → убедиться,
что пришло «✅ РЕШЕНО» → если автоматика не справилась — записать причину и улучшить автоматику.
Контейнеры приложения на сервере: `sudo /opt/autoops/bin/autoops-compose <app> ps|logs|restart`.

### SiteDown
*Значит:* внешняя проверка `https://<домен>/health/` не проходит > 1 мин.
*Проверить:* открыть сайт; `autoops-compose <app> ps`; `autoops-compose <app> logs --tail 100 web`; есть ли одновременно PostgresDown/RedisDown; `docker logs traefik --tail 50`.
*Исправить:* если упала зависимость — см. её runbook; если сломал деплой — `make rollback APP=<app>`; если Traefik — `cd /opt/autoops/stacks/proxy && docker compose up -d`.

### SSLCertExpiringSoon / SSLCertExpiryCritical
*Значит:* Let's Encrypt не продлил сертификат (обычно продлевает за 30 дней).
*Проверить:* `docker logs traefik 2>&1 | grep -i acme`; `dig +short <домен>` указывает на этот сервер; порт 80 открыт (`curl -I http://<домен>`).
*Исправить:* починить DNS/порт; `docker restart traefik`. Лимиты LE: 5 неудачных попыток/час — подождите.

### TargetDown
*Значит:* Prometheus не может собрать метрики цели 2 мин — мониторинг «ослеп» на этом участке.
*Проверить:* http://localhost:9090/targets (через туннель) — текст ошибки; `docker ps -a | grep exporter`.
*Исправить:* `docker start <контейнер>`; если цель удалена (старое приложение) — удалите `targets/<app>-*.yml`.

### AppHigh5xxRate
*Значит:* > 5 % ответов приложения — ошибки 5xx в течение 5 мин.
*Проверить:* Grafana «Приложение» → какие view; «Логи» → `{app="<app>"} |= "ERROR"`; был ли деплой (Telegram).
*Исправить:* откат `make rollback APP=<app>`; передать трассировку разработчикам.

### HighCPU
*Значит:* CPU > 85 % 10 мин.
*Проверить:* Grafana «Контейнеры» → кто ест CPU; `docker stats --no-stream`; `top`. Всплеск трафика? DDoS (access-логи Traefik)?
*Исправить:* поднять `gunicorn_workers`/лимиты или сервер мощнее (см. §5); при атаке — Cloudflare proxy, rate-limit в `middlewares.yml`.

### HighMemory
*Значит:* RAM > 90 % 5 мин, рядом OOM-killer.
*Проверить:* «Контейнеры» → память по контейнерам; `dmesg -T | grep -i oom`.
*Исправить:* утечка → рестарт контейнера и задача разработчикам; иначе уменьшить воркеры/увеличить RAM; проверить swap.

### DiskSpaceWarning / DiskSpaceCritical / DiskWillFillIn24h
*Значит:* диск > 80 % / > 90 % / заполнится за сутки. Watchdog уже пытался чистить при 85 %.
*Проверить:* `sudo du -xh / --max-depth=2 | sort -h | tail -20`; `docker system df`; `sudo du -sh /var/lib/docker/volumes/* | sort -h | tail`.
*Исправить:* старые образы `docker image prune -a`; логи; `/var/backups/autoops/*/pre-restore-*.dump`; растущие медиа — расширить диск у провайдера (Hetzner: Resize / Volume).

### ContainerCrashLoop
*Значит:* контейнер перезапускался > 3 раз за 15 мин — автоматика не помогает.
*Проверить:* `docker logs <имя> --tail 200`; `docker inspect <имя> --format '{{.State.OOMKilled}} {{.State.ExitCode}}'`.
*Исправить:* OOM → поднять лимит памяти; ошибка конфигурации после деплоя → откат; нет БД → чинить БД.

### ContainerRestarted (info, без звука)
*Значит:* Docker/autoheal перезапустил контейнер, сервис восстановлен. Действий не нужно; если повторяется — смотреть логи.

### ContainerUnhealthy
*Значит:* healthcheck падает > 1 мин, а autoheal должен был перезапустить. *Проверить:* `docker logs autoheal --tail 50`, `docker inspect --format '{{json .State.Health}}' <имя>`.

### WatchdogNotRunning
*Проверить:* `systemctl status autoops-watchdog.timer`; `journalctl -u autoops-watchdog -n 50`. *Исправить:* `sudo systemctl enable --now autoops-watchdog.timer`; ошибки Python — в журнале.

### SelfHealGaveUp
*Значит:* одно действие повторялось 3 раза за час и не помогло — **нужен человек**.
*Исправить:* найти первопричину по журналу; после исправления `sudo rm /var/lib/autoops/watchdog-state.json`.

### PostgresDown
*Проверить:* `autoops-compose <app> ps postgres`; `autoops-compose <app> logs --tail 100 postgres` (нет места? повреждение? OOM?).
*Исправить:* место на диске → освободить; `autoops-compose <app> up -d postgres`. Повреждение данных → восстановление из бэкапа (`restore.sh`).

### PostgresTooManyConnections
*Проверить:* `docker exec -it <app>-postgres-1 psql -U app -c "SELECT state, count(*) FROM pg_stat_activity GROUP BY 1"`.
*Исправить:* утечка соединений в коде; уменьшить воркеры×потоки; `POSTGRES_MAX_CONNECTIONS`; pgbouncer.

### PostgresLongRunningQuery
*Проверить:* `SELECT pid, now()-query_start AS dur, query FROM pg_stat_activity WHERE state='active' ORDER BY dur DESC;`
*Исправить:* `SELECT pg_cancel_backend(<pid>);` (мягко) или `pg_terminate_backend`; индекс/оптимизация — разработчикам.

### RedisDown
*Проверить:* `autoops-compose <app> logs redis`; память (`maxmemory`), диск (AOF). *Исправить:* `autoops-compose <app> up -d redis`.

### BackupTooOld / BackupNeverSucceeded / BackupFailed
*Проверить:* `systemctl list-timers | grep autoops`; `journalctl -u autoops-backup -n 100`.
*Частые причины:* неверные ключи S3 / бакет удалён; закончилось место (staging); блокировка restic после обрыва — `restic unlock`.
*Исправить и проверить:* `sudo systemctl start autoops-backup && journalctl -fu autoops-backup`.

### RestoreVerificationFailed
*Значит:* последний бэкап не восстановился или в нём меньше строк, чем было. **Это критично — бэкапам нельзя доверять.**
*Проверить:* `sudo systemctl start autoops-verify-restore; journalctl -u autoops-verify-restore -n 100`; `restic check` (с переменными из `/etc/autoops/backup.env`).
*Исправить:* сразу сделать новый бэкап и проверить; если таблица переименована — обновить `verify_tables` в inventory.

### RebootRequired (info)
Запланировать окно и выполнить `make update` (перезагрузит при необходимости, по одному серверу).

## 4. Обновления без простоя

* **ОС и Docker:** `make update` — `serial: 1`, watchdog в режиме обслуживания, `dist-upgrade`, перезагрузка
  только если требуется, ожидание healthy всех контейнеров. `live-restore: true` в daemon.json сохраняет контейнеры
  при обновлении самого dockerd. Короткий простой (~1–2 мин) возможен только при перезагрузке ядра — делайте в окно.
* **Приложение:** CI (`deploy.yml`) или `make deploy TAG=...`; health-gate и автооткат встроены. Для нулевого
  простоя при деплое — запуск двух реплик web (`docker compose up -d --scale web=2 --no-recreate`, затем пересоздание по одной)
  или blue/green через два имени приложения в Traefik.
* **Стек мониторинга:** поднимите версии образов в `stacks/monitoring/compose.yml` (по одной, читая changelog), прогоните
  `make lint`, `make local-up` и `make chaos-auto` локально, затем `make monitoring`. Данные Prometheus/Grafana в томах сохраняются.

## 5. Масштабирование

| Сигнал | Действие |
|---|---|
| CPU > 70 % в среднем за неделю, RAM > 80 % | вертикально: сервер мощнее (Hetzner: Rescale ~2 мин простоя) |
| База > 20–30 GB, нужен PITR/реплика | вынести БД в managed (DigitalOcean/Hetzner/Aiven Postgres): убрать сервис `postgres` из compose, `POSTGRES_HOST` → адрес managed-БД, бэкап — средствами провайдера + pg_dump для проверки |
| Несколько клиентов / проектов | по серверу на клиента (изоляция, отдельный счёт) — всё описано в одном inventory, группы по клиентам |
| Нужна высокая доступность | 2 сервера за балансировщиком провайдера + managed БД; AutoOps-роли применяются к обоим |

### Центральная Grafana для многих клиентов (как это превращается в услугу)
1. Отдельный «центральный» сервер с Prometheus (или Grafana Mimir/VictoriaMetrics) и Grafana.
2. На клиентских серверах в `prometheus.yml` добавить
   ```yaml
   remote_write:
     - url: https://metrics.your-company.uz/api/v1/write
       basic_auth: { username: client-shop-1, password: <secret> }
   ```
   (метка `server` уже добавляется через `external_labels`) — или federation (`/federate`) с центра через туннель.
3. На центре — те же дашборды (переменная `server`) и единый Alertmanager с маршрутизацией по клиенту в разные
   Telegram-группы. Локальные Alertmanager'ы остаются как резерв (если центр недоступен, клиент всё равно получит алерт).
4. Итог: одно окно на все серверы, отчёты по всем клиентам, и поддержку 20–30 серверов ведёт один человек.

## 6. Безопасность

* **Наименьшие привилегии:** `ops` — человек с sudo; `deploy` — только forced command `ci-deploy`; каждый S3-ключ —
  на один бакет; Grafana — отдельные пользователи (Viewer для клиента) вместо общего admin.
* **Ротация:** ключ CI — раз в 6 мес. (новый ключ в vault → `make provision --tags security`, затем удалить старый
  из `vault_deploy_public_keys`); S3-ключи, Telegram-токен (`/revoke` у BotFather), пароль Grafana — раз в 6–12 мес.
  Пароль restic не ротируется «на месте»: `restic key add` / `restic key remove`.
* **Аудит входов:** `last -a | head`, `journalctl -u ssh --since today`, `sudo fail2ban-client status sshd`.
  Идея для расширения: алерт в Telegram на каждый успешный SSH-вход (PAM-скрипт → notify-relay).
* **2FA** на GitHub, у хостинг-провайдера, в S3 (Backblaze/Cloudflare), на регистраторе домена и в почте.
* **RPO для критичных клиентов:** запускать `autoops-backup` каждые 4–6 ч (`backup_time` → дополнительный таймер)
  или включить WAL-архивацию (pgBackRest/WAL-G) — отдельная услуга.

### Подозрение на взлом
1. **Не перезагружать и не удалять** — сохранить улики. Снимок диска у провайдера (snapshot).
2. Отрезать доступ: `sudo ufw default deny outgoing` (кроме нужного), сменить все ключи/пароли из vault, отозвать ключ CI.
3. Посмотреть: `last`, `journalctl -u ssh`, `/etc/passwd` (новые пользователи), `crontab -l` всех, `systemctl list-timers`,
   `docker ps -a` (чужие контейнеры, майнеры), `ss -tulpn`, Grafana — всплески CPU/сети.
4. Восстановление — **на новом сервере** по DR-процедуре (§2) из бэкапа **до** момента компрометации; старый сервер — на анализ.
5. Уведомить клиента письменно; при утечке персональных данных — требования закона РУз.

## 7. Как разместить на AutoOps свои проекты (пример: сервис мониторинга цен)

Требования к проекту — RUN.md §7 (Dockerfile, `/health/live/`, `/health/`, команды `web`/`worker`/`migrate`).
```yaml
# ansible/inventory/hosts.yml
all:
  children:
    autoops:
      hosts:
        my-projects-1:
          ansible_host: 203.0.113.20
          ansible_user: ops
          autoops_base_domain: islam.dev
          autoops_apps:
            - name: pricewatch
              image: ghcr.io/<you>/price-monitor
              tag: latest
              domain: prices.islam.dev
              verify_tables: [products_product, products_pricehistory]
              gunicorn_workers: 2
              celery_concurrency: 4          # парсеры цен работают в Celery
              worker_memory: 1g
              env:
                SCRAPE_INTERVAL_MINUTES: "30"
            - name: portfolio
              image: ghcr.io/<you>/portfolio
              tag: latest
              domain: islam.dev
```
```yaml
# vault.yml
vault_app_secrets:
  pricewatch: { postgres_password: "...", django_secret_key: "..." }
  portfolio:  { postgres_password: "...", django_secret_key: "..." }
```
`make provision && make deploy` — оба проекта получат HTTPS, мониторинг, алерты, бэкапы и проверку восстановления.
