#!/usr/bin/env bash
# installer.sh (weavemarket-cdn-nginx) — nginx на 443 (TLS) + сертификат Let's Encrypt + XHTTP + UFW для Remnawave Node
#
# Запуск на сервере с нодой, от root:
#   bash <(curl -fsSL https://raw.githubusercontent.com/SikWeet/weavemarket-cdn-nginx/main/installer.sh)
#
# Скрипт спросит домен, path для XHTTP, адрес панели и порт ноды, затем:
#   1. добавит сервис nginx в /opt/remnanode/docker-compose.yml (остальное не трогает, отступы как в файле)
#   2. допишет в конец /opt/remnanode/nginx.conf блок для 80 порта и запустит nginx
#   3. настроит UFW: 22 (SSH), 80, 443, порты инбаундов ноды; порт ноды — только для панели
#   4. спросит email и выпустит сертификат через certbot (webroot)
#   5. допишет блок для 443 порта: сайт + проксирование XHTTP на 127.0.0.1:8443
#      (если 443 сейчас держит Xray ноды — остановит ноду на время настройки и запустит обратно)
#   6. включит автопродление сертификатов (с перезагрузкой nginx после продления)
#   7. создаст заглушку /opt/remnanode/www/index.html
#
# Повторный запуск безопасен: уже добавленное не дублируется, чужие настройки не трогаются.
# Без вопросов:
#   bash <(curl -fsSL https://raw.githubusercontent.com/SikWeet/weavemarket-cdn-nginx/main/installer.sh) \
#     --domain node.example.com --email you@example.com --panel panel.example.com -y

set -Eeuo pipefail

# ─── Настройки ───────────────────────────────────────────────────────────────
INSTALL_DIR="/opt/remnanode"
DOMAIN="" XHTTP_PATH="" EMAIL="" PANEL_ADDR="" NODE_PORT=""
XHTTP_PORT="8443"
ASSUME_YES=0 NO_UFW=0

DEFAULT_PATH="/api/v1/stream"
DEFAULT_NODE_PORT="2222"
NGINX_IMAGE="nginx:1.30-alpine"
CONTAINER="remnanode-nginx"
LE_DIR="/etc/letsencrypt"
SUPPORT="@WeaveVPN_support"
MARK="remnanode-setup"
HTML_MARK="<!-- remnanode-nginx-setup -->"
INSTALL_CMD="bash <(curl -fsSL https://raw.githubusercontent.com/SikWeet/weavemarket-cdn-nginx/main/installer.sh)"

TTY="" HAS_IPV6=0 RECREATE=0 SKIP_BLOCKS=0 ADD_DEFAULT=0 ROLLBACK_SIZE=0
NODE_PROJECT="" NODE_NAMES="" NODE_START_TS="" NODE_BIND_FAIL=0
NODE_HOLDS=() NODE_STOPPED=() NODE_RESTARTED=() NODE_PUBLIC_PORTS=() PANEL_IPS=() UFW_SUMMARY=()

# ─── Вывод ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_G=$'\033[1;32m' C_Y=$'\033[1;33m' C_R=$'\033[1;31m' C_B=$'\033[1m' C_0=$'\033[0m'
else
  C_G="" C_Y="" C_R="" C_B="" C_0=""
fi
log()  { printf '%s[+]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  {
  printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2
  printf '    Не получается? Напиши в поддержку: %s\n' "$SUPPORT" >&2
  exit 1
}
hdr()  { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0"; }
trap 'die "Ошибка на строке $LINENO: $BASH_COMMAND"' ERR

usage() {
  cat <<EOF
Использование (от root):
  ${INSTALL_CMD}
  (всё спросит сам)

Параметры (необязательные — чтобы не отвечать на вопросы):
  --domain DOMAIN      домен для настройки и сертификата
  --path PATH          path для XHTTP (по умолчанию ${DEFAULT_PATH})
  --email EMAIL        email для Let's Encrypt
  --panel ADDR         домен или IP панели — только ей будет открыт порт ноды в UFW
  --node-port PORT     порт ноды для связи с панелью (по умолчанию из docker-compose.yml, иначе ${DEFAULT_NODE_PORT})
  --no-ufw             не настраивать UFW
  --xhttp-port PORT    порт XHTTP-инбаунда на 127.0.0.1 (по умолчанию 8443)
  --dir DIR            каталог ноды (по умолчанию /opt/remnanode)
  -y, --yes            не задавать вопросов да/нет (берутся ответы по умолчанию)
  -h, --help           эта справка
EOF
}

# ─── Утилиты ─────────────────────────────────────────────────────────────────
trim()  { local s=$1; s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}; printf '%s' "$s"; }
stamp() { date +%Y%m%d-%H%M%S; }
rand_hex() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }

init_tty() { if { : <>/dev/tty; } 2>/dev/null; then TTY=/dev/tty; fi; }

# ask VAR "Вопрос" [по умолчанию] — если VAR уже задан параметром, ничего не спрашивает
ask() {
  local __var=$1 __q=$2 __def=${3:-} __ans=""
  [[ -z ${!__var:-} ]] || return 0
  if [[ -z $TTY ]]; then
    [[ -n $__def ]] || die "Не задано: $__q. Без терминала передай это параметром (см. --help)"
    printf -v "$__var" '%s' "$__def"
    return 0
  fi
  if [[ -n $__def ]]; then printf '%s [%s]: ' "$__q" "$__def" >"$TTY"
  else printf '%s: ' "$__q" >"$TTY"; fi
  IFS= read -r __ans <"$TTY" || true
  __ans=$(trim "$__ans")
  printf -v "$__var" '%s' "${__ans:-$__def}"
}

# confirm_yn "Вопрос" y|n — 0 = да. Без терминала или с -y берётся ответ по умолчанию.
confirm_yn() {
  local q=$1 def=${2:-n} a="" hint="y/N"
  if (( ASSUME_YES )) || [[ -z $TTY ]]; then [[ $def == y ]]; return; fi
  if [[ $def == y ]]; then hint="Y/n"; fi
  printf '%s [%s] ' "$q" "$hint" >"$TTY"
  IFS= read -r a <"$TTY" || true
  a=$(trim "${a,,}")
  case ${a:-$def} in y|yes|д|да) return 0 ;; *) return 1 ;; esac
}

retry_or_die() { [[ -n $TTY ]] || die "$1"; warn "$1 — попробуй ещё раз"; }

# apt-get с ожиданием: на свежем сервере apt часто занят автообновлениями (unattended-upgrades)
apt_run() {
  local out start=$SECONDS said=0
  while :; do
    if out=$(DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=60 "$@" 2>&1); then return 0; fi
    if grep -qiE 'could not get lock|unable to acquire|another process using it' <<<"$out"; then
      if (( ! said )); then log "apt занят — система ставит обновления. Жду, пока закончит (до 15 минут)…"; said=1; fi
      (( SECONDS - start < 900 )) \
        || die "apt занят больше 15 минут. Дождись окончания обновлений (или перезагрузи сервер) и запусти скрипт снова"
      sleep 10
      continue
    fi
    printf '%s\n' "$out" | tail -n 15 >&2 || true
    return 1
  done
}

apt_install() {
  command -v apt-get >/dev/null 2>&1 || die "Нет apt-get — установи вручную: $*"
  log "Устанавливаю: $*"
  apt_run update -qq || die "Не сработал apt-get update (вывод выше)"
  apt_run install -y -qq "$@" || die "Не удалось установить: $* (вывод выше)"
}

