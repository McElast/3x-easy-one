#!/usr/bin/env bash
# Прогон матрицы: каждый конфиг — отдельный клиент, через него открываем сайт.
set -uo pipefail
cd /lab/cases || exit 1
shopt -s nullglob
t() { # client port cmd...
  local port=$1 pid; shift
  "$@" >/tmp/c.log 2>&1 &
  pid=$!
  local code=000
  for i in 1 2 3 4 5 6; do
    sleep 1
    code=$(curl -s -m 8 -x socks5h://127.0.0.1:$port -o /dev/null -w '%{http_code}' https://www.google.com/generate_204)
    [[ $code == 204 ]] && break
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  sleep 0.5
  if [[ $code == 204 ]]; then
    echo "✓"
    return 0
  fi
  echo "✗ $(grep -i -m1 -E 'error|fail|fatal|invalid' /tmp/c.log | cut -c1-90)"
  return 1
}
checks=0; failures=0
printf '%-32s %-40s %-40s %s\n' "протокол" "Xray 26.6.27" "Mihomo" "sing-box"
for d in */; do
  d=${d%/}
  x='—'; m='—'; s='—'
  if [[ -f $d/xray.json ]]; then
    checks=$((checks + 1)); x=$(t 1080 /cl/xray run -c $d/xray.json) || failures=$((failures + 1))
  fi
  if [[ -f $d/mihomo.yaml ]]; then
    checks=$((checks + 1)); m=$(t 1081 /cl/mihomo -d /tmp/mh -f $d/mihomo.yaml) || failures=$((failures + 1))
  fi
  if [[ -f $d/singbox.json ]]; then
    checks=$((checks + 1)); s=$(t 1082 /cl/sing-box run -c $d/singbox.json) || failures=$((failures + 1))
  fi
  printf '%-32s %-40s %-40s %s\n' "$d" "$x" "$m" "$s"
done
if ((checks == 0)); then
  echo "Нет конфигов клиентов для проверки." >&2
  exit 1
fi
exit "$((failures > 0))"
