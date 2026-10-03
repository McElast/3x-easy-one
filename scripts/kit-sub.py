#!/usr/bin/env python3
"""Подписка с учётом приложения — посредник перед подпиской 3X-UI.

Original KIT: https://github.com/itsnotkubrick/3X-UI_KIT

Слушает публичный адрес подписки (HTTPS) и ходит в подписку 3X-UI на 127.0.0.1:
  * Clash / Mihomo (Clash Verge, FlClash, Mihomo Party…) — конфиг 3X-UI плюс AmneziaWG
    из подписки «<id>-awg»: Mihomo умеет AmneziaWG, а остальные приложения нет;
  * остальные приложения и браузер — ответ 3X-UI как есть (ссылки или страница);
  * заголовок Subscription-Userinfo: expire=0 («бессрочно») убирается — иначе
    приложения показывают срок «01.01.1970».

Настройки — /etc/kit-sub/config.json. Сертификат перечитывается сам после продления.
"""

import base64
import http.server
import json
import os
import re
import socket
import ssl
import threading
import time
import urllib.error
import urllib.request
import urllib.parse

import yaml

CONFIG = os.environ.get("KIT_SUB_CONFIG", "/etc/kit-sub/config.json")
CLASH_UA = re.compile(r"clash|mihomo|flclash|stash|nyanpasu|meta", re.I)
# AmneziaWG добавляем только приложениям на ядре Mihomo. Karing, Hiddify и другие на sing-box
# тоже могут просить формат Clash (Karing так и делает), но AmneziaWG не умеют.
NO_AWG_UA = re.compile(r"karing|hiddify|nekobox|sing-?box|husi|stash|shadowrocket|v2box|streisand|happ|loon|surge|quantumult", re.I)
SUB_ID = re.compile(r"^[A-Za-z0-9_.@-]{1,64}$")
PASS_HEADERS = ("content-type", "content-disposition", "profile-title", "profile-update-interval",
                "subscription-userinfo")

with open(CONFIG, encoding="utf-8") as f:
    CONF = json.load(f)
PATH = "/" + CONF["path"].strip("/") + "/"


def log(msg):
    print(msg, flush=True)


