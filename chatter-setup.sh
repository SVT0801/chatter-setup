#!/usr/bin/env bash
# Chatter AI — установка на сервер клиента тремя командами.
#
#   sudo bash chatter-setup.sh prepare --domain chatter.example.com
#   sudo bash chatter-setup.sh install --domain chatter.example.com --version vX.Y.Z
#   sudo bash chatter-setup.sh check
#   sudo bash chatter-setup.sh report
#
# prepare — проверка сервера и подготовка: обновления ОС, Docker, firewall, fail2ban,
#           автообновления безопасности, UTC и NTP, пользователь chatter. Повторный запуск безопасен.
# install — ставит релиз: спрашивает токены скрыто, проверяет их, сеть, часы, DNS и порты ДО начала,
#           запускает установщик релиза службой chatter-install (обрыв SSH её не прерывает),
#           ставит службы и таймеры, в конце — check. Прерванная установка продолжается той же командой.
# check   — проверка сервера и установки. Сразу после install, после каждого «Оновити»
#           и после обновления ОС. Только читает.
# report  — блок CHATTER SUPPORT для SVT: сервер, DNS, контейнеры, журналы. Секреты скрыты.
#
# Публичная копия: https://github.com/SVT0801/chatter-setup . Секретов и кода продукта нет.
set -uo pipefail

SETUP_VERSION="1.2.0"
CATALOG_REPO="${CHATTER_CATALOG_REPO:-SVT0801/chatter-ai-backend}"
CHATTER_USER="chatter"
CHATTER_HOME="/home/${CHATTER_USER}"
CHATTER_ROOT="${CHATTER_ROOT:-${CHATTER_HOME}/chatter-ai}"
LOG_FILE="${CHATTER_SETUP_LOG:-/var/log/chatter-setup.log}"
INSTALL_LOG="${CHATTER_INSTALL_LOG:-/var/log/chatter-install.log}"
SUPPORT_DIR="${CHATTER_SUPPORT_DIR:-/var/log}"
OS_RELEASE="${CHATTER_OS_RELEASE:-/etc/os-release}"
INSTALL_UNIT="chatter-install"
NGINX_CONTAINER="chatter-supabase-nginx"
AUTH_CONTAINER="chatter-supabase-auth"
AUTH_SERVICE="auth"
# The host API (uvicorn) binds to the compose network gateway, e.g.
# 172.18.0.1:8090; the nginx container reaches it from inside that network. ufw
# default-deny drops those packets unless the docker subnet is allowed to 8090.
# Allow only the RFC1918 range Docker Compose draws its networks from — never the
# internet.
API_PORT="8090"
DOCKER_API_NET="172.16.0.0/12"
# Cloudflare proxy ranges. A record pointing here = orange cloud. Whether
# Let's Encrypt HTTP-01 still reaches this server is checked live (acme_path_reaches_server).
CF_NETS="173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22"
CF_NETS6="2400:cb00: 2606:4700: 2803:f800: 2405:b500: 2405:8100: 2a06:98c 2c0f:f248:"
# Outbound HTTPS the install needs: catalog, bundle, images, pip, certificate.
NET_HOSTS="api.github.com codeload.github.com objects.githubusercontent.com release-assets.githubusercontent.com ghcr.io pkg-containers.githubusercontent.com registry-1.docker.io production.cloudflare.docker.com pypi.org files.pythonhosted.org acme-v02.api.letsencrypt.org"

FAILS=0 WARNS=0
CUR_CMD="" CUR_STEP="" CUR_DOMAIN=""
KNOWN_SECRETS="" TMP_PATHS=""
LOG_ACTIVE=0 LOG_START=0 LOG_PID=""
WHY="" TODO="" PROBE_CODE="" PROBE_ERR="" FETCH_ERR="" TP_CODE="" TP_DAYS=""

# ------------------------------------------------------------------ output
if [[ -t 1 ]]; then G=$'\033[32m' Y=$'\033[33m' R=$'\033[31m' B=$'\033[1m' N=$'\033[0m'; else G="" Y="" R="" B="" N=""; fi
hint() { if [[ -n "${1:-}" ]]; then printf '        → %s\n' "$1"; fi; }
pass() { printf '  %sPASS%s  %-24s %s\n' "$G" "$N" "$1" "$2"; }
warn() { printf '  %sWARN%s  %-24s %s\n' "$Y" "$N" "$1" "$2"; hint "${3:-}"; WARNS=$((WARNS + 1)); }
fail() { printf '  %sFAIL%s  %-24s %s\n' "$R" "$N" "$1" "$2"; hint "${3:-}"; FAILS=$((FAILS + 1)); }
info() { printf '  INFO  %-24s %s\n' "$1" "$2"; }
step() { CUR_STEP="$*"; printf '\n%s== %s%s\n' "$B" "$*" "$N"; }

# Every stop: WHAT / WHY / WHAT TO DO, then the support block to copy (S-06).
die() {
  local what="$1" why="${2:-}" todo="${3:-}"
  {
    printf '\n%sСТОП:%s %s\n' "$R" "$N" "$what"
    if [[ -n "$why" ]]; then printf '  Почему:      %s\n' "$why"; fi
    if [[ -n "$todo" ]]; then printf '  Что сделать: %s\n' "$todo"; fi
  } >&2
  if [[ "${CHATTER_SETUP_NO_REPORT:-0}" != 1 ]]; then support_report "$what" "$why" >&2; fi
  exit 1
}

track_tmp() { TMP_PATHS="${TMP_PATHS}${1}"$'\n'; }

# One exit path for temp files (S-22) and for the log pipe (S-29).
cleanup() {
  local p i
  while IFS= read -r p; do
    if [[ -n "$p" ]]; then rm -rf "$p"; fi
  done <<<"$TMP_PATHS"
  TMP_PATHS=""
  if (( LOG_ACTIVE )); then
    LOG_ACTIVE=0
    exec 1>&3 2>&4 3>&- 4>&-
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      kill -0 "$LOG_PID" 2>/dev/null || break
      sleep 0.1
    done
  fi
}

_t() { local s="$1"; shift; if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"; else "$@"; fi; }

# ------------------------------------------------------------------ secrets out of logs and reports
# sed -E script: token formats, KEY=value lines, URL passwords, colours, and the
# literal values of the secrets this server holds.
mask_rules() {
  printf 's/\033\\[[0-9;]*m//g\n'
  printf '%s\n' \
    's/github_pat_[A-Za-z0-9_]{8,}/***/g' \
    's/gh[opsur]_[A-Za-z0-9]{8,}/***/g' \
    's#([Bb]earer|[Bb]asic) +[A-Za-z0-9._~+/=-]{6,}#\1 ***#g' \
    's/eyJ[A-Za-z0-9_.-]{10,}/***/g' \
    's/([A-Za-z0-9_]*(_KEY|PASSWORD|SECRET|TOKEN))=[^[:space:]]*/\1=***/g' \
    's#(://[^:/@[:space:]]+):[^@[:space:]]+@#\1:***@#g'
  local v
  while IFS= read -r v; do
    if [[ ${#v} -ge 8 ]]; then
      printf 's#%s#***#g\n' "$(printf '%s' "$v" | sed -e 's/[][\.*^$(){}+?|#]/\\&/g')"
    fi
  done <<<"$(secret_values)"
}

secret_values() {
  local f
  {
    for f in "${CHATTER_ROOT}/env/.env" "${CHATTER_ROOT}/env/update-agent.env" "${CHATTER_ROOT}/env/api.env"; do
      if [[ -r "$f" ]]; then
        grep -E '^[A-Za-z0-9_]*(_KEY|PASSWORD|SECRET|TOKEN)=' "$f" 2>/dev/null | cut -d= -f2- | tr -d "\"'"
      fi
    done
    printf '%s\n' "${CHATTER_TOKEN:-}" "${GHCR_TOKEN:-}"
    printf '%s' "$KNOWN_SECRETS"
  } | awk 'length($0) >= 8' | sort -u
}

mask_secrets() {
  local rules; rules="$(mktemp)"
  mask_rules > "$rules"
  sed -E -f "$rules"
  rm -f "$rules"
}

# ------------------------------------------------------------------ helpers (pure — covered by test)
# 0 if $1 is a supported distro ID + VERSION_ID.
os_supported() {
  case "$1:$2" in
    debian:12|debian:13|ubuntu:24.04|ubuntu:26.04) return 0 ;;
    *) return 1 ;;
  esac
}

valid_version() { [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[a-z0-9.]+)?$ ]]; }

valid_domain() { [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; }

# " HTTPS://Chatter.Example.com/ " → chatter.example.com (S-20).
norm_domain() {
  printf '%s' "$1" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]' \
    | sed -E -e 's#^https?://##' -e 's#/.*$##' -e 's/\.$//'
}

# Token pasted from a messenger: no spaces, tabs or CR/LF (S-20).
trim_token() { local t="$1"; t="${t//[$' \t\r\n']/}"; printf '%s' "$t"; }

ip_to_int() {
  local IFS=. a b c d
  read -r a b c d <<<"$1"
  echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

# 0 if IPv4 $1 is inside CIDR $2.
ip_in_cidr() {
  local ip="$1" net="${2%/*}" bits="${2#*/}" mask
  mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
  (( ($(ip_to_int "$ip") & mask) == ($(ip_to_int "$net") & mask) ))
}

is_cloudflare_ip() {
  local n
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  for n in $CF_NETS; do ip_in_cidr "$1" "$n" && return 0; done
  return 1
}

is_cloudflare_ip6() {
  local x p
  x="$(printf '%s' "$1" | tr 'A-F' 'a-f')"
  for p in $CF_NETS6; do [[ "$x" == "$p"* ]] && return 0; done
  return 1
}

ip_is_private() {
  local n
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  for n in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10; do ip_in_cidr "$1" "$n" && return 0; done
  return 1
}

# 0 if a ufw "From" column value is a private/docker subnet (so a rule scoped to
# it is ours, not an exposure). "Anywhere" / a public IP → 1.
fw_from_is_internal() {
  local base="${1%% *}"; base="${base%%/*}"
  ip_is_private "$base"
}

# ufw ALLOW ports that are not expected. Expected: ssh ($1), 80, 443, and the API
# port ONLY from a docker/private subnet. The API port open to Anywhere is still
# listed (8090 must never face the internet). Reads `ufw status` on stdin.
fw_extra_rules() {
  local sp="$1" line to from
  while IFS= read -r line; do
    [[ "$line" == *ALLOW* && "$line" != *'(v6)'* ]] || continue
    to="$(awk '{print $1}' <<<"$line")"
    from="$(awk '{$1=""; $2=""; sub(/^[[:space:]]+/,""); print}' <<<"$line")"
    case " ${sp}/tcp 80/tcp 443/tcp " in *" $to "*) continue ;; esac
    if [[ "$to" == "${API_PORT}/tcp" ]] && fw_from_is_internal "$from"; then continue; fi
    printf '%s ' "$to"
  done
}

