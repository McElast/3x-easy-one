# Разработка и публикация 3x-easy-one

## Архитектура

- `install.sh` — небольшой bootstrap: один архив tag/SHA/main, запуск локального installer. Единственное повторение имени репозитория нужно для получения архива до появления runtime configuration.
- `KIT_VERSION` — единая версия проекта. `scripts/repo.conf` — runtime repository, ref и фиксированные версии компонентов. Bootstrap по умолчанию указывает первый stable tag; при следующем release его default ref нужно обновить. Документированная команда всегда передаёт явный KIT_REF.
- `scripts/3x-ui.sh` — установка 3X-UI, закреплённого Xray, создание выбранных inbounds, клиентов, cert-renew, подписки/nginx и UFW.
- `scripts/kit.sh` — штатные per-device пользователи, связанные AWG-записи, обслуживание. `scripts/kit-admin.py` — doctor/status, SQLite backup, чтение release metadata.
- `scripts/kit-sub.py` — proxy к нативной подписке 3X-UI. Собственный Host, ограничение ответа 2 MiB, no-store, без вывода User-Agent/URL в журнал. Для Mihomo строит полный профиль с AUTO/FALLBACK; native формат других клиентов сохраняет.
- REALITY и XHTTP: TCP/443 → nginx stream по двум разным SNI → 127.0.0.1:10443/10444. Это разные транспорты, но не независимые серверы.
- HTTPS подписки: TCP/443 → 127.0.0.1:10446 → kit-sub на 10460 → native backend 2097. Админ-панель не публикуется.
- Hysteria2 через Xray: UDP/443. AWG classic/3.1 встроены в панель, UDP/51821 и 51822.
- Два AWG требуют разных пар ключей и разных client records. Оригинальный механизм twins сохранён. Команды off/del применяются к обоим; вывод traffic суммируется, строгий общий лимит всех twin records не обещается.

Версии 3X-UI v3.8.5 и Xray v26.6.27 сохранены, поскольку исходный KIT документировал несовместимость REALITY с некоторыми клиентами на Xray 26.7.x. Это исходное наблюдение, не результат новой проверки на VPS. acme.sh 3.1.6 добавлен как фиксированная зависимость для IP-certificate вместо mutable get.acme.sh/auto-upgrade; SHA-256 записана в repo.conf. Standalone Hysteria 2.12.3 не обновлялась.

Для AWG31 требуется поддержка runtime ядра. Mihomo >=1.19.30 её документирует; конкретный FlClash v0.8.98 использует core submodule `70f0570405c3c2c47bb113b88db95006d239b346`, чей `adapter/outbound/wireguard.go` содержит v3.1-параметры. Если User-Agent не содержит подтверждённой версии, выдаётся совместимый профиль без AWG31; advanced opt-in `?format=mihomo&awg31=1` требует проверки ядра. XHTTP требует современного ядра (Mihomo >=1.19.22); не выдавайте его старым явно распознанным ядрам.

Полный VPN требует TUN/разрешения на устройстве. TUN в YAML выключен до явного включения в GUI; настройки DNS, маршрутов и локальных исключений подготовлены. Не включайте геобазы и удалённые rule-providers в пользовательскую subscription без необходимости. Сохранённый генератор роутера — отдельный инструмент со своими параметрами.

В генераторе роутера zashboard закреплён на официальном v3.29.1 вместо latest: это исполняемый JavaScript UI. Удалённые rule sets остаются обновляемыми данными маршрутизации. Они не входят в основной профиль подписки.

## Локальные проверки

Не создавайте новых unit/integration/e2e тестов. Обычные проверки после правок:

```bash
bash -n install.sh
bash -n scripts/3x-ui.sh
bash -n scripts/kit.sh
bash -n scripts/hysteria2.sh
python3 -m py_compile scripts/kit-sub.py scripts/kit-admin.py
node --check tools/lib/mihomo.js
git diff --check
```

