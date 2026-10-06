# weavemarket-cdn-nginx

Скрипт для ноды [Remnawave](https://docs.rw): ставит nginx на 443 порт, выпускает сертификат Let's Encrypt и проксирует XHTTP в Xray.

После запуска на ноде будет:

- `https://ваш-домен` — обычный сайт-заглушка с валидным сертификатом;
- `https://ваш-домен/api/v1/stream/…` — XHTTP, который nginx передаёт в инбаунд Xray на `127.0.0.1:8443`;
- автопродление сертификата.

## Быстрый старт

На сервере с нодой, от root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/WeaveProduct/weavemarket-cdn-nginx/main/installer.sh)
```

Если `raw.githubusercontent.com` недоступен с сервера, используйте зеркало:

```bash
bash <(curl -fsSL https://cdn.jsdelivr.net/gh/WeaveProduct/weavemarket-cdn-nginx@main/installer.sh)
```

Скрипт задаст три вопроса:

1. **Домен** — для него настраивается nginx и выпускается сертификат.
2. **Path для XHTTP** — Enter оставляет `/api/v1/stream`.
3. **Email** — нужен Let's Encrypt для выпуска сертификата.

В конце скрипт напишет «✅ Всё готово». Откройте свой домен в браузере: там должна быть заглушка.

## Что нужно до запуска

- **Установленная нода.** Remnawave Node уже установлена [по документации](https://docs.rw/install/remnawave-node) в `/opt/remnanode`.
- **Система и права.** Debian или Ubuntu, запуск от root.
- **Домен.** A-запись домена указывает на IP этого сервера. В Cloudflare нужен режим **DNS only** (серое облако).
- **Порты 80 и 443.** Свободны на сервере и открыты у хостера.
- **Порт 8443.** Не занят снаружи, например прямым REALITY. XHTTP-инбаунд должен слушать его на `127.0.0.1`.

## Параметры

Все параметры необязательные. Если параметр не передан, скрипт спросит его сам.

| Параметр | Что задаёт | По умолчанию |
|---|---|---|
| `--domain DOMAIN` | домен для nginx и сертификата | — |
| `--path PATH` | path для XHTTP | `/api/v1/stream` |
| `--email EMAIL` | email для Let's Encrypt | — |
| `--xhttp-port PORT` | порт XHTTP-инбаунда на `127.0.0.1` | `8443` |
| `--dir DIR` | каталог ноды | `/opt/remnanode` |
| `-y`, `--yes` | не задавать вопросов да/нет | — |

Пример запуска без вопросов:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/WeaveProduct/weavemarket-cdn-nginx/main/installer.sh) \
  --domain node.example.com --email you@example.com -y
```

## Что скрипт меняет

| Где | Что |
|---|---|
| `/opt/remnanode/docker-compose.yml` | добавляет сервис `nginx`. Остальное не трогает, отступы берёт из файла, старую версию сохраняет как `docker-compose.yml.bak-<дата>` |
| `/opt/remnanode/nginx.conf` | дописывает в конец блоки для 80 и 443 портов между маркерами `# >>> remnanode-setup …` и `# <<< remnanode-setup …`. Ваши настройки не удаляет |
| `/opt/remnanode/www/index.html` | заглушка. Если там уже есть своя страница, скрипт сначала спросит |
| `/etc/letsencrypt/live/<домен>/` | сертификат |
| `/etc/letsencrypt/renewal-hooks/deploy/remnanode-nginx-reload.sh` | перезагрузка nginx после продления |
| `certbot.timer` или `/etc/cron.d/remnanode-certbot` | автопродление два раза в день |

Повторный запуск безопасен: уже добавленное не дублируется, готовый сертификат заново не выпускается.

Если в `nginx.conf` уже есть ваш собственный `server` для этого домена, скрипт его не трогает и свои блоки не добавляет.

## Настройка в панели Remnawave

**1. Инбаунд в Config Profile**

```json
{
  "tag": "XHTTP_NGINX",
  "listen": "127.0.0.1",
  "port": 8443,
  "protocol": "vless",
  "settings": { "clients": [], "decryption": "none" },
  "streamSettings": {
    "network": "xhttp",
    "security": "none",
    "xhttpSettings": { "path": "/api/v1/stream", "mode": "auto" }
  },
  "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
}
```

`security: none` здесь правильно: TLS снимает nginx. Path и порт должны совпадать с тем, что вы указали скрипту.

**2. Инбаунд на ноде и в скваде.** Включите инбаунд на ноде и добавьте его во внутренний сквад.

**3. Хост**

- Адрес: ваш домен, порт `443`.
- Security layer: `TLS`, SNI — ваш домен, fingerprint `chrome`.
- XHTTP mode: `packet-up`.

## Проверка

```bash
curl -I https://ваш-домен                                        # HTTP/2 200 — заглушка
docker exec remnanode-nginx nginx -T | grep -E 'server_name|listen'   # что реально загрузил nginx
certbot renew --dry-run                                          # автопродление
```

## Если что-то пошло не так

**`DNS problem: NXDOMAIN`**
У домена нет A-записи, или она ещё не разошлась. Проверьте: `dig +short ваш-домен @1.1.1.1` должен вернуть IP сервера.

**`Connection refused` при выпуске сертификата**
На 80 порту никто не отвечает. Проверьте `docker ps -a | grep nginx` и `ss -tlnp | grep ':80 '`, а также что 80/tcp открыт у хостера и в `ufw`.

**`SSL_ERROR_UNRECOGNIZED_NAME_ALERT` в браузере**
nginx не нашёл блок 443 для домена, который вы открыли.
- Убедитесь, что открываете ровно тот домен, а не IP.
- Если правили `nginx.conf` вручную через `sed -i`, vim или заменой файла, контейнер может видеть старую версию. Пересоздайте его: `cd /opt/remnanode && docker compose up -d --force-recreate nginx`.

**«nginx уже сейчас падает при запуске»**
В `nginx.conf` есть ошибка, которая была ещё до скрипта, например блок 443 без сертификата. Посмотрите `docker logs remnanode-nginx`, исправьте и запустите скрипт снова.

**«Порт 8443 уже слушается не только на 127.0.0.1»**
На 8443 висит что-то снаружи. Освободите порт или запустите скрипт с `--xhttp-port <другой порт>`. Этот же порт укажите в инбаунде.

**Нужно изменить path или порт**
Удалите в `nginx.conf` участок от `# >>> remnanode-setup https <домен>` до `# <<< remnanode-setup https <домен>` и запустите скрипт заново с новыми значениями.

## Удаление

```bash
cd /opt/remnanode
docker rm -f remnanode-nginx
# уберите сервис nginx из docker-compose.yml (или верните docker-compose.yml.bak-<дата>)
# удалите блоки remnanode-setup из nginx.conf
certbot delete --cert-name ваш-домен
rm -f /etc/letsencrypt/renewal-hooks/deploy/remnanode-nginx-reload.sh /etc/cron.d/remnanode-certbot
```

## Поддержка

Не получилось? Напишите в Telegram: **[@WeaveVPN_support](https://t.me/WeaveVPN_support)**. Приложите вывод скрипта и результат команд из раздела «Проверка».

## Лицензия

MIT