# HTTP code of a GitHub call → WHY / TODO in plain words (S-05).
explain_http() {
  local code="${1:-000}" err="${2:-}" what="${3:-релиз}"
  case "$code" in
    000|"")
      WHY="нет связи с api.github.com${err:+: $err}"
      TODO="проверьте интернет, DNS, firewall и часы сервера: curl -sI https://api.github.com ; date -u" ;;
    401)
      WHY="GitHub не принял токен (HTTP 401): токен неверный, вставлен не полностью или истёк"
      TODO="запросите у SVT новый токен и запустите команду снова" ;;
    403)
      WHY="GitHub отказал (HTTP 403): исчерпан лимит запросов или у токена нет прав"
      TODO="повторите через час; если повторится — сообщите SVT" ;;
    404)
      WHY="токен не видит ${what} (HTTP 404): у токена нет доступа к каталогу или такой версии нет"
      TODO="сверьте версию и токен с SVT" ;;
    5??)
      WHY="сбой на стороне GitHub (HTTP ${code})"
      TODO="повторите через 10 минут; статус GitHub: https://www.githubstatus.com" ;;
    200)
      WHY="у ${what} нет manifest.json — релиз ещё собирается"
      TODO="повторите через 15 минут или уточните версию у SVT" ;;
    *)
      WHY="неожиданный ответ GitHub (HTTP ${code})${err:+: $err}"
      TODO="повторите; если повторится — отправьте SVT блок CHATTER SUPPORT" ;;
  esac
}

curl_net() {
  printf '%s\n' --connect-timeout 15 --retry 3 --retry-delay 3
  if curl --help all 2>/dev/null | grep -q -- '--retry-all-errors'; then printf '%s\n' --retry-all-errors; fi
}

# curl to GitHub with the token in a config read from stdin: never in argv (ps).
gh_curl() {
  local token="$1"; shift
  printf 'header = "Authorization: Bearer %s"\n' "$token" | curl -sS -K - "$@"
}

# Release tag exists and carries manifest.json. Sets PROBE_CODE / PROBE_ERR.
check_catalog_token() {
  local token="$1" version="$2" body err net
  body="$(mktemp)"; err="$(mktemp)"
  net="$(curl_net | tr '\n' ' ')"
  # shellcheck disable=SC2086
  PROBE_CODE="$(gh_curl "$token" $net -o "$body" -w '%{http_code}' --max-time 60 \
    -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/${CATALOG_REPO}/releases/tags/${version}" 2>"$err" || true)"
  [[ -n "$PROBE_CODE" ]] || PROBE_CODE=000
  PROBE_ERR="$(head -1 "$err" 2>/dev/null)"
  if [[ "$PROBE_CODE" == 200 ]] && grep -q '"name": *"manifest.json"' "$body"; then rm -f "$body" "$err"; return 0; fi
  rm -f "$body" "$err"; return 1
}

# docker login output → WHY / TODO (S-05).
explain_ghcr() {
  local first; first="$(printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | tail -1 | mask_secrets)"
  case "$1" in
    *denied*|*nauthorized*|*"incorrect username or password"*)
      WHY="ghcr.io не принял GHCR_TOKEN: нужен classic-токен с правом read:packages"
      TODO="проверьте, что вставили второй токен от SVT (ghp_…); иначе запросите новый" ;;
    *timeout*|*"no such host"*|*"connection refused"*|*"TLS handshake"*|*"network is unreachable"*)
      WHY="нет связи с ghcr.io: ${first}"
      TODO="откройте исходящий HTTPS к ghcr.io и pkg-containers.githubusercontent.com" ;;
    *)
      WHY="docker login ghcr.io: ${first:-нет ответа}"
      TODO="проверьте Docker (sudo docker info) и запустите install снова" ;;
  esac
}

# Download manifest + bundle of $2 into $3 and unpack deploy/ there; checks sha256.
# Root needs the release's systemd units and sudoers BEFORE the installer runs as
# chatter: install.sh restarts chatter-api via sudo -n and hard-fails API health.
# rc 2 = download failed, 3 = sha256 mismatch, 4 = cannot unpack; FETCH_ERR says why.
fetch_release_deploy() {
  local token="$1" version="$2" dir="$3" rel murl burl want got net err="$3/.curl.err"
  net="$(curl_net | tr '\n' ' ')"
  FETCH_ERR=""
  # shellcheck disable=SC2086
  rel="$(gh_curl "$token" -f $net --max-time 60 -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/${CATALOG_REPO}/releases/tags/${version}" 2>"$err")" \
    || { FETCH_ERR="описание релиза: $(head -1 "$err")"; return 2; }
  murl="$(jq -r '.assets[] | select(.name == "manifest.json") | .url' <<<"$rel")"
  burl="$(jq -r '[.assets[] | select(.name | test("^chatter-bundle.*\\.tar\\.gz$"))][0].url' <<<"$rel")"
  [[ -n "$murl" && "$murl" != null && -n "$burl" && "$burl" != null ]] \
    || { FETCH_ERR="в релизе нет manifest.json или бандла"; return 2; }
  # shellcheck disable=SC2086
  gh_curl "$token" -fL $net --max-time 120 -H 'Accept: application/octet-stream' "$murl" -o "$dir/manifest.json" 2>"$err" \
    || { FETCH_ERR="manifest.json: $(head -1 "$err")"; return 2; }
  # shellcheck disable=SC2086
  gh_curl "$token" -fL $net --speed-limit 1024 --speed-time 60 -H 'Accept: application/octet-stream' "$burl" \
    -o "$dir/bundle.tar.gz" 2>"$err" || { FETCH_ERR="бандл: $(head -1 "$err")"; return 2; }
  want="$(jq -r '.artifacts.sha256 // empty' "$dir/manifest.json")"
  got="$(sha256sum "$dir/bundle.tar.gz" | awk '{print $1}')"
  [[ -z "$want" || "$want" == "$got" ]] || { FETCH_ERR="sha256 ожидался ${want}, получен ${got}"; return 3; }
  tar -xzf "$dir/bundle.tar.gz" -C "$dir" deploy 2>/dev/null || tar -xzf "$dir/bundle.tar.gz" -C "$dir" ./deploy 2>"$err" \
    || { FETCH_ERR="tar: $(head -1 "$err")"; return 4; }
}

# ------------------------------------------------------------------ facts
read_os() { ( . "$OS_RELEASE" 2>/dev/null; printf '%s %s %s\n' "${ID:-?}" "${VERSION_ID:-?}" "${VERSION_CODENAME:-}" ); }

# Public IPv4: two services, then the route source address (private behind NAT) (S-11).
public_ip() {
  local ip src
  for src in https://api.ipify.org https://ifconfig.me/ip; do
    ip="$(curl -fsS --max-time 6 "$src" 2>/dev/null || true)"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then printf '%s' "$ip"; return 0; fi
  done
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") {printf "%s", $(i+1); exit}}'
}

ip_is_local() { ip -4 -o addr show 2>/dev/null | grep -qF " $1/"; }

