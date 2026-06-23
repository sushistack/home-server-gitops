# Runbook: homepage

Replaced Heimdall as the homelab dashboard (2026-06-23). Stateless: all tiles/widgets
are declared in `config/*.yaml` → ConfigMap. No PVC, no backup.

## What it does
gethomepage/homepage dashboard at `${SECRET:DOMAIN_HOMEPAGE}` (homepage.eli.kr), INTERNAL
behind CF Access: external-dns publishes a public CNAME → CF tunnel so Access can gate it;
LAN wildcard (*.eli.kr → 10.0.0.101 Traefik) resolves locally. Tiles link to every homelab
service; top bar shows system resources, clock, weather, and a Proxmox node/VM widget.

## Health check (exact command → expected output)
`kubectl -n homepage get deploy homepage` → `READY 1/1`
`kubectl -n homepage logs deploy/homepage | grep -i ready` → Next.js "ready" line.
Browser (on LAN): `https://homepage.eli.kr/` renders the tile grid.

## If DOWN do this (in order)
1. `kubectl -n homepage describe pod -l app.kubernetes.io/name=homepage` — image pull / probe?
2. Logs show "Host validation failed" → `HOMEPAGE_ALLOWED_HOSTS` ≠ request Host; fix env.
3. 502 via Traefik → check Service endpoints and that the cert `homepage-tls` is Ready.
4. Config typo → `kubectl -n homepage rollout restart deploy/homepage` after fixing `config/*.yaml`.

## Common failures
- EROFS log lines for docker.yaml/kubernetes.yaml/logs — harmless (read-only ConfigMap mount).
- Proxmox widget blank/401 → `homepage-secrets` Secret missing or token wrong (see below).
- Icon not loading → wrong dashboard-icons slug in `config/services.yaml`; cosmetic only.

## Backup/restore commands
None needed — config is in git. Restore = re-sync the Argo CD Application.
Proxmox token lives in the `homepage-secrets` SealedSecret (re-seal to rotate).

## Escalation / depends-on
Depends on: Traefik, cert-manager (`letsencrypt-prod`), external-dns, the CF tunnel
`761ca633-…cfargotunnel.com`, and CF Access policy. Proxmox widget depends on the
Proxmox API at `${SECRET:IP_PROXMOX}:8006` and the `homepage-secrets` token.
