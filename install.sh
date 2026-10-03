#!/usr/bin/env bash
# Bootstrap only; all runtime settings live in scripts/repo.conf.
set -Eeuo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo 'Сначала выполните sudo -i.' >&2; exit 1; }
for kit_cmd in curl tar; do
  command -v "$kit_cmd" >/dev/null || { echo "Нужен $kit_cmd." >&2; exit 1; }
done
KIT_REF=${KIT_REF:-v1.0.0}
[[ $KIT_REF =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ || $KIT_REF == main || $KIT_REF =~ ^[0-9a-f]{40}$ ]] || {
  echo 'KIT_REF: stable tag, commit SHA или main для разработки.' >&2; exit 1;
}
export KIT_REF
kit_tmp=$(mktemp -d)
trap 'rm -rf -- "$kit_tmp"' EXIT
# One archive makes all installed KIT files come from one repository snapshot.
curl -fSL --retry 3 --connect-timeout 15 --max-time 180 \
  "https://codeload.github.com/McElast/3x-easy-one/tar.gz/$KIT_REF" -o "$kit_tmp/source.tar.gz"
mkdir "$kit_tmp/source"
tar -xzf "$kit_tmp/source.tar.gz" --strip-components=1 -C "$kit_tmp/source"
bash "$kit_tmp/source/scripts/3x-ui.sh" "$@"
