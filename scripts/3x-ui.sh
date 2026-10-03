#!/usr/bin/env bash
# Thanks to itsnotkubrick for VPN server setup ideas: https://github.com/itsnotkubrick
#
# Установка:  bash <(curl -fsSL https://raw.githubusercontent.com/McElast/3x-easy-one/v1.0.0/install.sh)
#
# Ставит официальную панель 3X-UI (версия закреплена ниже) её собственным
# установщиком, получает сертификат Let's Encrypt на IP, создаёт подключения
# REALITY, XHTTP, VLESS/VMess WS, Trojan gRPC, Shadowsocks 2022, Hysteria2, TUIC,
# AmneziaWG (классика и 3.1) и MTProto (и WireGuard по запросу), включает единую подписку
# с форматом под каждый клиент и настраивает ufw. Домены не нужны.
# Материалы исходной проверки клиентов сохранены в tests/matrix.
# Этой версии KIT требуется отдельная приёмка на VPS.

set -Eeuo pipefail

umask 077
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ -r $SCRIPT_DIR/repo.conf ]] || { echo 'Скачайте архив KIT целиком или используйте install.sh.' >&2; exit 1; }
# shellcheck source=repo.conf
. "$SCRIPT_DIR/repo.conf"
# Ядро Xray для панели. С 26.7.x клиенты на Mihomo и sing-box (Hiddify, FlClash,
# Clash Verge, Mihomo в XKeen) не проходят REALITY — проверено 2026-09-25.
# 26.6.27 — последняя версия, с которой работают все клиенты и которую принимает 3X-UI.

XUI_REPO="MHSanaei/3x-ui"
RESULT=/root/3x-ui.txt
XUI_ENV=/etc/x-ui/install-result.env
# Сайты для маскировки REALITY: нужны TLS 1.3 и HTTP/2. Берём первый доступный.
# Apple, iCloud, Microsoft и домены .ru сам Xray не советует — их тут нет.
SNI_CANDIDATES=(dl.google.com www.amazon.com www.samsung.com www.yahoo.com)

ALL_PROTOS=(reality hy2 xhttp ws trojan vmess ss tuic wg awg awg3 mtproto)
# Обычный WireGuard в России режет DPI (проверено 2026-09-27: рукопожатие доходит до сервера,
# ответ — нет), а его попытки могут привлечь блокировку IP. По умолчанию не ставим.
DEFAULT_PROTOS=(reality xhttp hy2 awg awg3)
declare -A PORTS=([xhttp]=8443 [ws]=2053 [trojan]=2083 [vmess]=2087 [ss]=8388 [tuic]=8444 [wg]=51820 [awg]=51821 [awg3]=51822 [mtproto]=8445)
PROTOS=(); CREATED=(); OPEN=()
# Режим «всё TCP на 443»: nginx разводит по SNI и путям, подключения слушают только localhost.
SINGLE=no
declare -A INNER=([reality]=10443 [xhttp]=10444 [mtproto]=10445 [web]=10446 [ws]=10451 [vmess]=10452 [trojan]=10453 [sub]=10460)
SNI2=""; SNI3=""

if [[ -t 1 ]]; then
  G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; B=$'\e[1m'; D=$'\e[2m'; N=$'\e[0m'
else
  G=; Y=; R=; B=; D=; N=
fi
say()  { printf '%s\n' "${G}==>${N} $*"; }
warn() { printf '%s\n' "${Y}!${N}  $*" >&2; }
die()  { printf '%s\n' "${R}✗${N}  $*" >&2; exit 1; }
trap 'die "Ошибка в строке $LINENO. Исправьте причину и запустите скрипт ещё раз."' ERR

rand_str() { openssl rand -hex "${1:-16}"; }
port_busy() { ss -H -ln"${2:0:1}" "sport = :$1" 2>/dev/null | grep -q .; }