Проверьте JSON/YAML штатными парсерами, runtime-конфиг Mihomo его `-t`, nginx-конфиг через `nginx -t` при наличии nginx/stream module. Shellcheck используйте при доступности. Проверьте локальные ссылки, сетевые ссылки, .gitignore, секреты и все `itsnotkubrick`: оставаться должны только credits/upstream documentation и сохранённые исходные иллюстрации с пояснением.

Проверки синтаксиса не подтверждают работу API, сертификата IP, revoke AWG и переключение Wi-Fi/LTE. Приёмка на отдельном тестовом VPS: установить, `kit doctor`, создать два устройства, проверить подписки/оба AWG, reboot, revoke одного устройства, убедиться в работе другого. Не использовать реальные private keys в git.

## Новый репозиторий GitHub

Создайте пустой репозиторий `McElast/3x-easy-one` на GitHub без автоматического README. Локальный origin уже указывает на него; remote `source` сохранён для происхождения. Сначала проверьте diff, затем из корня проекта:

```bash
git status
git diff --check
git add .gitignore .gitattributes KIT_VERSION install.sh README.md SECURITY.md CHANGELOG.md scripts manuals tools tests index.html
git diff --cached
git commit -m "Prepare personal KIT v1.0.0"
git tag -a v1.0.0 -m "Personal KIT v1.0.0"
git push -u origin main
git push origin v1.0.0
```

Команды push выполняет владелец. GitHub Release создайте вручную из тега после приёмки; без Release `kit update check` не найдёт latest stable, хотя установка по tag уже доступна. Защитите опубликованные теги от перезаписи. История исходного проекта сохранена; авторство не удаляется.

В исходном KIT этого снимка нет LICENSE. Не назначайте лицензию за исходного автора; разберитесь с условиями исходных материалов перед внешним распространением. Сторонние компоненты имеют свои лицензии.

## Обновления KIT

`kit update check` читает release metadata **McElast/3x-easy-one**. `kit update` сохраняет backup и показывает этот документ, не применяет код. Автоматическая миграция отложена до проверки реального rollback.

Для проверенного обновления только файлов KIT на том же VPS:

1. `kit backup`, snapshot у хостера, запись `kit version`. Получите архив конкретного нового tag/SHA из нашего репозитория, изучите CHANGELOG/diff.
2. Убедитесь, что серверные pins, формат kit.env/sub config, пути и unit files совместимы. При изменении schema/протоколов используйте отдельно подготовленную и проверенную миграцию.
3. Проверьте синтаксис **всех** файлов новой версии до замены. Остановите kit-sub. Сохраните старые `/usr/local/bin/kit`, `/usr/local/lib/kit`, `/usr/local/lib/kit-sub`, `/etc/kit` отдельно для rollback.
4. Замените согласованным комплектом `kit.sh` → `/usr/local/bin/kit`, `kit-admin.py` → `/usr/local/lib/kit/kit-admin.py`, `kit-sub.py` → `/usr/local/lib/kit-sub/kit_sub.py`, `repo.conf` и `KIT_VERSION` → `/etc/kit`. Не заменяйте существующий kit.env или DB. Установите в kit.env KIT_REF нового тега; сохраните права 0600 для settings и 0755/0644 для кода.
5. Запустите kit-sub, выполните `kit version`, `kit doctor`, проверьте обе подписки и revoke тестового устройства. При сбое восстановите старый согласованный комплект и прежний KIT_REF.

Не выполняйте curl latest | bash и не запускайте full installer как updater. Меню `x-ui` относится к внешней панели; его самостоятельное обновление может изменить pinned компонент, поэтому сначала review/backup и проверка совместимости.

## Ручное сравнение upstream

Исходный upstream: [itsnotkubrick/3X-UI_KIT](https://github.com/itsnotkubrick/3X-UI_KIT).

```bash
git remote add upstream https://github.com/itsnotkubrick/3X-UI_KIT.git
git fetch upstream
git diff HEAD..upstream/main -- scripts manuals tools
```

Если remote уже существует, повторно не добавляйте. Изучение diff не исполняет код. Переносите только нужные изменения после review, проверьте pins/URL/секреты, затем выпускайте новый tag нашего проекта. Не запускайте скачанные upstream-скрипты на рабочем сервере автоматически.