dns_a() { getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' | sed 's/ $//'; }

dns_aaaa() { getent ahostsv6 "$1" 2>/dev/null | awk '{print $1}' | grep -v '^::ffff:' | sort -u | tr '\n' ' ' | sed 's/ $//'; }

server_ipv6s() { ip -6 addr show scope global 2>/dev/null | awk '/inet6/{split($2,a,"/"); print a[1]}'; }

# Let's Encrypt HTTP-01 path check, the way Let's Encrypt itself does it: serve a
# random file under /.well-known/acme-challenge/ on port 80 for a moment and fetch
# it by the public domain (through Cloudflare, if it proxies). No redirects followed.
# 0 = reached this server, 1 = did not, 2 = cannot test here (port busy / no python3).
acme_path_reaches_server() {
  local domain="$1" port="${CHATTER_SETUP_ACME_PORT:-80}" dir tok pid got rc=1 i
  command -v python3 >/dev/null 2>&1 || return 2
  dir="$(mktemp -d)"; tok="chatter-probe-$(date +%s)-${RANDOM}"
  mkdir -p "$dir/.well-known/acme-challenge"
  printf '%s' "$tok" > "$dir/.well-known/acme-challenge/$tok"
  python3 -m http.server "$port" --bind 0.0.0.0 --directory "$dir" >/dev/null 2>&1 &
  pid=$!
  # A busy port makes python exit at once — check that before trusting a reply.
  sleep 1
  kill -0 "$pid" 2>/dev/null || { rm -rf "$dir"; return 2; }
  for i in 1 2 3 4 5; do
    curl -s --max-time 2 -o /dev/null "http://127.0.0.1:${port}/" 2>/dev/null && break
    sleep 1
  done
  got="$(curl -s --max-time 15 "http://${domain}/.well-known/acme-challenge/${tok}" 2>/dev/null || true)"
  [[ "$got" == "$tok" ]] && rc=0
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  rm -rf "$dir"
  return "$rc"
}

ssh_port() { sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}'; }

env_get() { [[ -r "$2" ]] && grep -E "^$1=" "$2" | tail -1 | cut -d= -f2- | tr -d '"' || true; }

unit_active() { systemctl is-active --quiet "$1.service" 2>/dev/null; }

have_systemd_run() {
  [[ "${CHATTER_SETUP_NO_SYSTEMD_RUN:-0}" != 1 ]] && command -v systemd-run >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

# ------------------------------------------------------------------ install state (S-01)
# state/install-progress — an install attempt is running or was cut off; it is
# removed only when the whole install, check included, passed.
# state/install-complete — written by install.sh and by this script at the end.
# Older installs have neither: current + env/.env + state/update-status.json
# (install.sh seeds the status file only after health OK) count as installed.
progress_file() { printf '%s' "${CHATTER_ROOT}/state/install-progress"; }
done_file() { printf '%s' "${CHATTER_ROOT}/state/install-complete"; }

installed() {
  [[ -f "$(progress_file)" ]] && return 1
  [[ -f "$(done_file)" ]] && return 0
  [[ -L "${CHATTER_ROOT}/current" && -f "${CHATTER_ROOT}/env/.env" && -f "${CHATTER_ROOT}/state/update-status.json" ]]
}

install_started() { [[ -f "$(progress_file)" || -L "${CHATTER_ROOT}/current" || -f "${CHATTER_ROOT}/env/.env" ]]; }

progress_get() { if [[ -f "$(progress_file)" ]]; then grep -E "^$1=" "$(progress_file)" | tail -1 | cut -d= -f2-; fi; }

progress_mark() {
  install -d -m 755 -o "$CHATTER_USER" -g "$CHATTER_USER" "${CHATTER_ROOT}/state" 2>/dev/null || mkdir -p "${CHATTER_ROOT}/state"
  printf 'step=%s\nversion=%s\ndomain=%s\nupdated=%s\n' "$1" "$2" "$CUR_DOMAIN" "$(date -u +%FT%TZ)" > "$(progress_file)"
}

mark_install_complete() {
  printf 'version=%s\ndate=%s\nby=chatter-setup %s\n' "$1" "$(date -u +%FT%TZ)" "$SETUP_VERSION" > "$(done_file)"
  rm -f "$(progress_file)"
}

require_root() {
  [[ $EUID -eq 0 ]] || die "нужны права root" "команда меняет систему или читает закрытые файлы" "запустите через sudo: sudo bash $0 $*"
}

need_val() {
  [[ $# -ge 2 && -n "$2" && "$2" != --* ]] \
    || die "параметр $1 без значения" "после $1 нужно значение" "пример: sudo bash $0 install --domain chatter.example.com --version vX.Y.Z"
}

# stdout/stderr → terminal + log; the log copy goes through mask_rules (S-08).
start_log() {
  local rules unbuf
  touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
  LOG_START="$(wc -l < "$LOG_FILE" 2>/dev/null | tr -d ' ')"
  rules="$(mktemp)"; track_tmp "$rules"
  mask_rules > "$rules"
  if sed --version >/dev/null 2>&1; then unbuf=-u; else unbuf=-l; fi
  exec 3>&1 4>&2
  exec > >(tee >(sed -E "$unbuf" -f "$rules" >> "$LOG_FILE")) 2>&1
  LOG_PID="${!:-}"; LOG_ACTIVE=1
  printf '\n######## chatter-setup %s %s %s\n' "$SETUP_VERSION" "$1" "$(date -u +%FT%TZ)"
}

# ------------------------------------------------------------------ support block (S-06)
support_body() {
  local what="$1" why="$2" d a six
  d="${CUR_DOMAIN:-$(env_get PROXY_DOMAIN "${CHATTER_ROOT}/env/.env")}"
  echo "chatter-setup ${SETUP_VERSION}; команда: ${CUR_CMD:-report}; шаг: ${CUR_STEP:-—}"
  echo "время: $(date -u +%FT%TZ)"
  if [[ -n "$what" ]]; then echo "ошибка: $what"; fi
  if [[ -n "$why" ]]; then echo "причина: $why"; fi
  echo "ОС: $(read_os); ядро: $(uname -r 2>/dev/null) $(uname -m 2>/dev/null)"
  echo "CPU: $(nproc 2>/dev/null || echo ?); RAM: $(free -m 2>/dev/null | awk '/^Mem:/{print $2" МБ, доступно "$7" МБ"}'); swap: $(free -m 2>/dev/null | awk '/^Swap:/{print $2" МБ"}')"
  echo "диск /: $(df -h / 2>/dev/null | awk 'NR==2{print $4" свободно из "$2" ("$5")"}'); /var/lib/docker: $(df -h /var/lib/docker 2>/dev/null | awk 'NR==2{print $4" свободно ("$5")"}')"
  echo "IP: $(public_ip)"
  if [[ -n "$d" ]]; then
    a="$(dns_a "$d")"; six="$(dns_aaaa "$d")"
    echo "домен: $d; A: ${a:-нет}; AAAA: ${six:-нет}; Cloudflare: $(is_cloudflare_ip "${a%% *}" && echo да || echo нет)"
  fi
  echo "docker: $(_t 10 docker --version 2>/dev/null || echo нет); compose: $(_t 10 docker compose version --short 2>/dev/null || echo нет)"
  echo "установка: complete=$( [[ -f "$(done_file)" ]] && tr '\n' ' ' < "$(done_file)" || echo нет); progress=$( [[ -f "$(progress_file)" ]] && tr '\n' ' ' < "$(progress_file)" || echo нет)"
  echo "current: $(readlink "${CHATTER_ROOT}/current" 2>/dev/null || echo нет); релизы: $(ls "${CHATTER_ROOT}/releases" 2>/dev/null | tr '\n' ' ')"
  echo "--- docker ps -a"
  _t 15 docker ps -a --format '{{.Names}}  {{.Status}}' 2>&1 | head -40
  echo "--- docker logs ${NGINX_CONTAINER} (последние 40 строк)"
  _t 15 docker logs --tail 40 "$NGINX_CONTAINER" 2>&1 | tail -40
  echo "--- journalctl -u chatter-api (последние 40 строк)"
  _t 15 journalctl -u chatter-api -n 40 --no-pager 2>&1 | tail -40
  if [[ -r "$INSTALL_LOG" ]]; then
    echo "--- ${INSTALL_LOG} (последние 40 строк)"
    tail -n 40 "$INSTALL_LOG"
  fi
  if install_started; then
    echo "--- check: FAIL и WARN"
    ( FAILS=0 WARNS=0; check_system; check_app "$d" ) 2>&1 | grep -E 'FAIL|WARN|→' | head -40
  fi
  if [[ -r "$LOG_FILE" ]]; then
    echo "--- ${LOG_FILE}: последние 60 строк этого запуска"
    tail -n "+$(( ${LOG_START:-0} + 1 ))" "$LOG_FILE" 2>/dev/null | tail -n 60
  fi
}

support_report() {
  local what="${1:-}" why="${2:-}" body file=""
  body="$(support_body "$what" "$why" 2>&1 | mask_secrets)"
  printf '\n----- CHATTER SUPPORT BEGIN -----\n%s\n----- CHATTER SUPPORT END -----\n' "$body"
  if [[ -d "$SUPPORT_DIR" && -w "$SUPPORT_DIR" ]]; then
    file="${SUPPORT_DIR}/chatter-support-$(date -u +%Y%m%dT%H%M%SZ).txt"
    ( umask 077; printf '%s\n' "----- CHATTER SUPPORT BEGIN -----" "$body" "----- CHATTER SUPPORT END -----" > "$file" ) 2>/dev/null || file=""
  fi
  printf 'Скопируйте текст от «CHATTER SUPPORT BEGIN» до «END» целиком и отправьте SVT. Секреты в нём скрыты.%s\n' "${file:+ Копия: $file}"
}

# ------------------------------------------------------------------ checks shared by prepare / install
check_os_and_resources() {
  local id ver code mem disk cpu
  read -r id ver code <<<"$(read_os)"
  os_supported "$id" "$ver" && pass os "$id $ver ($code)" || fail os "$id $ver не поддерживается: Debian 12/13, Ubuntu 24.04/26.04" "нужен новый сервер с поддерживаемой ОС"
  mem=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))
  cpu="$(nproc)"
  disk=$(( $(df -Pk / | awk 'NR==2{print $4}') / 1048576 ))
  (( mem >= 3500 )) && pass ram "${mem} МБ" || fail ram "${mem} МБ — нужно минимум 4 ГБ" "увеличьте тариф сервера"
  (( cpu >= 2 )) && pass cpu "$cpu" || fail cpu "$cpu — нужно минимум 2" "увеличьте тариф сервера"
  (( disk >= 30 )) && pass disk "свободно ${disk} ГБ" || fail disk "свободно ${disk} ГБ — нужно минимум 30 ГБ" "увеличьте диск или освободите место"
}

# Ports 80/443 must be free for the Chatter nginx (or already ours, also after
# an install that was cut off).
check_web_ports() {
  local p who
  for p in 80 443; do
    who="$(ss -tlnpH "sport = :$p" 2>/dev/null | grep -oE 'users:\(\("[^"]+' | head -1 | sed 's/users:(("//')"
    if [[ -z "$who" ]]; then pass "port.$p" "свободен"
    elif [[ "$who" == docker-proxy ]] && install_started; then pass "port.$p" "занят Chatter (docker-proxy)"
    else fail "port.$p" "занят процессом '$who' — на сервере уже есть веб-сервер" "Chatter нужен отдельный сервер; или остановите '$who'"; fi
  done
}

_dns_bad() { if [[ "$1" == 1 ]]; then fail "$2" "$3" "${4:-}"; else warn "$2" "$3" "${4:-}"; fi; }

# $1 domain, $2 strict (1 = FAIL, 0 = WARN).
# The HTTP-01 probe runs for every A answer (S-02). Caveat: from the server
# itself a direct A record is reached over the local stack, so a provider
# firewall is not visible here — that is said out loud, and the certificate is
# re-checked through the public domain after install (http.public).
check_dns() {
  local domain="$1" strict="$2" ip a first rc=0
  ip="$(public_ip)"
  if [[ -z "$ip" ]]; then info server.ip "не определён"
  elif ip_is_private "$ip"; then info server.ip "$ip (частный — сервер за NAT)"
  else info server.ip "$ip"; fi
  a="$(dns_a "$domain")"
  first="${a%% *}"
  if [[ -z "$a" ]]; then
    _dns_bad "$strict" dns "$domain не резолвится" "создайте A-запись: $domain → ${ip:-IP сервера}; через 5–30 минут запустите снова"
  elif is_cloudflare_ip "$first"; then
    # Behind the Cloudflare proxy. Fine as long as Let's Encrypt can still reach us.
    acme_path_reaches_server "$domain" || rc=$?
    if (( rc == 0 )); then
      pass dns "$domain → прокси Cloudflare; проверка Let's Encrypt доходит до сервера"
      info dns.cloudflare "в Cloudflare: SSL/TLS → Full или Full (strict), НЕ Flexible (иначе петля редиректов)"
    elif (( rc == 2 )); then
      warn dns "$domain → прокси Cloudflare; путь Let's Encrypt проверить нельзя (порт 80 занят или нет python3)"
    else
      _dns_bad "$strict" dns "$domain → прокси Cloudflare, и он не пропускает проверку Let's Encrypt (/.well-known/acme-challenge/) до сервера" \
        "в Cloudflare: запись → Proxy status: DNS only (серое облако), IPv4 = ${ip:-IP сервера}; или откройте порт 80 на сервере"
    fi
  else
    acme_path_reaches_server "$domain" || rc=$?
    if [[ "$a" == "$ip" ]]; then
      if (( rc == 0 )); then
        pass dns "$domain → $ip; путь Let's Encrypt (порт 80) отвечает"
        info dns.firewall "внешний firewall провайдера изнутри не виден: в панели хостинга должны быть открыты 80 и 443"
      elif (( rc == 2 )); then
        pass dns "$domain → $ip"
        info dns.acme "путь Let's Encrypt не проверен (порт 80 занят или нет python3)"
      elif ip_is_local "$ip"; then
        _dns_bad "$strict" dns "$domain → $ip, но по http://$domain/.well-known/acme-challenge/ сервер не отвечает — Let's Encrypt не выпустит сертификат" \
          "проверьте, что порт 80 не перехватывает прокси/iptables на сервере, и откройте 80 и 443 во внешнем firewall провайдера"
      else
        warn dns "$domain → $ip (сервер за NAT); проверка порта 80 с самого сервера не прошла" \
          "проверьте, что 80 и 443 проброшены на этот сервер и открыты во внешнем firewall провайдера"
      fi
    elif (( rc == 0 )); then
      pass dns "$domain → $a; сервер за NAT или с другим внешним адресом, но путь Let's Encrypt доходит сюда"
    else
      _dns_bad "$strict" dns "$domain → $a, а сервер ${ip:-?}$(ip_is_private "$ip" && echo ' (частный адрес)')" \
        "исправьте A-запись: $domain → внешний IP этого сервера (панель хостинга)"
    fi
  fi
  check_aaaa "$domain" "$strict"
}

# Let's Encrypt tries IPv6 first: an AAAA record that points elsewhere breaks the
# certificate even when the A record is right (S-02).
check_aaaa() {
  local domain="$1" strict="$2" six mine x bad=""
  six="$(dns_aaaa "$domain")"
  [[ -n "$six" ]] || return 0
  mine=" $(server_ipv6s | tr '\n' ' ') "
  for x in $six; do
    is_cloudflare_ip6 "$x" && continue
    [[ "$mine" == *" $x "* ]] || bad+="$x "
  done
  if [[ -z "$bad" ]]; then pass dns.aaaa "$six"
  else
    _dns_bad "$strict" dns.aaaa "AAAA-запись $domain → ${bad% } — это не IPv6 этого сервера; Let's Encrypt проверяет сначала IPv6 и не выпустит сертификат" \
      "удалите AAAA-запись у домена (или укажите IPv6 этого сервера)"
  fi
}

# ------------------------------------------------------------------ install pre-checks (S-03, S-10)
check_install_tools() {
  local b miss=""
  for b in curl jq python3 rsync tar openssl sudo visudo; do
    command -v "$b" >/dev/null 2>&1 || miss+="$b "
  done
  if [[ -z "$miss" ]]; then pass tools "curl jq python3 rsync tar openssl sudo"
  else fail tools "нет программ: ${miss% }" "сначала: sudo bash $0 prepare"; fi
  if python3 -c 'import venv, ensurepip' >/dev/null 2>&1; then pass python.venv "python3-venv есть"
  else fail python.venv "нет python3-venv — окружение API не соберётся" "sudo apt-get install -y python3-venv (или sudo bash $0 prepare)"; fi
}

check_docker_ready() {
  if _t 20 docker info >/dev/null 2>&1; then pass docker.daemon "отвечает"
  else fail docker.daemon "Docker установлен, но не отвечает" "sudo systemctl restart docker; sudo journalctl -u docker -n 50"; fi
  if id -nG "$CHATTER_USER" 2>/dev/null | grep -qw docker; then pass user.docker "$CHATTER_USER в группе docker"
  else fail user.docker "$CHATTER_USER не в группе docker" "sudo bash $0 prepare"; fi
}

# Wrong clock = TLS to GitHub and Let's Encrypt fails with an obscure error.
check_clock() {
  local d ts now skew
  d="$(curl -sSI --max-time 10 https://api.github.com 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="date"{print $2; exit}')"
  if [[ -z "$d" ]] || ! ts="$(date -d "$d" +%s 2>/dev/null)"; then
    warn time.skew "часы не сверить (нет ответа api.github.com)"
    return 0
  fi
  now="$(date +%s)"; skew=$(( now - ts )); (( skew < 0 )) && skew=$(( -skew ))
  if (( skew > 300 )); then fail time.skew "часы сервера расходятся с точным временем на ${skew} с — TLS к GitHub и Let's Encrypt не пройдёт" "sudo timedatectl set-ntp true; через минуту запустите снова"
  elif (( skew > 60 )); then warn time.skew "часы расходятся на ${skew} с" "sudo timedatectl set-ntp true"
  else pass time.skew "расхождение ${skew} с"; fi
}

# Outbound HTTPS to every host the install talks to, in parallel. Any HTTP answer
# (even 404) means the path is open; 000 means DNS / firewall / TLS (S-10).
check_network() {
  local d h pids="" p bad="" why=""
  d="$(mktemp -d)"; track_tmp "$d"
  for h in $NET_HOSTS; do
    ( c="$(curl -sS -o /dev/null --connect-timeout 5 --max-time 12 -w '%{http_code}' "https://$h/" 2>"$d/$h.err")"
      printf '%s' "${c:-000}" > "$d/$h.code" ) &
    pids+="$! "
  done
  for p in $pids; do wait "$p" 2>/dev/null; done
  for h in $NET_HOSTS; do
    if [[ "$(cat "$d/$h.code" 2>/dev/null)" == 000 ]]; then
      bad+="$h "
      [[ -n "$why" ]] || why="$(head -1 "$d/$h.err" 2>/dev/null)"
    fi
  done
  if [[ -z "$bad" ]]; then pass net "исходящий HTTPS: GitHub, ghcr.io, Docker Hub, PyPI, Let's Encrypt"
  else fail net "нет исходящего HTTPS к: ${bad% }${why:+ ($why)}" "откройте исходящий HTTPS (443) к этим адресам в firewall провайдера / прокси и запустите снова"; fi
}

# ------------------------------------------------------------------ prepare
APT=(apt-get -o DPkg::Lock::Timeout=600 -y -q)

# Output of a failed step → WHY / TODO (S-04).
step_failure_hint() {
  local f="$1" last
  last="$(grep -v '^[[:space:]]*$' "$f" 2>/dev/null | tail -1)"
  if grep -qE 'Could not get lock|dpkg frontend lock|is another process using it' "$f"; then
    WHY="apt занят: идут автообновления или первичная настройка сервера (unattended-upgrades / cloud-init)"
    TODO="подождите 5–10 минут и запустите prepare снова"
  elif grep -q 'dpkg was interrupted' "$f"; then
    WHY="установка пакетов была прервана раньше"
    TODO="sudo dpkg --configure -a, затем запустите prepare снова"
  elif grep -q 'No space left on device' "$f"; then
    WHY="на диске нет места"
    TODO="освободите место (df -h) и запустите prepare снова"
  elif grep -qE 'download\.docker\.com' "$f" && grep -qE 'Release|404|NO_PUBKEY' "$f"; then
    WHY="репозиторий Docker не принял эту версию ОС: ${last}"
    TODO="сообщите SVT версию ОС: cat /etc/os-release"
  elif grep -qE 'Temporary failure resolving|Could not resolve|Failed to fetch|Connection timed out|Network is unreachable|Could not connect' "$f"; then
    WHY="нет доступа к репозиториям пакетов: ${last}"
    TODO="проверьте интернет и DNS сервера (resolvectl status) и запустите prepare снова"
  else
    WHY="${last:-нет вывода}"
    TODO="запустите prepare снова; если повторится — отправьте SVT блок CHATTER SUPPORT"
  fi
}

# Run one prepare step; on error stop with the step name, command, code and advice.
run_step() {
  local name="$1" out rc; shift
  out="$(mktemp)"; track_tmp "$out"
  "$@" 2>&1 | tee "$out"
  rc=${PIPESTATUS[0]}
  if (( rc == 0 )); then rm -f "$out"; return 0; fi
  step_failure_hint "$out"
  die "шаг «${name}» не выполнен: $* (код ${rc})" "$WHY" "$TODO"
}

fw_setup() {
  ufw default deny incoming && ufw default allow outgoing && ufw allow "$1/tcp" \
    && ufw allow 80/tcp && ufw allow 443/tcp \
    && ufw allow from "$DOCKER_API_NET" to any port "$API_PORT" proto tcp \
    && ufw --force enable
}

cmd_prepare() {
  local domain="" ssh_key=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain) need_val "$@"; domain="$(norm_domain "$2")"; shift 2 ;;
      --ssh-key) need_val "$@"; ssh_key="$2"; shift 2 ;;
      *) die "неизвестный параметр: $1" "prepare знает только --domain и --ssh-key" "sudo bash $0 prepare --domain chatter.example.com" ;;
    esac
  done
  CUR_DOMAIN="$domain"
  require_root prepare
  [[ -z "$domain" ]] || valid_domain "$domain" \
    || die "домен «$domain» некорректен" "нужно полное имя: латиница, цифры, дефис и точки" "sudo bash $0 prepare --domain chatter.example.com"
  start_log prepare
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  local id ver code; read -r id ver code <<<"$(read_os)"

  step "1/9 Проверка сервера"
  check_os_and_resources
  check_web_ports
  [[ -n "$domain" ]] && check_dns "$domain" 0
  (( FAILS == 0 )) || die "сервер не подходит" "см. FAIL выше" "исправьте FAIL и запустите prepare снова. Ничего не изменено."

  step "2/9 Обновление системы"
  if command -v cloud-init >/dev/null 2>&1; then
    info apt "ждём окончания первичной настройки сервера (cloud-init), до 10 минут…"
    _t 600 cloud-init status --wait >/dev/null 2>&1 || true
  fi
  info apt "если идут автообновления, apt подождёт их до 10 минут"
  run_step "2/9 apt-get update" "${APT[@]}" update
  run_step "2/9 apt-get full-upgrade" "${APT[@]}" -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade
  "${APT[@]}" autoremove || warn apt.autoremove "не выполнен (не мешает установке)"

  step "3/9 Пакеты"
  local pkgs=(ca-certificates curl tar rsync gnupg jq openssl python3 python3-venv sudo tmux
              ufw fail2ban python3-systemd unattended-upgrades apt-listchanges needrestart)
  # NTP for time.sync (S-17): systemd-timesyncd unless another time daemon is there.
  command -v chronyd >/dev/null 2>&1 || command -v ntpd >/dev/null 2>&1 || [[ -x /lib/systemd/systemd-timesyncd ]] \
    || pkgs+=(systemd-timesyncd)
  run_step "3/9 установка пакетов" "${APT[@]}" install "${pkgs[@]}"

  step "4/9 Docker"
  if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
    info docker "уже установлен: $(docker --version | cut -d, -f1), $(docker compose version --short 2>/dev/null) — не трогаем"
  else
    install -m 0755 -d /etc/apt/keyrings
    run_step "4/9 ключ репозитория Docker" curl -fsSL --connect-timeout 15 --retry 3 "https://download.docker.com/linux/${id}/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${id} ${code} stable" \
      > /etc/apt/sources.list.d/docker.list
    run_step "4/9 apt-get update (Docker)" "${APT[@]}" update
    run_step "4/9 установка Docker" "${APT[@]}" install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  local daemon_new=0
  if [[ ! -f /etc/docker/daemon.json ]]; then
    mkdir -p /etc/docker
    printf '%s\n' '{ "log-driver": "json-file", "log-opts": { "max-size": "20m", "max-file": "5" }, "live-restore": true }' > /etc/docker/daemon.json
    daemon_new=1
  fi
  systemctl enable docker containerd >/dev/null 2>&1
  # Restart only for a new daemon.json or a stopped Docker: a running portal stays up (S-18).
  if (( daemon_new )) || ! systemctl is-active -q docker; then
    run_step "4/9 перезапуск Docker" systemctl restart docker
  fi
  _t 30 docker info >/dev/null 2>&1 \
    || die "Docker не запустился" "docker info не отвечает" "sudo journalctl -u docker -n 50 — причина там; затем запустите prepare снова"

  step "5/9 Пользователь ${CHATTER_USER}"
  if ! id "$CHATTER_USER" >/dev/null 2>&1; then
    run_step "5/9 создание пользователя" adduser --disabled-password --gecos "Chatter AI" "$CHATTER_USER"
  fi
  run_step "5/9 группа docker" usermod -aG docker "$CHATTER_USER"
  install -d -m 755 -o "$CHATTER_USER" -g "$CHATTER_USER" "$CHATTER_ROOT"
  if [[ -n "$ssh_key" ]]; then
    [[ "$ssh_key" == ssh-* ]] || ssh_key="$(head -1 "$ssh_key" 2>/dev/null)"
    [[ "$ssh_key" == ssh-* ]] || die "--ssh-key: не похоже на публичный SSH-ключ" "ожидалась строка ssh-ed25519 … или путь к .pub" "sudo bash $0 prepare --ssh-key ~/.ssh/id_ed25519.pub"
    install -d -m 700 -o "$CHATTER_USER" -g "$CHATTER_USER" "${CHATTER_HOME}/.ssh"
    grep -qxF "$ssh_key" "${CHATTER_HOME}/.ssh/authorized_keys" 2>/dev/null || echo "$ssh_key" >> "${CHATTER_HOME}/.ssh/authorized_keys"
    chown "$CHATTER_USER:$CHATTER_USER" "${CHATTER_HOME}/.ssh/authorized_keys"; chmod 600 "${CHATTER_HOME}/.ssh/authorized_keys"
  fi

  step "6/9 Система: swap, UTC, NTP, журнал"
  if [[ -z "$(swapon --show --noheadings 2>/dev/null)" ]]; then
    if fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile; then
      grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    else
      warn swap "не удалось создать /swapfile"
    fi
  fi
  echo "vm.swappiness=10" > /etc/sysctl.d/99-chatter.conf && sysctl --system >/dev/null
  timedatectl set-timezone UTC || warn time.tz "не удалось выставить UTC"
  timedatectl set-ntp true 2>/dev/null || warn time.ntp "не удалось включить NTP" "sudo timedatectl set-ntp true"
  mkdir -p /etc/systemd/journald.conf.d
  printf '[Journal]\nSystemMaxUse=1G\n' > /etc/systemd/journald.conf.d/99-chatter.conf
  systemctl restart systemd-journald

  step "7/9 SSH"
  local who="${SUDO_USER:-root}" keys home
  home="$(getent passwd "$who" | cut -d: -f6)"
  keys="$(grep -cE '^(ssh-|ecdsa-|sk-)' "${home}/.ssh/authorized_keys" 2>/dev/null || echo 0)"
  if (( keys > 0 )); then
    cat > /etc/ssh/sshd_config.d/99-chatter.conf <<'CONF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
PubkeyAuthentication yes
MaxAuthTries 3
X11Forwarding no
CONF
    if sshd -t; then systemctl reload ssh 2>/dev/null || systemctl reload sshd; pass ssh "вход только по ключу"
    else rm -f /etc/ssh/sshd_config.d/99-chatter.conf; warn ssh "конфиг не прошёл sshd -t — не применён"; fi
  else
    warn ssh "у '$who' нет SSH-ключа — вход по паролю НЕ отключён, чтобы вы не потеряли доступ"
  fi

  step "8/9 Firewall, fail2ban, автообновления"
  local sp; sp="$(ssh_port)"; sp="${sp:-22}"
  run_step "8/9 firewall (ufw)" fw_setup "$sp"
  systemctl enable ufw >/dev/null 2>&1
  cat > /etc/fail2ban/jail.d/sshd.local <<CONF
[sshd]
enabled = true
port = ${sp}
backend = systemd
maxretry = 5
bantime = 1h
CONF
  systemctl enable fail2ban >/dev/null 2>&1
  run_step "8/9 fail2ban" systemctl restart fail2ban
  printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' > /etc/apt/apt.conf.d/20auto-upgrades
  printf 'Unattended-Upgrade::Automatic-Reboot "false";\n' > /etc/apt/apt.conf.d/52chatter-unattended
  systemctl enable --now unattended-upgrades >/dev/null 2>&1 || warn os.autoupdate "unattended-upgrades не включился" "sudo systemctl enable --now unattended-upgrades"

  step "9/9 Итог"
  FAILS=0 WARNS=0
  check_system
  [[ -n "$domain" ]] && check_dns "$domain" 0
  if [[ -f /var/run/reboot-required ]]; then
    warn reboot "нужна перезагрузка" "sudo reboot — затем снова: sudo bash $0 prepare${domain:+ --domain $domain}"
  fi
  summary prepare
  if (( FAILS == 0 )); then
    printf '\nСервер готов к установке. Сообщите SVT: IP %s%s.\n' "$(public_ip)" "${domain:+, домен $domain}"
  fi
  (( FAILS == 0 ))
}

