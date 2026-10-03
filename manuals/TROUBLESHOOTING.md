# Если VPN не работает

Начните с `kit doctor` на VPS. Он проверяет локальные службы, listening ports, API, сертификат и реальную HTTPS-подписку одного активного пользователя, не печатая токен. `OK` не доказывает внешнюю доступность UDP и обход DPI. UFW может быть исправен, а firewall хостера закрыт.

На устройстве: AUTO → FALLBACK → REALITY → XHTTP → Hysteria2. Затем отключите основной VPN и попробуйте Amnezia/AWG31 и AWG classic. Сравните Wi-Fi/LTE. Не меняйте одновременно десять настроек.

## Подключён, но сайты не открываются

Проверьте Rule и TUN/системный VPN, правильный выбранный профиль, отсутствие другого VPN/прокси. Сравните другой транспорт. На Linux:

```bash
ip route
getent hosts example.com
resolvectl status
curl -I --max-time 15 https://example.com
```

Без resolvectl: `cat /etc/resolv.conf`. Если по IP соединения работают, а имена нет, проверяйте DNS. Не отключайте проверку сертификатов ради «починки».

## Wi-Fi работает, мобильная сеть нет

На телефоне проверьте разрешение приложения на мобильные данные, фоновую работу и отсутствие режима экономии, убивающего клиент. Попробуйте REALITY/XHTTP: UDP может блокироваться или ограничиваться. На VPS:

```bash
kit doctor
ss -lntup
ufw status verbose
```

Проверьте также firewall хостера. Зелёный локальный UDP-порт не доказывает, что пакет дошёл через оператора.

## LTE работает, Wi-Fi нет

Отключите VPN, завершите авторизацию captive portal в браузере, снова включите VPN. Попробуйте TCP-вариант. Убедитесь, что часы телефона правильные и HTTPS-подписка обновляется. Не изменяйте server SNI только из-за одной чужой сети; сравните на другом Wi-Fi.

## REALITY работает, Hysteria2 нет

Hysteria2 основного KIT работает в Xray; отдельная systemd-служба Hysteria здесь не нужна.

```bash
kit doctor
ss -lunp 'sport = :443'
systemctl status x-ui --no-pager
ufw status verbose
```

Откройте 443/udp у хостера. Проверьте срок сертификата по `kit doctor`. Попробуйте другую сеть: если UDP запрещён, используйте TCP. Не устанавливайте standalone hysteria2.sh поверх KIT — он займёт тот же порт.

## AWG не подключается

Убедитесь, что импортировали ссылку именно своего устройства и выбрали нужный AWG. Проверьте официальный клиент и обновите stable версию. На сервере:

```bash
kit user list
kit doctor
ss -lunp 'sport = :51822'
ss -lunp 'sport = :51821'
systemctl status x-ui --no-pager
```

51822 — AWG31, 51821 — classic. Для обоих проверьте firewall хостера. В Mihomo проверьте версию ядра: AWG31 требует совместимой реализации. При ошибке импорта вернитесь к обычной URL без advanced opt-in или используйте Amnezia. Смена интерфейса телефона может требовать переподключения.

## Subscription не обновляется

Проверьте URL без лишних пробелов, часы устройства и работающий интернет без VPN. Убедитесь, что пользователь включён, не истёк и не достиг лимита. Не вставляйте URL в сторонний сервис проверки.

```bash
kit doctor
systemctl status kit-sub nginx x-ui --no-pager
systemctl list-timers kit-cert-renew.timer
systemctl status kit-cert-renew.service --no-pager
```

80/tcp должен быть доступен ACME постоянно. Если HTTPS-клиент сообщает недоверенный/истёкший сертификат, исправьте renewal; не включайте insecure. Для FlClash/Clash при неправильном формате можно использовать собственную URL с `?format=mihomo` и обновить профиль. Секретный URL не указывайте в shell history или снимках экрана.

## После отключения VPN Linux потерял интернет

Выключите TUN и System Proxy, затем завершите VPN-клиент. Проверьте ручной proxy в системных настройках и настройках браузера.

```bash
nmcli general status
nmcli connection show --active
ip addr
ip route
getent hosts example.com
resolvectl status
```

Переподключите Wi-Fi штатным меню NetworkManager. Если нужно, перезапустите локальный ПК; удалённо такие действия могут оборвать доступ. Не удаляйте NetworkManager connections, routes или resolv.conf вслепую. Полностью выключенный System Proxy особенно важен, если клиент уже закрыт, а браузер продолжает пытаться обращаться к localhost:7890.

## После перезагрузки VPS VPN не поднялся

```bash
kit doctor
systemctl is-enabled x-ui nginx kit-sub
systemctl status x-ui nginx kit-sub --no-pager
nginx -t
df -h /
free -h
```

Если службы не enabled, выясните причину и включите нужные: `systemctl enable x-ui nginx kit-sub`. При invalid nginx config не перезапускайте его до исправления. Личные журналы можно посмотреть `journalctl -u x-ui -n 50 --no-pager`, но перед пересылкой удалите ключи, credentials и URL.

## YouTube работает медленно

Сравните REALITY/XHTTP/Hysteria2/AWG на одном видео в одной сети. Посмотрите старт, перемотку и буферизацию, а не только Speedtest. Временно снизьте качество, сравните Wi-Fi/LTE. На VPS:

```bash
uptime
free -h
df -h /
ip -s link
```

На ПК сравните задержку/потери: Linux/macOS `ping -c 10 example.com`, Windows `ping -n 10 example.com`. ICMP может блокироваться и не отражает путь прокси. Проверка HTTPS через реальный прокси информативнее. Если плохо через все протоколы, проверьте загрузку/лимиты VPS и качество его маршрута; AUTO не меняет сам IP сервера.