# Всё нужное ставим сразу, до любых изменений на сервере
install_deps() {
  local pkgs=()
  command -v certbot >/dev/null 2>&1 || pkgs+=(certbot)
  if (( ! NO_UFW )); then command -v ufw >/dev/null 2>&1 || pkgs+=(ufw); fi
  (( ${#pkgs[@]} )) || return 0
  apt_install "${pkgs[@]}"
}

is_domain() { local re='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9-]{2,63}$'; [[ $1 =~ $re ]]; }
is_email()  { local re='^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'; [[ $1 =~ $re ]]; }
is_path()   { local re='^/[A-Za-z0-9._~/-]+$'; [[ $1 =~ $re && $1 != *//* ]]; }
is_ipv4()   { local re='^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; [[ $1 =~ $re ]]; }
is_port()   { [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
norm_path() {
  local p; p=$(trim "$1")
  [[ $p == /* ]] || p="/$p"
  while [[ $p == */ && $p != / ]]; do p=${p%/}; done
  printf '%s' "$p"
}

# Значение переменной из docker-compose.yml / .env ("- KEY=val", "KEY: val", "KEY=val"); пусто — не нашлось
extract_var() {
  local name=$1 f v=""; shift
  for f in "$@"; do
    [[ -r $f ]] || continue
    v=$(sed -nE "/^[[:space:]]*(-[[:space:]]*)?${name}[[:space:]]*[=:]/{s/^[^=:]*[=:][[:space:]]*//;p;q;}" "$f" 2>/dev/null || true)
    v=$(trim "${v%$'\r'}")
    v=${v#\"}; v=${v%\"}; v=${v#\'}; v=${v%\'}
    [[ -z $v ]] || break
  done
  printf '%s' "$v"
}

container_exists()  { docker inspect "$CONTAINER" >/dev/null 2>&1; }
container_running() { [[ $(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true) == true ]]; }
container_project() { docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "${1:-$CONTAINER}" 2>/dev/null || true; }
compose_project()   { docker compose -f "$COMPOSE" config 2>/dev/null | sed -n '/^name:/{s/^name:[[:space:]]*//p;q;}' || true; }
cert_exists()       { [[ -s $LE_DIR/live/$DOMAIN/fullchain.pem && -s $LE_DIR/live/$DOMAIN/privkey.pem ]]; }
cert_end() {
  if command -v openssl >/dev/null 2>&1; then
    openssl x509 -enddate -noout -in "$LE_DIR/live/$DOMAIN/fullchain.pem" 2>/dev/null | cut -d= -f2 || true
  fi
}

# ─── Кто держит порт ─────────────────────────────────────────────────────────
# PID → имя docker-контейнера, в котором работает процесс (пусто — процесс не из контейнера)
container_of_pid() {
  local p=$1 anc=" " n=0 cpid name
  while [[ -n $p && $p != 0 && $p != 1 && $n -lt 40 ]]; do
    anc+="$p "
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ' || true)
    n=$((n + 1))
  done
  while read -r cpid name; do
    if [[ -n $cpid && $cpid != 0 && $anc == *" $cpid "* ]]; then printf '%s' "${name#/}"; return 0; fi
  done < <(docker ps -q 2>/dev/null | xargs -r docker inspect -f '{{.State.Pid}} {{.Name}}' 2>/dev/null || true)
  return 0
}

# Контейнер ноды: из того же compose-проекта, что и /opt/remnanode, и это не наш nginx
is_node_container() {
  local name=$1 proj
  [[ -n $name && $name != "$CONTAINER" ]] || return 1
  [[ $name == remnanode ]] && return 0
  proj=$(container_project "$name")
  [[ -n $proj && $proj == "$NODE_PROJECT" ]]
}

# free | ours | node:<контейнеры> | foreign:<кто>
port_status() {
  local port=$1 line pids pid c node="" foreign="" comm
  line=$(ss -Htlnp "sport = :$port" 2>/dev/null || true)
  [[ -n $line ]] || { echo free; return 0; }
  pids=$(grep -o 'pid=[0-9]*' <<<"$line" | cut -d= -f2 | sort -u || true)
  [[ -n $pids ]] || { echo "foreign:неизвестный процесс"; return 0; }
  for pid in $pids; do
    c=$(container_of_pid "$pid")
    if [[ $c == "$CONTAINER" ]]; then
      continue
    elif is_node_container "$c"; then
      [[ " $node " == *" $c "* ]] || node+=" $c"
    else
      comm=$(ps -o comm= -p "$pid" 2>/dev/null || true)
      foreign+=" ${comm:-pid $pid}${c:+ (контейнер $c)}"
    fi
  done
  if [[ -n $foreign ]]; then echo "foreign:$(trim "$foreign")"
  elif [[ -n $node ]]; then echo "node:$(trim "$node")"
  else echo ours; fi
}

# Публичные порты, которые слушает нода (её инбаунды), — чтобы открыть их в UFW
collect_node_ports() {
  local flag proto line addr port pid c
  for proto in tcp udp; do
    if [[ $proto == tcp ]]; then flag=-Htlnp; else flag=-Hulnp; fi
    while IFS= read -r line; do
      [[ -n $line ]] || continue
      addr=$(awk '{print $4}' <<<"$line")
      port=${addr##*:}
      case $addr in 127.*|\[::1\]:*|::1:*) continue ;; esac
      case $port in 80|443|"$NODE_PORT"|"$XHTTP_PORT") continue ;; esac
      pid=$(grep -o 'pid=[0-9]*' <<<"$line" | cut -d= -f2 | sed -n 1p || true)
      [[ -n $pid ]] || continue
      c=$(container_of_pid "$pid")
      is_node_container "$c" || continue
      [[ " ${NODE_PUBLIC_PORTS[*]-} " == *" $port/$proto "* ]] || NODE_PUBLIC_PORTS+=("$port/$proto")
    done < <(ss "$flag" 2>/dev/null || true)
  done
}

# ─── Остановка / запуск ноды ─────────────────────────────────────────────────
stop_node() {
  (( ${#NODE_HOLDS[@]} )) || return 0
  (( ${#NODE_STOPPED[@]} == 0 )) || return 0
  local n _ p busy
  for n in $NODE_NAMES; do
    log "Останавливаю ноду ($n) — порт ${NODE_HOLDS[*]} нужен nginx"
    docker stop -t 20 "$n" >/dev/null
    NODE_STOPPED+=("$n")
  done
  for _ in $(seq 1 15); do
    busy=0
    for p in "${NODE_HOLDS[@]}"; do
      case $(port_status "$p") in free|ours) ;; *) busy=1 ;; esac
    done
    (( busy )) || return 0
    sleep 1
  done
  die "Нода остановлена, но порт ${NODE_HOLDS[*]} всё ещё занят"
}

start_node() {
  (( ${#NODE_STOPPED[@]} )) || return 0
  local n
  NODE_START_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  for n in "${NODE_STOPPED[@]}"; do
    if docker start "$n" >/dev/null 2>&1; then
      log "Нода ($n) снова запущена"
      NODE_RESTARTED+=("$n")
    else
      warn "Не смог запустить ноду ($n) — запусти вручную: docker start $n"
    fi
  done
  NODE_STOPPED=()
}

# После запуска: поднялся ли Xray или упал на занятом порту
check_node_after_start() {
  (( ${#NODE_RESTARTED[@]} )) || return 0
  local _ n logs
  log "Жду, пока нода получит конфиг от панели (до 30 секунд)…"
  for _ in $(seq 1 15); do
    sleep 2
    for n in "${NODE_RESTARTED[@]}"; do
      logs=$(docker logs --since "$NODE_START_TS" "$n" 2>&1 || true)
      if grep -qiE 'address already in use' <<<"$logs"; then NODE_BIND_FAIL=1; return 0; fi
    done
  done
}

# При любом выходе (в том числе по ошибке) — вернуть ноду
on_exit() {
  local rc=$?
  trap - ERR
  set +e
  if (( ${#NODE_STOPPED[@]} )); then
    warn "Возвращаю ноду…"
    start_node
  fi
  exit "$rc"
}

# ─── docker-compose.yml ──────────────────────────────────────────────────────
# Отступы в compose: "S U L HAS_NGINX FOUND"
#   S — отступ имён сервисов, U — шаг до их ключей, L — отступ элементов списка от ключа
compose_layout() {
  awk '
    BEGIN { S = -1; U = -1; L = -1; nginx = 0; found = 0; insvc = 0; lastkey = -1 }
    /^[ \t]*$/ { next }
    /^[ \t]*#/ { next }
    /^[^ ]/    { insvc = ($0 ~ /^services:[ \t]*(#.*)?$/); if (insvc) found = 1; next }
    !insvc     { next }
    {
      match($0, /^ */); ind = RLENGTH
      item = ($0 ~ /^ *-( |$)/)
      if (S < 0) S = ind
      if (ind == S && !item) {
        k = $0; sub(/^ +/, "", k); sub(/[ \t]*:.*$/, "", k); gsub(/["\047]/, "", k)
        if (k == "nginx") nginx = 1
        lastkey = ind; next
      }
      if (!item) { if (U < 0 && ind > S) U = ind - S; lastkey = ind; next }
      if (L < 0 && lastkey >= 0) L = ind - lastkey
    }
    END {
      if (S < 0) S = 2
      if (U < 1) U = 2
      if (L < 0) L = U
      print S, U, L, nginx, found
    }
  ' "$1"
}

gen_compose_block() { # S U L
  local s k i
  s=$(printf '%*s' "$1" '')
  k=$(printf '%*s' "$(( $1 + $2 ))" '')
  i=$(printf '%*s' "$(( $1 + $2 + $3 ))" '')
  cat <<EOF
${s}nginx:
${k}image: ${NGINX_IMAGE}
${k}container_name: ${CONTAINER}
${k}restart: always
${k}network_mode: host
${k}volumes:
${i}- ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
${i}- ${LE_DIR}:${LE_DIR}:ro
${i}- ./www:/var/www/html:ro
EOF
}

# Вставить блок в конец секции services: (перед следующим ключом верхнего уровня или в конец файла)
compose_insert() { # FILE BLOCKFILE
  awk -v bf="$2" '
    BEGIN { while ((getline line < bf) > 0) blk = blk line "\n"; close(bf); insvc = 0; done = 0; last = "" }
    /^[^ \t#]/ {
      if (insvc && !done) { printf "%s\n", blk; done = 1 }
      insvc = ($0 ~ /^services:[ \t]*(#.*)?$/)
    }
    { print; last = $0 }
    END {
      if (!done) { if (last !~ /^[ \t]*$/) print ""; printf "%s", blk }
    }
  ' "$1"
}

compose_add_nginx() {
  local re="^[[:space:]]*container_name:[[:space:]]*[\"']?${CONTAINER}[\"']?[[:space:]]*(#.*)?\$"
  if grep -Eq "$re" "$COMPOSE"; then
    log "Сервис nginx уже есть в $COMPOSE — не трогаю"
    return 0
  fi
  local s u l has_nginx found blockf tmp bak
  read -r s u l has_nginx found < <(compose_layout "$COMPOSE")
  [[ $found == 1 ]] || die "В $COMPOSE не нашёл секцию services:"
  [[ $has_nginx == 0 ]] || die "В $COMPOSE уже есть другой сервис с именем nginx — переименуй его и запусти скрипт снова"

  blockf=$(mktemp); tmp=$(mktemp)
  gen_compose_block "$s" "$u" "$l" >"$blockf"
  bak="$COMPOSE.bak-$(stamp)"
  cp -a "$COMPOSE" "$bak"
  compose_insert "$COMPOSE" "$blockf" >"$tmp"
  cat "$tmp" >"$COMPOSE"
  rm -f "$tmp" "$blockf"

  if ! docker compose -f "$COMPOSE" config -q >/dev/null 2>&1; then
    cat "$bak" >"$COMPOSE"
    die "После добавления nginx файл $COMPOSE перестал проходить проверку — вернул как было"
  fi
  log "Добавил сервис nginx в $COMPOSE (копия старого: $bak)"
}

# ─── nginx.conf ──────────────────────────────────────────────────────────────
prepare_dirs() {
  mkdir -p "$WWW_DIR/.well-known/acme-challenge"
  chmod 755 "$WWW_DIR" "$WWW_DIR/.well-known" "$WWW_DIR/.well-known/acme-challenge"
  if [[ -d $NGINX_CONF ]]; then
    # docker создаёт папку на месте отсутствующего файла
    rmdir "$NGINX_CONF" 2>/dev/null \
      || die "$NGINX_CONF — папка, а должен быть файл. Перенеси её содержимое и запусти скрипт снова"
    warn "$NGINX_CONF был пустой папкой (её создаёт docker, когда файла нет) — заменил на файл"
    RECREATE=1
  fi
  [[ -f $NGINX_CONF ]] || : >"$NGINX_CONF"
}

prepare_container() {
  container_exists || return 0
  local have
  have=$(container_project)
  if [[ -n $NODE_PROJECT && $have != "$NODE_PROJECT" ]]; then
    log "Контейнер $CONTAINER создан не из $COMPOSE — пересоздаю"
    docker rm -f "$CONTAINER" >/dev/null
    return 0
  fi
  if [[ $(docker inspect -f '{{.State.Restarting}}' "$CONTAINER" 2>/dev/null || true) == true ]]; then
    docker logs --tail 10 "$CONTAINER" >&2 2>&1 || true
    die "nginx уже сейчас падает при запуске (лог выше) — сначала исправь $NGINX_CONF"
  fi
}

# Есть ли в nginx.conf пользовательский (не наш) server для этого домена
user_conf_has_domain() {
  local stripped re
  stripped=$(awk -v t="# >>> $MARK " -v e="# <<< $MARK " '
    index($0, t) == 1 { skip = 1 }
    !skip && $0 !~ /^[ \t]*#/ { print }
    index($0, e) == 1 { skip = 0 }
  ' "$NGINX_CONF")
  re="server_name[^;]*[[:space:]]${DOMAIN//./\\.}([[:space:]]|;)"
  grep -Eq "$re" <<<"$stripped"
}

has_default_443() {
  local re='listen[[:space:]]+([^;[:space:]]*:)?443[^;]*default_server'
  grep -Eq "$re" "$NGINX_CONF"
}

# Нужен ли nginx порт PORT по текущему nginx.conf
conf_listens() {
  [[ $1 == 80 ]] && return 0
  grep -Eq "^[^#]*listen[[:space:]]+([^;[:space:]]*:)?$1([^0-9]|\$)" "$NGINX_CONF"
}

gen_http_block() {
  local v6=""
  if (( HAS_IPV6 )); then v6=$'\n    listen [::]:80;'; fi
  cat <<EOF
# >>> ${MARK} http ${DOMAIN}
server {
    listen 80;${v6}
    server_name ${DOMAIN};

    # проверка домена для Let's Encrypt
    location /.well-known/acme-challenge/ { root /var/www/html; }

    location / { return 301 https://\$host\$request_uri; }
}
# <<< ${MARK} http ${DOMAIN}
EOF
}

gen_default_block() {
  local v6=""
  if (( HAS_IPV6 )); then v6=$'\n    listen [::]:443 ssl default_server;'; fi
  cat <<EOF

# Запросы не на наши домены (сканеры по IP и т.п.) — обрываем на TLS-рукопожатии
server {
    listen 443 ssl default_server;${v6}
    server_name _;
    ssl_reject_handshake on;
}
EOF
}

gen_https_block() {
  local v6="" def=""
  if (( HAS_IPV6 )); then v6=$'\n    listen [::]:443 ssl;'; fi
  if (( ADD_DEFAULT )); then def=$(gen_default_block); fi
  cat <<EOF
# >>> ${MARK} https ${DOMAIN}
server {
    listen 443 ssl;${v6}
    http2 on;
    server_name ${DOMAIN};

    ssl_certificate     ${LE_DIR}/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key ${LE_DIR}/live/${DOMAIN}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:remnanode_ssl:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    root  /var/www/html;
    index index.html;

    client_header_timeout 5m;
    keepalive_timeout     5m;

    # XHTTP -> инбаунд Xray на 127.0.0.1:${XHTTP_PORT} (HTTP/1.1, режим packet-up)
    location ${XHTTP_PATH}/ {
        proxy_pass http://127.0.0.1:${XHTTP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 900s;
        proxy_send_timeout 900s;
        client_max_body_size 0;
    }
}${def}
# <<< ${MARK} https ${DOMAIN}
EOF
}

# Дописать блок в конец nginx.conf. 0 — дописал, 1 — такой блок уже был.
append_block() { # KIND GENERATOR
  local kind=$1 gen=$2
  if grep -Fqx "# >>> $MARK $kind $DOMAIN" "$NGINX_CONF"; then return 1; fi
  ROLLBACK_SIZE=$(stat -c %s "$NGINX_CONF")
  {
    if [[ -n $(tail -c1 "$NGINX_CONF") ]]; then echo; fi
    if (( ROLLBACK_SIZE > 0 )); then echo; fi
    "$gen"
  } >>"$NGINX_CONF"
  return 0
}

# Убрать только что дописанный блок (truncate сохраняет файл, который смонтирован в контейнер)
rollback() { truncate -s "$ROLLBACK_SIZE" "$NGINX_CONF"; }

wait_http() {
  local _
  for _ in $(seq 1 20); do
    if curl -s -o /dev/null --max-time 2 --resolve "$DOMAIN:80:127.0.0.1" "http://$DOMAIN/"; then return 0; fi
    sleep 1
  done
  return 1
}

# Освободить для nginx порты, которые держит нода (только те, что nginx реально слушает)
free_ports_for_nginx() {
  local p
  for p in ${NODE_HOLDS[@]+"${NODE_HOLDS[@]}"}; do
    if conf_listens "$p"; then stop_node; return 0; fi
  done
}

# Применить nginx.conf: перечитать работающий nginx или запустить контейнер.
# nginx_up 1 — при ошибке убрать только что дописанный блок.
nginx_up() {
  local rb=${1:-0} out extra=()
  free_ports_for_nginx
  if container_running && (( ! RECREATE )); then
    if ! out=$(docker exec "$CONTAINER" nginx -t 2>&1); then
      printf '%s\n' "$out" | tail -n 5 >&2 || true
      if (( rb )); then rollback; die "nginx не принял новый блок — убрал его из $NGINX_CONF"; fi
      die "nginx не принимает $NGINX_CONF (ошибка выше)"
    fi
    docker exec "$CONTAINER" nginx -s reload >/dev/null 2>&1 || true
    sleep 1
  else
    if (( RECREATE )); then extra=(--force-recreate); fi
    if ! out=$(docker compose -f "$COMPOSE" up -d ${extra[@]+"${extra[@]}"} nginx 2>&1); then
      printf '%s\n' "$out" >&2
      if (( rb )); then rollback; fi
      die "Не удалось запустить nginx через docker compose"
    fi
    RECREATE=0
  fi
  if ! wait_http; then
    docker logs --tail 15 "$CONTAINER" >&2 2>&1 || true
    if (( rb )); then rollback; die "nginx не поднялся на 80 порту (лог выше) — новый блок убрал из $NGINX_CONF"; fi
    die "nginx не поднялся на 80 порту (лог выше)"
  fi
}

# nginx действительно слушает 443 (а не остался на старом конфиге из-за занятого порта)
wait_443() {
  local _
  for _ in $(seq 1 10); do
    [[ $(port_status 443) == ours ]] && return 0
    sleep 1
  done
  docker logs --tail 10 "$CONTAINER" >&2 2>&1 || true
  die "nginx не смог занять 443 порт (лог выше): $(port_status 443)"
}

selftest_challenge() {
  local token got dir="$WWW_DIR/.well-known/acme-challenge"
  token="selftest-$(rand_hex 8)"
  printf '%s' "$token" >"$dir/$token"
  chmod 644 "$dir/$token"
  got=$(curl -fsS --max-time 5 --resolve "$DOMAIN:80:127.0.0.1" "http://$DOMAIN/.well-known/acme-challenge/$token" 2>/dev/null || true)
  rm -f "$dir/$token"
  [[ $got == "$token" ]] || die "nginx не отдаёт файлы проверки из $dir — без этого сертификат не выпустится"
}

# ─── Шаги ────────────────────────────────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --domain|--path|--email|--panel|--node-port|--xhttp-port|--dir)
        [[ $# -ge 2 && -n ${2:-} ]] || die "Параметру $1 нужно значение"
        case $1 in
          --domain)     DOMAIN=$2 ;;
          --path)       XHTTP_PATH=$2 ;;
          --email)      EMAIL=$2 ;;
          --panel)      PANEL_ADDR=$2 ;;
          --node-port)  NODE_PORT=$2 ;;
          --xhttp-port) XHTTP_PORT=$2 ;;
          --dir)        INSTALL_DIR=${2%/} ;;
        esac
        shift 2 ;;
      --no-ufw)  NO_UFW=1; shift ;;
      -y|--yes)  ASSUME_YES=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Неизвестный параметр: $1 (см. --help)" ;;
    esac
  done
  COMPOSE="$INSTALL_DIR/docker-compose.yml"
  NGINX_CONF="$INSTALL_DIR/nginx.conf"
  WWW_DIR="$INSTALL_DIR/www"
  is_port "$XHTTP_PORT" || die "Некорректный --xhttp-port: $XHTTP_PORT"
  XHTTP_PORT=$(( 10#$XHTTP_PORT ))
  if [[ -n $NODE_PORT ]]; then is_port "$NODE_PORT" || die "Некорректный --node-port: $NODE_PORT"; fi
}

preflight() {
  (( EUID == 0 )) || die "Нужны права root: выполни «sudo -i» и запусти команду установки ещё раз"
  [[ -f $COMPOSE ]] || die "Не найден $COMPOSE — сначала установи Remnawave Node: https://docs.rw/install/remnawave-node"
  command -v docker >/dev/null 2>&1 || die "Не найден docker — сначала установи Remnawave Node: https://docs.rw/install/remnawave-node"
  docker compose version >/dev/null 2>&1 || die "Не найден docker compose (пакет docker-compose-plugin)"
  command -v curl >/dev/null 2>&1 || apt_install curl ca-certificates
  command -v ss   >/dev/null 2>&1 || apt_install iproute2
  if [[ -s /proc/net/if_inet6 ]]; then HAS_IPV6=1; fi
  NODE_PROJECT=$(compose_project)
}

ask_domain() {
  while :; do
    ask DOMAIN "Домен для настройки и сертификата (например node.example.com)"
    DOMAIN=${DOMAIN,,}; DOMAIN=${DOMAIN#http://}; DOMAIN=${DOMAIN#https://}; DOMAIN=${DOMAIN%%/*}
    if is_domain "$DOMAIN"; then return 0; fi
    retry_or_die "Некорректный домен: '$DOMAIN'"
    DOMAIN=""
  done
}

ask_path() {
  while :; do
    ask XHTTP_PATH "Path для XHTTP" "$DEFAULT_PATH"
    XHTTP_PATH=$(norm_path "$XHTTP_PATH")
    if is_path "$XHTTP_PATH"; then return 0; fi
    retry_or_die "Некорректный path: '$XHTTP_PATH' (латиница, цифры, . _ ~ - /)"
    XHTTP_PATH=""
  done
}

ask_email() {
  while :; do
    ask EMAIL "Email для выпуска сертификата (Let's Encrypt)"
    EMAIL=$(trim "$EMAIL")
    if is_email "$EMAIL"; then return 0; fi
    retry_or_die "Некорректный email: '$EMAIL'"
    EMAIL=""
  done
}

# IP панели по домену или IP. 0 — нашлись.
resolve_panel() {
  local a=$1 ip
  PANEL_IPS=()
  if is_ipv4 "$a" || [[ $a == *:* ]]; then PANEL_IPS=("$a"); return 0; fi
  is_domain "$a" || return 1
  while read -r ip; do
    [[ -n $ip ]] && PANEL_IPS+=("$ip")
  done < <(getent ahosts "$a" 2>/dev/null | awk '{print $1}' | sort -u || true)
  (( ${#PANEL_IPS[@]} ))
}

ask_ufw() {
  (( NO_UFW )) && return 0
  if [[ -z $PANEL_ADDR && -z $TTY ]]; then
    warn "UFW не настраиваю: не задан адрес панели (--panel)"
    NO_UFW=1
    return 0
  fi
  local def_port
  def_port=$(extract_var NODE_PORT "$COMPOSE" "$INSTALL_DIR/.env")
  is_port "${def_port:-x}" || def_port=$DEFAULT_NODE_PORT

  while :; do
    ask PANEL_ADDR "Домен или IP панели, которая подключается к ноде (Enter — не настраивать UFW)"
    PANEL_ADDR=$(trim "${PANEL_ADDR,,}")
    PANEL_ADDR=${PANEL_ADDR#http://}; PANEL_ADDR=${PANEL_ADDR#https://}; PANEL_ADDR=${PANEL_ADDR%%/*}
    if [[ -z $PANEL_ADDR ]]; then
      warn "UFW не настраиваю — адрес панели не указан"
      NO_UFW=1
      return 0
    fi
    if resolve_panel "$PANEL_ADDR"; then break; fi
    retry_or_die "Не получилось определить IP панели по '$PANEL_ADDR'"
    PANEL_ADDR=""
  done
  log "Панель: $PANEL_ADDR → ${PANEL_IPS[*]}"

  while :; do
    ask NODE_PORT "Порт ноды для связи с панелью (NODE_PORT)" "$def_port"
    if is_port "$NODE_PORT"; then NODE_PORT=$(( 10#$NODE_PORT )); return 0; fi
    retry_or_die "Некорректный порт: '$NODE_PORT'"
    NODE_PORT=""
  done
}

check_dns() {
  local my_ip dns_ips
  my_ip=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null \
          || curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)
  dns_ips=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd' ' - || true)
  if [[ -z $dns_ips ]]; then
    warn "$DOMAIN пока не резолвится. Создай A-запись на IP этого сервера${my_ip:+ ($my_ip)}, иначе сертификат не выпустится"
  elif [[ -n $my_ip && " $dns_ips " != *" $my_ip "* ]]; then
    warn "$DOMAIN указывает на $dns_ips, а у этого сервера $my_ip — сертификат, скорее всего, не выпустится"
  else
    log "DNS в порядке: $DOMAIN → ${my_ip:-$dns_ips}"
    return 0
  fi
  confirm_yn "Продолжить всё равно?" y || die "Остановлено. Поправь DNS и запусти скрипт снова"
}

check_ports() {
  local p st
  for p in 80 443; do
    st=$(port_status "$p")
    case $st in
      free|ours) ;;
      node:*)    NODE_HOLDS+=("$p"); NODE_NAMES=${st#node:} ;;
      foreign:*) die "Порт $p занят: ${st#foreign:}. nginx нужны свободные 80 и 443" ;;
    esac
  done
  collect_node_ports

  if (( ${#NODE_HOLDS[@]} )); then
    warn "Порт ${NODE_HOLDS[*]} сейчас слушает нода ($NODE_NAMES, Xray)."
    warn "Перед запуском nginx на этом порту ноду остановлю, а в конце запущу обратно."
    warn "Важно: дальше ${NODE_HOLDS[*]} будет у nginx. Инбаунд на этом порту в профиле ноды перенеси на другой порт"
    warn "или убери — иначе Xray на ноде не запустится."
    confirm_yn "Продолжить?" y || die "Остановлено — порт ${NODE_HOLDS[*]} оставлен ноде"
  fi

  # XHTTP-инбаунд должен слушать только 127.0.0.1. Если порт занят снаружи (например, прямым REALITY) —
  # инбаунд на нём не поднимется.
  local addrs
  addrs=$(ss -Htln "sport = :$XHTTP_PORT" 2>/dev/null | awk '{print $4}' | grep -vE '^(127\.0\.0\.1|\[::1\]):' | paste -sd' ' - || true)
  if [[ -n $addrs ]]; then
    warn "Порт $XHTTP_PORT уже слушается не только на 127.0.0.1 ($addrs) — XHTTP-инбаунд на нём не поднимется."
    warn "Освободи порт или запусти скрипт с --xhttp-port <другой порт>"
    confirm_yn "Продолжить всё равно?" n || die "Остановлено: порт $XHTTP_PORT занят"
  fi
}

setup_ufw() {
  if (( NO_UFW )); then return 0; fi
  command -v ufw >/dev/null 2>&1 || apt_install ufw
  local was_active=0 p ip ssh_ports=""
  if [[ $(ufw status 2>/dev/null || true) == *"Status: active"* ]]; then was_active=1; fi

  # SSH: 22 всегда + порты, на которых реально слушает sshd (если он перенесён)
  ssh_ports=$(ss -Htlnp 2>/dev/null | grep '"sshd"' | awk '{print $4}' | sed 's/.*://' | sort -un | paste -sd' ' - || true)
  for p in 22 $ssh_ports; do ufw allow "$p/tcp" comment 'SSH' >/dev/null; done
  UFW_SUMMARY+=("SSH: $(printf '%s\n' 22 $ssh_ports | sort -un | paste -sd, -)")

  ufw allow 80/tcp comment 'HTTP (certbot)' >/dev/null
  ufw allow 443/tcp comment 'HTTPS (nginx)' >/dev/null
  UFW_SUMMARY+=("80, 443: для всех")

  for p in ${NODE_PUBLIC_PORTS[@]+"${NODE_PUBLIC_PORTS[@]}"}; do
    ufw allow "$p" comment 'Remnawave inbound' >/dev/null
  done
  if (( ${#NODE_PUBLIC_PORTS[@]} )); then UFW_SUMMARY+=("инбаунды ноды: ${NODE_PUBLIC_PORTS[*]}"); fi

  # Порт ноды — только для панели: убираем правила «открыт всем», если были
  ufw delete allow "$NODE_PORT/tcp" >/dev/null 2>&1 || true
  ufw delete allow "$NODE_PORT" >/dev/null 2>&1 || true
  for ip in "${PANEL_IPS[@]}"; do
    ufw allow from "$ip" to any port "$NODE_PORT" proto tcp comment 'Remnawave panel' >/dev/null
  done
  UFW_SUMMARY+=("$NODE_PORT: только для панели ($PANEL_ADDR → ${PANEL_IPS[*]})")

  if (( ! was_active )); then
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
  fi
  ufw --force enable >/dev/null
  log "UFW включён:"
  for p in "${UFW_SUMMARY[@]}"; do echo "    - $p"; done
}

issue_cert() {
  if cert_exists; then
    log "Сертификат для $DOMAIN уже есть (действует до $(cert_end)) — заново не выпускаю"
    return 0
  fi
  ask_email
  command -v certbot >/dev/null 2>&1 || apt_install certbot
  selftest_challenge
  log "Выпускаю сертификат для $DOMAIN…"
  if ! certbot certonly --webroot -w "$WWW_DIR" -d "$DOMAIN" --cert-name "$DOMAIN" \
        -m "$EMAIL" --agree-tos --no-eff-email --non-interactive --keep-until-expiring; then
    die "Сертификат не выпустился. Проверь, что A-запись $DOMAIN указывает на этот сервер и что 80 порт открыт у хостера. Подробности: /var/log/letsencrypt/letsencrypt.log"
  fi
  cert_exists || die "certbot отработал, но сертификата в $LE_DIR/live/$DOMAIN/ нет"
  log "Сертификат выпущен (действует до $(cert_end))"
}

setup_renewal() {
  command -v certbot >/dev/null 2>&1 || apt_install certbot
  local hook="$LE_DIR/renewal-hooks/deploy/remnanode-nginx-reload.sh"
  mkdir -p "$(dirname "$hook")"
  cat >"$hook" <<EOF
#!/bin/sh
# remnanode-nginx-setup: перечитать nginx после продления сертификата
docker exec ${CONTAINER} nginx -s reload >/dev/null 2>&1 || true
EOF
  chmod 755 "$hook"
  log "После продления nginx будет перечитывать сертификат ($hook)"

  local units=""
  if command -v systemctl >/dev/null 2>&1; then
    units=$(systemctl list-unit-files 'certbot.timer' 'snap.certbot.renew.timer' 2>/dev/null || true)
  fi
  if [[ $units == *snap.certbot.renew.timer* ]]; then
    log "Автопродление: snap.certbot.renew.timer"
  elif [[ $units == *certbot.timer* ]]; then
    systemctl enable --now certbot.timer >/dev/null 2>&1 || true
    log "Автопродление: systemd-таймер certbot.timer (2 раза в день)"
  else
    command -v cron >/dev/null 2>&1 || apt_install cron
    printf '%s\n' "# remnanode-nginx-setup: автопродление сертификатов" \
      "17 3,15 * * * root certbot -q renew" >/etc/cron.d/remnanode-certbot
    chmod 644 /etc/cron.d/remnanode-certbot
    log "Автопродление: cron (/etc/cron.d/remnanode-certbot, 2 раза в день)"
  fi

  if certbot renew --dry-run --cert-name "$DOMAIN" >/dev/null 2>&1; then
    log "Проверка продления прошла (certbot renew --dry-run)"
  else
    warn "Проверка продления не прошла — запусти «certbot renew --dry-run» и посмотри вывод"
  fi
}

gen_index() {
  local parts name initial year
  IFS=. read -ra parts <<<"$DOMAIN"
  name=${parts[${#parts[@]}-2]}
  name=${name^}
  initial=${name:0:1}
  year=$(date +%Y)
  cat <<EOF
<!doctype html>
${HTML_MARK}
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${name}</title>
<meta name="description" content="${name} — media delivery platform.">
<style>
  :root {
    --bg: #0b0d12; --fg: #e8eaf0; --muted: #8b93a7; --card: #121621; --line: #1f2535;
    --accent: #6c8cff; --accent2: #a06cff;
    color-scheme: dark light;
  }
  @media (prefers-color-scheme: light) {
    :root { --bg: #f5f7fb; --fg: #151a26; --muted: #5d667a; --card: #ffffff; --line: #e3e7ef; }
  }
  * { box-sizing: border-box; }
  html, body { height: 100%; }
  body {
    margin: 0; display: flex; flex-direction: column;
    font: 16px/1.6 system-ui, -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    background: var(--bg); color: var(--fg);
    background-image: radial-gradient(60rem 30rem at 85% -10%, rgba(108, 140, 255, .16), transparent 60%),
                      radial-gradient(40rem 24rem at -10% 110%, rgba(160, 108, 255, .12), transparent 60%);
  }
  header { padding: 24px 28px; display: flex; align-items: center; gap: 10px; font-weight: 600; }
  .logo {
    width: 30px; height: 30px; border-radius: 9px; display: grid; place-items: center;
    background: linear-gradient(135deg, var(--accent), var(--accent2)); color: #fff; font-size: 15px;
  }
  main { flex: 1; display: grid; place-items: center; padding: 24px; }
  .hero { max-width: 600px; text-align: center; }
  h1 { font-size: clamp(30px, 5.5vw, 48px); line-height: 1.12; letter-spacing: -.02em; margin: 0 0 16px; }
  h1 span {
    background: linear-gradient(90deg, var(--accent), var(--accent2));
    -webkit-background-clip: text; background-clip: text; color: transparent;
  }
  p { color: var(--muted); margin: 0 auto 30px; max-width: 46ch; }
  .status {
    display: inline-flex; align-items: center; gap: 9px; padding: 8px 15px; font-size: 14px;
    border: 1px solid var(--line); border-radius: 999px; background: var(--card); color: var(--muted);
  }
  .dot { width: 8px; height: 8px; border-radius: 50%; background: #22c55e; animation: pulse 2s infinite; }
  @keyframes pulse {
    0%   { box-shadow: 0 0 0 0 rgba(34, 197, 94, .5); }
    70%  { box-shadow: 0 0 0 9px rgba(34, 197, 94, 0); }
    100% { box-shadow: 0 0 0 0 rgba(34, 197, 94, 0); }
  }
  footer { padding: 24px; text-align: center; font-size: 13px; color: var(--muted); }
</style>
</head>
<body>
  <header><div class="logo">${initial}</div>${name}</header>
  <main>
    <section class="hero">
      <h1>Fast, reliable <span>media delivery</span></h1>
      <p>${name} powers streaming and content distribution for our partners. Public access is limited while we prepare the new platform.</p>
      <div class="status"><span class="dot"></span>All systems operational</div>
    </section>
  </main>
  <footer>&copy; ${year} ${name}</footer>
</body>
</html>
EOF
}

make_index() {
  local f="$WWW_DIR/index.html"
  if [[ -s $f ]] && ! grep -Fq "$HTML_MARK" "$f"; then
    if confirm_yn "В $f уже есть своя страница. Заменить её заглушкой?" n; then
      cp -a "$f" "$f.bak-$(stamp)"
    else
      log "Оставил текущий $f"
      return 0
    fi
  fi
  gen_index >"$f"
  chmod 644 "$f"
  log "Заглушка: $f"
}

finish() {
  local code s
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
         --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/" 2>/dev/null || true)

  hdr "Для панели Remnawave"
  echo "  Инбаунд:  VLESS, xhttp, security none, listen 127.0.0.1, port $XHTTP_PORT, path $XHTTP_PATH"
  echo "  Хост:     адрес $DOMAIN, порт 443, TLS, SNI $DOMAIN, XHTTP mode packet-up"
  if (( ! NO_UFW )); then
    echo "  UFW:"
    for s in "${UFW_SUMMARY[@]}"; do echo "    - $s"; done
    echo "    Новый инбаунд на публичном порту — открой его: ufw allow <порт>"
  fi

  if (( ${#NODE_HOLDS[@]} )); then
    echo
    if (( NODE_BIND_FAIL )); then
      warn "Xray на ноде НЕ запустился: порт ${NODE_HOLDS[*]} теперь у nginx."
      warn "В панели перенеси инбаунд с ${NODE_HOLDS[*]} на другой порт (и открой его: ufw allow <порт>)"
      warn "или назначь ноде профиль, где на ${NODE_HOLDS[*]} ничего нет. Пока это не сделано — нода offline."
    else
      warn "Порт ${NODE_HOLDS[*]} теперь у nginx. Если в профиле ноды остался инбаунд на ${NODE_HOLDS[*]} — перенеси его,"
      warn "иначе Xray не запустится. Проверь в панели, что нода Online."
    fi
  fi

  echo
  if [[ $code == 200 ]]; then
    printf '%s✅ Всё готово!%s\n' "$C_G" "$C_0"
  else
    warn "Проверка с сервера вернула код '${code:-нет ответа}' — что-то может быть не так."
  fi
  echo "Открой в браузере https://$DOMAIN — там должна открыться заглушка."
  echo "Если её нет или браузер ругается на сертификат — напиши в поддержку: $SUPPORT"
}

main() {
  parse_args "$@"
  init_tty
  trap on_exit EXIT
  hdr "Remnawave Node: nginx + сертификат + XHTTP + UFW"
  preflight
  ask_domain
  ask_path
  ask_ufw
  install_deps
  check_dns
  check_ports

  hdr "docker-compose.yml"
  compose_add_nginx

  hdr "nginx: 80 порт"
  prepare_dirs
  prepare_container
  if user_conf_has_domain; then
    SKIP_BLOCKS=1
    warn "В $NGINX_CONF уже есть твоя настройка для $DOMAIN — её не трогаю и свои блоки не добавляю."
    warn "Проверь сам, что XHTTP-location там ведёт на 127.0.0.1:$XHTTP_PORT."
    nginx_up 0
  elif append_block http gen_http_block; then
    nginx_up 1
    log "Добавил блок 80 порта для $DOMAIN в конец $NGINX_CONF"
  else
    nginx_up 0
    log "Блок 80 порта для $DOMAIN уже есть в $NGINX_CONF"
  fi

  hdr "UFW"
  if (( NO_UFW )); then log "Пропускаю"; else setup_ufw; fi

  hdr "Сертификат"
  issue_cert

  hdr "nginx: 443 порт"
  if (( ! SKIP_BLOCKS )); then
    if has_default_443; then ADD_DEFAULT=0; else ADD_DEFAULT=1; fi
    if append_block https gen_https_block; then
      nginx_up 1
      log "Добавил блок 443 порта: сайт + XHTTP $XHTTP_PATH → 127.0.0.1:$XHTTP_PORT"
    else
      nginx_up 0
      log "Блок 443 порта для $DOMAIN уже есть в $NGINX_CONF"
    fi
  else
    nginx_up 0
  fi
  if conf_listens 443; then wait_443; fi

  hdr "Автопродление"
  setup_renewal

  hdr "Заглушка"
  make_index

  if (( ${#NODE_STOPPED[@]} )); then
    hdr "Нода"
    start_node
    check_node_after_start
  fi

  finish
}

[[ ${RNS_NO_MAIN:-0} == 1 ]] || main "$@"#!/usr/bin/env bash
# installer.sh (weavemarket-cdn-nginx) — nginx на 443 (TLS) + сертификат Let's Encrypt + XHTTP + UFW для Remnawave Node
#
# Запуск на сервере с нодой, от root:
#   bash <(curl -fsSL https://raw.githubusercontent.com/SikWeet/weavemarket-cdn-nginx/main/installer.sh)
#
# Скрипт спросит домен, path для XHTTP, адрес панели и порт ноды, затем:
#   1. добавит сервис nginx в /opt/remnanode/docker-compose.yml (остальное не трогает, отступы как в файле)
#   2. допишет в конец /opt/remnanode/nginx.conf блок для 80 порта и запустит nginx
#   3. настроит UFW: 22 (SSH), 80, 443, порты инбаундов ноды; порт ноды — только для панели
#   4. спросит email и выпустит сертификат через certbot (webroot)
#   5. допишет блок для 443 порта: сайт + проксирование XHTTP на 127.0.0.1:8443
#      (если 443 сейчас держит Xray ноды — остановит ноду на время настройки и запустит обратно)
#   6. включит автопродление сертификатов (с перезагрузкой nginx после продления)
#   7. создаст заглушку /opt/remnanode/www/index.html
#
# Повторный запуск безопасен: уже добавленное не дублируется, чужие настройки не трогаются.
# Без вопросов:
#   bash <(curl -fsSL https://raw.githubusercontent.com/SikWeet/weavemarket-cdn-nginx/main/installer.sh) \
#     --domain node.example.com --email you@example.com --panel panel.example.com -y

set -Eeuo pipefail

# ─── Настройки ───────────────────────────────────────────────────────────────
INSTALL_DIR="/opt/remnanode"
DOMAIN="" XHTTP_PATH="" EMAIL="" PANEL_ADDR="" NODE_PORT=""
XHTTP_PORT="8443"
ASSUME_YES=0 NO_UFW=0

DEFAULT_PATH="/api/v1/stream"
DEFAULT_NODE_PORT="2222"
NGINX_IMAGE="nginx:1.30-alpine"
CONTAINER="remnanode-nginx"
LE_DIR="/etc/letsencrypt"
SUPPORT="@WeaveVPN_support"
MARK="remnanode-setup"
HTML_MARK="<!-- remnanode-nginx-setup -->"
INSTALL_CMD="bash <(curl -fsSL https://raw.githubusercontent.com/SikWeet/weavemarket-cdn-nginx/main/installer.sh)"

TTY="" HAS_IPV6=0 RECREATE=0 SKIP_BLOCKS=0 ADD_DEFAULT=0 ROLLBACK_SIZE=0
NODE_PROJECT="" NODE_NAMES="" NODE_START_TS="" NODE_BIND_FAIL=0
NODE_HOLDS=() NODE_STOPPED=() NODE_RESTARTED=() NODE_PUBLIC_PORTS=() PANEL_IPS=() UFW_SUMMARY=()

# ─── Вывод ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_G=$'\033[1;32m' C_Y=$'\033[1;33m' C_R=$'\033[1;31m' C_B=$'\033[1m' C_0=$'\033[0m'
else
  C_G="" C_Y="" C_R="" C_B="" C_0=""
fi
log()  { printf '%s[+]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  {
  printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2
  printf '    Не получается? Напиши в поддержку: %s\n' "$SUPPORT" >&2
  exit 1
}
hdr()  { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0"; }
trap 'die "Ошибка на строке $LINENO: $BASH_COMMAND"' ERR

usage() {
  cat <<EOF
Использование (от root):
  ${INSTALL_CMD}
  (всё спросит сам)

Параметры (необязательные — чтобы не отвечать на вопросы):
  --domain DOMAIN      домен для настройки и сертификата
  --path PATH          path для XHTTP (по умолчанию ${DEFAULT_PATH})
  --email EMAIL        email для Let's Encrypt
  --panel ADDR         домен или IP панели — только ей будет открыт порт ноды в UFW
  --node-port PORT     порт ноды для связи с панелью (по умолчанию из docker-compose.yml, иначе ${DEFAULT_NODE_PORT})
  --no-ufw             не настраивать UFW
  --xhttp-port PORT    порт XHTTP-инбаунда на 127.0.0.1 (по умолчанию 8443)
  --dir DIR            каталог ноды (по умолчанию /opt/remnanode)
  -y, --yes            не задавать вопросов да/нет (берутся ответы по умолчанию)
  -h, --help           эта справка
EOF
}

# ─── Утилиты ─────────────────────────────────────────────────────────────────
trim()  { local s=$1; s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}; printf '%s' "$s"; }
stamp() { date +%Y%m%d-%H%M%S; }
rand_hex() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }

init_tty() { if { : <>/dev/tty; } 2>/dev/null; then TTY=/dev/tty; fi; }

# ask VAR "Вопрос" [по умолчанию] — если VAR уже задан параметром, ничего не спрашивает
ask() {
  local __var=$1 __q=$2 __def=${3:-} __ans=""
  [[ -z ${!__var:-} ]] || return 0
  if [[ -z $TTY ]]; then
    [[ -n $__def ]] || die "Не задано: $__q. Без терминала передай это параметром (см. --help)"
    printf -v "$__var" '%s' "$__def"
    return 0
  fi
  if [[ -n $__def ]]; then printf '%s [%s]: ' "$__q" "$__def" >"$TTY"
  else printf '%s: ' "$__q" >"$TTY"; fi
  IFS= read -r __ans <"$TTY" || true
  __ans=$(trim "$__ans")
  printf -v "$__var" '%s' "${__ans:-$__def}"
}

# confirm_yn "Вопрос" y|n — 0 = да. Без терминала или с -y берётся ответ по умолчанию.
confirm_yn() {
  local q=$1 def=${2:-n} a="" hint="y/N"
  if (( ASSUME_YES )) || [[ -z $TTY ]]; then [[ $def == y ]]; return; fi
  if [[ $def == y ]]; then hint="Y/n"; fi
  printf '%s [%s] ' "$q" "$hint" >"$TTY"
  IFS= read -r a <"$TTY" || true
  a=$(trim "${a,,}")
  case ${a:-$def} in y|yes|д|да) return 0 ;; *) return 1 ;; esac
}

retry_or_die() { [[ -n $TTY ]] || die "$1"; warn "$1 — попробуй ещё раз"; }

# apt-get с ожиданием: на свежем сервере apt часто занят автообновлениями (unattended-upgrades)
apt_run() {
  local out start=$SECONDS said=0
  while :; do
    if out=$(DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=60 "$@" 2>&1); then return 0; fi
    if grep -qiE 'could not get lock|unable to acquire|another process using it' <<<"$out"; then
      if (( ! said )); then log "apt занят — система ставит обновления. Жду, пока закончит (до 15 минут)…"; said=1; fi
      (( SECONDS - start < 900 )) \
        || die "apt занят больше 15 минут. Дождись окончания обновлений (или перезагрузи сервер) и запусти скрипт снова"
      sleep 10
      continue
    fi
    printf '%s\n' "$out" | tail -n 15 >&2 || true
    return 1
  done
}

apt_install() {
  command -v apt-get >/dev/null 2>&1 || die "Нет apt-get — установи вручную: $*"
  log "Устанавливаю: $*"
  apt_run update -qq || die "Не сработал apt-get update (вывод выше)"
  apt_run install -y -qq "$@" || die "Не удалось установить: $* (вывод выше)"
}

# Всё нужное ставим сразу, до любых изменений на сервере
install_deps() {
  local pkgs=()
  command -v certbot >/dev/null 2>&1 || pkgs+=(certbot)
  if (( ! NO_UFW )); then command -v ufw >/dev/null 2>&1 || pkgs+=(ufw); fi
  (( ${#pkgs[@]} )) || return 0
  apt_install "${pkgs[@]}"
}

is_domain() { local re='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9-]{2,63}$'; [[ $1 =~ $re ]]; }
is_email()  { local re='^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'; [[ $1 =~ $re ]]; }
is_path()   { local re='^/[A-Za-z0-9._~/-]+$'; [[ $1 =~ $re && $1 != *//* ]]; }
is_ipv4()   { local re='^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; [[ $1 =~ $re ]]; }
is_port()   { [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
norm_path() {
  local p; p=$(trim "$1")
  [[ $p == /* ]] || p="/$p"
  while [[ $p == */ && $p != / ]]; do p=${p%/}; done
  printf '%s' "$p"
}

# Значение переменной из docker-compose.yml / .env ("- KEY=val", "KEY: val", "KEY=val"); пусто — не нашлось
extract_var() {
  local name=$1 f v=""; shift
  for f in "$@"; do
    [[ -r $f ]] || continue
    v=$(sed -nE "/^[[:space:]]*(-[[:space:]]*)?${name}[[:space:]]*[=:]/{s/^[^=:]*[=:][[:space:]]*//;p;q;}" "$f" 2>/dev/null || true)
    v=$(trim "${v%$'\r'}")
    v=${v#\"}; v=${v%\"}; v=${v#\'}; v=${v%\'}
    [[ -z $v ]] || break
  done
  printf '%s' "$v"
}

container_exists()  { docker inspect "$CONTAINER" >/dev/null 2>&1; }
container_running() { [[ $(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true) == true ]]; }
container_project() { docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "${1:-$CONTAINER}" 2>/dev/null || true; }
compose_project()   { docker compose -f "$COMPOSE" config 2>/dev/null | sed -n '/^name:/{s/^name:[[:space:]]*//p;q;}' || true; }
cert_exists()       { [[ -s $LE_DIR/live/$DOMAIN/fullchain.pem && -s $LE_DIR/live/$DOMAIN/privkey.pem ]]; }
cert_end() {
  if command -v openssl >/dev/null 2>&1; then
    openssl x509 -enddate -noout -in "$LE_DIR/live/$DOMAIN/fullchain.pem" 2>/dev/null | cut -d= -f2 || true
  fi
}

# ─── Кто держит порт ─────────────────────────────────────────────────────────
# PID → имя docker-контейнера, в котором работает процесс (пусто — процесс не из контейнера)
container_of_pid() {
  local p=$1 anc=" " n=0 cpid name
  while [[ -n $p && $p != 0 && $p != 1 && $n -lt 40 ]]; do
    anc+="$p "
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ' || true)
    n=$((n + 1))
  done
  while read -r cpid name; do
    if [[ -n $cpid && $cpid != 0 && $anc == *" $cpid "* ]]; then printf '%s' "${name#/}"; return 0; fi
  done < <(docker ps -q 2>/dev/null | xargs -r docker inspect -f '{{.State.Pid}} {{.Name}}' 2>/dev/null || true)
  return 0
}

# Контейнер ноды: из того же compose-проекта, что и /opt/remnanode, и это не наш nginx
is_node_container() {
  local name=$1 proj
  [[ -n $name && $name != "$CONTAINER" ]] || return 1
  [[ $name == remnanode ]] && return 0
  proj=$(container_project "$name")
  [[ -n $proj && $proj == "$NODE_PROJECT" ]]
}

# free | ours | node:<контейнеры> | foreign:<кто>
port_status() {
  local port=$1 line pids pid c node="" foreign="" comm
  line=$(ss -Htlnp "sport = :$port" 2>/dev/null || true)
  [[ -n $line ]] || { echo free; return 0; }
  pids=$(grep -o 'pid=[0-9]*' <<<"$line" | cut -d= -f2 | sort -u || true)
  [[ -n $pids ]] || { echo "foreign:неизвестный процесс"; return 0; }
  for pid in $pids; do
    c=$(container_of_pid "$pid")
    if [[ $c == "$CONTAINER" ]]; then
      continue
    elif is_node_container "$c"; then
      [[ " $node " == *" $c "* ]] || node+=" $c"
    else
      comm=$(ps -o comm= -p "$pid" 2>/dev/null || true)
      foreign+=" ${comm:-pid $pid}${c:+ (контейнер $c)}"
    fi
  done
  if [[ -n $foreign ]]; then echo "foreign:$(trim "$foreign")"
  elif [[ -n $node ]]; then echo "node:$(trim "$node")"
  else echo ours; fi
}

# Публичные порты, которые слушает нода (её инбаунды), — чтобы открыть их в UFW
collect_node_ports() {
  local flag proto line addr port pid c
  for proto in tcp udp; do
    if [[ $proto == tcp ]]; then flag=-Htlnp; else flag=-Hulnp; fi
    while IFS= read -r line; do
      [[ -n $line ]] || continue
      addr=$(awk '{print $4}' <<<"$line")
      port=${addr##*:}
      case $addr in 127.*|\[::1\]:*|::1:*) continue ;; esac
      case $port in 80|443|"$NODE_PORT"|"$XHTTP_PORT") continue ;; esac
      pid=$(grep -o 'pid=[0-9]*' <<<"$line" | cut -d= -f2 | sed -n 1p || true)
      [[ -n $pid ]] || continue
      c=$(container_of_pid "$pid")
      is_node_container "$c" || continue
      [[ " ${NODE_PUBLIC_PORTS[*]-} " == *" $port/$proto "* ]] || NODE_PUBLIC_PORTS+=("$port/$proto")
    done < <(ss "$flag" 2>/dev/null || true)
  done
}

# ─── Остановка / запуск ноды ─────────────────────────────────────────────────
stop_node() {
  (( ${#NODE_HOLDS[@]} )) || return 0
  (( ${#NODE_STOPPED[@]} == 0 )) || return 0
  local n _ p busy
  for n in $NODE_NAMES; do
    log "Останавливаю ноду ($n) — порт ${NODE_HOLDS[*]} нужен nginx"
    docker stop -t 20 "$n" >/dev/null
    NODE_STOPPED+=("$n")
  done
  for _ in $(seq 1 15); do
    busy=0
    for p in "${NODE_HOLDS[@]}"; do
      case $(port_status "$p") in free|ours) ;; *) busy=1 ;; esac
    done
    (( busy )) || return 0
    sleep 1
  done
  die "Нода остановлена, но порт ${NODE_HOLDS[*]} всё ещё занят"
}

start_node() {
  (( ${#NODE_STOPPED[@]} )) || return 0
  local n
  NODE_START_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  for n in "${NODE_STOPPED[@]}"; do
    if docker start "$n" >/dev/null 2>&1; then
      log "Нода ($n) снова запущена"
      NODE_RESTARTED+=("$n")
    else
      warn "Не смог запустить ноду ($n) — запусти вручную: docker start $n"
    fi
  done
  NODE_STOPPED=()
}

# После запуска: поднялся ли Xray или упал на занятом порту
check_node_after_start() {
  (( ${#NODE_RESTARTED[@]} )) || return 0
  local _ n logs
  log "Жду, пока нода получит конфиг от панели (до 30 секунд)…"
  for _ in $(seq 1 15); do
    sleep 2
    for n in "${NODE_RESTARTED[@]}"; do
      logs=$(docker logs --since "$NODE_START_TS" "$n" 2>&1 || true)
      if grep -qiE 'address already in use' <<<"$logs"; then NODE_BIND_FAIL=1; return 0; fi
    done
  done
}

# При любом выходе (в том числе по ошибке) — вернуть ноду
on_exit() {
  local rc=$?
  trap - ERR
  set +e
  if (( ${#NODE_STOPPED[@]} )); then
    warn "Возвращаю ноду…"
    start_node
  fi
  exit "$rc"
}

# ─── docker-compose.yml ──────────────────────────────────────────────────────
# Отступы в compose: "S U L HAS_NGINX FOUND"
#   S — отступ имён сервисов, U — шаг до их ключей, L — отступ элементов списка от ключа
compose_layout() {
  awk '
    BEGIN { S = -1; U = -1; L = -1; nginx = 0; found = 0; insvc = 0; lastkey = -1 }
    /^[ \t]*$/ { next }
    /^[ \t]*#/ { next }
    /^[^ ]/    { insvc = ($0 ~ /^services:[ \t]*(#.*)?$/); if (insvc) found = 1; next }
    !insvc     { next }
    {
      match($0, /^ */); ind = RLENGTH
      item = ($0 ~ /^ *-( |$)/)
      if (S < 0) S = ind
      if (ind == S && !item) {
        k = $0; sub(/^ +/, "", k); sub(/[ \t]*:.*$/, "", k); gsub(/["\047]/, "", k)
        if (k == "nginx") nginx = 1
        lastkey = ind; next
      }
      if (!item) { if (U < 0 && ind > S) U = ind - S; lastkey = ind; next }
      if (L < 0 && lastkey >= 0) L = ind - lastkey
    }
    END {
      if (S < 0) S = 2
      if (U < 1) U = 2
      if (L < 0) L = U
      print S, U, L, nginx, found
    }
  ' "$1"
}

gen_compose_block() { # S U L
  local s k i
  s=$(printf '%*s' "$1" '')
  k=$(printf '%*s' "$(( $1 + $2 ))" '')
  i=$(printf '%*s' "$(( $1 + $2 + $3 ))" '')
  cat <<EOF
${s}nginx:
${k}image: ${NGINX_IMAGE}
${k}container_name: ${CONTAINER}
${k}restart: always
${k}network_mode: host
${k}volumes:
${i}- ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
${i}- ${LE_DIR}:${LE_DIR}:ro
${i}- ./www:/var/www/html:ro
EOF
}

# Вставить блок в конец секции services: (перед следующим ключом верхнего уровня или в конец файла)
compose_insert() { # FILE BLOCKFILE
  awk -v bf="$2" '
    BEGIN { while ((getline line < bf) > 0) blk = blk line "\n"; close(bf); insvc = 0; done = 0; last = "" }
    /^[^ \t#]/ {
      if (insvc && !done) { printf "%s\n", blk; done = 1 }
      insvc = ($0 ~ /^services:[ \t]*(#.*)?$/)
    }
    { print; last = $0 }
    END {
      if (!done) { if (last !~ /^[ \t]*$/) print ""; printf "%s", blk }
    }
  ' "$1"
}

compose_add_nginx() {
  local re="^[[:space:]]*container_name:[[:space:]]*[\"']?${CONTAINER}[\"']?[[:space:]]*(#.*)?\$"
  if grep -Eq "$re" "$COMPOSE"; then
    log "Сервис nginx уже есть в $COMPOSE — не трогаю"
    return 0
  fi
  local s u l has_nginx found blockf tmp bak
  read -r s u l has_nginx found < <(compose_layout "$COMPOSE")
  [[ $found == 1 ]] || die "В $COMPOSE не нашёл секцию services:"
  [[ $has_nginx == 0 ]] || die "В $COMPOSE уже есть другой сервис с именем nginx — переименуй его и запусти скрипт снова"

  blockf=$(mktemp); tmp=$(mktemp)
  gen_compose_block "$s" "$u" "$l" >"$blockf"
  bak="$COMPOSE.bak-$(stamp)"
  cp -a "$COMPOSE" "$bak"
  compose_insert "$COMPOSE" "$blockf" >"$tmp"
  cat "$tmp" >"$COMPOSE"
  rm -f "$tmp" "$blockf"

  if ! docker compose -f "$COMPOSE" config -q >/dev/null 2>&1; then
    cat "$bak" >"$COMPOSE"
    die "После добавления nginx файл $COMPOSE перестал проходить проверку — вернул как было"
  fi
  log "Добавил сервис nginx в $COMPOSE (копия старого: $bak)"
}

# ─── nginx.conf ──────────────────────────────────────────────────────────────
prepare_dirs() {
  mkdir -p "$WWW_DIR/.well-known/acme-challenge"
  chmod 755 "$WWW_DIR" "$WWW_DIR/.well-known" "$WWW_DIR/.well-known/acme-challenge"
  if [[ -d $NGINX_CONF ]]; then
    # docker создаёт папку на месте отсутствующего файла
    rmdir "$NGINX_CONF" 2>/dev/null \
      || die "$NGINX_CONF — папка, а должен быть файл. Перенеси её содержимое и запусти скрипт снова"
    warn "$NGINX_CONF был пустой папкой (её создаёт docker, когда файла нет) — заменил на файл"
    RECREATE=1
  fi
  [[ -f $NGINX_CONF ]] || : >"$NGINX_CONF"
}

prepare_container() {
  container_exists || return 0
  local have
  have=$(container_project)
  if [[ -n $NODE_PROJECT && $have != "$NODE_PROJECT" ]]; then
    log "Контейнер $CONTAINER создан не из $COMPOSE — пересоздаю"
    docker rm -f "$CONTAINER" >/dev/null
    return 0
  fi
  if [[ $(docker inspect -f '{{.State.Restarting}}' "$CONTAINER" 2>/dev/null || true) == true ]]; then
    docker logs --tail 10 "$CONTAINER" >&2 2>&1 || true
    die "nginx уже сейчас падает при запуске (лог выше) — сначала исправь $NGINX_CONF"
  fi
}

# Есть ли в nginx.conf пользовательский (не наш) server для этого домена
user_conf_has_domain() {
  local stripped re
  stripped=$(awk -v t="# >>> $MARK " -v e="# <<< $MARK " '
    index($0, t) == 1 { skip = 1 }
    !skip && $0 !~ /^[ \t]*#/ { print }
    index($0, e) == 1 { skip = 0 }
  ' "$NGINX_CONF")
  re="server_name[^;]*[[:space:]]${DOMAIN//./\\.}([[:space:]]|;)"
  grep -Eq "$re" <<<"$stripped"
}

has_default_443() {
  local re='listen[[:space:]]+([^;[:space:]]*:)?443[^;]*default_server'
  grep -Eq "$re" "$NGINX_CONF"
}

# Нужен ли nginx порт PORT по текущему nginx.conf
conf_listens() {
  [[ $1 == 80 ]] && return 0
  grep -Eq "^[^#]*listen[[:space:]]+([^;[:space:]]*:)?$1([^0-9]|\$)" "$NGINX_CONF"
}

gen_http_block() {
  local v6=""
  if (( HAS_IPV6 )); then v6=$'\n    listen [::]:80;'; fi
  cat <<EOF
# >>> ${MARK} http ${DOMAIN}
server {
    listen 80;${v6}
    server_name ${DOMAIN};

    # проверка домена для Let's Encrypt
    location /.well-known/acme-challenge/ { root /var/www/html; }

    location / { return 301 https://\$host\$request_uri; }
}
# <<< ${MARK} http ${DOMAIN}
EOF
}

gen_default_block() {
  local v6=""
  if (( HAS_IPV6 )); then v6=$'\n    listen [::]:443 ssl default_server;'; fi
  cat <<EOF

# Запросы не на наши домены (сканеры по IP и т.п.) — обрываем на TLS-рукопожатии
server {
    listen 443 ssl default_server;${v6}
    server_name _;
    ssl_reject_handshake on;
}
EOF
}

gen_https_block() {
  local v6="" def=""
  if (( HAS_IPV6 )); then v6=$'\n    listen [::]:443 ssl;'; fi
  if (( ADD_DEFAULT )); then def=$(gen_default_block); fi
  cat <<EOF
# >>> ${MARK} https ${DOMAIN}
server {
    listen 443 ssl;${v6}
    http2 on;
    server_name ${DOMAIN};

    ssl_certificate     ${LE_DIR}/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key ${LE_DIR}/live/${DOMAIN}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:remnanode_ssl:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    root  /var/www/html;
    index index.html;

    client_header_timeout 5m;
    keepalive_timeout     5m;

    # XHTTP -> инбаунд Xray на 127.0.0.1:${XHTTP_PORT} (HTTP/1.1, режим packet-up)
    location ${XHTTP_PATH}/ {
        proxy_pass http://127.0.0.1:${XHTTP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 900s;
        proxy_send_timeout 900s;
        client_max_body_size 0;
    }
}${def}
# <<< ${MARK} https ${DOMAIN}
EOF
}

# Дописать блок в конец nginx.conf. 0 — дописал, 1 — такой блок уже был.
append_block() { # KIND GENERATOR
  local kind=$1 gen=$2
  if grep -Fqx "# >>> $MARK $kind $DOMAIN" "$NGINX_CONF"; then return 1; fi
  ROLLBACK_SIZE=$(stat -c %s "$NGINX_CONF")
  {
    if [[ -n $(tail -c1 "$NGINX_CONF") ]]; then echo; fi
    if (( ROLLBACK_SIZE > 0 )); then echo; fi
    "$gen"
  } >>"$NGINX_CONF"
  return 0
}

# Убрать только что дописанный блок (truncate сохраняет файл, который смонтирован в контейнер)
rollback() { truncate -s "$ROLLBACK_SIZE" "$NGINX_CONF"; }

wait_http() {
  local _
  for _ in $(seq 1 20); do
    if curl -s -o /dev/null --max-time 2 --resolve "$DOMAIN:80:127.0.0.1" "http://$DOMAIN/"; then return 0; fi
    sleep 1
  done
  return 1
}

# Освободить для nginx порты, которые держит нода (только те, что nginx реально слушает)
free_ports_for_nginx() {
  local p
  for p in ${NODE_HOLDS[@]+"${NODE_HOLDS[@]}"}; do
    if conf_listens "$p"; then stop_node; return 0; fi
  done
}

# Применить nginx.conf: перечитать работающий nginx или запустить контейнер.
# nginx_up 1 — при ошибке убрать только что дописанный блок.
nginx_up() {
  local rb=${1:-0} out extra=()
  free_ports_for_nginx
  if container_running && (( ! RECREATE )); then
    if ! out=$(docker exec "$CONTAINER" nginx -t 2>&1); then
      printf '%s\n' "$out" | tail -n 5 >&2 || true
      if (( rb )); then rollback; die "nginx не принял новый блок — убрал его из $NGINX_CONF"; fi
      die "nginx не принимает $NGINX_CONF (ошибка выше)"
    fi
    docker exec "$CONTAINER" nginx -s reload >/dev/null 2>&1 || true
    sleep 1
  else
    if (( RECREATE )); then extra=(--force-recreate); fi
    if ! out=$(docker compose -f "$COMPOSE" up -d ${extra[@]+"${extra[@]}"} nginx 2>&1); then
      printf '%s\n' "$out" >&2
      if (( rb )); then rollback; fi
      die "Не удалось запустить nginx через docker compose"
    fi
    RECREATE=0
  fi
  if ! wait_http; then
    docker logs --tail 15 "$CONTAINER" >&2 2>&1 || true
    if (( rb )); then rollback; die "nginx не поднялся на 80 порту (лог выше) — новый блок убрал из $NGINX_CONF"; fi
    die "nginx не поднялся на 80 порту (лог выше)"
  fi
}

# nginx действительно слушает 443 (а не остался на старом конфиге из-за занятого порта)
wait_443() {
  local _
  for _ in $(seq 1 10); do
    [[ $(port_status 443) == ours ]] && return 0
    sleep 1
  done
  docker logs --tail 10 "$CONTAINER" >&2 2>&1 || true
  die "nginx не смог занять 443 порт (лог выше): $(port_status 443)"
}

selftest_challenge() {
  local token got dir="$WWW_DIR/.well-known/acme-challenge"
  token="selftest-$(rand_hex 8)"
  printf '%s' "$token" >"$dir/$token"
  chmod 644 "$dir/$token"
  got=$(curl -fsS --max-time 5 --resolve "$DOMAIN:80:127.0.0.1" "http://$DOMAIN/.well-known/acme-challenge/$token" 2>/dev/null || true)
  rm -f "$dir/$token"
  [[ $got == "$token" ]] || die "nginx не отдаёт файлы проверки из $dir — без этого сертификат не выпустится"
}

# ─── Шаги ────────────────────────────────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --domain|--path|--email|--panel|--node-port|--xhttp-port|--dir)
        [[ $# -ge 2 && -n ${2:-} ]] || die "Параметру $1 нужно значение"
        case $1 in
          --domain)     DOMAIN=$2 ;;
          --path)       XHTTP_PATH=$2 ;;
          --email)      EMAIL=$2 ;;
          --panel)      PANEL_ADDR=$2 ;;
          --node-port)  NODE_PORT=$2 ;;
          --xhttp-port) XHTTP_PORT=$2 ;;
          --dir)        INSTALL_DIR=${2%/} ;;
        esac
        shift 2 ;;
      --no-ufw)  NO_UFW=1; shift ;;
      -y|--yes)  ASSUME_YES=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Неизвестный параметр: $1 (см. --help)" ;;
    esac
  done
  COMPOSE="$INSTALL_DIR/docker-compose.yml"
  NGINX_CONF="$INSTALL_DIR/nginx.conf"
  WWW_DIR="$INSTALL_DIR/www"
  is_port "$XHTTP_PORT" || die "Некорректный --xhttp-port: $XHTTP_PORT"
  XHTTP_PORT=$(( 10#$XHTTP_PORT ))
  if [[ -n $NODE_PORT ]]; then is_port "$NODE_PORT" || die "Некорректный --node-port: $NODE_PORT"; fi
}

preflight() {
  (( EUID == 0 )) || die "Нужны права root: выполни «sudo -i» и запусти команду установки ещё раз"
  [[ -f $COMPOSE ]] || die "Не найден $COMPOSE — сначала установи Remnawave Node: https://docs.rw/install/remnawave-node"
  command -v docker >/dev/null 2>&1 || die "Не найден docker — сначала установи Remnawave Node: https://docs.rw/install/remnawave-node"
  docker compose version >/dev/null 2>&1 || die "Не найден docker compose (пакет docker-compose-plugin)"
  command -v curl >/dev/null 2>&1 || apt_install curl ca-certificates
  command -v ss   >/dev/null 2>&1 || apt_install iproute2
  if [[ -s /proc/net/if_inet6 ]]; then HAS_IPV6=1; fi
  NODE_PROJECT=$(compose_project)
}

ask_domain() {
  while :; do
    ask DOMAIN "Домен для настройки и сертификата (например node.example.com)"
    DOMAIN=${DOMAIN,,}; DOMAIN=${DOMAIN#http://}; DOMAIN=${DOMAIN#https://}; DOMAIN=${DOMAIN%%/*}
    if is_domain "$DOMAIN"; then return 0; fi
    retry_or_die "Некорректный домен: '$DOMAIN'"
    DOMAIN=""
  done
}

ask_path() {
  while :; do
    ask XHTTP_PATH "Path для XHTTP" "$DEFAULT_PATH"
    XHTTP_PATH=$(norm_path "$XHTTP_PATH")
    if is_path "$XHTTP_PATH"; then return 0; fi
    retry_or_die "Некорректный path: '$XHTTP_PATH' (латиница, цифры, . _ ~ - /)"
    XHTTP_PATH=""
  done
}

ask_email() {
  while :; do
    ask EMAIL "Email для выпуска сертификата (Let's Encrypt)"
    EMAIL=$(trim "$EMAIL")
    if is_email "$EMAIL"; then return 0; fi
    retry_or_die "Некорректный email: '$EMAIL'"
    EMAIL=""
  done
}

# IP панели по домену или IP. 0 — нашлись.
resolve_panel() {
  local a=$1 ip
  PANEL_IPS=()
  if is_ipv4 "$a" || [[ $a == *:* ]]; then PANEL_IPS=("$a"); return 0; fi
  is_domain "$a" || return 1
  while read -r ip; do
    [[ -n $ip ]] && PANEL_IPS+=("$ip")
  done < <(getent ahosts "$a" 2>/dev/null | awk '{print $1}' | sort -u || true)
  (( ${#PANEL_IPS[@]} ))
}

ask_ufw() {
  (( NO_UFW )) && return 0
  if [[ -z $PANEL_ADDR && -z $TTY ]]; then
    warn "UFW не настраиваю: не задан адрес панели (--panel)"
    NO_UFW=1
    return 0
  fi
  local def_port
  def_port=$(extract_var NODE_PORT "$COMPOSE" "$INSTALL_DIR/.env")
  is_port "${def_port:-x}" || def_port=$DEFAULT_NODE_PORT

  while :; do
    ask PANEL_ADDR "Домен или IP панели, которая подключается к ноде (Enter — не настраивать UFW)"
    PANEL_ADDR=$(trim "${PANEL_ADDR,,}")
    PANEL_ADDR=${PANEL_ADDR#http://}; PANEL_ADDR=${PANEL_ADDR#https://}; PANEL_ADDR=${PANEL_ADDR%%/*}
    if [[ -z $PANEL_ADDR ]]; then
      warn "UFW не настраиваю — адрес панели не указан"
      NO_UFW=1
      return 0
    fi
    if resolve_panel "$PANEL_ADDR"; then break; fi
    retry_or_die "Не получилось определить IP панели по '$PANEL_ADDR'"
    PANEL_ADDR=""
  done
  log "Панель: $PANEL_ADDR → ${PANEL_IPS[*]}"

  while :; do
    ask NODE_PORT "Порт ноды для связи с панелью (NODE_PORT)" "$def_port"
    if is_port "$NODE_PORT"; then NODE_PORT=$(( 10#$NODE_PORT )); return 0; fi
    retry_or_die "Некорректный порт: '$NODE_PORT'"
    NODE_PORT=""
  done
}

check_dns() {
  local my_ip dns_ips
  my_ip=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null \
          || curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)
  dns_ips=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd' ' - || true)
  if [[ -z $dns_ips ]]; then
    warn "$DOMAIN пока не резолвится. Создай A-запись на IP этого сервера${my_ip:+ ($my_ip)}, иначе сертификат не выпустится"
  elif [[ -n $my_ip && " $dns_ips " != *" $my_ip "* ]]; then
    warn "$DOMAIN указывает на $dns_ips, а у этого сервера $my_ip — сертификат, скорее всего, не выпустится"
  else
    log "DNS в порядке: $DOMAIN → ${my_ip:-$dns_ips}"
    return 0
  fi
  confirm_yn "Продолжить всё равно?" y || die "Остановлено. Поправь DNS и запусти скрипт снова"
}

check_ports() {
  local p st
  for p in 80 443; do
    st=$(port_status "$p")
    case $st in
      free|ours) ;;
      node:*)    NODE_HOLDS+=("$p"); NODE_NAMES=${st#node:} ;;
      foreign:*) die "Порт $p занят: ${st#foreign:}. nginx нужны свободные 80 и 443" ;;
    esac
  done
  collect_node_ports

  if (( ${#NODE_HOLDS[@]} )); then
    warn "Порт ${NODE_HOLDS[*]} сейчас слушает нода ($NODE_NAMES, Xray)."
    warn "Перед запуском nginx на этом порту ноду остановлю, а в конце запущу обратно."
    warn "Важно: дальше ${NODE_HOLDS[*]} будет у nginx. Инбаунд на этом порту в профиле ноды перенеси на другой порт"
    warn "или убери — иначе Xray на ноде не запустится."
    confirm_yn "Продолжить?" y || die "Остановлено — порт ${NODE_HOLDS[*]} оставлен ноде"
  fi

  # XHTTP-инбаунд должен слушать только 127.0.0.1. Если порт занят снаружи (например, прямым REALITY) —
  # инбаунд на нём не поднимется.
  local addrs
  addrs=$(ss -Htln "sport = :$XHTTP_PORT" 2>/dev/null | awk '{print $4}' | grep -vE '^(127\.0\.0\.1|\[::1\]):' | paste -sd' ' - || true)
  if [[ -n $addrs ]]; then
    warn "Порт $XHTTP_PORT уже слушается не только на 127.0.0.1 ($addrs) — XHTTP-инбаунд на нём не поднимется."
    warn "Освободи порт или запусти скрипт с --xhttp-port <другой порт>"
    confirm_yn "Продолжить всё равно?" n || die "Остановлено: порт $XHTTP_PORT занят"
  fi
}

setup_ufw() {
  if (( NO_UFW )); then return 0; fi
  command -v ufw >/dev/null 2>&1 || apt_install ufw
  local was_active=0 p ip ssh_ports=""
  if [[ $(ufw status 2>/dev/null || true) == *"Status: active"* ]]; then was_active=1; fi

  # SSH: 22 всегда + порты, на которых реально слушает sshd (если он перенесён)
  ssh_ports=$(ss -Htlnp 2>/dev/null | grep '"sshd"' | awk '{print $4}' | sed 's/.*://' | sort -un | paste -sd' ' - || true)
  for p in 22 $ssh_ports; do ufw allow "$p/tcp" comment 'SSH' >/dev/null; done
  UFW_SUMMARY+=("SSH: $(printf '%s\n' 22 $ssh_ports | sort -un | paste -sd, -)")

  ufw allow 80/tcp comment 'HTTP (certbot)' >/dev/null
  ufw allow 443/tcp comment 'HTTPS (nginx)' >/dev/null
  UFW_SUMMARY+=("80, 443: для всех")

  for p in ${NODE_PUBLIC_PORTS[@]+"${NODE_PUBLIC_PORTS[@]}"}; do
    ufw allow "$p" comment 'Remnawave inbound' >/dev/null
  done
  if (( ${#NODE_PUBLIC_PORTS[@]} )); then UFW_SUMMARY+=("инбаунды ноды: ${NODE_PUBLIC_PORTS[*]}"); fi

  # Порт ноды — только для панели: убираем правила «открыт всем», если были
  ufw delete allow "$NODE_PORT/tcp" >/dev/null 2>&1 || true
  ufw delete allow "$NODE_PORT" >/dev/null 2>&1 || true
  for ip in "${PANEL_IPS[@]}"; do
    ufw allow from "$ip" to any port "$NODE_PORT" proto tcp comment 'Remnawave panel' >/dev/null
  done
  UFW_SUMMARY+=("$NODE_PORT: только для панели ($PANEL_ADDR → ${PANEL_IPS[*]})")

  if (( ! was_active )); then
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
  fi
  ufw --force enable >/dev/null
  log "UFW включён:"
  for p in "${UFW_SUMMARY[@]}"; do echo "    - $p"; done
}

issue_cert() {
  if cert_exists; then
    log "Сертификат для $DOMAIN уже есть (действует до $(cert_end)) — заново не выпускаю"
    return 0
  fi
  ask_email
  command -v certbot >/dev/null 2>&1 || apt_install certbot
  selftest_challenge
  log "Выпускаю сертификат для $DOMAIN…"
  if ! certbot certonly --webroot -w "$WWW_DIR" -d "$DOMAIN" --cert-name "$DOMAIN" \
        -m "$EMAIL" --agree-tos --no-eff-email --non-interactive --keep-until-expiring; then
    die "Сертификат не выпустился. Проверь, что A-запись $DOMAIN указывает на этот сервер и что 80 порт открыт у хостера. Подробности: /var/log/letsencrypt/letsencrypt.log"
  fi
  cert_exists || die "certbot отработал, но сертификата в $LE_DIR/live/$DOMAIN/ нет"
  log "Сертификат выпущен (действует до $(cert_end))"
}

setup_renewal() {
  command -v certbot >/dev/null 2>&1 || apt_install certbot
  local hook="$LE_DIR/renewal-hooks/deploy/remnanode-nginx-reload.sh"
  mkdir -p "$(dirname "$hook")"
  cat >"$hook" <<EOF
#!/bin/sh
# remnanode-nginx-setup: перечитать nginx после продления сертификата
docker exec ${CONTAINER} nginx -s reload >/dev/null 2>&1 || true
EOF
  chmod 755 "$hook"
  log "После продления nginx будет перечитывать сертификат ($hook)"

  local units=""
  if command -v systemctl >/dev/null 2>&1; then
    units=$(systemctl list-unit-files 'certbot.timer' 'snap.certbot.renew.timer' 2>/dev/null || true)
  fi
  if [[ $units == *snap.certbot.renew.timer* ]]; then
    log "Автопродление: snap.certbot.renew.timer"
  elif [[ $units == *certbot.timer* ]]; then
    systemctl enable --now certbot.timer >/dev/null 2>&1 || true
    log "Автопродление: systemd-таймер certbot.timer (2 раза в день)"
  else
    command -v cron >/dev/null 2>&1 || apt_install cron
    printf '%s\n' "# remnanode-nginx-setup: автопродление сертификатов" \
      "17 3,15 * * * root certbot -q renew" >/etc/cron.d/remnanode-certbot
    chmod 644 /etc/cron.d/remnanode-certbot
    log "Автопродление: cron (/etc/cron.d/remnanode-certbot, 2 раза в день)"
  fi

  if certbot renew --dry-run --cert-name "$DOMAIN" >/dev/null 2>&1; then
    log "Проверка продления прошла (certbot renew --dry-run)"
  else
    warn "Проверка продления не прошла — запусти «certbot renew --dry-run» и посмотри вывод"
  fi
}

gen_index() {
  local parts name initial year
  IFS=. read -ra parts <<<"$DOMAIN"
  name=${parts[${#parts[@]}-2]}
  name=${name^}
  initial=${name:0:1}
  year=$(date +%Y)
  cat <<EOF
<!doctype html>
${HTML_MARK}
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${name}</title>
<meta name="description" content="${name} — media delivery platform.">
<style>
  :root {
    --bg: #0b0d12; --fg: #e8eaf0; --muted: #8b93a7; --card: #121621; --line: #1f2535;
    --accent: #6c8cff; --accent2: #a06cff;
    color-scheme: dark light;
  }
  @media (prefers-color-scheme: light) {
    :root { --bg: #f5f7fb; --fg: #151a26; --muted: #5d667a; --card: #ffffff; --line: #e3e7ef; }
  }
  * { box-sizing: border-box; }
  html, body { height: 100%; }
  body {
    margin: 0; display: flex; flex-direction: column;
    font: 16px/1.6 system-ui, -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    background: var(--bg); color: var(--fg);
    background-image: radial-gradient(60rem 30rem at 85% -10%, rgba(108, 140, 255, .16), transparent 60%),
                      radial-gradient(40rem 24rem at -10% 110%, rgba(160, 108, 255, .12), transparent 60%);
  }
  header { padding: 24px 28px; display: flex; align-items: center; gap: 10px; font-weight: 600; }
  .logo {
    width: 30px; height: 30px; border-radius: 9px; display: grid; place-items: center;
    background: linear-gradient(135deg, var(--accent), var(--accent2)); color: #fff; font-size: 15px;
  }
  main { flex: 1; display: grid; place-items: center; padding: 24px; }
  .hero { max-width: 600px; text-align: center; }
  h1 { font-size: clamp(30px, 5.5vw, 48px); line-height: 1.12; letter-spacing: -.02em; margin: 0 0 16px; }
  h1 span {
    background: linear-gradient(90deg, var(--accent), var(--accent2));
    -webkit-background-clip: text; background-clip: text; color: transparent;
  }
  p { color: var(--muted); margin: 0 auto 30px; max-width: 46ch; }
  .status {
    display: inline-flex; align-items: center; gap: 9px; padding: 8px 15px; font-size: 14px;
    border: 1px solid var(--line); border-radius: 999px; background: var(--card); color: var(--muted);
  }
  .dot { width: 8px; height: 8px; border-radius: 50%; background: #22c55e; animation: pulse 2s infinite; }
  @keyframes pulse {
    0%   { box-shadow: 0 0 0 0 rgba(34, 197, 94, .5); }
    70%  { box-shadow: 0 0 0 9px rgba(34, 197, 94, 0); }
    100% { box-shadow: 0 0 0 0 rgba(34, 197, 94, 0); }
  }
  footer { padding: 24px; text-align: center; font-size: 13px; color: var(--muted); }
</style>
</head>
<body>
  <header><div class="logo">${initial}</div>${name}</header>
  <main>
    <section class="hero">
      <h1>Fast, reliable <span>media delivery</span></h1>
      <p>${name} powers streaming and content distribution for our partners. Public access is limited while we prepare the new platform.</p>
      <div class="status"><span class="dot"></span>All systems operational</div>
    </section>
  </main>
  <footer>&copy; ${year} ${name}</footer>
</body>
</html>
EOF
}

make_index() {
  local f="$WWW_DIR/index.html"
  if [[ -s $f ]] && ! grep -Fq "$HTML_MARK" "$f"; then
    if confirm_yn "В $f уже есть своя страница. Заменить её заглушкой?" n; then
      cp -a "$f" "$f.bak-$(stamp)"
    else
      log "Оставил текущий $f"
      return 0
    fi
  fi
  gen_index >"$f"
  chmod 644 "$f"
  log "Заглушка: $f"
}

finish() {
  local code s
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
         --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/" 2>/dev/null || true)

  hdr "Для панели Remnawave"
  echo "  Инбаунд:  VLESS, xhttp, security none, listen 127.0.0.1, port $XHTTP_PORT, path $XHTTP_PATH"
  echo "  Хост:     адрес $DOMAIN, порт 443, TLS, SNI $DOMAIN, XHTTP mode packet-up"
  if (( ! NO_UFW )); then
    echo "  UFW:"
    for s in "${UFW_SUMMARY[@]}"; do echo "    - $s"; done
    echo "    Новый инбаунд на публичном порту — открой его: ufw allow <порт>"
  fi

  if (( ${#NODE_HOLDS[@]} )); then
    echo
    if (( NODE_BIND_FAIL )); then
      warn "Xray на ноде НЕ запустился: порт ${NODE_HOLDS[*]} теперь у nginx."
      warn "В панели перенеси инбаунд с ${NODE_HOLDS[*]} на другой порт (и открой его: ufw allow <порт>)"
      warn "или назначь ноде профиль, где на ${NODE_HOLDS[*]} ничего нет. Пока это не сделано — нода offline."
    else
      warn "Порт ${NODE_HOLDS[*]} теперь у nginx. Если в профиле ноды остался инбаунд на ${NODE_HOLDS[*]} — перенеси его,"
      warn "иначе Xray не запустится. Проверь в панели, что нода Online."
    fi
  fi

  echo
  if [[ $code == 200 ]]; then
    printf '%s✅ Всё готово!%s\n' "$C_G" "$C_0"
  else
    warn "Проверка с сервера вернула код '${code:-нет ответа}' — что-то может быть не так."
  fi
  echo "Открой в браузере https://$DOMAIN — там должна открыться заглушка."
  echo "Если её нет или браузер ругается на сертификат — напиши в поддержку: $SUPPORT"
}

main() {
  parse_args "$@"
  init_tty
  trap on_exit EXIT
  hdr "Remnawave Node: nginx + сертификат + XHTTP + UFW"
  preflight
  ask_domain
  ask_path
  ask_ufw
  install_deps
  check_dns
  check_ports

  hdr "docker-compose.yml"
  compose_add_nginx

  hdr "nginx: 80 порт"
  prepare_dirs
  prepare_container
  if user_conf_has_domain; then
    SKIP_BLOCKS=1
    warn "В $NGINX_CONF уже есть твоя настройка для $DOMAIN — её не трогаю и свои блоки не добавляю."
    warn "Проверь сам, что XHTTP-location там ведёт на 127.0.0.1:$XHTTP_PORT."
    nginx_up 0
  elif append_block http gen_http_block; then
    nginx_up 1
    log "Добавил блок 80 порта для $DOMAIN в конец $NGINX_CONF"
  else
    nginx_up 0
    log "Блок 80 порта для $DOMAIN уже есть в $NGINX_CONF"
  fi

  hdr "UFW"
  if (( NO_UFW )); then log "Пропускаю"; else setup_ufw; fi

  hdr "Сертификат"
  issue_cert

  hdr "nginx: 443 порт"
  if (( ! SKIP_BLOCKS )); then
    if has_default_443; then ADD_DEFAULT=0; else ADD_DEFAULT=1; fi
    if append_block https gen_https_block; then
      nginx_up 1
      log "Добавил блок 443 порта: сайт + XHTTP $XHTTP_PATH → 127.0.0.1:$XHTTP_PORT"
    else
      nginx_up 0
      log "Блок 443 порта для $DOMAIN уже есть в $NGINX_CONF"
    fi
  else
    nginx_up 0
  fi
  if conf_listens 443; then wait_443; fi

  hdr "Автопродление"
  setup_renewal

  hdr "Заглушка"
  make_index

  if (( ${#NODE_STOPPED[@]} )); then
    hdr "Нода"
    start_node
    check_node_after_start
  fi

  finish
}

[[ ${RNS_NO_MAIN:-0} == 1 ]] || main "$@"