# ------------------------------------------------------------------ install
# Step 4 runs as a transient systemd unit: an SSH drop does not kill it (S-09).
# Tokens reach it through a 600 root file that is removed as soon as it started.
run_installer() {
  local boot="$1" version="$2" domain="$3" start rc=0
  touch "$INSTALL_LOG"; chmod 600 "$INSTALL_LOG"
  printf '\n######## %s chatter-setup %s install %s\n' "$(date -u +%FT%TZ)" "$SETUP_VERSION" "$version" >> "$INSTALL_LOG"
  start=$(( $(wc -l < "$INSTALL_LOG") + 1 ))
  INSTALL_START="$start"
  if have_systemd_run; then
    local envf sr i
    envf="$(mktemp /run/chatter-install.XXXXXX 2>/dev/null || mktemp)"; track_tmp "$envf"; chmod 600 "$envf"
    { printf 'CHATTER_TOKEN=%s\n' "$CHATTER_TOKEN"
      if [[ -n "${GHCR_TOKEN:-}" ]]; then printf 'GHCR_TOKEN=%s\n' "$GHCR_TOKEN"; fi; } > "$envf"
    systemctl reset-failed "${INSTALL_UNIT}.service" >/dev/null 2>&1 || true
    info install.unit "идёт службой ${INSTALL_UNIT}: обрыв SSH её не прервёт. Связь пропала — войдите снова: sudo tail -f ${INSTALL_LOG}"
    systemd-run --unit "$INSTALL_UNIT" --wait --collect --quiet \
      -p User="$CHATTER_USER" -p Group="$CHATTER_USER" \
      -p WorkingDirectory="$CHATTER_HOME" -p Environment=HOME="$CHATTER_HOME" \
      -p EnvironmentFile="$envf" \
      -p StandardOutput=append:"$INSTALL_LOG" -p StandardError=append:"$INSTALL_LOG" \
      /bin/bash "$boot" --version "$version" --domain "$domain" &
    sr=$!
    for i in $(seq 1 120); do
      (( $(wc -l < "$INSTALL_LOG") >= start )) && break
      kill -0 "$sr" 2>/dev/null || break
      sleep 0.5
    done
    rm -f "$envf"
    local tp
    tail -n "+$start" -f "$INSTALL_LOG" &
    tp=$!
    wait "$sr" || rc=$?
    sleep 1; kill "$tp" 2>/dev/null; wait "$tp" 2>/dev/null
  else
    warn install.ssh "нет systemd-run — установка идёт в этой SSH-сессии" "при обрыве связи она прервётся: запускайте внутри tmux (tmux new -s chatter)"
    ( cd /tmp && sudo -u "$CHATTER_USER" -H --preserve-env=CHATTER_TOKEN,GHCR_TOKEN \
        bash "$boot" --version "$version" --domain "$domain" ) 2>&1 | tee -a "$INSTALL_LOG"
    rc=${PIPESTATUS[0]}
  fi
  return "$rc"
}

