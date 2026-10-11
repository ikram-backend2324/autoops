# Какие данные и доступы нужны и как их получить

Для **локального демо не нужно ничего** из этого списка — только Docker. Всё ниже — для реального сервера.

## Сводная таблица

| Что | Зачем | Обязательно? | Куда вписать |
|---|---|---|---|
| [VPS-сервер](#1-vps-сервер) | где всё работает | да | `hosts.yml → ansible_host` |
| [SSH-ключ](#2-ssh-ключ-и-ip) | вход без пароля | да | `~/.ssh/id_ed25519.pub` → `autoops_admin_keys` |
| [Домен и DNS](#3-домен-и-dns) | HTTPS, адрес сайта | да | `hosts.yml → domain`, `autoops_base_domain` |
| [Telegram-бот](#4-telegram) | алерты | очень желательно | vault: `vault_telegram_*` |
| [S3-хранилище](#5-s3-хранилище-для-бэкапов) | бэкапы вне сервера | да (иначе бэкапы бесполезны) | vault: `vault_restic_repository`, `vault_s3_*` |
| [GitHub](#6-github) | CI/CD, хранение образов | для автодеплоя | GitHub Secrets/Variables |
| [Пароли](#7-пароли) | Grafana, restic, Postgres, Django | да | vault |
| [Данные клиента](#8-что-запросить-у-клиента) | при продаже услуги | — | чек-лист ниже |

---

## 1. VPS-сервер

**Минимум:** 2 vCPU · 4 GB RAM · 40 GB SSD · Ubuntu 24.04 LTS (или 22.04) · публичный IPv4.
Мониторинг (Prometheus, Grafana, Loki, exporters) занимает ~1–1.3 GB RAM; на 2 GB тоже заработает
(роль `base` создаст swap), но для клиентского продакшена берите 4 GB.

| Провайдер | Конфигурация ≈ 2 vCPU / 4 GB | Цена в месяц (ориентир 2026) | Комментарий |
|---|---|---|---|
| Hetzner Cloud (CX22 / CPX21) | 2 vCPU, 4 GB, 40 GB | €4–8 | лучшее соотношение цены, ДЦ в Германии/Финляндии |
| Contabo (Cloud VPS S) | 4 vCPU, 8 GB, 75 GB NVMe | €5–7 | дёшево, но «шумные соседи» |
| DigitalOcean (Basic) | 2 vCPU, 4 GB, 80 GB | $24 | простой интерфейс, популярен у клиентов |
| Узбекские провайдеры (UZCLOUD, Ahost, Spaceweb.uz и др.) | 2 vCPU, 4 GB | ~150–350 тыс. сум | данные в Узбекистане — важно для гос. и финансовых клиентов (закон о персональных данных) |

Как купить на примере Hetzner: hetzner.com/cloud → Sign up → Create project → Add server →
Location (Helsinki/Falkenstein) → Image **Ubuntu 24.04** → Type CX22 → *SSH keys: добавьте ваш публичный ключ* →
Create. Через минуту появится IP.

## 2. SSH-ключ и IP

```bash
ssh-keygen -t ed25519 -C "you@laptop"            # Enter, Enter (лучше задать passphrase)
cat ~/.ssh/id_ed25519.pub                        # это публичная часть — её можно показывать
```
* У провайдера при создании сервера вставьте публичный ключ, **или** на существующем сервере:
  `ssh-copy-id root@IP`.
* Проверка: `ssh root@IP` входит без пароля.
* Отдельный ключ для GitHub Actions: `ssh-keygen -t ed25519 -f autoops-ci -N "" -C github-actions` (см. RUN.md §6).
* Приватный ключ (`id_ed25519`, без `.pub`) **никогда** никому не отправляйте и не коммитьте.

## 3. Домен и DNS

* Домен `.uz`: у аккредитованных регистраторов (например, Ahost, Webspace.uz, Uzinfocom-партнёры), ~50–100 тыс. сум/год.
* Международный: Cloudflare Registrar (по себестоимости) или Namecheap, ~$10–15/год за `.com`.
* DNS-записи (в панели регистратора или Cloudflare):

| Тип | Имя | Значение | Для чего |
|---|---|---|---|
| A | `shop` (или `@`) | IP сервера | приложение |
| A | `grafana.shop` | IP сервера | Grafana |

  В Cloudflare ставьте **DNS only** (серое облако) на время выпуска сертификата — иначе HTTP-01 challenge
  может не пройти.
* Проверка (подождите 5–30 минут):
  ```bash
  dig +short shop.example.uz          # должен вернуть IP сервера
  dig +short grafana.shop.example.uz
  ```

## 4. Telegram

1. В Telegram откройте **@BotFather** → `/newbot` → имя (`AutoOps Alerts`) → username (`myco_autoops_bot`).
   BotFather пришлёт **токен** вида `123456789:AAH...` → `vault_telegram_bot_token`.
2. Создайте группу «Алерты — <клиент>», добавьте туда бота (и коллег/клиента).
3. Напишите в группе любое сообщение, затем откройте в браузере
   `https://api.telegram.org/bot<ТОКЕН>/getUpdates` — найдите `"chat":{"id":-100…}` → `vault_telegram_chat_id`
   (для групп id отрицательный, начинается с `-100`). Для личного чата — напишите боту `/start`, id положительный.
4. Проверка: 
   ```bash
   curl -s "https://api.telegram.org/bot<ТОКЕН>/sendMessage" -d chat_id=<ID> -d text="AutoOps test"
   ```

## 5. S3-хранилище для бэкапов

Бэкап на том же сервере — не бэкап. Нужен внешний S3-совместимый бакет.

**Backblaze B2** (рекомендую для старта):
1. backblaze.com → B2 Cloud Storage → Sign up.
2. *Buckets → Create a Bucket*: имя `autoops-backups-<клиент>`, **Private**, Encryption — можно Enable (restic и так шифрует).
3. *Application Keys → Add a New Application Key*: доступ **только к этому бакету**, Read and Write.
   Получите `keyID` → `vault_s3_access_key_id`, `applicationKey` → `vault_s3_secret_access_key` (показывается один раз!).
4. Endpoint виден на странице бакета, например `s3.eu-central-003.backblazeb2.com`.
   `vault_restic_repository: "s3:https://s3.eu-central-003.backblazeb2.com/autoops-backups-shop/client-shop-1"`

**Cloudflare R2:** dash.cloudflare.com → R2 → Create bucket → *Manage R2 API Tokens* → Create token
(Object Read & Write, только этот бакет). Endpoint: `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`.
`vault_restic_repository: "s3:https://<ACCOUNT_ID>.r2.cloudflarestorage.com/autoops-backups/client-shop-1"`

| Хранилище | 100 GB в месяц | Скачивание (restore) |
|---|---|---|
| Backblaze B2 | ≈ $0.60 | бесплатно до 3× объёма хранения |
| Cloudflare R2 | ≈ $1.50 (10 GB бесплатно) | бесплатно |
| AWS S3 Standard | ≈ $2.30 | ≈ $0.09/GB |
| Hetzner Object Storage | ≈ €5 за 1 TB (минимальный тариф) | включено в квоту |

Благодаря дедупликации restic 7 дневных + 4 недельных + 6 месячных снапшотов типичного проекта
занимают 1.5–3× размера базы, а не 17×.

## 6. GitHub

1. Создайте репозиторий и запушьте проект (`git remote add origin ... && git push -u origin main`).
2. **Secrets/Variables** — таблица в [RUN.md §6](RUN.md#6-github-actions):
   `SSH_PRIVATE_KEY`, `SERVER_HOST`, `SERVER_PORT`, `SERVER_KNOWN_HOSTS`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`;
   переменные `APP_NAME`, `APP_DOMAIN`, `DEPLOY_ENABLED=true`.
3. **GHCR**: публикация работает через встроенный `GITHUB_TOKEN`. Для приватного образа серверу нужен
   Personal Access Token (classic) с правом `read:packages`: GitHub → Settings → Developer settings →
   Personal access tokens → Tokens (classic) → Generate → `read:packages` → в vault `vault_registry_username`,
   `vault_registry_password`.
4. Включите **2FA** на GitHub (Settings → Password and authentication).
5. Создайте Environment `production` (Settings → Environments) — можно добавить ручное подтверждение деплоя.

## 7. Пароли

Генерация:
```bash
openssl rand -base64 32     # Grafana admin, restic, Postgres
openssl rand -base64 48     # DJANGO_SECRET_KEY
```
| Секрет | Где хранится | Что будет, если потерять |
|---|---|---|
| Пароль ansible-vault | менеджер паролей (Bitwarden/1Password/KeePassXC) | придётся заново заполнить vault |
| `vault_restic_password` | vault **и** менеджер паролей **и** у клиента в договоре/сейфе | **бэкапы невозможно расшифровать** |
| Grafana admin | vault | сброс через `grafana cli admin reset-admin-password` |
| Postgres / Django | vault | смена — `make deploy` (Postgres: ALTER USER) |

Правила: никаких секретов в git (`vault.yml` зашифрован, `hosts.yml`, `local/.env` в `.gitignore`),
свой набор паролей на каждого клиента, ротация раз в 6–12 месяцев (см. PRODUCTION.md).

## 8. Что запросить у клиента

Скопируйте и отправьте клиенту:

> **Для настройки сервера «под ключ» нам понадобится:**
> 1. Доступ к хостингу/VPS (или разрешение купить сервер на ваш аккаунт; оплата — ваша карта).
>    Если сервер уже есть: IP, root-доступ по SSH-ключу (мы пришлём публичный ключ).
> 2. Доступ к DNS домена (панель регистратора/Cloudflare) или готовность добавить 2 A-записи по нашей инструкции.
> 3. Репозиторий приложения (GitHub/GitLab) с правами на чтение, либо Docker-образ. Если Docker нет — сделаем.
> 4. Список переменных окружения приложения (без значений — значения передадим защищённо).
> 5. Текущая база данных (дамп) и файлы пользователей, если переносим существующий проект.
> 6. Кто получает алерты: Telegram-аккаунты ответственных (добавим в группу).
> 7. Требования к хранению данных: можно ли хранить бэкапы за пределами Узбекистана (закон о персональных данных).
> 8. Контакт для экстренной связи и согласованное «окно» для работ (например, ночь с субботы на воскресенье).
> 9. Реквизиты для договора/оферты.
