#!/usr/bin/env bash
# kit — пользователи 3X-UI KIT: один пользователь сразу на всех протоколах.
# Thanks to itsnotkubrick for VPN server setup ideas: https://github.com/itsnotkubrick
#
#   kit user add имя [--gb 50] [--days 30] [--devices 3]
#   kit user list | link имя | limit имя [--gb N] [--days N] | off имя | on имя | del имя

set -Eeuo pipefail
umask 077
export LC_ALL=C.UTF-8  # ширина колонок по символам, а не байтам

XUI_ENV=/etc/x-ui/install-result.env
KIT_ENV=/etc/kit/kit.env

if [[ -t 1 ]]; then
  G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; B=$'\e[1m'; D=$'\e[2m'; N=$'\e[0m'
else
  G=; Y=; R=; B=; D=; N=
fi
say()  { printf '%s\n' "${G}==>${N} $*"; }
die()  { printf '%s\n' "${R}✗${N}  $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Запустите от root: sudo -i, затем команду ещё раз."
[[ -f $XUI_ENV && -f $KIT_ENV ]] || die "Не найдена установка — сначала поставьте сервер скриптом 3x-ui.sh."
# shellcheck disable=SC1090
. "$XUI_ENV"; . "$KIT_ENV"
# shellcheck source=repo.conf
. /etc/kit/repo.conf

API="${API_SCHEME:-http}://127.0.0.1:$XUI_PANEL_PORT/$XUI_WEB_BASE_PATH/panel/api"
export HOST SUB_BASE SUB_PATH SUB_INTERNAL SINGLE XUI_PANEL_PORT XUI_WEB_BASE_PATH XUI_API_TOKEN
export CERT KEY API_SCHEME REPO_OWNER REPO_NAME

api() { # METHOD path [json]
  local out
  if [[ $1 == GET ]]; then
    out=$(curl -sSk -m 20 -H "Authorization: Bearer $XUI_API_TOKEN" "$API/$2")
  else
    out=$(curl -sSk -m 20 -H "Authorization: Bearer $XUI_API_TOKEN" -H 'Content-Type: application/json' -X "$1" -d "${3:-{\}}" "$API/$2")
  fi
  [[ $(jq -r '.success' <<<"$out" 2>/dev/null) == true ]] || die "Панель ответила ошибкой: проверьте kit doctor и службу x-ui"
  jq -c '.obj' <<<"$out"
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

clients() { api GET clients/list | jq -c 'if type == "array" then . else .clients end'; }
client() { clients | jq -c --arg e "$1" 'map(select(.email == $e))[0] // empty'; }
# Все записи пользователя: основная и «двойники» для AmneziaWG («имя-awgN»).
emails_of() { clients | jq -r --arg e "$1" '.[] | select(.email == $e or ((.email | startswith($e + "-awg")) and (.email | ltrimstr($e + "-awg") | test("^[0-9]*$")))) | .email'; }
valid_name() {
  [[ $1 =~ ^[A-Za-z0-9_.-]{1,32}$ ]] || die "Имя: латиница, цифры, _ . - (до 32 символов)."
  [[ ! $1 =~ -awg[0-9]*$ ]] || die "Суффикс -awg зарезервирован для внутренних записей."
}
rand_id() { openssl rand -hex 16; }

gb_bytes() { [[ $1 =~ ^[0-9]+$ ]] || die "--gb: целое число гигабайт"; echo $(($1 * 1073741824)); }
days_ms() { [[ $1 =~ ^[0-9]+$ ]] || die "--days: целое число дней"; ((${1} == 0)) && { echo 0; return; }; echo $((($(date +%s) + $1 * 86400) * 1000)); }

human() { # байты → «1.2 ГБ»
  awk -v b="$1" 'BEGIN { split("Б КБ МБ ГБ ТБ", u, " "); i = 1; while (b >= 1024 && i < 5) { b /= 1024; i++ }
    printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i] }'
}

sub_url() { echo "${SUB_BASE}$1"; }