# Last error line of the release installer in this attempt.
installer_cause() {
  tail -n "+${INSTALL_START:-1}" "$INSTALL_LOG" 2>/dev/null | grep -E '❌|Health not confirmed' | tail -1 | sed -E 's/^❌ *(\[[a-z-]+\] *)?//'
}

final_banner_text() {
  cat <<EOF

${B}Chatter AI установлен.${N}
  Портал:   https://$1
  Вход:     admin / admin1 — при первом входе портал попросит сменить пароль и заполнить профиль
  Studio:   https://$1/project/default — ${2:-?} / $3
  Сохраните пароль Studio в менеджер паролей — повторно он не выводится.
  Обновления: портал → Налаштування → Оновлення → «Оновити».
  Проверка в любой момент: sudo bash $0 check
EOF
}

# The Studio password goes to the terminal only, never into the log (S-08).
final_banner() {
  local domain="$1" u p tty="${CHATTER_SETUP_TTY:-/dev/tty}"
  u="$(env_get DASHBOARD_USERNAME "${CHATTER_ROOT}/env/.env")"
  p="$(env_get DASHBOARD_PASSWORD "${CHATTER_ROOT}/env/.env")"
  if [[ -n "$p" ]] && { : >>"$tty"; } 2>/dev/null; then
    sleep 0.3
    final_banner_text "$domain" "$u" "$p" >>"$tty"
    final_banner_text "$domain" "$u" "(пароль показан на экране; хранится в env/.env, DASHBOARD_PASSWORD)" | mask_secrets >> "$LOG_FILE"
  else
    final_banner_text "$domain" "$u" "пароль: sudo grep DASHBOARD_PASSWORD ${CHATTER_ROOT}/env/.env"
  fi
}

# Recreate just the auth container from the installed compose so GoTrue re-reads
# env/.env. A plain `docker restart` keeps the value compose baked in at create
# time, so a changed DISABLE_SIGNUP would not take effect. Project dir =
# current/supabase (same project the installer used), so root targets the same
# container; falls back to a restart if compose files are not where expected.
recreate_auth() {
  local sup="${CHATTER_ROOT}/current/supabase" envf="${CHATTER_ROOT}/env/.env"
  if [[ -f "$sup/docker-compose.yml" ]]; then
    ( cd "$sup" && _t 180 docker compose \
        -f docker-compose.yml -f docker-compose.nginx.yml \
        -f "${CHATTER_ROOT}/deploy/compose.prod.yml" \
        --env-file "$envf" up -d --no-deps "$AUTH_SERVICE" ) >/dev/null 2>&1 && return 0
  fi
  _t 60 docker restart "$AUTH_CONTAINER" >/dev/null 2>&1
}