def upstream(sub_id, ua, host, accept):
    """GET к подписке 3X-UI. Возвращает (код, заголовки, тело) или (None, {}, b"")."""
    req = urllib.request.Request(CONF["upstream"].rstrip("/") + PATH + sub_id, headers={
        "User-Agent": ua, "Host": host, "Accept": accept or "*/*"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            body = r.read(2 * 1024 * 1024 + 1)
            if len(body) > 2 * 1024 * 1024:
                return None, {}, b""
            return r.status, {k.lower(): v for k, v in r.getheaders()}, body
    except urllib.error.HTTPError as e:
        body = e.read(2 * 1024 * 1024 + 1)
        if len(body) > 2 * 1024 * 1024:
            return None, {}, b""
        return e.code, {k.lower(): v for k, v in e.headers.items()}, body
    except (urllib.error.URLError, OSError, socket.timeout) as e:
        log("subscription backend недоступен")
        return None, {}, b""


def fix_userinfo(value):
    # «expire=0» значит «бессрочно», но приложения рисуют 01.01.1970 — убираем.
    parts = [p.strip() for p in value.split(";") if p.strip() and p.strip() != "expire=0"]
    return "; ".join(parts)


def strip_links(body):
    """Список ссылок (base64 или текст) без vpn:// и tg:// — их не умеет ни одно VPN-приложение
    со ссылками: vpn:// — конфиг для AmneziaVPN, tg:// — прокси для Telegram."""
    text = body.decode("utf-8", "replace").strip()
    encoded = "://" not in text
    if encoded:
        try:
            text = base64.b64decode(text + "=" * (-len(text) % 4)).decode("utf-8", "replace")
        except ValueError:
            return body
    lines = [l for l in text.splitlines() if l.strip() and not l.startswith(("vpn://", "tg://"))]
    out = "\n".join(lines)
    return base64.b64encode(out.encode()).decode().encode() if encoded else out.encode()


def strip_awg(clash_yaml):
    """Clash-конфиг без AmneziaWG — для приложений, которые его не умеют."""
    cfg = yaml.safe_load(clash_yaml)
    if not isinstance(cfg, dict):
        return clash_yaml
    awg = {p.get("name") for p in cfg.get("proxies") or [] if isinstance(p, dict) and "amnezia-wg-option" in p}
    if not awg:
        return clash_yaml
    cfg["proxies"] = [p for p in cfg["proxies"] if p.get("name") not in awg]
    for g in cfg.get("proxy-groups") or []:
        if isinstance(g.get("proxies"), list):
            g["proxies"] = [x for x in g["proxies"] if x not in awg]
    return yaml.safe_dump(cfg, allow_unicode=True, sort_keys=False).encode()


def merge_awg(main_yaml, awg_yaml):
    """Добавляет прокси AmneziaWG в Clash-конфиг и во все группы, где перечислены прокси."""
    main = yaml.safe_load(main_yaml)
    awg = yaml.safe_load(awg_yaml)
    if not isinstance(main, dict) or not isinstance(awg, dict):
        return main_yaml
    extra = [p for p in (awg.get("proxies") or []) if isinstance(p, dict) and p.get("name")]
    if not extra:
        return main_yaml
    names = {p.get("name") for p in main.get("proxies") or []}
    for p in extra:
        # 3X-UI дописывает к имени запись-«двойника» («AmneziaWG-3.1-sasha-awg») — убираем хвост.
        p["name"] = re.sub(r"-[^-\s]+-awg\d*$", "", p["name"]) or p["name"]
        base, n = p["name"], 2
        while p["name"] in names:
            p["name"] = f"{base} {n}"
            n += 1
        names.add(p["name"])
    main.setdefault("proxies", []).extend(extra)
    added = [p["name"] for p in extra]
    for g in main.get("proxy-groups") or []:
        lst = g.get("proxies")
        if isinstance(lst, list) and any(x in names for x in lst):
            pos = lst.index("DIRECT") if "DIRECT" in lst else len(lst)
            g["proxies"] = lst[:pos] + added + lst[pos:]
    return yaml.safe_dump(main, allow_unicode=True, sort_keys=False).encode()


def mihomo_profile(body, ua, awg31=False):
    """Keep only supported transports; build a complete full-tunnel profile."""
    cfg = yaml.safe_load(body)
    if not isinstance(cfg, dict) or not isinstance(cfg.get("proxies"), list):
        raise ValueError("invalid subscription")
    version = re.search(r"mihomo[/\s]v?(\d+)\.(\d+)\.(\d+)", ua, re.I)
    flclash = re.search(r"flclash[/\s]v?(\d+)\.(\d+)\.(\d+)", ua, re.I)
    awg31 = awg31 or bool(version and tuple(map(int, version.groups())) >= (1, 19, 30))
    # Official stable v0.8.98 core submodule was checked for v3.1 fields.
    awg31 = awg31 or bool(flclash and tuple(map(int, flclash.groups())) >= (0, 8, 98))
    proxies = []
    seen = {"VPN", "AUTO", "FALLBACK", "DIRECT", "REJECT"}
    for source in cfg["proxies"]:
        if not isinstance(source, dict):
            continue
        p = dict(source)
        opts = p.get("amnezia-wg-option")
        if isinstance(opts, dict):
            full = opts.get("version") == 3 or bool(opts.get("header-protection-key"))
            if full and not awg31:
                continue
            name = "AWG31" if full else "AWG CLASSIC"
            if full:
                p["amnezia-wg-option"] = dict(opts, version=3)
        elif p.get("type") == "vless" and p.get("reality-opts"):
            name = "XHTTP" if p.get("network") == "xhttp" else "REALITY"
            if name == "XHTTP" and version and tuple(map(int, version.groups())) < (1, 19, 22):
                continue
        elif p.get("type") == "hysteria2":
            name = "HYSTERIA2"
        else:
            name = str(p.get("name", "VPN"))
        name = re.sub(r"[\r\n,]", " ", name)
        base, n = name, 2
        while name in seen:
            name = f"{base} {n}"
            n += 1
        seen.add(name)
        p["name"] = name
        proxies.append(p)
    if not proxies:
        raise ValueError("no supported proxies")
    priority = {"REALITY": 0, "XHTTP": 1, "HYSTERIA2": 2, "AWG31": 3, "AWG CLASSIC": 4}
    proxies.sort(key=lambda p: priority.get(p["name"], 5))
    names = [p["name"] for p in proxies]
    probe = CONF.get("probe_url", "https://www.gstatic.com/generate_204")
    lan = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8",
           "169.254.0.0/16", "224.0.0.0/4"]
    return yaml.safe_dump({
        "mixed-port": 7890, "allow-lan": False, "bind-address": "127.0.0.1",
        "mode": "rule", "log-level": "warning", "ipv6": False,
        "tun": {"enable": False, "stack": "mixed", "auto-route": True,
                "auto-detect-interface": True, "dns-hijack": ["any:53", "tcp://any:53"],
                "route-exclude-address": lan},
        "dns": {"enable": True, "listen": "127.0.0.1:1053", "ipv6": False,
                "enhanced-mode": "fake-ip", "fake-ip-filter": ["*.lan", "*.local", "localhost"],
                "nameserver-policy": {"+.lan": "system", "+.local": "system"},
                "direct-nameserver": ["system"],
                "respect-rules": True, "default-nameserver": ["1.1.1.1", "9.9.9.9"],
                "proxy-server-nameserver": ["https://1.1.1.1/dns-query"],
                "nameserver": ["https://1.1.1.1/dns-query", "https://dns.quad9.net/dns-query"]},
        "proxies": proxies,
        "proxy-groups": [
            {"name": "VPN", "type": "select", "proxies": ["AUTO", "FALLBACK"] + names},
            {"name": "AUTO", "type": "url-test", "proxies": names, "url": probe,
             "interval": 60, "tolerance": 100, "lazy": True},
            {"name": "FALLBACK", "type": "fallback", "proxies": names, "url": probe,
             "interval": 60, "lazy": True}],
        "rules": ["DOMAIN-SUFFIX,lan,DIRECT", "DOMAIN-SUFFIX,local,DIRECT"] +
                 [f"IP-CIDR,{net},DIRECT,no-resolve" for net in lan] +
                 ["IP-CIDR6,::1/128,DIRECT,no-resolve", "IP-CIDR6,fc00::/7,DIRECT,no-resolve",
                  "IP-CIDR6,fe80::/10,DIRECT,no-resolve", "MATCH,VPN"],
    }, allow_unicode=True, sort_keys=False).encode()


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "nginx"
    sys_version = ""
    timeout = 20  # зависшие соединения не держим

    def setup(self):
        # TLS-рукопожатие — в потоке запроса, а не в общем цикле приёма соединений.
        # Без сертификата (за nginx, на 127.0.0.1) работаем по обычному HTTP.
        self.request.settimeout(self.timeout)
        if self.server.ssl_ctx is not None:
            self.request = self.server.ssl_ctx.wrap_socket(self.request, server_side=True)
        super().setup()

    def handle(self):
        try:
            super().handle()
        except (ssl.SSLError, ConnectionError, socket.timeout, OSError):
            pass

    def log_message(self, fmt, *args):  # без IP клиентов в логах
        pass

    def send_plain(self, code, text=""):
        body = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        parsed = urllib.parse.urlsplit(self.path)
        path = parsed.path
        options = urllib.parse.parse_qs(parsed.query)
        if not path.startswith(PATH):
            return self.send_plain(404, "404 page not found")
        sub_id = path[len(PATH):]
        if not SUB_ID.match(sub_id):
            return self.send_plain(404, "404 page not found")
        ua = self.headers.get("User-Agent", "")
        # A supplied Host must never change generated server addresses.
        host = CONF.get("host", "")
        accept = self.headers.get("Accept", "")
        if options.get("format") == ["mihomo"]:
            ua = "mihomo/1.19.22"
        code, headers, body = upstream(sub_id, ua, host, accept)
        if code is None:
            return self.send_plain(502, "subscription backend is unavailable")

        clash = bool(CLASH_UA.search(ua)) and "yaml" in headers.get("content-type", "")
        awg = clash and not NO_AWG_UA.search(ua)
        # В журнал — только приложение и что ему отдали, без IP.
        log("subscription: mihomo" if clash else "subscription: client")
        try:
            if code == 200 and clash:
                if not awg:
                    body = strip_awg(body)
                elif not sub_id.endswith(("-awg", "-tg")):
                # Установки до kit 1.1 держали AmneziaWG в подписке «<id>-awg» — подмешиваем её.
                    acode, _, abody = upstream(sub_id + "-awg", ua, host, accept)
                    if acode == 200 and abody:
                        body = merge_awg(body, abody)
                body = mihomo_profile(body, ua, options.get("awg31") == ["1"])
            elif code == 200 and "text/plain" in headers.get("content-type", ""):
                body = strip_links(body)
        except (yaml.YAMLError, UnicodeError, ValueError, TypeError, AttributeError):
            log("не удалось обработать подписку")
            return self.send_plain(502, "invalid subscription backend response")

        self.send_response(code)
        for k in PASS_HEADERS:
            if k in headers:
                v = fix_userinfo(headers[k]) if k == "subscription-userinfo" else headers[k]
                if v:
                    self.send_header(k.title(), v)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    ssl_ctx = None

    def handle_error(self, request, client_address):  # обрывы TLS от сканеров — не ошибка
        pass
    address_family = socket.AF_INET6 if ":" in CONF.get("listen", "") else socket.AF_INET


def main():
    cert, key = CONF.get("cert"), CONF.get("key")
    if not cert:
        srv = Server((CONF.get("listen", "127.0.0.1"), int(CONF["port"])), Handler)
        log("kit-sub запущен за nginx")
        srv.serve_forever()
        return
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(cert, key)
    stamp = [os.path.getmtime(cert)]

    def reload_cert():
        # Let's Encrypt на IP живёт 6 дней — после продления берём новый сертификат без перезапуска.
        while True:
            time.sleep(600)
            try:
                m = os.path.getmtime(cert)
                if m != stamp[0]:
                    ctx.load_cert_chain(cert, key)
                    stamp[0] = m
                    log("сертификат обновлён")
            except (OSError, ssl.SSLError):
                log("не удалось перечитать сертификат")

    threading.Thread(target=reload_cert, daemon=True).start()
    srv = Server((CONF.get("listen", "0.0.0.0"), int(CONF["port"])), Handler)
    srv.ssl_ctx = ctx
    log("kit-sub запущен с TLS")
    srv.serve_forever()


if __name__ == "__main__":
    main()