public_ip() {
  # Read the local route instead of sending the server IP to lookup services.
  local ip
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
  case $ip in
    10.*|127.*|192.168.*|169.254.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 1 ;;
  esac
  [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$ip"
}
free_port() {
  local p
  for _ in $(seq 1 50); do
    p=$(shuf -i 20000-60000 -n 1)
    port_busy "$p" tcp || { echo "$p"; return; }
  done
  die "Не нашёл свободный порт для панели."
}

# REALITY маскируется под чужой сайт: он должен отвечать по TLS 1.3 и HTTP/2.
sni_ok() {
  echo | timeout 8 openssl s_client -connect "$1:443" -servername "$1" -tls1_3 -alpn h2 2>/dev/null \
    | grep -q 'ALPN protocol: h2'
}

# ---------- API панели ----------

api() { # METHOD path [json]
  local url="$API/$2" out
  if [[ $1 == GET ]]; then
    out=$(curl -fsSk -m 20 -H "Authorization: Bearer $TOKEN" "$url")
  else
    out=$(curl -fsSk -m 20 -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -X "$1" -d "$3" "$url")
  fi
  [[ $(jq -r '.success' <<<"$out") == true ]] || die "Панель ответила ошибкой на $2; проверьте x-ui через SSH-туннель."
  jq -c '.obj' <<<"$out"
}

wait_panel() {
  local i
  for i in $(seq 1 60); do
    curl -fsk -m 5 -o /dev/null -H "Authorization: Bearer $TOKEN" "$API/server/getNewUUID" 2>/dev/null && return 0
    sleep 2
  done
  die "Панель не отвечает. Лог: journalctl -u x-ui -n 50"
}

# ---------- установка ----------

kit_banner() {
  echo
  echo "${B}McElast 3X Easy One — KIT $KIT_VERSION${N}"
  echo "Источник: $REPO_URL:$REPO_REF"
  echo "Спасибо itsnotkubrick за идеи; авторам 3X-UI, Xray, Mihomo, Hysteria и AmneziaWG — за технологии."
}

main() {
  [[ $EUID -eq 0 ]] || die "Запустите от root: sudo -i, затем команду ещё раз."
  command -v systemctl >/dev/null || die "Нужен systemd."
  if [[ -f $RESULT && -x /usr/local/x-ui/x-ui ]]; then
    die "3X-UI уже установлена этим скриптом. Управление: команда x-ui, данные для входа: cat $RESULT"
  fi
  local resume=no arg
  for arg in "$@"; do [[ $arg != --resume ]] || resume=yes; done
  if [[ -d /usr/local/x-ui || -f /etc/x-ui/x-ui.db ]]; then
    [[ $resume == yes && -f $XUI_ENV && -f /etc/kit/repo.conf && -f /etc/kit/KIT_VERSION ]] ||
      die "Найдена незавершённая/чужая установка. Для своей незавершённой установки: та же версия и параметры + --resume; см. manuals/INSTALL.md."
    local installed
    installed=$(cat /etc/kit/KIT_VERSION)
    [[ $installed == "$KIT_VERSION" ]] || die "Продолжать можно только той же версией KIT."
    python3 "$SCRIPT_DIR/kit-admin.py" backup || die "Не удалось сохранить текущую установку; продолжение отменено."
  fi
  . /etc/os-release
  case "$ID:$VERSION_ID" in
    ubuntu:22.04|ubuntu:24.04|debian:12|debian:13) ;;
    *) die "Нужен чистый Ubuntu 22.04/24.04 или Debian 12/13 с systemd." ;;
  esac
  case "$(uname -m)" in x86_64|aarch64) ;; *) die "Поддерживаются x86_64 и arm64." ;; esac

  local PORT=443 SNI="" PANEL_SSL=auto HOST="" UFW=yes NAME="admin" yes=no protos=recommended ucert="" ukey="" multi=no
  while [[ $# -gt 0 ]]; do
    case $1 in
      --port|--sni|--panel-ssl|--host|--user|--protocols|--cert|--key)
        [[ $# -ge 2 ]] || die "Для $1 нужно значение." ;;
    esac
    case $1 in
      --port) PORT=$2; shift 2 ;;
      --sni) SNI=$2; shift 2 ;;
      --panel-ssl) PANEL_SSL=$2; shift 2 ;;
      --host) HOST=$2; shift 2 ;;
      --user) NAME=$2; shift 2 ;;
      --protocols) protos=$2; shift 2 ;;
      --cert) ucert=$2; shift 2 ;;
      --multi-port) multi=yes; shift ;;
      --resume) shift ;;
      --key) ukey=$2; shift 2 ;;
      --no-ufw) UFW=no; shift ;;
      -y|--yes) yes=yes; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Неизвестный параметр: $1 (см. --help)" ;;
    esac
  done
  [[ $multi == yes || $PORT == 443 ]] || die "Для единого порта нужен --port 443; иной порт — только с --multi-port."
  [[ $PORT =~ ^[0-9]+$ ]] && ((PORT > 0 && PORT < 65536)) || die "Неверный порт: $PORT"
  [[ $NAME =~ ^[A-Za-z0-9_.-]{1,32}$ ]] || die "Имя: латиница, цифры, _ . - (до 32 символов)."
  [[ ! $NAME =~ -awg[0-9]*$ ]] || die "Суффикс -awg зарезервирован."
  [[ $PANEL_SSL =~ ^(auto|ip|none)$ ]] || die "--panel-ssl: auto, ip или none"
  if [[ -n $ucert || -n $ukey ]]; then
    [[ -s $ucert && -s $ukey ]] || die "Нужны оба файла: --cert fullchain.pem --key privkey.pem"
    openssl x509 -in "$ucert" -noout 2>/dev/null || die "$ucert — не сертификат в формате PEM"
    PANEL_SSL=custom
  fi
  case $protos in
    recommended|recommended-plus) PROTOS=("${DEFAULT_PROTOS[@]}") ;;
    all) PROTOS=(reality hy2 xhttp ws trojan vmess ss tuic awg awg3 mtproto) ;;
    minimal) PROTOS=(reality) ;;
    *) IFS=, read -ra PROTOS <<<"$protos"
       local x
       for x in "${PROTOS[@]}"; do [[ " ${ALL_PROTOS[*]} " == *" $x "* ]] || die "Неизвестный протокол: $x. Доступны: ${ALL_PROTOS[*]}"; done ;;
  esac
  if port_busy "$PORT" tcp && ! { [[ -f $XUI_ENV ]] && ss -H -ltnp "sport = :$PORT" | grep -q -E 'xray|nginx'; }; then
    die "Порт $PORT/tcp уже занят. REALITY нужен свободный порт — укажите другой: --port 8443"
  fi

  if [[ $PANEL_SSL == auto ]]; then
    if port_busy 80 tcp; then
      die "Порт 80 занят. Для установки с публичной HTTPS-подпиской нужен свободный 80/tcp."
    else
      PANEL_SSL=ip
    fi
  fi
  [[ $PANEL_SSL == ip ]] && port_busy 80 tcp && die "Для сертификата панели нужен свободный порт 80/tcp."
  # Доверенный сертификат (Let's Encrypt или свой) — панель и подписка доступны снаружи по HTTPS.
  TRUSTED=no
  [[ $PANEL_SSL == ip || $PANEL_SSL == custom ]] && TRUSTED=yes
  if [[ $PANEL_SSL == custom ]]; then
    mkdir -p /root/cert/custom
    install -m 644 "$ucert" /root/cert/custom/fullchain.pem
    install -m 600 "$ukey" /root/cert/custom/privkey.pem
  fi

  say "Ставлю пакеты: curl, jq, openssl, qrencode, ufw"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl jq openssl qrencode ca-certificates iproute2 ufw socat cron python3 python3-yaml >/dev/null

  HOST=${HOST:-$(public_ip || true)}
  [[ $HOST =~ ^[A-Za-z0-9.-]+$ ]] || die "Не удалось узнать корректный адрес. Укажите --host IPv4."
  [[ $SNI =~ ^[A-Za-z0-9.-]*$ ]] || die "Неверный --sni."
  # Only add rules here; do not enable a firewall until SSH listeners are identified.
  [[ $UFW == yes && $PANEL_SSL == ip ]] && ufw allow 80/tcp >/dev/null
  install -d -m 700 /etc/kit
  install -m 600 "$SCRIPT_DIR/repo.conf" /etc/kit/repo.conf
  install -m 600 "$SCRIPT_DIR/../KIT_VERSION" /etc/kit/KIT_VERSION


  if [[ -z $SNI ]]; then
    say "Выбираю сайт для маскировки REALITY"
    for s in "${SNI_CANDIDATES[@]}"; do
      if sni_ok "$s"; then SNI=$s; break; fi
    done
    [[ -n $SNI ]] || die "Ни один сайт из списка не ответил по TLS 1.3 + HTTP/2. Укажите свой: --sni example.com"
  elif ! sni_ok "$SNI"; then
    die "$SNI не отвечает по TLS 1.3 + HTTP/2 — REALITY с ним работать не будет. Выберите другой сайт."
  fi
  say "Маскировка: ${B}$SNI${N}"
  # Для режима «всё на 443» XHTTP и MTProto нужны свои сайты: nginx различает их по SNI.
  for s in "${SNI_CANDIDATES[@]}"; do
    [[ $s == "$SNI" ]] && continue
    if [[ -z $SNI2 ]] && sni_ok "$s"; then SNI2=$s; continue; fi
    [[ -z $SNI3 && -n $SNI2 ]] && { SNI3=$s; break; }
  done
  if [[ $TRUSTED == yes && $multi == no && " ${PROTOS[*]} " == *" xhttp "* && -z $SNI2 ]]; then
    die "Нужны два разных доступных SNI для REALITY и XHTTP на TCP/443. Попробуйте позднее или --multi-port."
  fi
  SNI2=${SNI2:-$SNI}; SNI3=${SNI3:-www.cloudflare.com}

  # --- официальный установщик 3X-UI с закреплённой версией ---
  local panel_port panel_path panel_user panel_pass tmp
  panel_port=$(free_port)
  panel_path=$(rand_str 18)
  panel_user=$(rand_str 10)
  panel_pass=$(rand_str 20)
  if [[ -f $XUI_ENV ]]; then
    say "3X-UI уже стоит после прошлого запуска — продолжаю с создания подключений"
  else
  tmp=$(mktemp)
  say "Ставлю 3X-UI $XUI_VERSION официальным установщиком (пара минут)"
  curl -fsSL --retry 3 -o "$tmp" "https://raw.githubusercontent.com/$XUI_REPO/$XUI_VERSION/install.sh"
  # The pinned installer otherwise leaves its noninteractive HTTP panel public.
  # Change only the temporary installer, never the installed x-ui menu.
  [[ $(grep -Fc 'bind_local="n"' "$tmp") == 1 ]] || die "Изменился ожидаемый installer 3X-UI; нужна проверка localhost bind."
  sed -i 's/bind_local="n"/bind_local="y"/' "$tmp"
  bash -n "$tmp" || die "Повреждён установщик 3X-UI."
  install -m 600 /dev/null /var/log/3x-ui-install.log
  if ! XUI_NONINTERACTIVE=1 XUI_SSL_MODE=none XUI_ENABLE_FAIL2BAN=false XUI_SERVER_IP="$HOST" \
      XUI_PANEL_PORT="$panel_port" XUI_WEB_BASE_PATH="$panel_path" \
      XUI_USERNAME="$panel_user" XUI_PASSWORD="$panel_pass" \
      bash "$tmp" "$XUI_VERSION" </dev/null >/var/log/3x-ui-install.log 2>&1; then
    echo "Подробности в защищённом /var/log/3x-ui-install.log (может содержать секреты)." >&2
    die "Установщик 3X-UI завершился с ошибкой. Полный лог: /var/log/3x-ui-install.log"
  fi
  rm -f "$tmp"
  fi
  [[ -f $XUI_ENV ]] || die "Установщик не сохранил данные входа. Лог: /var/log/3x-ui-install.log"

  # Данные для входа — из файла, который пишет сам установщик.
  # shellcheck disable=SC1090
  . "$XUI_ENV"
  TOKEN=$XUI_API_TOKEN
  # Панель может уже работать по HTTPS (сертификат ставится после установщика) — пробуем оба.
  local scheme
  for scheme in https http; do
    API="$scheme://127.0.0.1:$XUI_PANEL_PORT/$XUI_WEB_BASE_PATH/panel/api"
    curl -fsk -m 5 -o /dev/null -H "Authorization: Bearer $XUI_API_TOKEN" "$API/server/getNewUUID" 2>/dev/null && break
  done
  wait_panel

  # Administrative panel and native subscription backend always stay on localhost.
  local all
  all=$(api POST setting/all '{}')
  api POST setting/update "$(jq -c '.webListen = "127.0.0.1" | .subListen = "127.0.0.1"' <<<"$all")" >/dev/null
  systemctl restart x-ui
  wait_panel
  [[ $PANEL_SSL != ip ]] || setup_ip_cert

  # --- ядро Xray, совместимое со всеми клиентами ---
  local cur_core
  cur_core=$(/usr/local/x-ui/bin/xray-linux-* version 2>/dev/null | awk 'NR==1 {print "v" $2}')
  if [[ $cur_core != "$XRAY_CORE" ]]; then
    say "Ставлю ядро Xray $XRAY_CORE (совместимо с Hiddify, Mihomo и другими клиентами)"
    api POST "server/installXray/$XRAY_CORE" '{}' >/dev/null
    for _ in $(seq 1 30); do
      cur_core=$(/usr/local/x-ui/bin/xray-linux-* version 2>/dev/null | awk 'NR==1 {print "v" $2}')
      [[ $cur_core == "$XRAY_CORE" ]] && break
      sleep 2
    done
    [[ $cur_core == "$XRAY_CORE" ]] || die "Не удалось закрепить Xray $XRAY_CORE. Установка не считается завершённой."
  fi

  # --- сертификат для протоколов с TLS ---
  setup_tls_cert
  if [[ $PANEL_SSL == ip && -n $PIN ]]; then
    die "Не получен доверенный сертификат: публичная подписка не будет включена. Проверьте 80/tcp и /root/.acme.sh."
  fi

  # --- подключения: все выбранные протоколы, один subId на пользователя ---
  EXISTING=$(api GET inbounds/list)
  SUBID=""
  # «Всё на 443» — для новых установок с доверенным сертификатом. Старую многопортовую
  # установку не переделываем: перенос работающих подключений — осознанное решение.
  if [[ $TRUSTED == yes && $multi == no ]]; then
    if jq -e 'any(.[]; .remark == "REALITY" and (.listen // "") != "127.0.0.1")' <<<"$EXISTING" >/dev/null; then
      warn "Установка уже работает в режиме с отдельными портами — оставляю его."
    else
      SINGLE=yes
    fi
  fi
  local p
  for p in "${PROTOS[@]}"; do "proto_$p"; done
  # Первый пользователь — сразу на всех протоколах (как «kit user add»).
  ensure_user

  # --- подписка: ссылки, Clash/Mihomo и JSON с автоопределением клиента ---
  setup_subscription
  [[ $SINGLE == yes ]] && setup_nginx
  install_kit_cli
  rm -f /etc/cron.d/kit-xui-menu /etc/kit/xui-menu.sed

  # --- файрвол ---
  local ssh_ports=() ssh_port ssh_tunnel_port=SSH_PORT
  mapfile -t ssh_ports < <(ss -H -ltnp | awk '/sshd|"ssh"/ {sub(/.*:/,"",$4); print $4}' | sort -nu)
  if [[ ${SSH_CONNECTION:-} ]]; then
    ssh_port=${SSH_CONNECTION##* }
    if [[ $ssh_port =~ ^[0-9]+$ ]]; then
      ssh_ports+=("$ssh_port")
      ssh_tunnel_port=$ssh_port
    fi
  fi
  if [[ $ssh_tunnel_port == SSH_PORT ]]; then
    if ((${#ssh_ports[@]} == 1)); then
      ssh_tunnel_port=${ssh_ports[0]}
    else
      warn "SSH-порт для туннеля неизвестен: замените SSH_PORT в итоговой команде своим портом."
    fi
  fi
  if [[ $UFW == yes ]]; then
    if ((${#ssh_ports[@]} == 0)); then
      warn "Не удалось определить SSH-порт: UFW автоматически не включаю. Настройте его через консоль VPS."
    else
      for ssh_port in "${ssh_ports[@]}"; do OPEN+=("$ssh_port/tcp"); done
      [[ $TRUSTED == yes && $SINGLE == no ]] && OPEN+=("$SUB_PORT/tcp")
      [[ $PANEL_SSL == ip ]] && OPEN+=("80/tcp")
      say "Настраиваю ufw: ${OPEN[*]}"
      local o
      for o in "${OPEN[@]}"; do ufw allow "$o" >/dev/null; done
      ufw --force enable >/dev/null || warn "UFW не включился — проверьте firewall хостера."
    fi
  fi

  # --- итог ---
  local panel_url links ssh_command
  ssh_command="ssh -p $ssh_tunnel_port -N -L 8888:127.0.0.1:$XUI_PANEL_PORT root@$HOST"
  panel_url="http://127.0.0.1:8888/${XUI_WEB_BASE_PATH#/}"
  panel_url="${panel_url%/}/"
  links=$(sub_links "$SUBID")
  # У установок до kit 1.1 AmneziaWG и MTProto лежат в подписках «-awg» и «-tg».
  local extra
  extra=$(sub_links "$SUBID-awg" 1; sub_links "$SUBID-tg" 1)
  [[ -n $extra ]] && links+=$'\n'"$extra"
  AWG_LINKS=$(grep '^vpn://' <<<"$links" || true)
  # MTProto слушает localhost, а клиенты приходят через nginx на 443.
  [[ $SINGLE == yes ]] && links=$(sed "s/^\(tg:\/\/proxy?\)\(.*\)port=${INNER[mtproto]}/\1\2port=443/" <<<"$links")
  umask 077
  {
    echo "3X-UI KIT (3X-UI $XUI_VERSION) — данные для входа (файл виден только root)"
    echo "Сервер: $HOST"
    echo "Протоколы: ${CREATED[*]}"
    echo
    echo "Панель (localhost): $panel_url"
    echo "SSH: $ssh_command"
    echo "Логин:   $XUI_USERNAME"
    echo "Пароль:  $XUI_PASSWORD"
    echo
    [[ $TRUSTED == yes ]] && { echo "Подписка ($NAME) — все протоколы одной ссылкой:"; echo "$SUB_URL"; echo; }
    echo "Отдельные подключения ($NAME):"
    echo "$links"
  } >"$RESULT"
  chmod 600 "$RESULT"; chown root:root "$RESULT"

  kit_banner
  echo
  echo "${G}${B}Установка завершена: создано ${#CREATED[@]} протоколов. Проверьте kit doctor.${N}"
  echo "Сервер: $HOST"
  echo "${D}${CREATED[*]}${N}"
  echo
  echo "Панель (только SSH): ${B}$panel_url${N}"
  echo "На вашем ПК: $ssh_command"
  echo "Логин:   ${B}$XUI_USERNAME${N}"
  echo "Пароль:  ${B}$XUI_PASSWORD${N}"
  echo
  if [[ $TRUSTED == yes ]]; then
    echo "Подписка для ${B}$NAME${N} — вставьте её в Clash Verge Rev, FlClash или Happ:"
    echo "приложение получит совместимые с ним протоколы."
    echo
    echo "$SUB_URL"
    echo
    qrencode -t ANSIUTF8 -m 1 "$SUB_URL" || true
    if [[ -n $AWG_LINKS ]]; then
      echo
      echo "AmneziaWG приходит по подписке в Clash Verge и FlClash; для AmneziaVPN — ссылки vpn:// в $RESULT."
    fi
  else
    echo "Без сертификата подписка недоступна снаружи — вот ссылки по одной:"
    echo
    echo "$links"
  fi
  echo
  if [[ -n $PIN && " ${CREATED[*]} " == *" TUIC "* ]]; then
    warn "TUIC со своим сертификатом: в клиенте включите «Разрешить небезопасный» (allow insecure) — отпечаток TUIC-ссылки не передают."
  fi
  echo "Всё это сохранено в ${B}$RESULT${N}."
  echo
  echo "Дополнительные пользователи — одной командой, сразу во все протоколы, со своей подпиской:"
  echo "  kit user add desktop-windows"
  echo "  kit user add phone-android"
  echo "  kit doctor"
  echo "Документация: $REPO_URL/blob/$REPO_REF/README.md"
  echo "QR и subscription URL — секреты. Не публикуйте их."
  echo "  ${B}kit user list${N}     — кто сколько израсходовал и до какого числа"
}

# ---------- сертификат ----------

setup_ip_cert() {
  say "Получаю HTTPS-сертификат для IP (acme.sh $ACME_VERSION)"
  [[ $HOST =~ ^[0-9.]+$ ]] || die "Для сертификата IP нужен IPv4; для домена используйте --cert/--key."
  install -d -m 700 /root/.acme.sh /root/cert/ip
  local tmp
  tmp=$(mktemp)
  curl -fsSL --retry 3 -o "$tmp" "https://raw.githubusercontent.com/acmesh-official/acme.sh/$ACME_VERSION/acme.sh"
  [[ $(sha256sum "$tmp" | awk '{print $1}') == "$ACME_SHA256" ]] || die "Контрольная сумма acme.sh не совпала."
  install -m 700 "$tmp" /root/.acme.sh/acme.sh
  rm -f "$tmp"
  install -d -m 755 /usr/local/lib/kit
  cat >/usr/local/lib/kit/cert-reload.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
systemctl restart x-ui
if [[ -f /etc/nginx/kit-stream.conf ]]; then
  nginx -t && systemctl reload nginx
fi
SH
  chmod 700 /usr/local/lib/kit/cert-reload.sh
  if [[ -s /root/cert/ip/fullchain.pem && -s /root/cert/ip/privkey.pem ]] &&
      openssl x509 -in /root/cert/ip/fullchain.pem -checkend 172800 -noout >/dev/null 2>&1 &&
      openssl x509 -in /root/cert/ip/fullchain.pem -checkip "$HOST" -noout >/dev/null 2>&1; then
    say "Использую действующий сертификат своей незавершённой установки."
  else
    /root/.acme.sh/acme.sh --issue --home /root/.acme.sh --server letsencrypt \
      -d "$HOST" --standalone --certificate-profile shortlived --days 3 --keylength ec-256 ||
      die "Сертификат не получен. Проверьте доступность 80/tcp у хостера; продолжение: та же команда + --resume."
  fi
  /root/.acme.sh/acme.sh --install-cert --home /root/.acme.sh -d "$HOST" --ecc \
    --key-file /root/cert/ip/privkey.pem --fullchain-file /root/cert/ip/fullchain.pem \
    --reloadcmd /usr/local/lib/kit/cert-reload.sh
  cat >/etc/systemd/system/kit-cert-renew.service <<'UNIT'
[Unit]
Description=Renew KIT IP certificate
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
UMask=0077
ExecStart=/root/.acme.sh/acme.sh --cron --home /root/.acme.sh
UNIT
  cat >/etc/systemd/system/kit-cert-renew.timer <<'UNIT'
[Unit]
Description=Check KIT certificate renewal twice daily
[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=30m
Persistent=true
[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable --now kit-cert-renew.timer >/dev/null
}

setup_tls_cert() {
  PIN=""
  if [[ $PANEL_SSL == custom ]]; then
    CERT=/root/cert/custom/fullchain.pem; KEY=/root/cert/custom/privkey.pem
  elif [[ $PANEL_SSL == ip && -s /root/cert/ip/fullchain.pem ]]; then
    CERT=/root/cert/ip/fullchain.pem; KEY=/root/cert/ip/privkey.pem
  else
    # Без Let's Encrypt — свой сертификат, а его отпечаток уходит в ссылки (pcs),
    # чтобы клиенты доверяли именно ему.
    CERT=/root/cert/self/fullchain.pem; KEY=/root/cert/self/privkey.pem
    if [[ ! -s $CERT ]]; then
      mkdir -p /root/cert/self
      local san="DNS:$HOST"
      [[ $HOST =~ ^[0-9.]+$ ]] && san="IP:$HOST"
      openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout "$KEY" -out "$CERT" \
        -subj "/CN=$HOST" -addext "subjectAltName=$san" -days 3650 2>/dev/null
      chmod 600 "$KEY"
    fi
    PIN=$(openssl x509 -in "$CERT" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f')
  fi
}

tls_json() { # alpn(JSON-массив)
  jq -nc --arg sni "$HOST" --arg c "$CERT" --arg k "$KEY" --arg pin "$PIN" --argjson alpn "$1" '{
    serverName: $sni, alpn: $alpn, certificates: [{certificateFile: $c, keyFile: $k}],
    settings: ({fingerprint: "chrome"} + (if $pin != "" then {pinnedPeerCertSha256: [$pin]} else {} end))}'
}

# ---------- протоколы ----------

# AmneziaWG — в отдельной подписке: приложения на Xray и sing-box (Happ, v2rayN, Karing,
# Hiddify) его не умеют и видят как обычный WireGuard, который не подключается.
client_base() { # суффикс
  local sid=$SUBID
  [[ $1 == awg* ]] && sid="$SUBID-awg"
  [[ $1 == mtproto ]] && sid="$SUBID-tg"   # ссылка для Telegram, VPN-приложениям не нужна
  jq -nc --arg e "$NAME-$1" --arg s "$sid" '{email: $e, limitIp: 0, totalGB: 0, expiryTime: 0, enable: true, tgId: 0, subId: $s, comment: "", reset: 0}'
}
uuid() { cat /proc/sys/kernel/random/uuid; }
rnd() { shuf -i "$1-$2" -n 1; }

# add_inbound remark port proto(tcp|udp|both|inner) protocol settings stream
# inner — подключение за nginx: слушает 127.0.0.1, наружу порт не открываем.
add_inbound() {
  local remark=$1 port=$2 net=$3 protocol=$4 settings=$5 stream=$6 body listen=""
  [[ $net == inner ]] && listen=127.0.0.1
  if jq -e --arg r "$remark" 'any(.[]; .remark == $r)' <<<"$EXISTING" >/dev/null; then
    CREATED+=("$remark"); open_port "$port" "$net"; return
  fi
  # Клиентов в подключение не кладём: пользователь добавляется потом сразу во все подключения.
  settings=$(jq -c 'if has("clients") then .clients = [] else . end' <<<"$settings")
  local n
  local nets=$net
  [[ $net == both ]] && nets="tcp udp"
  [[ $net == inner ]] && nets=tcp
  for n in $nets; do
    if port_busy "$port" "$n"; then die "$remark: порт $port/$n занят; установка не завершена."; fi
  done
  body=$(jq -nc --arg rm "$remark" --argjson port "$port" --arg p "$protocol" --arg s "$settings" --arg st "$stream" --arg l "$listen" '{
    remark: $rm, enable: true, listen: $l, port: $port, protocol: $p, settings: $s, streamSettings: $st,
    sniffing: "{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"],\"metadataOnly\":false,\"routeOnly\":false}",
    expiryTime: 0, total: 0}')
  local out
  out=$(curl -sSk -m 20 -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -X POST -d "$body" "$API/inbounds/add")
  if [[ $(jq -r '.success' <<<"$out") != true ]] && grep -q 'Duplicate email' <<<"$out"; then
    # Клиент с таким именем остался от удалённого подключения — берём уникальное имя.
    body=$(jq -c --arg sfx "-$(openssl rand -hex 2)" '.settings |= (fromjson | .clients[0].email += $sfx | tojson)' <<<"$body")
    out=$(curl -sSk -m 20 -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -X POST -d "$body" "$API/inbounds/add")
  fi
  [[ $(jq -r '.success' <<<"$out") == true ]] || die "Панель не создала $remark; проверьте подключение через SSH-туннель."
  CREATED+=("$remark"); open_port "$port" "$net"
}

open_port() { # port net
  case $2 in
    inner) ;;
    tcp|udp) OPEN+=("$1/$2") ;;
    both) OPEN+=("$1/tcp" "$1/udp") ;;
  esac
}

# External Proxy 3X-UI: ссылки ведут на HOST:443, хотя подключение слушает localhost.
# SNI — только для TLS через nginx: у REALITY своё имя сайта маскировки, его не трогаем.
ext_proxy() { # forceTls(same|tls) alpn(JSON)
  local sni=""
  [[ $HOST =~ ^[0-9.]+$ ]] || sni=$HOST
  jq -nc --arg f "$1" --arg h "$HOST" --arg sni "$sni" --argjson alpn "${2:-null}" '[{forceTls: $f, dest: $h, port: 443, remark: ""}
    + (if $f == "tls" then {fingerprint: "chrome", alpn: $alpn} + (if $sni != "" then {sni: $sni} else {} end) else {} end)]'
}

proto_reality() {
  local keys stream settings
  keys=$(api GET server/getNewX25519Cert)
  settings=$(jq -nc --arg id "$(uuid)" --argjson c "$(client_base reality)" '{clients: [$c + {id: $id, flow: "xtls-rprx-vision"}], decryption: "none", fallbacks: []}')
  stream=$(jq -nc --arg sni "$SNI" --argjson k "$keys" --arg sid "$(openssl rand -hex 8)" '{
    network: "tcp", security: "reality", externalProxy: [],
    realitySettings: {show: false, xver: 0, target: ($sni + ":443"), serverNames: [$sni], privateKey: $k.privateKey,
      minClientVer: "", maxClientVer: "", maxTimediff: 0, shortIds: [$sid],
      settings: {publicKey: $k.publicKey, fingerprint: "chrome", serverName: "", spiderX: "/"}},
    tcpSettings: {acceptProxyProtocol: false, header: {type: "none"}}}')
  if [[ $SINGLE == yes ]]; then
    stream=$(jq -c --argjson e "$(ext_proxy same)" '.externalProxy = $e | .tcpSettings.acceptProxyProtocol = true' <<<"$stream")
    add_inbound "REALITY" "${INNER[reality]}" inner vless "$settings" "$stream"
  else
    add_inbound "REALITY" "$PORT" tcp vless "$settings" "$stream"
  fi
}

proto_xhttp() {
  local keys stream settings
  keys=$(api GET server/getNewX25519Cert)
  settings=$(jq -nc --arg id "$(uuid)" --argjson c "$(client_base xhttp)" '{clients: [$c + {id: $id, flow: ""}], decryption: "none"}')
  stream=$(jq -nc --arg sni "$SNI" --argjson k "$keys" --arg sid "$(openssl rand -hex 8)" --arg path "/$(rand_str 10 | tr 'A-Z' 'a-z')" '{
    network: "xhttp", security: "reality", xhttpSettings: {path: $path, mode: "auto"},
    realitySettings: {target: ($sni + ":443"), serverNames: [$sni], privateKey: $k.privateKey, shortIds: [$sid],
      settings: {publicKey: $k.publicKey, fingerprint: "chrome", spiderX: "/"}}}')
  if [[ $SINGLE == yes ]]; then
    stream=$(jq -c --arg sni "$SNI2" --argjson e "$(ext_proxy same)" '.realitySettings.target = ($sni + ":443") | .realitySettings.serverNames = [$sni]
      | .externalProxy = $e | .sockopt = {acceptProxyProtocol: true}' <<<"$stream")
    add_inbound "XHTTP" "${INNER[xhttp]}" inner vless "$settings" "$stream"
  else
    add_inbound "XHTTP" "${PORTS[xhttp]}" tcp vless "$settings" "$stream"
  fi
}

proto_ws() {
  local settings stream
  settings=$(jq -nc --arg id "$(uuid)" --argjson c "$(client_base ws)" '{clients: [$c + {id: $id, flow: ""}], decryption: "none"}')
  stream=$(jq -nc --argjson t "$(tls_json '["http/1.1"]')" --arg path "/$(rand_str 10 | tr 'A-Z' 'a-z')" '{network: "ws", security: "tls", wsSettings: {path: $path}, tlsSettings: $t}')
  if [[ $SINGLE == yes ]]; then
    stream=$(jq -c --argjson e "$(ext_proxy tls '["http/1.1"]')" '{network, wsSettings, security: "none", externalProxy: $e}' <<<"$stream")
    add_inbound "VLESS-WS" "${INNER[ws]}" inner vless "$settings" "$stream"
  else
    add_inbound "VLESS-WS" "${PORTS[ws]}" tcp vless "$settings" "$stream"
  fi
}

proto_trojan() {
  local settings stream
  settings=$(jq -nc --arg pw "$(rand_str 16)" --argjson c "$(client_base trojan)" '{clients: [$c + {password: $pw}]}')
  stream=$(jq -nc --argjson t "$(tls_json '["h2"]')" --arg sn "$(rand_str 8 | tr 'A-Z' 'a-z')" '{network: "grpc", security: "tls", grpcSettings: {serviceName: $sn}, tlsSettings: $t}')
  if [[ $SINGLE == yes ]]; then
    stream=$(jq -c --argjson e "$(ext_proxy tls '["h2"]')" '{network, grpcSettings, security: "none", externalProxy: $e}' <<<"$stream")
    add_inbound "Trojan-gRPC" "${INNER[trojan]}" inner trojan "$settings" "$stream"
  else
    add_inbound "Trojan-gRPC" "${PORTS[trojan]}" tcp trojan "$settings" "$stream"
  fi
}

proto_vmess() {
  local settings stream
  settings=$(jq -nc --arg id "$(uuid)" --argjson c "$(client_base vmess)" '{clients: [$c + {id: $id, security: "auto", alterId: 0}]}')
  stream=$(jq -nc --argjson t "$(tls_json '["http/1.1"]')" --arg path "/$(rand_str 10 | tr 'A-Z' 'a-z')" '{network: "ws", security: "tls", wsSettings: {path: $path}, tlsSettings: $t}')
  if [[ $SINGLE == yes ]]; then
    stream=$(jq -c --argjson e "$(ext_proxy tls '["http/1.1"]')" '{network, wsSettings, security: "none", externalProxy: $e}' <<<"$stream")
    add_inbound "VMess-WS" "${INNER[vmess]}" inner vmess "$settings" "$stream"
  else
    add_inbound "VMess-WS" "${PORTS[vmess]}" tcp vmess "$settings" "$stream"
  fi
}

proto_ss() {
  local settings
  settings=$(jq -nc --arg pw "$(openssl rand -base64 16)" --arg upw "$(openssl rand -base64 16)" --argjson c "$(client_base ss)" '{
    method: "2022-blake3-aes-128-gcm", password: $pw, network: "tcp,udp", clients: [$c + {method: "", password: $upw}]}')
  add_inbound "Shadowsocks" "${PORTS[ss]}" both shadowsocks "$settings" '{"network":"tcp","security":"none"}'
}

proto_hy2() {
  local settings stream
  settings=$(jq -nc --arg a "$(rand_str 16)" --argjson c "$(client_base hy2)" '{version: 2, clients: [$c + {auth: $a}]}')
  stream=$(jq -nc --argjson t "$(tls_json '["h3"]')" '{network: "hysteria", hysteriaSettings: {version: 2}, security: "tls", tlsSettings: $t}')
  add_inbound "Hysteria2" "$PORT" udp hysteria "$settings" "$stream"
}

proto_tuic() {
  local settings id
  id=$(uuid)
  settings=$(jq -nc --arg id "$id" --arg pw "$(rand_str 16)" --arg c "$CERT" --arg k "$KEY" --argjson cb "$(client_base tuic)" '{
    server: {certificate: $c, private_key: $k, congestion_control: "bbr", alpn: ["h3"], udp_relay_mode: "native",
      zero_rtt_handshake: false, log_level: "warn", sni: ""},
    clients: [$cb + {uuid: $id, id: $id, password: $pw}]}')
  add_inbound "TUIC" "${PORTS[tuic]}" udp tuic "$settings" '{}'
}

wg_pair() { /usr/local/x-ui/bin/xray-linux-* wg; }

proto_wg() {
  local srv cli settings
  srv=$(wg_pair); cli=$(wg_pair)
  settings=$(jq -nc --arg sk "$(awk '/Private/ {print $NF}' <<<"$srv")" \
    --arg pr "$(awk '/Private/ {print $NF}' <<<"$cli")" --arg pu "$(awk '/Public|Password/ {print $NF}' <<<"$cli" | head -1)" \
    --argjson c "$(client_base wg)" '{mtu: 1420, secretKey: $sk, peers: [], subnetIp: "10.0.0.0", subnetCidr: 24,
    clients: [$c + {privateKey: $pr, publicKey: $pu, allowedIPs: ["10.0.0.2/32"]}]}')
  add_inbound "WireGuard" "${PORTS[wg]}" udp wireguard "$settings" '{"network":"tcp","security":"none"}'
}

# AmneziaWG: классические параметры понимают Mihomo и роутеры Keenetic,
# полный набор 3.1 — AmneziaVPN/AmneziaWG и совместимые новые ядра Mihomo.
awg_obfuscation() { # classic|full
  local jmin s1 s2
  jmin=$(rnd 40 89); s1=$(rnd 15 150); s2=$(rnd 15 150)
  while ((s1 + 56 == s2)); do s2=$(rnd 15 150); done
  local o
  o=$(jq -nc --argjson jc "$(rnd 3 6)" --argjson jmin "$jmin" --argjson jmax "$((jmin + $(rnd 50 250)))" --argjson s1 "$s1" --argjson s2 "$s2" \
    --arg h1 "$(rnd 5 536870911)" --arg h2 "$(rnd 536870912 1073741823)" --arg h3 "$(rnd 1073741824 1610612735)" --arg h4 "$(rnd 1610612736 2147483647)" \
    '{jc: $jc, jmin: $jmin, jmax: $jmax, s1: $s1, s2: $s2, h1: $h1, h2: $h2, h3: $h3, h4: $h4}')
  if [[ $1 == full ]]; then
    # С защитой заголовков (3.1) документация AmneziaWG советует H1–H4 = 1, 2, 3, 4:
    # тип сообщения тогда скрывает сама защита, а свои заголовки отключаются.
    local cp rk rj rt ka ha
    cp=$(rnd 8 24); rk=$(rnd 100 120); rj=$((rk + $(rnd 10 40) + $(rnd 30 60))); rt=$(rnd 3 6); ka=$(rnd 8 12); ha=$(rnd 15 25)
    o=$(jq -c --argjson s3 "$(rnd 12 55)" --argjson s4 "$(rnd 12 27)" --arg i1 "<r $(rnd 32 256)>" --arg hp "$(openssl rand -base64 32)" \
      --arg cp "$cp-$((cp + $(rnd 8 40)))" --arg rk "$rk-$((rk + $(rnd 10 40)))" --arg rj "$rj-$((rj + $(rnd 30 90)))" \
      --arg rt "$rt-$((rt + $(rnd 1 4)))" --arg ka "$ka-$((ka + $(rnd 2 8)))" --arg ha "$ha-$((ha + $(rnd 5 25)))" \
      '. + {h1: "1", h2: "2", h3: "3", h4: "4",
            s3: $s3, s4: $s4, i1: $i1, headerProtectionKey: $hp, contentPaddingAddition: $cp, rekeyAfterTime: $rk,
            rejectAfterTime: $rj, rekeyTimeout: $rt, keepaliveTimeout: $ka, maxHandshakeAttempts: $ha}' <<<"$o")
  fi
  echo "$o"
}

awg_inbound() { # remark port subnet client-ip suffix mode
  local srv cli settings
  srv=$(wg_pair); cli=$(wg_pair)
  settings=$(jq -nc --arg pk "$(awk '/Private/ {print $NF}' <<<"$srv")" --arg pub "$(awk '/Public|Password/ {print $NF}' <<<"$srv" | head -1)" \
    --arg pr "$(awk '/Private/ {print $NF}' <<<"$cli")" --arg pu "$(awk '/Public|Password/ {print $NF}' <<<"$cli" | head -1)" \
    --arg net "$3" --arg ip "$4" --argjson o "$(awg_obfuscation "$6")" --argjson c "$(client_base "$5")" '{
    server: ({privateKey: $pk, publicKey: $pub, subnetIp: $net, subnetCidr: 24, primaryDns: "1.1.1.1", secondaryDns: "8.8.8.8"} + $o),
    clients: [$c + {privateKey: $pr, publicKey: $pu, allowedIPs: [$ip]}]}')
  add_inbound "$1" "$2" udp amneziawg "$settings" '{}'
}

proto_awg() { awg_inbound "AmneziaWG" "${PORTS[awg]}" 10.8.1.0 10.8.1.2/32 awg classic; }
proto_awg3() { awg_inbound "AmneziaWG-3.1" "${PORTS[awg3]}" 10.8.2.0 10.8.2.2/32 awg3 full; }

telegram_reachable() {
  local ip
  for ip in 149.154.167.51 149.154.175.50 91.108.56.130; do
    timeout 5 bash -c "</dev/tcp/$ip/443" 2>/dev/null && return 0
  done
  return 1
}

proto_mtproto() {
  # MTProto бесполезен, если сам сервер не достаёт до Telegram (некоторые хостеры его блокируют).
  if ! telegram_reachable; then
    warn "MTProto пропущен: с этого сервера недоступны серверы Telegram — прокси для Telegram здесь работать не будет."
    return
  fi
  local settings
  if [[ $SINGLE == yes ]]; then
    # FakeTLS-домен — свой сайт: nginx узнаёт MTProto по нему и передаёт mtg с реальным IP клиента.
    settings=$(jq -nc --arg d "$SNI3" --argjson c "$(client_base mtproto)" '{fakeTlsDomain: $d, proxyProtocolListener: true, clients: [$c + {secret: ""}]}')
    add_inbound "MTProto" "${INNER[mtproto]}" inner mtproto "$settings" '{}'
  else
    settings=$(jq -nc --argjson c "$(client_base mtproto)" '{fakeTlsDomain: "www.cloudflare.com", clients: [$c + {secret: ""}]}')
    add_inbound "MTProto" "${PORTS[mtproto]}" tcp mtproto "$settings" '{}'
  fi
}

# ---------- пользователи ----------

# Один клиент 3X-UI на все подключения: общие трафик, лимиты и срок, одна подписка.
ensure_user() {
  local list me ids missing legacy
  list=$(api GET clients/list | jq -c 'if type == "array" then . else .clients end')
  ids=$(non_awg_ids)
  # An AWG-only selection still needs its primary client attached to an inbound.
  if [[ $ids == '[]' ]]; then
    ids=$(awg_ids | jq -s '.[0:1]')
    [[ $ids != '[]' ]] || die "Не выбраны подключения для пользователя."
  fi
  me=$(jq -c --arg e "$NAME" 'map(select(.email == $e))[0] // empty' <<<"$list")
  legacy=$(jq -r --arg p "$NAME-" 'map(select((.email | startswith($p)) and (.email | test("-awg[0-9]*$") | not))) | .[0].subId // empty' <<<"$list")
  if [[ -n $me ]]; then
    SUBID=$(jq -r '.subId' <<<"$me")
    missing=$(jq -c --argjson all "$ids" '$all - (.inboundIds // [])' <<<"$me")
    [[ $missing == "[]" ]] || api POST "clients/$NAME/attach" "$(jq -nc --argjson i "$missing" '{inboundIds: $i}')" >/dev/null
    awg_attach "$NAME" "$SUBID"
  elif [[ -n $legacy ]]; then
    # Установка до kit 1.1: у каждого протокола свой клиент — оставляем как есть.
    SUBID=$legacy
  else
    SUBID=$(openssl rand -hex 16)
    api POST clients/add "$(jq -nc --arg e "$NAME" --arg s "$SUBID" --argjson ids "$ids" \
      '{client: {email: $e, subId: $s, totalGB: 0, expiryTime: 0, limitIp: 0, enable: true, comment: "kit"}, inboundIds: $ids}')" >/dev/null
    awg_attach "$NAME" "$SUBID"
  fi
}

# В 3X-UI 3.x у клиента одна запись и в ней одна пара ключей WireGuard и один адрес. Если
# клиент подключён к двум AmneziaWG, в подписку для обоих уходят ключ и адрес одного из них,
# и второй сервер клиента не узнаёт (проверено 2026-09-27). Поэтому к первому AmneziaWG
# подключаем основную запись, а ко второму — запись-«двойник» «имя-awg» с подпиской «<id>-awg»
# (subId в 3X-UI обязан быть уникальным) и теми же лимитами; kit-sub подмешивает её в Clash.
awg_ids() { api GET inbounds/list | jq -r '[.[] | select(.protocol == "amneziawg") | .id] | sort | .[]'; }
non_awg_ids() { api GET inbounds/list | jq -c '[.[] | select(.protocol != "amneziawg") | .id]'; }

awg_attach() { # имя subId [лимит-байт] [срок-мс] [устройств]
  local name=$1 sid=$2 total=${3:-0} exp=${4:-0} lim=${5:-0} n=1 id email have ids
  have=$(api GET clients/list | jq -c 'if type == "array" then . else .clients end') || die "Не удалось получить список клиентов."
  ids=$(awg_ids) || die "Не удалось получить подключения AmneziaWG."
  for id in $ids; do
    local esid=$sid
    if ((n == 1)); then email=$name
    elif ((n == 2)); then email="$name-awg"; esid="$sid-awg"
    else email="$name-awg$n"; esid="$sid-awg$n"; fi
    n=$((n + 1))
    if jq -e --arg e "$email" --argjson i "$id" 'any(.[]; .email == $e and ((.inboundIds // []) | index($i)))' <<<"$have" >/dev/null; then
      continue
    elif jq -e --arg e "$email" 'any(.[]; .email == $e)' <<<"$have" >/dev/null; then
      api POST "clients/$email/attach" "$(jq -nc --argjson i "$id" '{inboundIds: [$i]}')" >/dev/null
    else
      api POST clients/add "$(jq -nc --arg e "$email" --arg s "$esid" --argjson t "$total" --argjson x "$exp" --argjson l "$lim" --argjson i "$id" \
        '{client: {email: $e, subId: $s, totalGB: $t, expiryTime: $x, limitIp: $l, enable: true, comment: "kit"}, inboundIds: [$i]}')" >/dev/null
    fi
  done
}

install_kit_cli() {
  install -d -m 700 /etc/kit
  {
    printf 'HOST=%q\n' "$HOST"
    printf 'SUB_BASE=%q\n' "${SUB_URL%$SUBID}"
    printf 'SUB_PATH=%q\n' "$SUB_PATH"
    printf 'SUB_INTERNAL=%q\n' "${SUB_INTERNAL:-$SUB_PORT}"
    printf 'SINGLE=%q\n' "$SINGLE"
    printf 'MTPROTO_INNER=%q\n' "${INNER[mtproto]}"
  } >/etc/kit/kit.env
  chmod 600 /etc/kit/kit.env
  install -m 755 "$SCRIPT_DIR/kit.sh" /usr/local/bin/kit
  install -d -m 755 /usr/local/lib/kit
  install -m 644 "$SCRIPT_DIR/kit-admin.py" /usr/local/lib/kit/kit-admin.py
  install -m 600 "$SCRIPT_DIR/repo.conf" /etc/kit/repo.conf
  install -m 600 "$SCRIPT_DIR/../KIT_VERSION" /etc/kit/KIT_VERSION
  printf 'KIT_REF=%q\n' "$REPO_REF" >>/etc/kit/kit.env
  printf 'CERT=%q\nKEY=%q\nAPI_SCHEME=%q\n' "$CERT" "$KEY" "${API%%:*}" >>/etc/kit/kit.env
  bash -n /usr/local/bin/kit || die "Некорректная команда kit"
}

# ---------- всё на 443: nginx ----------

setup_nginx() {
  say "Настраиваю nginx: всё TCP через порт 443"
  apt-get install -y -qq nginx libnginx-mod-stream >/dev/null
  # Порт 80 нужен Let's Encrypt для продления сертификата — сайт nginx по умолчанию убираем.
  rm -f /etc/nginx/sites-enabled/default

  # Панель остаётся только на localhost для SSH-туннеля.
  local all
  all=$(api POST setting/all '{}')
  if [[ $(jq -r '.webListen' <<<"$all") != 127.0.0.1 ]]; then
    api POST setting/update "$(jq -c '.webListen = "127.0.0.1"' <<<"$all")" >/dev/null
    systemctl restart x-ui
    wait_panel
  fi

  install -d -m 755 /var/www/kit
  [[ -f /var/www/kit/index.html ]] || cat >/var/www/kit/index.html <<'HTML'
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Welcome</title><style>body{font-family:-apple-system,Segoe UI,Roboto,sans-serif;margin:0;min-height:100vh;display:grid;place-items:center;background:#f6f7f9;color:#1f2328}main{text-align:center;padding:24px}h1{font-weight:600;font-size:28px}p{color:#57606a}</style></head><body><main><h1>Site is under construction</h1><p>Please check back soon.</p></main></body></html>
HTML
  chmod 644 /var/www/kit/index.html

  # Маршруты — из текущих подключений панели: сайты REALITY, пути WebSocket, сервисы gRPC.
  local list reality_sni xhttp_sni mt_sni locs="" kind path port
  list=$(api GET inbounds/list)
  reality_sni=$(jq -r '.[] | select(.remark == "REALITY" and .listen == "127.0.0.1") | (.streamSettings | if type == "string" then fromjson else . end).realitySettings.serverNames[0]' <<<"$list")
  xhttp_sni=$(jq -r '.[] | select(.remark == "XHTTP" and .listen == "127.0.0.1") | (.streamSettings | if type == "string" then fromjson else . end).realitySettings.serverNames[0]' <<<"$list")
  mt_sni=$(jq -r '.[] | select(.protocol == "mtproto" and .listen == "127.0.0.1") | (.settings | if type == "string" then fromjson else . end).fakeTlsDomain' <<<"$list")
  while IFS=$'\t' read -r kind path port; do
    [[ -n $path ]] || continue
    if [[ $kind == ws ]]; then
      locs+="
    location = $path {
        proxy_pass http://127.0.0.1:$port;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_protocol_addr;
        proxy_read_timeout 1h;
    }"
    else
      locs+="
    location /$path/ {
        grpc_pass grpc://127.0.0.1:$port;
        grpc_set_header X-Real-IP \$proxy_protocol_addr;
        grpc_read_timeout 1h;
        grpc_send_timeout 1h;
        client_max_body_size 0;
    }"
    fi
  done < <(jq -r '.[] | select(.listen == "127.0.0.1") | (.streamSettings | if type == "string" then fromjson else . end) as $st
    | if $st.network == "ws" then ["ws", $st.wsSettings.path, .port]
      elif $st.network == "grpc" then ["grpc", $st.grpcSettings.serviceName, .port]
      else empty end | @tsv' <<<"$list")

  local panel_path=/${XUI_WEB_BASE_PATH#/}
  panel_path=${panel_path%/}/
  {
    echo "# Сгенерировано 3x-ui.sh (3X-UI KIT) — перезаписывается при повторном запуске."
    echo "stream {"
    echo "    map \$ssl_preread_server_name \$kit_upstream {"
    [[ -n $reality_sni ]] && echo "        $reality_sni 127.0.0.1:${INNER[reality]};"
    [[ -n $xhttp_sni && $xhttp_sni != "$reality_sni" ]] && echo "        $xhttp_sni 127.0.0.1:${INNER[xhttp]};"
    [[ -n $mt_sni ]] && echo "        $mt_sni 127.0.0.1:${INNER[mtproto]};"
    echo "        default 127.0.0.1:${INNER[web]};"
    echo "    }"
    echo "    server {"
    echo "        listen 443;"
    echo "        listen [::]:443;"
    echo "        ssl_preread on;"
    echo "        proxy_pass \$kit_upstream;"
    echo "        proxy_protocol on;"
    echo "        proxy_connect_timeout 10s;"
    echo "        proxy_timeout 1h;"
    echo "    }"
    echo "}"
  } >/etc/nginx/kit-stream.conf
  cat >/etc/nginx/conf.d/kit.conf <<NGX
# Сгенерировано 3x-ui.sh (3X-UI KIT) — перезаписывается при повторном запуске.
server {
    listen 127.0.0.1:${INNER[web]} ssl http2 proxy_protocol;
    server_name _;
    ssl_certificate $CERT;
    ssl_certificate_key $KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;
    server_tokens off;
    # Иначе редирект «добавить слеш» уйдёт на внутренний порт nginx.
    absolute_redirect off;
    access_log off;
$locs
    location $SUB_PATH {
        proxy_pass http://127.0.0.1:${INNER[sub]};
        proxy_set_header Host \$host;
    }
    location $panel_path { return 404; }
    location / {
        root /var/www/kit;
        index index.html;
    }
}
NGX
  grep -q 'kit-stream.conf' /etc/nginx/nginx.conf || echo 'include /etc/nginx/kit-stream.conf;' >>/etc/nginx/nginx.conf
  nginx -t >/tmp/nginx-test.log 2>&1 || { cat /tmp/nginx-test.log >&2; die "nginx не принял конфиг — лог выше."; }
  systemctl enable nginx >/dev/null 2>&1
  systemctl restart nginx
  # Let's Encrypt на IP продлевается каждые несколько дней — nginx раз в сутки перечитывает сертификат.
  echo '17 4 * * * root systemctl reload nginx >/dev/null 2>&1' >/etc/cron.d/kit-nginx-reload
  OPEN+=("443/tcp")
  local i
  for i in $(seq 1 10); do port_busy 443 tcp && return 0; sleep 1; done
  die "nginx не открыл порт 443."
}

# ---------- подписка ----------

setup_subscription() {
  local all upd
  all=$(api POST setting/all '{}')
  SUB_PATH=$(jq -r '.subPath // "/sub/"' <<<"$all")
  if [[ $SUB_PATH == /sub/ || -z $SUB_PATH ]]; then SUB_PATH="/$(openssl rand -hex 16)/"; fi
  if [[ $TRUSTED == yes ]]; then
    # Наружу смотрит kit-sub (подписка с учётом приложения), 3X-UI — только на 127.0.0.1.
    SUB_PORT=2096; SUB_INTERNAL=2097
    # Без subURI панель показывает ссылку на внутренний порт 2097, до которого снаружи не достучаться.
    local uri="https://$HOST:$SUB_PORT$SUB_PATH"
    [[ $SINGLE == yes ]] && uri="https://$HOST$SUB_PATH"
    upd=$(jq -c --arg path "$SUB_PATH" --argjson ip "$SUB_INTERNAL" --arg title "3X-UI KIT" --arg uri "$uri" '
      .subEnable = true | .subPath = $path | .subTitle = $title | .subListen = "127.0.0.1" | .subPort = $ip
      | .subURI = $uri
      | .subCertFile = "" | .subKeyFile = ""
      | .subClashEnable = true | .subClashAutoDetect = true | .subJsonEnable = true | .subJsonAutoDetect = true' <<<"$all")
  else
    SUB_PORT=$(jq -r '.subPort // 2096' <<<"$all")
    upd=$(jq -c --arg path "$SUB_PATH" --arg title "3X-UI KIT" '
      .subEnable = true | .subPath = $path | .subTitle = $title
      | .subClashEnable = true | .subClashAutoDetect = true | .subJsonEnable = true | .subJsonAutoDetect = true' <<<"$all")
  fi
  if [[ $upd != "$all" ]]; then
    api POST setting/update "$upd" >/dev/null
    systemctl restart x-ui
    wait_panel
  fi
  [[ $TRUSTED == yes ]] && install_kit_sub
  if [[ $SINGLE == yes ]]; then SUB_URL="https://$HOST$SUB_PATH$SUBID"
  elif [[ $TRUSTED == yes ]]; then SUB_URL="https://$HOST:$SUB_PORT$SUB_PATH$SUBID"; else SUB_URL="http://127.0.0.1:$SUB_PORT$SUB_PATH$SUBID"; fi
  SUB_FETCH="$(if [[ $TRUSTED == yes ]]; then echo https; else echo http; fi)://$HOST:$SUB_PORT$SUB_PATH$SUBID"
}



install_kit_sub() {
  say "Ставлю подписку с учётом приложения (kit-sub)"
  apt-get install -y -qq python3 python3-yaml >/dev/null
  install -d -m 755 /usr/local/lib/kit-sub
  install -d -m 700 /etc/kit-sub
  install -m 644 "$SCRIPT_DIR/kit-sub.py" /usr/local/lib/kit-sub/kit_sub.py
  python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" /usr/local/lib/kit-sub/kit_sub.py || die "kit-sub скачался повреждённым"
  if [[ $SINGLE == yes ]]; then
    # За nginx: слушаем только localhost, TLS снимает nginx на 443.
    jq -n --arg path "$SUB_PATH" --argjson port "${INNER[sub]}" --arg up "http://127.0.0.1:$SUB_INTERNAL" --arg host "$HOST" \
      '{listen: "127.0.0.1", port: $port, path: $path, upstream: $up, host: $host}' >/etc/kit-sub/config.json
  else
    jq -n --arg path "$SUB_PATH" --argjson port "$SUB_PORT" --arg up "http://127.0.0.1:$SUB_INTERNAL" \
      --arg cert "$CERT" --arg key "$KEY" --arg host "$HOST" \
      '{listen: "0.0.0.0", port: $port, path: $path, upstream: $up, cert: $cert, key: $key, host: $host}' >/etc/kit-sub/config.json
  fi
  chmod 600 /etc/kit-sub/config.json
  cat >/etc/systemd/system/kit-sub.service <<'UNIT'
[Unit]
Description=kit-sub: подписка с учётом приложения (3X-UI KIT)
After=network-online.target x-ui.service
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/lib/kit-sub/kit_sub.py
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
MemoryMax=64M

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable kit-sub >/dev/null 2>&1
  systemctl restart kit-sub
  local i
  local kp=$SUB_PORT
  [[ $SINGLE == yes ]] && kp=${INNER[sub]}
  for i in $(seq 1 20); do port_busy "$kp" tcp && return 0; sleep 1; done
  journalctl -u kit-sub -n 20 --no-pager >&2 || true
  die "kit-sub не запустился — лог выше."
}

# Ссылки пользователя — из его же подписки (её собирает сама 3X-UI).
# Ссылки пользователя — прямо из подписки 3X-UI внутри сервера (мимо kit-sub, который
# прячет от VPN-приложений vpn:// и tg://). sub_links subId [попыток]
sub_links() {
  local id=$1 tries=${2:-20} raw="" i port=${SUB_INTERNAL:-$SUB_PORT} scheme=http
  [[ -z ${SUB_INTERNAL:-} && $TRUSTED == yes ]] && scheme=https
  for i in $(seq 1 "$tries"); do
    # Настоящий адрес в Host — 3X-UI подставит его в ссылки.
    raw=$(curl -fsSk -m 10 -A "v2rayN/7.0" -H "Host: $HOST:$SUB_PORT" "$scheme://127.0.0.1:$port$SUB_PATH$id" 2>/dev/null) && [[ -n $raw ]] && break
    raw=""; sleep 2
  done
  if grep -q '://' <<<"$raw"; then echo "$raw"; else base64 -d <<<"$raw" 2>/dev/null || true; fi
}

usage() {
  cat <<EOF
3X-UI со всеми протоколами одной командой

  --protocols recommended  по умолчанию: reality,xhttp,hy2,awg,awg3
                      recommended-plus — тот же профиль; all — остальные протоколы тоже
                      minimal — только REALITY
                      или список через запятую: reality,hy2,xhttp,ws,trojan,vmess,ss,tuic,wg,awg,awg3,mtproto
                      (обычный WireGuard в России блокируется — включайте его, только если сервер и
                      пользователи за границей)
  --port 443          порт REALITY (TCP) и Hysteria2 (UDP), по умолчанию 443
  --sni сайт          сайт для маскировки (по умолчанию подбирается сам)
  --panel-ssl ip|none сертификат подписки: ip — Let's Encrypt на IP (нужен порт 80),
                      none — панель только через SSH-туннель (по умолчанию выбирается сам)
  --cert файл --key файл  свой сертификат (например, для домена) вместо Let's Encrypt на IP;
                      тогда --host — это домен из сертификата
  --user admin        имя первого клиента
  --host 1.2.3.4      адрес в ссылке, если IP определился неверно
  --multi-port        отдельные порты протоколов (для advanced использования)
  --resume            продолжить свою незавершённую установку той же версии после backup
  --no-ufw            не трогать файрвол
  -y                  не задавать вопросов
EOF
}

if [[ ${1:-} == --help || ${1:-} == -h ]]; then usage; exit 0; fi
main "$@"