# Public GoTrue signup is forbidden on a client portal (staff-access.md). The
# release installer may ship an install.sh that does not set the flag (v0.2.124),
# so the wrapper enforces it: set DISABLE_SIGNUP=true in env/.env (add the line if
# missing) and recreate auth so GoTrue picks it up — then step 6's sec.signup is
# PASS and the install-complete marker can be written.
ensure_signup_closed() {
  local envf="${CHATTER_ROOT}/env/.env" cur
  [[ -f "$envf" ]] || return 0
  cur="$(env_get DISABLE_SIGNUP "$envf")"
  if [[ "$cur" == true ]]; then
    pass sec.signup "публичная регистрация закрыта (DISABLE_SIGNUP=true)"
    return 0
  fi
  if grep -qE '^DISABLE_SIGNUP=' "$envf"; then
    sed -i.bak 's/^DISABLE_SIGNUP=.*/DISABLE_SIGNUP=true/' "$envf" && rm -f "$envf.bak"
  else
    printf 'DISABLE_SIGNUP=true\n' >> "$envf"
  fi
  if recreate_auth; then
    pass sec.signup "публичная регистрация закрыта: DISABLE_SIGNUP=true, контейнер auth перезапущен"
  else
    warn sec.signup "DISABLE_SIGNUP=true записан, но контейнер auth не перезапустился" "sudo docker restart ${AUTH_CONTAINER}"
  fi
}

