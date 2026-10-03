#!/usr/bin/env python3
"""Read-only diagnostics and consistent SQLite backups. No secrets in reports."""
import datetime
import http.client
import json
import os
from pathlib import Path
import shutil
import socket
import sqlite3
import ssl
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
import yaml


def command(*args):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=15, check=False)
        return p.returncode, p.stdout
    except (OSError, subprocess.TimeoutExpired):
        return 1, ""


def api(path):
    port = int(os.environ["XUI_PANEL_PORT"])
    base = os.environ["XUI_WEB_BASE_PATH"].strip("/")
    scheme = os.environ.get("API_SCHEME", "http")
    req = urllib.request.Request(f"{scheme}://127.0.0.1:{port}/{base}/panel/api/{path}",
        headers={"Authorization": "Bearer " + os.environ["XUI_API_TOKEN"]})
    # The only unverified TLS here is the loopback administrative backend.
    with urllib.request.urlopen(req, timeout=8, context=ssl._create_unverified_context()) as r:
        data = json.load(r)
    if not data.get("success"):
        raise ValueError("panel API failed")
    return data["obj"]


def certificate():
    path = os.environ.get("CERT", "")
    rc, end = command("openssl", "x509", "-in", path, "-noout", "-enddate")
    if rc:
        return False, "сертификат не читается; проверьте cert-renew и 80/tcp"
    ok = command("openssl", "x509", "-in", path, "-checkend", "86400", "-noout")[0] == 0
    return ok, end.strip() if ok else "до истечения меньше суток; проверьте kit-cert-renew.timer"