show_link() { # имя subId
  local url qr qr_width qr_columns
  url=$(sub_url "$2")
  echo
  echo "Подписка ${B}$1${N} — совместимые протоколы одной ссылкой. Вставьте в Clash Verge Rev, FlClash или Happ:"
  echo "Subscription URL и QR — секреты подключения. Не публикуйте их."
  echo
  echo "$url"
  echo
  if [[ -t 1 ]] && command -v qrencode >/dev/null; then
    # Background cells avoid font-dependent UTF-8 half blocks. Keep the full
    # quiet zone and do not print a QR that the terminal would wrap.
    if qr=$(qrencode -t ANSI -m 4 "$url"); then
      qr_width=$(awk 'NR == 1 { gsub(/\033\[[0-9;]*m/, ""); print length; exit }' <<<"$qr")
      qr_columns=$(tput cols 2>/dev/null) || qr_columns=${COLUMNS:-80}
      [[ $qr_columns =~ ^[0-9]+$ ]] || qr_columns=80
      if ((qr_width > 10#$qr_columns)); then
        echo "Для QR нужна ширина $qr_width символов (сейчас $qr_columns). Разверните терминал и повторите: kit user link $1"
      else
        printf '%s\n' "$qr"
      fi
    else
      echo "Не удалось построить QR. Ссылка подписки указана выше." >&2
    fi
  fi
  echo "${D}AmneziaVPN и Telegram: kit user link $1 --all — отдельные ссылки vpn:// и tg://${N}"
}

cmd_add() {
  local name=${1:-} gb=0 days=0 devices=0
  valid_name "$name"; shift
  while [[ $# -gt 0 ]]; do
    [[ $# -ge 2 ]] || die "Для $1 нужно значение."
    case $1 in
      --gb) gb=$2; shift 2 ;;
      --days) days=$2; shift 2 ;;
      --devices) devices=$2; shift 2 ;;
      *) die "Неизвестный параметр: $1" ;;
    esac
  done
  [[ $devices =~ ^[0-9]+$ ]] || die "--devices: целое число"
  [[ -z $(client "$name") ]] || die "Пользователь $name уже есть. Ссылка: kit user link $name"
  local ids sid body
  ids=$(non_awg_ids)
  [[ $ids != '[]' ]] || ids=$(awg_ids | jq -s '.[0:1]')
  [[ $ids != "[]" ]] || die "На сервере нет подключений."
  sid=$(rand_id)
  body=$(jq -nc --arg e "$name" --arg s "$sid" --argjson t "$(gb_bytes "$gb")" --argjson x "$(days_ms "$days")" \
    --argjson ip "$devices" --argjson ids "$ids" '{client: {email: $e, subId: $s, totalGB: $t, expiryTime: $x,
    limitIp: $ip, enable: true, comment: "kit"}, inboundIds: $ids}')
  api POST clients/add "$body" >/dev/null
  awg_attach "$name" "$sid" "$(gb_bytes "$gb")" "$(days_ms "$days")" "$devices"
  say "Пользователь $name добавлен во все протоколы ($(api GET inbounds/list | jq length))$( ((gb)) && echo ", лимит $gb ГБ")$( ((days)) && echo ", на $days дн")."
  show_link "$name" "$sid"
}

cmd_link() {
  local name=${1:-} all=${2:-} c
  valid_name "$name"
  c=$(client "$name"); [[ -n $c ]] || die "Нет пользователя $name"
  show_link "$name" "$(jq -r '.subId' <<<"$c")"
  if [[ $all == --all ]]; then
    local sid raw out="" suffix
    sid=$(jq -r '.subId' <<<"$c")
    for suffix in "" -awg; do
      raw=$(curl -fsSk -m 10 -A "v2rayN/7" -H "Host: $HOST" "http://127.0.0.1:$SUB_INTERNAL$SUB_PATH$sid$suffix" 2>/dev/null || true)
      grep -q '://' <<<"$raw" || raw=$(base64 -d <<<"$raw" 2>/dev/null || true)
      out+=$(grep -E '^(vpn|tg)://' <<<"$raw" || true)$'\n'
    done
    [[ ${SINGLE:-no} == yes ]] && out=$(sed "s/^\(tg:\/\/proxy?\)\(.*\)port=${MTPROTO_INNER:-10445}/\1\2port=443/" <<<"$out")
    echo; grep . <<<"$out" || echo "Отдельных ссылок нет."
  fi
}

cmd_list() {
  local now
  now=$(($(date +%s) * 1000))
  clients | jq -r --argjson now "$now" '
    map(select(.subId != null)) | group_by(.subId | sub("-awg[0-9]*$"; "")) | map(sort_by(.email | length) as $g | $g[0] + {used: ([$g[] | (.traffic.up // 0) + (.traffic.down // 0)] | add),
      seen: ([$g[] | .traffic.lastOnline // 0] | max)}) | sort_by(.email)[]
    | [.email, .used, (.totalGB // 0), (.expiryTime // 0), .enable, .seen] | @tsv' |
  {
    printf "${B}%-18s %-22s %-14s %-10s %s${N}\n" "Пользователь" "Трафик" "До" "Статус" "Был в сети"
    while IFS=$'\t' read -r email used total exp en last; do
      local tr till st seen
      tr="$(human "$used")"; ((total > 0)) && tr="$tr / $(human "$total")"
      if ((exp > 0)); then till=$(date -d "@$((exp / 1000))" +%d.%m.%Y); else till="бессрочно"; fi
      if [[ $en != true ]]; then st="${R}выключен${N}"
      elif ((exp > 0 && exp < $(date +%s) * 1000)); then st="${Y}истёк${N}"
      elif ((total > 0 && used >= total)); then st="${Y}лимит${N}"
      else st="${G}активен${N}"; fi
      if ((last > 0)); then seen=$(date -d "@$((last / 1000))" '+%d.%m %H:%M'); else seen="—"; fi
      printf "%-18s %-22s %-14s %-19s %s\n" "$email" "$tr" "$till" "$st" "$seen"
    done
  }
}

# Меняет все записи пользователя (основную и «двойников» AmneziaWG), каждую — от её собственных данных.
update_user() { # имя jq-фильтр [аргументы jq...]
  local name=$1 filter=$2 e rec body records
  shift 2
  records=$(emails_of "$name") || die "Не удалось получить записи пользователя $name."
  [[ -n $records ]] || die "Не найдены записи пользователя $name."
  for e in $records; do
    rec=$(client "$e")
    body=$(jq -c "$@" "{email, subId, totalGB, expiryTime, limitIp, enable, comment} | $filter" <<<"$rec")
    api POST "clients/update/$e" "$body" >/dev/null
  done
}

cmd_limit() {
  local name=${1:-} f="." gb="" days="" dev=""
  valid_name "$name"; shift
  [[ -n $(client "$name") ]] || die "Нет пользователя $name"
  while [[ $# -gt 0 ]]; do
    [[ $# -ge 2 ]] || die "Для $1 нужно значение."
    case $1 in
      --gb) gb=$(gb_bytes "$2"); f+=" | .totalGB = \$gb"; shift 2 ;;
      --days) days=$(days_ms "$2"); f+=" | .expiryTime = \$days"; shift 2 ;;
      --devices) [[ $2 =~ ^[0-9]+$ ]] || die "--devices: целое число"; dev=$2; f+=" | .limitIp = \$dev"; shift 2 ;;
      *) die "Неизвестный параметр: $1" ;;
    esac
  done
  update_user "$name" "$f" --argjson gb "${gb:-0}" --argjson days "${days:-0}" --argjson dev "${dev:-0}"
  say "Лимиты $name обновлены (0 — без ограничений)."
}

cmd_toggle() { # имя true|false
  valid_name "$1"
  [[ -n $(client "$1") ]] || die "Нет пользователя $1"
  update_user "$1" ".enable = \$v" --argjson v "$2"
  if [[ $2 == true ]]; then say "Пользователь $1 включён."; else say "Пользователь $1 выключен — подписка и подключения не работают."; fi
}

cmd_del() {
  local name=${1:-} ans=""
  valid_name "$name"
  [[ -n $(client "$name") ]] || die "Нет пользователя $name"
  if [[ ${2:-} != -y && -t 0 ]]; then
    read -rp "Удалить $name со всех протоколов? [y/N] " ans
    [[ $ans =~ ^[yYдД]$ ]] || { echo "Отменено."; return; }
  fi
  local e records
  records=$(emails_of "$name") || die "Не удалось получить записи пользователя $name."
  [[ -n $records ]] || die "Не найдены записи пользователя $name."
  for e in $records; do api POST "clients/del/$e" >/dev/null; done
  say "Пользователь $name удалён, его подписка больше не работает."
}


usage() {
  cat <<EOF
${B}kit${N} — пользователи: один пользователь сразу на всех протоколах

  kit user add имя [--gb 50] [--days 30] [--devices 3]   добавить и показать подписку
  kit user list                                           трафик, срок, статус
  kit user link имя [--all]                               подписка и QR; --all — ещё vpn:// и tg://
  kit user limit имя [--gb N] [--days N] [--devices N]    изменить лимиты (0 — без ограничений)
  kit user off имя  /  kit user on имя                    выключить и включить
  kit user del имя                                        удалить
  kit status                                              состояние сервера
  kit doctor                                              диагностика без секретов
  kit backup                                              защищённый архив данных
  kit version                                             версия KIT и источник
  kit update check                                        проверить stable release
  kit update                                              backup + инструкция ручного обновления
  kit harden ssh                                          безопасный порядок настройки SSH
EOF
}

case "${1:-}" in
  status|doctor|backup) exec python3 /usr/local/lib/kit/kit-admin.py "$1" ;;
  version) echo "KIT $KIT_VERSION ($REPO_OWNER/$REPO_NAME:$REPO_REF)"; exit 0 ;;
  update)
    if [[ ${2:-} == check ]]; then exec python3 /usr/local/lib/kit/kit-admin.py update-check; fi
    [[ $# == 1 ]] || die "Использование: kit update [check]"
    python3 /usr/local/lib/kit/kit-admin.py backup
    echo "Автоматическое применение отключено: обновление панели/БД требует ручного review."
    echo "$REPO_URL/blob/$REPO_REF/manuals/DEVELOPMENT.md"
    exit 0 ;;
  harden)
    [[ ${2:-} == ssh ]] || die "Использование: kit harden ssh"
    echo "SSH не изменён. Создайте sudo-пользователя, установите его public key и проверьте вход в НОВОЙ сессии."
    echo "Только затем sshd -t, отключение пароля и проверка входа; текущую сессию держите открытой."
    echo "$REPO_URL/blob/$REPO_REF/SECURITY.md"
    exit 0 ;;
  restore) die "Автоматическое восстановление не поддерживается. Сначала kit backup; см. manuals/INSTALL.md." ;;
esac

case "${1:-} ${2:-}" in
  "user add") shift 2; cmd_add "$@" ;;
  "user list") cmd_list ;;
  "user link") shift 2; cmd_link "$@" ;;
  "user limit") shift 2; cmd_limit "$@" ;;
  "user off") cmd_toggle "${3:-}" false ;;
  "user on") cmd_toggle "${3:-}" true ;;
  "user del") shift 2; cmd_del "$@" ;;
  *) usage ;;
esac