cmd_install() {
  local domain="" version=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain) need_val "$@"; domain="$(norm_domain "$2")"; shift 2 ;;
      --version) need_val "$@"; version="$(trim_token "$2")"; shift 2 ;;
      *) die "неизвестный параметр: $1" "install знает только --domain и --version" "sudo bash $0 install --domain chatter.example.com --version vX.Y.Z" ;;
    esac
  done
  CUR_DOMAIN="$domain"
  require_root install
  [[ -n "$domain" ]] || die "нужен --domain" "не указан домен портала" "sudo bash $0 install --domain chatter.example.com --version vX.Y.Z"
  valid_domain "$domain" || die "домен «$domain» некорректен" "нужно полное имя: латиница, цифры, дефис и точки" "sudo bash $0 install --domain chatter.example.com --version vX.Y.Z"
  valid_version "$version" || die "нужен --version в формате vX.Y.Z" "версия «${version}» не подходит" "версию сообщает SVT, например: --version v0.2.120"
  start_log install
  # The install outlives a dropped SSH session; step 4 also runs as its own unit (S-09).
  trap '' HUP
  if [[ -z "${TMUX:-}" && -z "${STY:-}" ]] && ! have_systemd_run; then
    warn ssh.session "не tmux: при обрыве SSH установка прервётся" "apt install -y tmux; tmux new -s chatter; затем эта же команда"
    sleep 5
  fi

  step "1/6 Проверки до установки"
  if installed; then
    die "Chatter уже установлен в ${CHATTER_ROOT}" "найдена завершённая установка" "обновление — кнопка «Оновити» в портале (Налаштування → Оновлення); проверка — sudo bash $0 check"
  fi
  if unit_active "$INSTALL_UNIT"; then
    die "установка уже идёт в фоне (служба ${INSTALL_UNIT})" "прошлый запуск продолжает работать — обрыв SSH его не останавливает" \
      "дождитесь конца: sudo tail -f ${INSTALL_LOG} ; затем: sudo bash $0 check"
  fi
  if install_started; then
    info resume "прошлая установка не завершилась (шаг $(progress_get step || true), версия $(progress_get version || true)) — продолжаю; env/.env и база сохраняются"
  fi
  check_os_and_resources
  id "$CHATTER_USER" >/dev/null 2>&1 && pass user "$CHATTER_USER есть" || fail user "нет пользователя $CHATTER_USER" "сначала: sudo bash $0 prepare"
  command -v docker >/dev/null && docker compose version >/dev/null 2>&1 && pass docker "$(docker compose version --short 2>/dev/null)" || fail docker "нет Docker" "сначала: sudo bash $0 prepare"
  check_install_tools
  check_docker_ready
  check_clock
  check_network
  check_web_ports
  check_dns "$domain" 1
  (( FAILS == 0 )) || die "предпроверка не пройдена: FAIL $FAILS" "см. строки FAIL выше — у каждой есть «→ что сделать»" "исправьте и запустите install снова. Ничего не установлено."

  step "2/6 Токены"
  local chatter_token="${CHATTER_TOKEN:-}" ghcr_token="${GHCR_TOKEN:-}" i
  if [[ -z "$chatter_token" ]]; then
    read -rsp "CHATTER_TOKEN — первый токен от SVT (обычно github_pat_…). Вставьте и нажмите Enter, на экран не выводится: " chatter_token </dev/tty; echo
  fi
  chatter_token="$(trim_token "$chatter_token")"
  [[ -n "$chatter_token" ]] || die "CHATTER_TOKEN пустой" "токен не вставлен" "запустите install снова и вставьте первый токен от SVT"
  ghcr_token="$(trim_token "$ghcr_token")"
  for i in 1 2 3; do
    [[ -z "$ghcr_token" && "$chatter_token" != ghp_* ]] || break
    read -rsp "GHCR_TOKEN — второй токен от SVT (начинается с ghp_), на экран не выводится: " ghcr_token </dev/tty; echo
    ghcr_token="$(trim_token "$ghcr_token")"
    [[ -n "$ghcr_token" ]] || warn token.images "GHCR_TOKEN пустой — вставьте второй токен от SVT"
  done
  if [[ -z "$ghcr_token" && "$chatter_token" != ghp_* ]]; then
    die "GHCR_TOKEN не вставлен" "образ интерфейса в ghcr.io первым токеном не скачать — нужен второй (classic, read:packages)" "запустите install снова и вставьте оба токена от SVT"
  fi
  KNOWN_SECRETS="${chatter_token}"$'\n'"${ghcr_token}"$'\n'
  if check_catalog_token "$chatter_token" "$version"; then pass token.catalog "релиз $version доступен"
  else
    explain_http "$PROBE_CODE" "$PROBE_ERR" "релиз $version"
    die "CHATTER_TOKEN не открывает релиз $version (HTTP $PROBE_CODE)" "$WHY" "$TODO"
  fi
  local dcfg out lrc=0; dcfg="$(mktemp -d)"; track_tmp "$dcfg"
  out="$(printf '%s' "${ghcr_token:-$chatter_token}" | DOCKER_CONFIG="$dcfg" _t 60 docker login ghcr.io -u svt0801 --password-stdin 2>&1)" || lrc=$?
  rm -rf "$dcfg"
  if (( lrc == 0 )); then pass token.images "вход в ghcr.io работает"
  else explain_ghcr "$out"; die "токен образов не принят ghcr.io" "$WHY" "$TODO"; fi

  step "3/6 Службы релиза $version"
  install -d -m 755 -o "$CHATTER_USER" -g "$CHATTER_USER" "$CHATTER_ROOT" "${CHATTER_ROOT}/state"
  progress_mark 3 "$version"
  local rd frc=0; rd="$(mktemp -d)"; track_tmp "$rd"
  fetch_release_deploy "$chatter_token" "$version" "$rd" || frc=$?
  case "$frc" in
    0) ;;
    3) die "бандл $version повреждён: контрольная сумма не совпала" "$FETCH_ERR" "запустите install снова — бандл скачается заново; если повторится — сообщите SVT" ;;
    4) die "бандл $version не распаковался" "$FETCH_ERR" "проверьте место на диске (df -h) и запустите install снова" ;;
    *) die "не удалось скачать релиз $version" "$FETCH_ERR" "проверьте исходящий HTTPS к api.github.com, objects.githubusercontent.com, release-assets.githubusercontent.com и запустите install снова" ;;
  esac
  install -m 440 -o root -g root "$rd/deploy/api/chatter-api.sudoers" /etc/sudoers.d/chatter-api
  if ! out="$(visudo -cf /etc/sudoers.d/chatter-api 2>&1)"; then
    rm -f /etc/sudoers.d/chatter-api
    die "sudoers chatter-api из релиза $version не прошёл проверку visudo" "$(printf '%s' "$out" | head -1)" "сообщите SVT версию $version"
  fi
  local u
  for u in "$rd"/deploy/api/*.service "$rd"/deploy/update-agent/*.service "$rd"/deploy/update-agent/*.timer \
           "$rd"/deploy/kb-backup/*.service "$rd"/deploy/kb-backup/*.timer; do
    [[ -f "$u" ]] && install -m 644 -o root -g root "$u" /etc/systemd/system/
  done
  rm -rf "$rd"
  systemctl daemon-reload
  pass units "chatter-api, update-agent, kb-backup + sudoers (включаются после установки)"

  step "4/6 Установка релиза $version (5–15 минут: образы, база, сертификат)"
  progress_mark 4 "$version"
  export CHATTER_TOKEN="$chatter_token"
  if [[ -n "$ghcr_token" ]]; then export GHCR_TOKEN="$ghcr_token"; fi
  local boot net irc=0; boot="$(mktemp)"; track_tmp "$boot"; chmod 644 "$boot"
  net="$(curl_net | tr '\n' ' ')"
  # shellcheck disable=SC2086
  if ! out="$(gh_curl "$chatter_token" -f $net --max-time 120 -H "Accept: application/vnd.github.raw" \
      "https://api.github.com/repos/${CATALOG_REPO}/contents/deploy/bootstrap.sh?ref=${version}" -o "$boot" 2>&1)"; then
    die "не удалось скачать bootstrap.sh для $version" "$(printf '%s' "$out" | head -1)" "проверьте исходящий HTTPS к api.github.com и запустите install снова"
  fi
  run_installer "$boot" "$version" "$domain" || irc=$?
  if (( irc != 0 )); then
    die "установщик релиза $version завершился с ошибкой (код $irc)" "$(installer_cause)" \
      "исправьте причину и запустите ту же команду install снова — она продолжит; env/.env и база сохраняются. Журнал: ${INSTALL_LOG}"
  fi

  systemctl daemon-reload
  if ! out="$(systemctl enable --now chatter-api chatter-update-agent.timer chatter-kb-backup.timer 2>&1)"; then
    warn units "не все службы включились: $(printf '%s' "$out" | tail -1)" "sudo systemctl status chatter-api; sudo journalctl -u chatter-api -n 50"
  fi
  # The release installer may not close public signup (older install.sh); enforce
  # it here so step 6 re-check passes and the marker can be written.
  ensure_signup_closed

  step "5/6 Токены для «Оновити»"
  progress_mark 5 "$version"
  local agent_env="${CHATTER_ROOT}/env/update-agent.env"
  if [[ ! -f "$agent_env" ]]; then
    ( umask 077
      { echo "CHATTER_ROOT=${CHATTER_ROOT}"; echo "AUTO_APPLY=false"
        echo "CHATTER_TOKEN=${chatter_token}"; [[ -n "$ghcr_token" ]] && echo "GHCR_TOKEN=${ghcr_token}"; } > "$agent_env" )
  fi
  chown "$CHATTER_USER:$CHATTER_USER" "$agent_env"; chmod 600 "$agent_env"
  pass agent.env "env/update-agent.env (значения не выводятся)"
  unset CHATTER_TOKEN GHCR_TOKEN chatter_token ghcr_token

  step "6/6 Проверка"
  progress_mark 6 "$version"
  install_finish "$domain" "$version"
}

# Step 6. The install counts as finished only when the portal checks pass;
# server hygiene FAILs (updates, SSH, …) are reported but do not reopen it.
install_finish() {
  local domain="$1" version="$2" sys_fails app_fails
  FAILS=0 WARNS=0
  check_system
  sys_fails=$FAILS
  check_app "$domain"
  app_fails=$(( FAILS - sys_fails ))
  summary install
  # S-12: no «installed» banner while the portal itself has a FAIL.
  if (( app_fails > 0 )); then
    printf '\n%sУстановка завершена с ошибками — портал может не работать.%s\n' "$R" "$N"
    printf 'Исправьте FAIL выше (у каждого есть «→ что сделать») и запустите ту же команду install снова: env/.env и база сохраняются.\n'
    support_report "install: FAIL в проверке портала: $app_fails" ""
    return 1
  fi
  mark_install_complete "$version"
  final_banner "$domain"
  (( FAILS == 0 ))
}

# ------------------------------------------------------------------ check
check_system() {
  local sp; sp="$(ssh_port)"; sp="${sp:-22}"
  [[ -f /var/run/reboot-required ]] && warn os.reboot "нужна перезагрузка" "sudo reboot (портал поднимется сам)" || pass os.reboot "не нужна"
  local up; up="$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | grep -c '^Inst' || true)"
  [[ "$up" == 0 ]] && pass os.updates "обновлений нет" || warn os.updates "$up пакетов ждут обновления" "sudo apt-get update && sudo apt-get upgrade -y"
  # WARN, not FAIL: an update published during the install is not an install error.
  local sec; sec="$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | grep '^Inst' | grep -ci security || true)"
  [[ "$sec" == 0 ]] && pass os.security "нет ожидающих обновлений безопасности" \
    || warn os.security "$sec обновлений безопасности ждут установки — автообновление поставит их ночью" "или сейчас: sudo apt-get upgrade -y"
  grep -qs 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades && systemctl is-active -q unattended-upgrades \
    && pass os.autoupdate "автообновления безопасности включены" || fail os.autoupdate "автообновления не включены" "sudo bash $0 prepare"
  [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == yes ]] && pass time.sync "часы синхронизированы" \
    || fail time.sync "часы не синхронизированы" "sudo timedatectl set-ntp true (нет службы — sudo apt-get install -y systemd-timesyncd)"
  local tz; tz="$(timedatectl show -p Timezone --value 2>/dev/null)"
  [[ "$tz" == UTC || "$tz" == Etc/UTC ]] && pass time.tz "UTC" || warn time.tz "$tz (стандарт — UTC)" "sudo timedatectl set-timezone UTC"
  local disk use; disk=$(( $(df -Pk / | awk 'NR==2{print $4}') / 1048576 )); use="$(df -P / | awk 'NR==2{print $5}' | tr -d %)"
  (( disk >= 10 && use < 85 )) && pass disk "свободно ${disk} ГБ (${use}%)" \
    || fail disk "свободно ${disk} ГБ (${use}%)" "sudo journalctl --vacuum-size=200M; что занимает место: sudo du -xh / --max-depth=2 | sort -h | tail"
  for s in docker ssh fail2ban; do
    systemctl is-active -q "$s" 2>/dev/null || systemctl is-active -q "${s}d" 2>/dev/null && pass "svc.$s" active \
      || fail "svc.$s" "не работает" "sudo systemctl restart $s; sudo journalctl -u $s -n 50"
  done
  ufw status 2>/dev/null | grep -q '^Status: active' && pass fw.ufw "включён" || fail fw.ufw "выключен" "sudo bash $0 prepare"
  local open; open="$(ufw status 2>/dev/null | awk '/ALLOW/ && !/\(v6\)/{print $1}' | sort -u | tr '\n' ' ')"
  local extra_fw; extra_fw="$(ufw status 2>/dev/null | fw_extra_rules "$sp")"
  [[ -z "${extra_fw// /}" ]] && pass fw.allow "$(echo $open)" || warn fw.allow "лишние правила UFW: ${extra_fw% }" "sudo ufw delete allow <порт>"
  fail2ban-client status sshd >/dev/null 2>&1 && pass fw.fail2ban "jail sshd" || warn fw.fail2ban "jail sshd не работает" "sudo systemctl restart fail2ban"
  local pa; pa="$(sshd -T 2>/dev/null | awk '$1=="passwordauthentication"{print $2}')"
  [[ "$pa" == no ]] && pass ssh.password "вход по паролю выключен" || warn ssh.password "вход по паролю включён" "добавьте SSH-ключ и запустите: sudo bash $0 prepare"
  if id "$CHATTER_USER" >/dev/null 2>&1; then
    id -nG "$CHATTER_USER" | grep -qw sudo && fail user "$CHATTER_USER в sudo" "sudo deluser $CHATTER_USER sudo" || pass user "$CHATTER_USER, без sudo"
  else fail user "нет $CHATTER_USER" "sudo bash $0 prepare"; fi
  local pub extra=""; pub="$(ss -tlnH | awk '{print $4}' | grep -E '^(0\.0\.0\.0|\[::\]|\*):' | sed -E 's/.*:([0-9]+)$/\1/' | sort -un)"
  for p in $pub; do [[ " $sp 80 443 " == *" $p "* ]] || extra+="$p "; done
  [[ -z "$extra" ]] && pass net.listen "на всех интерфейсах: $(echo $pub)" \
    || fail net.listen "лишние порты на всех интерфейсах: ${extra% }" "кто слушает: sudo ss -tlnp | grep -E ':(${extra// /|}) ' — остановите лишнюю службу"
  local hist; hist="$(grep -lE 'github_pat_|ghp_[A-Za-z0-9]{20}' /root/.bash_history /home/*/.bash_history /root/.zsh_history /home/*/.zsh_history 2>/dev/null | tr '\n' ' ')"
  [[ -z "$hist" ]] && pass hyg.history "токенов в истории shell нет" || fail hyg.history "токен в истории: ${hist% }" "удалите строки с токеном из этих файлов и выполните: history -c"
}

# What Let's Encrypt said in the nginx-certbot log (S-14).
le_log_hint() {
  local logs; logs="$(_t 15 docker logs --tail 300 "$NGINX_CONTAINER" 2>&1)"
  case "$logs" in
    *"too many failed authorizations"*|*rateLimited*|*"too many certificates"*)
      echo "лимит Let's Encrypt на неудачные попытки: подождите 1 час, затем: sudo docker restart ${NGINX_CONTAINER}" ;;
    *"likely firewall problem"*|*"Timeout during connect"*|*"Connection refused"*)
      echo "Let's Encrypt не достучался до сервера по порту 80 — откройте 80 и 443 во внешнем firewall провайдера (панель хостинга), затем: sudo docker restart ${NGINX_CONTAINER}" ;;
    *NXDOMAIN*|*"DNS problem"*)
      echo "Let's Encrypt не нашёл домен в DNS — проверьте A-запись, затем: sudo docker restart ${NGINX_CONTAINER}" ;;
    *)
      echo "сертификат Let's Encrypt не выпущен — причина в логе: sudo docker logs ${NGINX_CONTAINER} 2>&1 | tail -40" ;;
  esac
}

cert_info() { echo | _t 15 openssl s_client -connect 127.0.0.1:443 -servername "$1" 2>/dev/null | openssl x509 -noout "${@:2}" 2>/dev/null; }

# Local origin check through 127.0.0.1 — prints the actual code (S-12).
http_local() { # name domain path expected fix
  local code
  code="$(curl --resolve "$2:443:127.0.0.1" -s -o /dev/null -m 15 -w '%{http_code}' "https://$2$3" 2>/dev/null)"
  [[ -n "$code" ]] || code=000
  if [[ "$code" == "$4" ]]; then pass "$1" "$code"
  elif [[ "$code" == 000 ]]; then
    if cert_info "$2" -issuer | grep -q "Let's Encrypt"; then
      fail "$1" "https://$2$3 не ответил (000)" "nginx не отвечает: sudo docker ps -a; sudo docker logs --tail 40 ${NGINX_CONTAINER}"
    else
      fail "$1" "https://$2$3 не ответил (000: сертификат не Let's Encrypt)" "$(le_log_hint)"
    fi
  else fail "$1" "https://$2$3 → HTTP $code, ожидали $4" "$5"; fi
}

# The portal the way a visitor's browser gets it: public domain (through
# Cloudflare, if it proxies), no -k, up to 5 redirects.
check_public() {
  local domain="$1" code rc=0 err msg
  err="$(mktemp)"
  code="$(curl -sS -o /dev/null -L --max-redirs 5 -m 20 -w '%{http_code}' "https://${domain}/" 2>"$err")" || rc=$?
  msg="$(head -1 "$err" 2>/dev/null)"; rm -f "$err"
  case "$rc" in
    0)
      case "$code" in
        200) pass http.public "https://${domain}/ → 200, как у посетителя" ;;
        525|526) fail http.public "Cloudflare: HTTP $code — не принимает сертификат сервера" "$(le_log_hint)" ;;
        520|521|522|523|524) fail http.public "Cloudflare не может подключиться к серверу (HTTP $code)" "откройте 80 и 443 во внешнем firewall провайдера; проверьте: sudo docker ps" ;;
        *) fail http.public "снаружи https://${domain}/ → HTTP $code" "sudo docker ps -a; затем sudo bash $0 report" ;;
      esac ;;
    47) fail http.public "петля редиректов на https://${domain}/ (curl: Maximum redirects)" "Cloudflare в режиме Flexible: SSL/TLS → Full или Full (strict)" ;;
    35|51|53|54|58|59|60|64|66|77|80|83|90|91)
      fail http.public "сертификат https://${domain}/ не принят (curl $rc${msg:+: $msg})" "$(le_log_hint)" ;;
    6) fail http.public "$domain не резолвится с сервера (curl 6)" "проверьте A-запись домена" ;;
    7|28) warn http.public "с самого сервера https://${domain}/ не открылся (curl $rc) — у провайдера может не быть «hairpin»" "откройте https://${domain}/ в браузере с другого устройства" ;;
    *) warn http.public "https://${domain}/: curl $rc${msg:+: $msg}" "откройте https://${domain}/ в браузере" ;;
  esac
}

# GET api.github.com$2 with token $1 → TP_CODE, TP_DAYS (days to expiry, empty = none).
token_probe() {
  local h exp
  h="$(mktemp)"
  TP_CODE="$(gh_curl "$1" -o /dev/null -D "$h" -w '%{http_code}' --connect-timeout 10 -m 20 \
    -H 'Accept: application/vnd.github+json' "https://api.github.com$2" 2>/dev/null || true)"
  [[ -n "$TP_CODE" ]] || TP_CODE=000
  exp="$(tr -d '\r' < "$h" | awk -F': ' 'tolower($1)=="github-authentication-token-expiration"{print $2; exit}')"
  rm -f "$h"
  TP_DAYS=""
  if [[ -n "$exp" ]]; then TP_DAYS="$(days_until "$exp")"; fi
}

days_until() {
  python3 - "$1" <<'PY' 2>/dev/null
import datetime, sys
s = sys.argv[1].strip()
for fmt in ("%Y-%m-%d %H:%M:%S %Z", "%Y-%m-%d %H:%M:%S %z"):
    try:
        d = datetime.datetime.strptime(s, fmt)
    except ValueError:
        continue
    if d.tzinfo is None:
        d = d.replace(tzinfo=datetime.timezone.utc)
    print(int((d - datetime.datetime.now(datetime.timezone.utc)).total_seconds() // 86400))
    break
PY
}

token_verdict() { # name label file
  case "$TP_CODE" in
    200)
      if [[ -z "$TP_DAYS" ]]; then pass "$1" "$2 работает, срок не ограничен"
      elif (( TP_DAYS < 0 )); then fail "$1" "$2 истёк — «Оновити» не работает" "запросите у SVT новый токен и замените строку в $3"
      elif (( TP_DAYS < 14 )); then warn "$1" "$2 истекает через $TP_DAYS дн." "заранее запросите у SVT новый токен"
      else pass "$1" "$2 работает, ещё $TP_DAYS дн."; fi ;;
    401) fail "$1" "$2 не принят GitHub (401: истёк или отозван) — «Оновити» не работает" "запросите у SVT новый токен и замените строку в $3" ;;
    403|404) fail "$1" "$2: нет доступа (HTTP $TP_CODE)" "сообщите SVT" ;;
    *) warn "$1" "$2: GitHub не ответил (HTTP $TP_CODE)" "проверьте исходящий HTTPS к api.github.com" ;;
  esac
}

# Tokens of «Оновити» are alive and not about to expire (S-13).
check_tokens() {
  local f="${CHATTER_ROOT}/env/update-agent.env" ct gt it dcfg
  ct="$(env_get CHATTER_TOKEN "$f")"; gt="$(env_get GHCR_TOKEN "$f")"
  if [[ -z "$ct" ]]; then
    fail token.catalog "в env/update-agent.env нет CHATTER_TOKEN — «Оновити» не увидит релизы" "сообщите SVT"
  else
    token_probe "$ct" "/repos/${CATALOG_REPO}"
    token_verdict token.catalog "CHATTER_TOKEN" "$f"
  fi
  if [[ -n "$gt" ]]; then
    token_probe "$gt" "/rate_limit"
    token_verdict token.images.exp "GHCR_TOKEN" "$f"
  fi
  it="${gt:-$ct}"
  [[ -n "$it" ]] || return 0
  dcfg="$(mktemp -d)"
  if printf '%s' "$it" | DOCKER_CONFIG="$dcfg" _t 60 docker login ghcr.io -u svt0801 --password-stdin >/dev/null 2>&1; then
    pass token.images "вход в ghcr.io работает"
  else
    fail token.images "ghcr.io не принял токен образов — «Оновити» не скачает интерфейс" "запросите у SVT новый GHCR_TOKEN и замените строку в $f"
  fi
  rm -rf "$dcfg"
}

check_app() {
  local domain="$1" e="${CHATTER_ROOT}/env"
  [[ -n "$domain" ]] || domain="$(env_get PROXY_DOMAIN "$e/.env")"
  info app.version "$(readlink "${CHATTER_ROOT}/current" 2>/dev/null | xargs -r basename)"
  local f m bad=""
  for f in .env api.env update-agent.env; do
    [[ -f "$e/$f" ]] || { bad+="[$f нет] "; continue; }
    m="$(stat -c '%a %U' "$e/$f")"; [[ "$m" == "600 $CHATTER_USER" ]] || bad+="[$f $m] "
  done
  [[ -z "$bad" ]] && pass sec.env "env/*.env 600 $CHATTER_USER" \
    || fail sec.env "${bad% }" "sudo chown $CHATTER_USER:$CHATTER_USER $e/*.env && sudo chmod 600 $e/*.env"
  [[ "$(env_get DISABLE_SIGNUP "$e/.env")" == true ]] && pass sec.signup "публичная регистрация закрыта" \
    || fail sec.signup "DISABLE_SIGNUP не true" "sudo sed -i 's/^DISABLE_SIGNUP=.*/DISABLE_SIGNUP=true/' $e/.env и сообщите SVT"
  [[ "$(env_get AUTO_APPLY "$e/update-agent.env")" == false ]] && pass app.autoapply "AUTO_APPLY=false" \
    || warn app.autoapply "AUTO_APPLY не false" "sudo sed -i 's/^AUTO_APPLY=.*/AUTO_APPLY=false/' $e/update-agent.env"
  local unh; unh="$(docker ps --format '{{.Names}} {{.Status}}' | grep -E 'unhealthy|Restarting' | tr '\n' ';')"
  [[ -z "$unh" ]] && pass app.containers "$(docker ps -q | wc -l | tr -d ' ') контейнеров, без unhealthy" \
    || fail app.containers "$unh" "sudo docker logs --tail 50 <имя контейнера>; затем sudo bash $0 report"
  local exp; exp="$(docker ps --format '{{.Names}} {{.Ports}}' | grep -E '(0\.0\.0\.0|\[::\]):[0-9]+->' | grep -vE '(0\.0\.0\.0|\[::\]):(80|443)->' | awk '{print $1}' | tr '\n' ' ')"
  [[ -z "$exp" ]] && pass app.publish "наружу из Docker только 80/443" || fail app.publish "наружу публикуют: ${exp% }" "сообщите SVT: наружу должны смотреть только 80/443"
  for u in chatter-api chatter-update-agent.timer chatter-kb-backup.timer; do
    systemctl is-active -q "$u" && pass "unit.$u" active || fail "unit.$u" "не active" "sudo systemctl restart $u; sudo journalctl -u ${u%.timer} -n 50"
  done
  local res
  for u in chatter-update-agent.service chatter-kb-backup.service; do
    res="$(systemctl show -p Result --value "$u" 2>/dev/null)"
    if [[ -z "$res" || "$res" == success ]]; then pass "last.${u%.service}" "последний запуск: ${res:-нет данных}"
    else fail "last.${u%.service}" "последний запуск: $res" "sudo journalctl -u $u -n 50"; fi
  done
  http_local http.ui "$domain" / 200 "sudo docker logs --tail 40 chatter-ui"
  http_local http.api "$domain" /api/v1/health 200 "sudo systemctl status chatter-api; sudo journalctl -u chatter-api -n 50"
  http_local http.gate "$domain" /api/v1/system/version 401 "сообщите SVT: API отвечает без входа"
  http_local http.studio "$domain" /project/default 401 "сообщите SVT: Studio открыт без пароля"
  check_public "$domain"
  local end days issuer
  end="$(cert_info "$domain" -enddate | cut -d= -f2)"
  if [[ -n "$end" ]]; then
    days=$(( ($(date -d "$end" +%s) - $(date +%s)) / 86400 ))
    (( days >= 20 )) && pass tls "сертификат ещё $days дн." \
      || fail tls "сертификат истекает через $days дн." "продление: sudo docker restart ${NGINX_CONTAINER}; если не помогло — $(le_log_hint)"
    issuer="$(cert_info "$domain" -issuer | sed 's/^issuer= *//')"
    if [[ "$issuer" == *"Let's Encrypt"* ]]; then pass tls.issuer "Let's Encrypt"
    else fail tls.issuer "сертификат выдан не Let's Encrypt (${issuer:-?}) — временный, браузер его не примет" "$(le_log_hint)"; fi
    if cert_info "$domain" -checkhost "$domain" | grep -q 'does match'; then pass tls.name "$domain"
    else fail tls.name "сертификат не для $domain" "$(le_log_hint)"; fi
  else fail tls "нет сертификата на 443" "nginx не отвечает: sudo docker ps -a; sudo docker logs --tail 40 ${NGINX_CONTAINER}"; fi
  check_tokens
  local dd use n
  dd=/var/lib/docker; [[ -d "$dd" ]] || dd=/
  use="$(df -P "$dd" | awk 'NR==2{print $5}' | tr -d %)"
  (( use < 85 )) && pass disk.docker "$dd занято ${use}%" || warn disk.docker "$dd занято ${use}%" "что занимает место: sudo docker system df — чистку согласуйте с SVT"
  n="$(find "${CHATTER_ROOT}/releases" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
  (( n <= 3 )) && pass releases.count "$n" || warn releases.count "$n релизов на диске" "размер: sudo du -sh ${CHATTER_ROOT}/releases — старые релизы уберёт SVT"
  local art; art="$(find "$CHATTER_ROOT" -maxdepth 4 \( -name .git -o -name Sprint -o -name .cursor -o -name 'Client_*' -o -name node_modules \) -not -path '*/venv/*' 2>/dev/null | head -3 | tr '\n' ' ')"
  [[ -z "$art" ]] && pass hyg.artifacts "лишних файлов нет" || fail hyg.artifacts "${art% }" "сообщите SVT: на сервере лишние файлы"
}

