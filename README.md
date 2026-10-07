# weavemarket-cdn-nginx

Скрипт для ноды [Remnawave](https://docs.rw): ставит nginx, выпускает сертификат Let's Encrypt, проксирует XHTTP в Xray и настраивает UFW.

## Два режима

Первым делом скрипт спросит, как настроить ноду.

**1) По скрипту eGames — порт 443 свободен.** nginx слушает unix-сокет `/dev/shm/nginx.sock` за Xray. Порт 443 держит Xray (REALITY), а всё постороннее (браузеры, CDN, сканеры) он отдаёт в nginx через сокет. REALITY и XHTTP работают на одном 443.

```
клиент ──443──► Xray (REALITY)
                 ├─ свой клиент REALITY ─────────────► прокси
                 └─ всё остальное (браузер, CDN, сканер)
                      └─► unix:/dev/shm/nginx.sock (PROXY protocol)
                            └─► nginx: сайт-заглушка с настоящим сертификатом
                                  └─ /api/video/stream/… ─► XHTTP-инбаунд 127.0.0.1:4443
```

**2) По официальной документации Remnawave — порт 443 занят nginx.** nginx сам слушает 443. Инбаунды Xray на 443 (например, REALITY) работать не смогут, их нужно держать на других портах.

```
клиент ──443──► nginx: сайт-заглушка с настоящим сертификатом
                  └─ /api/video/stream/… ─► XHTTP-инбаунд 127.0.0.1:4443
```

Если сомневаетесь, выбирайте **1**: 443 остаётся за Xray, а XHTTP и CDN всё равно работают.

## Быстрый старт