def report(status_only=False):
    failures = 0
    def row(name, state, detail=""):
        nonlocal failures
        failures += state == "FAIL"
        print(f"{name:<20} {state:<5} {detail}")

    print("Server:", os.environ.get("HOST", "unknown"))
    for service in ("x-ui", "nginx", "kit-sub"):
        if service == "nginx" and os.environ.get("SINGLE") != "yes":
            row(service, "N/A", "режим отдельных портов")
            continue
        rc, _ = command("systemctl", "is-active", "--quiet", service)
        row(service, "OK" if rc == 0 else "FAIL", "" if rc == 0 else f"проверьте systemctl status {service}")
    ok, info = certificate()
    row("certificate", "OK" if ok else "FAIL", info)
    units = api_ok = None
    try:
        units = api("inbounds/list")
        clients = api("clients/list")
        clients = clients if isinstance(clients, list) else clients.get("clients", [])
        now = int(datetime.datetime.now(datetime.timezone.utc).timestamp() * 1000)
        import re
        active = [c for c in clients if c.get("enable") and not re.search(r"-awg\d*$", c.get("email", ""))
                  and (not c.get("expiryTime") or c["expiryTime"] > now)]
        row("users", "OK", f"активных записей устройств: {len(active)}")
        api_ok = True
    except (OSError, ValueError, KeyError, TypeError):
        row("panel API", "FAIL", "нет ответа; проверьте x-ui и /etc/x-ui/install-result.env")

    if units is not None:
        _, sockets = command("ss", "-H", "-lntup")
        for inbound in units:
            name = str(inbound.get("remark", inbound.get("protocol", "protocol")))
            port = int(inbound.get("port", 0))
            if not inbound.get("enable"):
                row(name, "OFF", "выключено в панели")
                continue
            udp = inbound.get("protocol") in ("hysteria", "amneziawg", "wireguard", "tuic")
            listening = any(line.split()[0] == ("udp" if udp else "tcp") and
                line.split()[4].rsplit(":", 1)[-1] == str(port) for line in sockets.splitlines()
                if len(line.split()) > 4)
            row(name, "OK" if listening else "FAIL",
                f"{'UDP' if udp else 'TCP'}/{port} слушает" if listening else
                f"{'UDP' if udp else 'TCP'}/{port} не слушает; проверьте x-ui и включение протокола")
        if api_ok and not status_only:
            try:
                data = api("server/status")
                state = data.get("xray", {}).get("state", "unknown")
                row("Xray", "OK" if state == "running" else "FAIL", str(state))
                settings_req = urllib.request.Request(
                    f"{os.environ.get('API_SCHEME', 'http')}://127.0.0.1:{os.environ['XUI_PANEL_PORT']}/"
                    f"{os.environ['XUI_WEB_BASE_PATH'].strip('/')}/panel/api/setting/all", data=b"{}",
                    headers={"Authorization": "Bearer " + os.environ["XUI_API_TOKEN"], "Content-Type": "application/json"})
                with urllib.request.urlopen(settings_req, timeout=8, context=ssl._create_unverified_context()) as r:
                    settings = json.load(r)["obj"]
                local = settings.get("webListen") == "127.0.0.1" and settings.get("subListen") == "127.0.0.1"
                row("admin isolation", "OK" if local else "FAIL", "localhost" if local else "панель/backend должны слушать localhost")
            except (OSError, ValueError, KeyError, TypeError):
                row("Xray/admin API", "FAIL", "проверьте x-ui через SSH-туннель")

    disk = shutil.disk_usage("/")
    row("disk", "OK" if disk.free > 512 * 1024**2 else "FAIL", f"свободно {disk.free // 1024**2} MiB")
    memory = {}
    for line in Path("/proc/meminfo").read_text().splitlines():
        parts = line.split()
        memory[parts[0].rstrip(":")] = int(parts[1])
    row("memory", "OK" if memory.get("MemAvailable", 0) > 64 * 1024 else "WARN",
        f"доступно {memory.get('MemAvailable', 0) // 1024} MiB")
    if not status_only:
        if os.environ.get("SINGLE") == "yes":
            row("nginx config", "OK" if command("nginx", "-t")[0] == 0 else "FAIL", "при ошибке: sudo nginx -t")
        rc, output = command("ufw", "status")
        row("UFW", "OK" if rc == 0 and "Status: active" in output else "WARN",
            "проверьте также firewall в панели VPS; внешнюю доступность это не доказывает")
        if Path("/etc/systemd/system/kit-cert-renew.timer").exists():
            row("cert renewal", "OK" if command("systemctl", "is-active", "--quiet", "kit-cert-renew.timer")[0] == 0 else "FAIL",
                "systemctl list-timers kit-cert-renew.timer")
        # Fetch a real device subscription locally through public TLS termination.
        # Token stays in this process; no curl command line or log can expose it.
        candidate = next((c for c in active if c.get("subId")), None) if api_ok else None
        if candidate:
            url = os.environ["SUB_BASE"] + candidate["subId"]
            try:
                from urllib.parse import urlsplit
                target = urlsplit(url)
                host = target.hostname
                port = target.port or 443
                # Validate HTTPS name/chain, but connect to local nginx/kit-sub.
                ctx = ssl.create_default_context()
                class LocalHTTPS(http.client.HTTPSConnection):
                    def connect(self):
                        self.sock = ctx.wrap_socket(socket.create_connection(("127.0.0.1", port), 8), server_hostname=host)
                conn = LocalHTTPS(host, port, timeout=8)
                conn.request("GET", target.path, headers={"User-Agent": "mihomo/1.19.30", "Host": target.netloc})
                response = conn.getresponse()
                body = response.read(2 * 1024 * 1024)
                profile = yaml.safe_load(body)
                success = response.status == 200 and isinstance(profile, dict) and bool(profile.get("proxies"))
                conn.close()
                row("subscription", "OK" if success else "FAIL", "HTTPS + профиль" if success else "проверьте kit-sub и сертификат")
            except (OSError, ValueError, TypeError, yaml.YAMLError, http.client.HTTPException):
                row("subscription", "FAIL", "проверьте kit-sub, сертификат и nginx")
        else:
            row("subscription", "WARN", "нет активного пользователя; создайте kit user add имя")
        print("OK означает локальную исправность. Доступность из Wi-Fi/LTE и DPI проверяется на устройстве.")
    return int(failures > 0)