cmd_check() {
  require_root check
  printf '%schatter-setup %s check — %s%s\n' "$B" "$SETUP_VERSION" "$(date -u +%FT%TZ)" "$N"
  step "Сервер"
  check_system
  if installed; then step "Chatter"; check_app ""
  elif install_started; then
    warn app "установка не завершена (шаг $(progress_get step || true))" "запустите ту же команду install снова: sudo bash $0 install --domain <домен> --version <версия>"
  else info app "Chatter ещё не установлен"; fi
  summary check
  (( FAILS == 0 ))
}

cmd_report() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain) need_val "$@"; CUR_DOMAIN="$(norm_domain "$2")"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ $EUID -eq 0 ]] || printf 'Без sudo часть данных недоступна: sudo bash %s report\n' "$0" >&2
  support_report "" ""
}

summary() {
  printf '\n%sИТОГ %s:%s FAIL %d · WARN %d — %s\n' "$B" "$1" "$N" "$FAILS" "$WARNS" \
    "$( (( FAILS == 0 )) && echo 'OK' || echo 'есть ошибки, см. FAIL и «→ что сделать»')"
}

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; }

main() {
  local cmd="${1:-}"; shift || true
  CUR_CMD="$cmd"
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  case "$cmd" in
    prepare) cmd_prepare "$@" ;;
    install) cmd_install "$@" ;;
    check)   cmd_check "$@" ;;
    report)  cmd_report "$@" ;;
    version) echo "$SETUP_VERSION" ;;
    *) usage; exit 2 ;;
  esac
}

# Sourcing with CHATTER_SETUP_LIB=1 loads the functions only (tests).
[[ "${CHATTER_SETUP_LIB:-0}" == 1 ]] || main "$@"