На сервере с нодой, от root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/WeaveProduct/weavemarket-cdn-nginx/main/installer.sh)
```

Если `raw.githubusercontent.com` недоступен с сервера, используйте зеркало:

```bash
bash <(curl -fsSL https://cdn.jsdelivr.net/gh/WeaveProduct/weavemarket-cdn-nginx@main/installer.sh)
```

Скрипт задаст вопросы:

1. **Режим** — 1 (eGames, 443 свободен) или 2 (официальная документация, 443 у nginx). Enter оставляет 1.
2. **Домен** — для него настраивается nginx и выпускается сертификат.
3. **Порт XHTTP** — должен совпадать с вашим конфигом: например, `4443` должен быть указан и в nginx, и в inbound. Enter оставляет `4443`.
4. **Путь XHTTP** — должен совпадать с вашим конфигом: например, `/api/video/stream` должен быть указан и в nginx, и в inbound. Enter оставляет `/api/video/stream`.
5. **Домен или IP панели** — только с этого адреса будет разрешено подключение к ноде. Enter — не настраивать UFW.
6. **Порт ноды** — Enter оставляет значение из `docker-compose.yml` (обычно `2222`).
7. **Email** — нужен Let's Encrypt для выпуска сертификата.

В конце скрипт напишет «✅ Всё успешно настроено». Готовые конфиги для панели — на сайте **[weavemarket-cdn.vercel.app](https://weavemarket-cdn.vercel.app)**.

## Что нужно до запуска

- **Установленная нода.** Remnawave Node уже установлена [по документации](https://docs.rw/install/remnawave-node) в `/opt/remnanode`.
- **Система и права.** Debian или Ubuntu, запуск от root.
- **Домен.** A-запись домена указывает на IP этого сервера. В Cloudflare нужен режим **DNS only** (серое облако).
- **Порт 80.** Свободен на сервере и открыт у хостера: он нужен для сертификата.
- **Порт XHTTP (по умолчанию 4443).** Не занят снаружи: XHTTP-инбаунд слушает его на `127.0.0.1`.
- **Адрес панели.** Домен панели должен указывать прямо на сервер панели (без прокси Cloudflare), иначе UFW откроет порт ноды не тому IP и нода уйдёт в offline. Можно указать IP панели напрямую.

## Параметры

Все параметры необязательные. Если параметр не передан, скрипт спросит его сам.

| Параметр | Что задаёт | По умолчанию |
|---|---|---|
| `--mode MODE` | `egames` — nginx на сокете, 443 свободен для Xray; `docs` — nginx слушает 443 | спросит (без терминала — `egames`) |
| `--domain DOMAIN` | домен для nginx и сертификата | — |
| `--xhttp-port PORT` | порт XHTTP-инбаунда на `127.0.0.1` | `4443` |
| `--path PATH` | путь XHTTP | `/api/video/stream` |
| `--email EMAIL` | email для Let's Encrypt | — |
| `--panel ADDR` | домен или IP панели — только ей откроется порт ноды в UFW | — |
| `--node-port PORT` | порт ноды для связи с панелью | из `docker-compose.yml`, иначе `2222` |
| `--no-ufw` | не настраивать UFW | — |
| `--dir DIR` | каталог ноды | `/opt/remnanode` |
| `-y`, `--yes` | не задавать вопросов да/нет | — |

Пример запуска без вопросов:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/WeaveProduct/weavemarket-cdn-nginx/main/installer.sh) \
  --mode egames --domain node.example.com --email you@example.com --panel panel.example.com -y
```

Без `--panel` в режиме без вопросов UFW не настраивается.

## Что скрипт меняет

| Где | Что |
|---|---|
| `/opt/remnanode/docker-compose.yml` | добавляет сервис `nginx`. В режиме eGames ещё монтирует `/dev/shm:/dev/shm` и в nginx, и в ноду: у каждого контейнера свой `/dev/shm`, и без общего маунта Xray не увидит сокет. Остальное не трогает, отступы берёт из файла, старую версию сохраняет как `docker-compose.yml.bak-<дата>` |
| `/opt/remnanode/nginx.conf` | дописывает в конец блок для 80 порта и основной блок (сокет или 443) с `client_header_buffer_size 16k` и `large_client_header_buffers 8 64k` — между маркерами `# >>> remnanode-setup …` и `# <<< remnanode-setup …`. Ваши настройки не удаляет |
| `/opt/remnanode/www/index.html` | заглушка. Название берётся из домена. Если там уже есть своя страница, скрипт сначала спросит |
| `/etc/letsencrypt/live/<домен>/` | сертификат |
| `/etc/letsencrypt/renewal-hooks/deploy/remnanode-nginx-reload.sh` | перезагрузка nginx после продления |
| `certbot.timer` или `/etc/cron.d/remnanode-certbot` | автопродление два раза в день |
| UFW | разрешает 22 и порт SSH (если он другой), 80, 443, публичные порты инбаундов ноды; порт ноды — только с IP панели. Правило «порт ноды открыт всем», если было, удаляет. Остальные правила не трогает. Если UFW был выключен — ставит «запрещать входящие по умолчанию» и включает |

**Что происходит с нодой:**
- **Режим eGames.** Если ноде добавлялся `/dev/shm`, в конце она один раз пересоздаётся: это несколько секунд простоя.
- **Режим документации.** Если 443 (или 80) держит Xray ноды, скрипт останавливает ноду перед запуском nginx на этом порту и в конце запускает обратно. Если что-то пошло не так, нода тоже запускается обратно.

Повторный запуск безопасен: уже добавленное не дублируется, готовый сертификат заново не выпускается, нода лишний раз не перезапускается.

Режим можно сменить повторным запуском с другим ответом: скрипт уберёт свой блок прошлого режима и добавит новый.

Если в `nginx.conf` уже есть ваш собственный `server` для этого домена, скрипт его не трогает и свои блоки не добавляет.

## Настройка в панели Remnawave

Готовые конфиги (инбаунды, хосты, xHTTP extra) — на сайте **[weavemarket-cdn.vercel.app](https://weavemarket-cdn.vercel.app)**: выберите там тот же режим, что и в скрипте.

Главное, чтобы совпадало:

- **Порт и путь XHTTP** — в nginx и в inbound одинаковые (по умолчанию `4443` и `/api/video/stream/`). Inbound слушает `127.0.0.1`, `security: none` — TLS снимает nginx.
- **Режим eGames** — REALITY на 443 с `"target": "/dev/shm/nginx.sock"`, `"xver": 1` и вашим доменом в `serverNames`.
- **Режим документации** — на 443 у ноды ничего нет: его занимает nginx.
- **Хост XHTTP** — адрес и SNI = ваш домен, порт `443`, `TLS`, mode `packet-up`.

## Проверка

```bash
curl -I https://ваш-домен                         # HTTP/2 200 — заглушка
docker exec remnanode-nginx nginx -T | grep -E 'server_name|listen'
certbot renew --dry-run                            # автопродление
# только режим eGames:
ls -l /dev/shm/nginx.sock                          # сокет nginx существует
docker exec remnanode ls -l /dev/shm/nginx.sock    # и виден внутри ноды
```

## Если что-то пошло не так

**`DNS problem: NXDOMAIN`**
У домена нет A-записи, или она ещё не разошлась. Проверьте: `dig +short ваш-домен @1.1.1.1` должен вернуть IP сервера.

**`Connection refused` при выпуске сертификата**
На 80 порту никто не отвечает. Проверьте `docker ps -a | grep nginx` и `ss -tlnp | grep ':80 '`, а также что 80/tcp открыт у хостера и в `ufw`.

**Режим eGames: домен не открывается или чужой сертификат**
- REALITY на 443 настроен не так: проверьте в профиле `target: /dev/shm/nginx.sock`, `xver: 1` и ваш домен в `serverNames`. Проверьте, что 443 вообще слушается: `ss -tlnp | grep ':443 '` должен показать `rw-core`.
- Xray не видит сокет: `docker exec remnanode ls -l /dev/shm/nginx.sock` должен показать файл. Если его нет, у ноды нет `/dev/shm:/dev/shm` в compose. Добавьте и пересоздайте ноду: `cd /opt/remnanode && docker compose up -d`.
- В логе nginx `broken header` — в REALITY не стоит `"xver": 1`.

**Режим документации: «Xray на ноде НЕ запустился» / нода offline**
В профиле ноды остался инбаунд на 443, а 443 теперь у nginx. Перенесите этот инбаунд на другой порт и откройте его: `ufw allow <порт>`. Либо запустите скрипт заново в режиме eGames, тогда 443 вернётся к Xray.

**`SSL_ERROR_UNRECOGNIZED_NAME_ALERT` в браузере**
nginx не нашёл блок для домена, который вы открыли.
- Убедитесь, что открываете ровно тот домен, а не IP.
- Если правили `nginx.conf` вручную через `sed -i`, vim или заменой файла, контейнер может видеть старую версию. Пересоздайте его: `cd /opt/remnanode && docker compose up -d --force-recreate nginx`.

**«nginx уже сейчас падает при запуске»**
В `nginx.conf` есть ошибка, которая была ещё до скрипта. Посмотрите `docker logs remnanode-nginx`, исправьте и запустите скрипт снова.

**Нода offline, а Xray не ругается**
Скорее всего, UFW не пускает панель: адрес панели указывает не на её сервер (например, домен за Cloudflare). Проверьте `ufw status` и при необходимости разрешите IP панели: `ufw allow from <IP панели> to any port 2222 proto tcp`.

**Новый инбаунд на публичном порту не подключается**
Скрипт открыл в UFW только порты, которые нода слушала во время установки. Откройте новый: `ufw allow <порт>`.

**«Порт 4443 уже слушается не только на 127.0.0.1»**
На этом порту висит что-то снаружи. Освободите порт или запустите скрипт с `--xhttp-port <другой порт>`. Этот же порт укажите в XHTTP-инбаунде.

**Нужно изменить path или порт**
Удалите в `nginx.conf` участок от `# >>> remnanode-setup sock <домен>` (или `https <домен>`) до соответствующего `# <<< …` и запустите скрипт заново с новыми значениями.

## Удаление

```bash
cd /opt/remnanode
docker rm -f remnanode-nginx
# уберите сервис nginx из docker-compose.yml (или верните docker-compose.yml.bak-<дата>)
# удалите блоки remnanode-setup из nginx.conf
# режим eGames: в профиле ноды верните REALITY обычный target (например, сайт-донор)
certbot delete --cert-name ваш-домен
rm -f /etc/letsencrypt/renewal-hooks/deploy/remnanode-nginx-reload.sh /etc/cron.d/remnanode-certbot
```

## Поддержка

Не получилось? Напишите в Telegram: **[@WeaveVPN_support](https://t.me/WeaveVPN_support)**. Приложите вывод скрипта и результат команд из раздела «Проверка».

## Лицензия

MIT
