# Changelog

## v1.0.0 — подготовлена локально, требуется приёмка на тестовом VPS

- Runtime source: McElast/3x-easy-one; tag/SHA archive keeps installer, CLI and subscription in one snapshot. Original KIT attribution preserved.
- Default profile: REALITY, XHTTP REALITY, Hysteria2, AmneziaWG classic and 3.1; existing other protocol implementations retained for explicit selection.
- Per-device users and QR retained; subscription token and shared secret prefix have 128-bit randomness; reserved twin names and literal matching prevent cross-device revoke.
- Failed client/AWG enumeration now aborts user operations instead of reporting success. Matrix runner returns failure for failed/empty runs and stops only its own client process. Shell/config version files retain LF on Windows; SSH tunnel output includes the detected SSH port.
- Mihomo VPN/AUTO/FALLBACK, ordered priority, 60-second checks, full internet with LAN exceptions, DNS and explicit TUN activation. AWG31 only for known compatible core or deliberate opt-in.
- Administrative panel stays on localhost with SSH tunnel; nginx no longer publishes it. Public subscription remains HTTPS.
- Fixed acme.sh 3.1.6 and checksum, IP certificate renewal via systemd; 3X-UI v3.8.5, Xray v26.6.27 and standalone Hysteria 2.12.3 retained.
- kit status, doctor, consistent SQLite backup, version and stable release metadata checks; no automatic DB migration/restore or SSH hardening.
- Removed KIT branding cron that rewrote external x-ui menu. Retained functional certificate reload/renewal.
- Optional router dashboard pinned to zashboard v3.29.1 instead of mutable latest.
- Protected secret files, no secret subscription paths or arbitrary User-Agent in KIT logs, no server IP lookup endpoints.
- Russian README, free client walkthroughs, SECURITY, recovery/development/troubleshooting documentation and GitHub publication steps.
- No new test infrastructure. Local checks are separate from real-client/VPS acceptance.
