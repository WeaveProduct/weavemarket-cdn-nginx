# weavemarket-cdn-nginx

Скрипт для ноды [Remnawave](https://docs.rw): ставит nginx за REALITY через unix-сокет, выпускает сертификат Let's Encrypt, проксирует XHTTP в Xray и настраивает UFW.

## Как это работает

```
клиент ──443──► Xray (REALITY)
                 ├─ свой клиент REALITY ─────────────► прокси
                 └─ всё остальное (браузер, CDN, сканер)
                      └─► unix:/dev/shm/nginx.sock (PROXY protocol)
                            └─► nginx: сайт-заглушка с настоящим сертификатом
                                  └─ /api/v1/stream/… ─► XHTTP-инбаунд 127.0.0.1:8443
```

- 443 держит Xray. nginx на 443 не слушает: он сидит на сокете `/dev/shm/nginx.sock` (`ssl proxy_protocol`, `http2 on`).
- Кто открывает домен в браузере, видит обычный сайт с валидным сертификатом.
- XHTTP-клиенты подключаются к домену по TLS на 443. Xray передаёт их в nginx, а nginx — в XHTTP-инбаунд.
- Порт 80 nginx держит для выпуска и продления сертификата.

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

1. **Домен** — для него настраивается nginx и выпускается сертификат.
2. **Path для XHTTP** — Enter оставляет `/api/v1/stream`.
3. **Домен или IP панели** — только с этого адреса будет разрешено подключение к ноде. Enter — не настраивать UFW.
4. **Порт ноды** — Enter оставляет значение из `docker-compose.yml` (обычно `2222`).
5. **Email** — нужен Let's Encrypt для выпуска сертификата.

В конце скрипт покажет инбаунды для панели и напишет «✅ Всё готово» или что осталось сделать в панели.

## Что нужно до запуска

- **Установленная нода.** Remnawave Node уже установлена [по документации](https://docs.rw/install/remnawave-node) в `/opt/remnanode`.
- **Система и права.** Debian или Ubuntu, запуск от root.
- **Домен.** A-запись домена указывает на IP этого сервера. В Cloudflare нужен режим **DNS only** (серое облако).
- **Порт 80.** Свободен на сервере и открыт у хостера: он нужен для сертификата.
- **Порт 8443.** Не занят снаружи: XHTTP-инбаунд слушает его на `127.0.0.1`.
- **Адрес панели.** Домен панели должен указывать прямо на сервер панели (без прокси Cloudflare), иначе UFW откроет порт ноды не тому IP и нода уйдёт в offline. Можно указать IP панели напрямую.

## Параметры

Все параметры необязательные. Если параметр не передан, скрипт спросит его сам.

| Параметр | Что задаёт | По умолчанию |
|---|---|---|
| `--domain DOMAIN` | домен для nginx и сертификата | — |
| `--path PATH` | path для XHTTP | `/api/v1/stream` |
| `--email EMAIL` | email для Let's Encrypt | — |
| `--panel ADDR` | домен или IP панели — только ей откроется порт ноды в UFW | — |
| `--node-port PORT` | порт ноды для связи с панелью | из `docker-compose.yml`, иначе `2222` |
| `--no-ufw` | не настраивать UFW | — |
| `--xhttp-port PORT` | порт XHTTP-инбаунда на `127.0.0.1` | `8443` |
| `--dir DIR` | каталог ноды | `/opt/remnanode` |
| `-y`, `--yes` | не задавать вопросов да/нет | — |

Пример запуска без вопросов:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/WeaveProduct/weavemarket-cdn-nginx/main/installer.sh) \
  --domain node.example.com --email you@example.com --panel panel.example.com -y
```

Без `--panel` в режиме без вопросов UFW не настраивается.

## Что скрипт меняет

| Где | Что |
|---|---|
| `/opt/remnanode/docker-compose.yml` | добавляет сервис `nginx` и монтирует `/dev/shm:/dev/shm` и в nginx, и в ноду: у каждого контейнера свой `/dev/shm`, и без общего маунта Xray не увидит сокет. Остальное не трогает, отступы берёт из файла, старую версию сохраняет как `docker-compose.yml.bak-<дата>` |
| `/opt/remnanode/nginx.conf` | дописывает в конец блок для 80 порта и блок для сокета между маркерами `# >>> remnanode-setup …` и `# <<< remnanode-setup …`. Ваши настройки не удаляет |
| `/opt/remnanode/www/index.html` | заглушка. Название берётся из домена. Если там уже есть своя страница, скрипт сначала спросит |
| `/etc/letsencrypt/live/<домен>/` | сертификат |
| `/etc/letsencrypt/renewal-hooks/deploy/remnanode-nginx-reload.sh` | перезагрузка nginx после продления |
| `certbot.timer` или `/etc/cron.d/remnanode-certbot` | автопродление два раза в день |
| UFW | разрешает 22 и порт SSH (если он другой), 80, 443, публичные порты инбаундов ноды; порт ноды — только с IP панели. Правило «порт ноды открыт всем», если было, удаляет. Остальные правила не трогает. Если UFW был выключен — ставит «запрещать входящие по умолчанию» и включает |
| `/opt/remnanode/remnawave-inbounds.json` | готовые инбаунды для панели |

Если ноде добавлялся `/dev/shm`, в конце она один раз пересоздаётся: это несколько секунд простоя.

Повторный запуск безопасен: уже добавленное не дублируется, готовый сертификат заново не выпускается, нода лишний раз не перезапускается.

Если в `nginx.conf` уже есть ваш собственный `server` для этого домена, скрипт его не трогает и свои блоки не добавляет.

**Переход с прошлой версии, где nginx слушал 443.** Скрипт сам убирает свой старый блок 443 для домена, переводит nginx на сокет и перезапускает ноду, чтобы Xray занял 443.

## Настройка в панели Remnawave

**1. Инбаунды в Config Profile ноды.** Скрипт печатает их в конце и сохраняет в `/opt/remnanode/remnawave-inbounds.json`.

```json
{
  "tag": "REALITY_SELFSTEAL",
  "listen": "0.0.0.0",
  "port": 443,
  "protocol": "vless",
  "settings": { "clients": [], "decryption": "none" },
  "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] },
  "streamSettings": {
    "network": "raw",
    "security": "reality",
    "realitySettings": {
      "target": "/dev/shm/nginx.sock",
      "xver": 1,
      "serverNames": ["node.example.com"],
      "privateKey": "СГЕНЕРИРУЙ_В_ПАНЕЛИ",
      "shortIds": [""]
    }
  }
},
{
  "tag": "XHTTP_NGINX",
  "listen": "127.0.0.1",
  "port": 8443,
  "protocol": "vless",
  "settings": { "clients": [], "decryption": "none" },
  "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] },
  "streamSettings": {
    "network": "xhttp",
    "security": "none",
    "xhttpSettings": { "path": "/api/v1/stream", "mode": "auto" }
  }
}
```

- `target: /dev/shm/nginx.sock` и `xver: 1` — именно так Xray отдаёт посторонний трафик в nginx.
- В `serverNames` — ваш домен.
- `privateKey` и `shortIds` сгенерируйте в панели.
- Если у ноды уже есть REALITY на 443, поменяйте в нём `target` и `xver` и добавьте домен в `serverNames`.

**2. Инбаунды на ноде и в скваде.** Включите оба инбаунда на ноде и добавьте их во внутренний сквад.

**3. Хосты**

- **REALITY:** адрес — ваш домен, порт `443`, SNI — ваш домен, fingerprint `chrome`.
- **XHTTP:** адрес — ваш домен, порт `443`, Security layer `TLS`, SNI — ваш домен, XHTTP mode `packet-up`.

## Проверка

```bash
curl -I https://ваш-домен                       # HTTP/2 200 — заглушка (через REALITY → nginx)
ls -l /dev/shm/nginx.sock                        # сокет nginx существует
docker exec remnanode ls -l /dev/shm/nginx.sock  # и виден внутри ноды
docker exec remnanode-nginx nginx -T | grep -E 'server_name|listen'
certbot renew --dry-run                          # автопродление
```

## Если что-то пошло не так

**`DNS problem: NXDOMAIN`**
У домена нет A-записи, или она ещё не разошлась. Проверьте: `dig +short ваш-домен @1.1.1.1` должен вернуть IP сервера.

**`Connection refused` при выпуске сертификата**
На 80 порту никто не отвечает. Проверьте `docker ps -a | grep nginx` и `ss -tlnp | grep ':80 '`, а также что 80/tcp открыт у хостера и в `ufw`.

**Домен не открывается или чужой сертификат**
- REALITY на 443 настроен не так: проверьте в профиле `target: /dev/shm/nginx.sock`, `xver: 1` и ваш домен в `serverNames`.
- Xray не видит сокет: `docker exec remnanode ls -l /dev/shm/nginx.sock` должен показать файл. Если его нет, у ноды нет `/dev/shm:/dev/shm` в compose. Добавьте и пересоздайте ноду: `cd /opt/remnanode && docker compose up -d`.

**`SSL_ERROR_UNRECOGNIZED_NAME_ALERT` в браузере**
nginx не нашёл блок для домена, который вы открыли.
- Убедитесь, что открываете ровно тот домен, а не IP.
- Если правили `nginx.conf` вручную через `sed -i`, vim или заменой файла, контейнер может видеть старую версию. Пересоздайте его: `cd /opt/remnanode && docker compose up -d --force-recreate nginx`.

**Xray на ноде не запускается («address already in use» на 443)**
443 занят чем-то ещё, например вашим собственным `listen 443` в `nginx.conf`. Скрипт предупреждает о таких строках. Уберите их или переведите на `listen unix:/dev/shm/nginx.sock ssl proxy_protocol;`.

**«nginx уже сейчас падает при запуске»**
В `nginx.conf` есть ошибка, которая была ещё до скрипта. Посмотрите `docker logs remnanode-nginx`, исправьте и запустите скрипт снова.

**Нода offline, а Xray не ругается**
Скорее всего, UFW не пускает панель: адрес панели указывает не на её сервер (например, домен за Cloudflare). Проверьте `ufw status` и при необходимости разрешите IP панели: `ufw allow from <IP панели> to any port 2222 proto tcp`.

**Новый инбаунд на публичном порту не подключается**
Скрипт открыл в UFW только порты, которые нода слушала во время установки. Откройте новый: `ufw allow <порт>`.

**«Порт 8443 уже слушается не только на 127.0.0.1»**
На 8443 висит что-то снаружи. Освободите порт или запустите скрипт с `--xhttp-port <другой порт>`. Этот же порт укажите в XHTTP-инбаунде.

**Нужно изменить path или порт**
Удалите в `nginx.conf` участок от `# >>> remnanode-setup sock <домен>` до `# <<< remnanode-setup sock <домен>` и запустите скрипт заново с новыми значениями.

## Удаление

```bash
cd /opt/remnanode
docker rm -f remnanode-nginx
# уберите сервис nginx из docker-compose.yml (или верните docker-compose.yml.bak-<дата>)
# удалите блоки remnanode-setup из nginx.conf
# в профиле ноды верните REALITY обычный target (например, сайт-донор)
certbot delete --cert-name ваш-домен
rm -f /etc/letsencrypt/renewal-hooks/deploy/remnanode-nginx-reload.sh /etc/cron.d/remnanode-certbot
```

## Поддержка

Не получилось? Напишите в Telegram: **[@WeaveVPN_support](https://t.me/WeaveVPN_support)**. Приложите вывод скрипта и результат команд из раздела «Проверка».

## Лицензия

MIT