def backup():
    destination = Path("/root/kit-backups")
    destination.mkdir(mode=0o700, exist_ok=True)
    destination.chmod(0o700)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    fd, name = tempfile.mkstemp(prefix=f"kit-{stamp}-", suffix=".tar.gz", dir=destination)
    os.fchmod(fd, 0o600)
    os.close(fd)
    db = Path("/etc/x-ui/x-ui.db")
    if not db.is_file():
        Path(name).unlink()
        raise ValueError("Не найдена SQLite DB; нестандартное размещение/ PostgreSQL не поддерживается.")
    try:
        with tempfile.TemporaryDirectory(prefix="kit-backup-") as scratch:
            os.chmod(scratch, 0o700)
            snapshot = Path(scratch) / "x-ui.db"
            with sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=15) as src, sqlite3.connect(snapshot) as dst:
                deadline = time.monotonic() + 120
                def progress(_status, _remaining, _total):
                    if time.monotonic() > deadline:
                        raise ValueError("SQLite backup timeout; retry without active administration")
                src.backup(dst, pages=256, progress=progress)
                if dst.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                    raise ValueError("SQLite integrity_check failed")
            snapshot.chmod(0o600)
            def include(info):
                if info.issym() or info.islnk():
                    # Restoring unreviewed links is unsafe. Preserve regular files only.
                    return None
                if any(x in {"backup", "backups", "cache", "logs", "__pycache__"} for x in Path(info.name).parts):
                    return None
                if info.name.startswith("etc/x-ui/x-ui.db") or info.name.endswith((".log", ".tmp")):
                    return None
                return info
            paths = ["/etc/x-ui", "/etc/kit", "/etc/kit-sub", "/root/cert", "/root/.acme.sh",
                "/etc/nginx/nginx.conf", "/etc/nginx/kit-stream.conf", "/etc/nginx/conf.d/kit.conf",
                "/etc/systemd/system/x-ui.service", "/etc/systemd/system/kit-sub.service",
                "/etc/systemd/system/kit-cert-renew.service", "/etc/systemd/system/kit-cert-renew.timer",
                "/etc/cron.d/kit-nginx-reload", "/root/3x-ui.txt", "/usr/local/bin/kit",
                "/usr/local/lib/kit", "/usr/local/lib/kit-sub"]
            with tarfile.open(name, "w:gz") as archive:
                for path in paths:
                    if Path(path).exists():
                        archive.add(path, arcname=path.lstrip("/"), filter=include)
                archive.add(snapshot, arcname="etc/x-ui/x-ui.db")
                metadata = Path(scratch) / "BACKUP.json"
                metadata.write_text(json.dumps({"format": 1, "kit": Path("/etc/kit/KIT_VERSION").read_text().strip(),
                    "created_utc": stamp, "db": "sqlite", "restore": "manual review required"}))
                archive.add(metadata, arcname="BACKUP.json")
            with tarfile.open(name) as archive:
                if "etc/x-ui/x-ui.db" not in archive.getnames():
                    raise ValueError("Incomplete archive")
        print(name)
        print("Архив содержит секреты. Храните его вне VPS в защищённом месте; права 0600.")
        return 0
    except BaseException:
        Path(name).unlink(missing_ok=True)
        raise


def update_check():
    repo = os.environ["REPO_OWNER"] + "/" + os.environ["REPO_NAME"]
    req = urllib.request.Request(f"https://api.github.com/repos/{repo}/releases/latest",
        headers={"User-Agent": "3x-easy-one-update-check", "Accept": "application/vnd.github+json"})
    print("Installed KIT:", Path("/etc/kit/KIT_VERSION").read_text().strip())
    try:
        with urllib.request.urlopen(req, timeout=15) as response:
            data = json.load(response)
        import re
        tag = data.get("tag_name", "")
        if not re.fullmatch(r"v\d+\.\d+\.\d+", tag) or data.get("prerelease") or data.get("draft"):
            raise ValueError("No stable release")
        print("Available KIT:", tag)
        print(f"Review: https://github.com/{repo}/releases/tag/{tag}")
        print("Применение вручную по manuals/DEVELOPMENT.md; автоматическая миграция отключена.")
        return 0
    except (OSError, ValueError):
        print("Не удалось получить stable release: проверьте публикацию релиза и доступ к GitHub.")
        return 1


def main():
    try:
        action = sys.argv[1]
        if action == "backup":
            return backup()
        if action == "update-check":
            return update_check()
        return report(status_only=action == "status")
    except (OSError, ValueError, KeyError, sqlite3.Error, tarfile.TarError, yaml.YAMLError, http.client.HTTPException):
        print("Не удалось выполнить команду. Проверьте установку, права и свободное место.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
