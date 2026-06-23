# Runbook: lidarr (music auto-collection — Lidarr + slskd + soularr)

> One workload, three components on k3s-cp-1, sharing the node-local music library
> `/mnt/manga/music` (the manga disk). Lidarr = library manager, slskd = Soulseek (FLAC) download
> source, soularr = the bridge (Lidarr wanted → slskd download → Lidarr import).

## What it does

Lidarr monitors artists and tracks missing/wanted albums. **soularr** reads Lidarr's wanted list,
searches **slskd** (a headless Soulseek daemon), downloads lossless releases into
`/mnt/manga/music/.incoming`, then triggers Lidarr to import them (hardlink, same filesystem) into the
library at `/mnt/manga/music`. **Navidrome** serves that same directory, so new music appears with no
copy. UIs (Lidarr 8686, slskd 5030) are INTERNAL — behind CF Access (Google SSO). soularr has no UI.

## Health check (exact command → expected output)

```
kubectl -n lidarr get pods           # expected: lidarr, slskd, soularr all 1/1 Running
kubectl -n lidarr exec deploy/lidarr -- wget -qO- localhost:8686/ping   # expected: {"status":"OK"}
kubectl -n lidarr exec deploy/slskd  -- wget -qO- localhost:5030/ >/dev/null && echo OK  # web up (probes use / too)
kubectl -n lidarr logs deploy/soularr --tail=20   # expected: a recent cycle log, no auth/connect errors
```

slskd Soulseek login: open the slskd UI → it shows "Connected" once the credentials are valid.

## If DOWN do this (in order)

1. **Pods Pending / unschedulable** → the node-local PV pins everything to `k3s-cp-1`. Confirm the node
   is Ready and the disk is mounted: `ssh root@10.0.0.2` → on k3s-cp-1 `mountpoint /mnt/manga && df -h /mnt/manga`.
2. **slskd/soularr pod stuck `ContainerCreating` ("secret not found")** → the `slskd-soulseek` /
   `soularr-config` SealedSecret is still a PLACEHOLDER (never decrypts → the target Secret is never
   created → envFrom/volume can't resolve). This is the expected pre-reseal state, NOT a login failure.
   Reseal both with real values (see Backup/restore → kubeseal) BEFORE the first sync, then the pods start.
3. **slskd connected but login fails / soularr "401/connection refused"** → wrong creds, or stale Lidarr
   API key. The Lidarr API key only exists after Lidarr's first boot — do the **2-stage reseal** (below),
   then `kubectl -n lidarr rollout restart deploy/soularr` (subPath mounts do NOT live-update on reseal).
   Verify `download_dir=/mnt/manga/music/.incoming` and `host_url`s point at the in-cluster Services
   (`http://lidarr:8686`, `http://slskd:5030`).
4. **Imports not landing in the library** → check `/mnt/manga/music/.incoming` ownership is uid 1000
   (`ssh root@10.0.0.2` → `ls -ln /mnt/manga/music/.incoming`) and that Lidarr's root folder is
   `/mnt/manga/music`. Same-fs hardlink import needs both under the one mounted volume.

## Common failures

- **PLACEHOLDER secrets committed** — slskd/soularr won't function until both SealedSecrets are resealed
  with real values. This is expected on first deploy.
- **Disk full** — `/mnt/manga` is SHARED with the manga library (SPOF + capacity). Grow online:
  `ssh root@10.0.0.2` → `qm resize 101 scsi2 +50G` then on k3s-cp-1 `growpart /dev/sdX N && resize2fs /dev/sdXN`.
- **Navidrome empty after migration** — the repoint synced before the copy finished. See migration order.
- **Leeching** — `shares` is empty (download-only); some Soulseek peers throttle non-sharers. Add a
  shared dir in `configmap.yaml` if download speeds suffer.

## Backup/restore commands

**Disk prep (once, before first deploy)** — `ssh root@10.0.0.2`, then on k3s-cp-1:
```
mkdir -p /mnt/manga/music/.incoming /mnt/manga/music/.incomplete
chown -R 1000:1000 /mnt/manga/music      # match lidarr/slskd uid 1000
```

**Reseal slskd creds** (before first sync):
```
kubectl create secret generic slskd-soulseek -n lidarr \
  --from-literal=SLSKD_SLSK_USERNAME='<soulseek-user>' \
  --from-literal=SLSKD_SLSK_PASSWORD='<soulseek-pass>' \
  --dry-run=client -o yaml | kubeseal --format yaml > workloads/lidarr/sealedsecret-slskd.yaml
```

**Reseal soularr config (2-stage)**:
1. Deploy with slskd resealed; let Lidarr boot once. Grab the API key: Lidarr UI → Settings → General →
   API Key (or `kubectl -n lidarr exec deploy/lidarr -- grep -i apikey /config/config.xml`).
2. Author `config.ini` ([Lidarr] host_url=http://lidarr:8686 + api_key; [Slskd] host_url=http://slskd:5030,
   api_key= blank, download_dir=/mnt/manga/music/.incoming), then:
```
kubectl create secret generic soularr-config -n lidarr \
  --from-file=config.ini=./config.ini \
  --dry-run=client -o yaml | kubeseal --format yaml > workloads/lidarr/sealedsecret-soularr.yaml
```
After ANY reseal+sync, restart the consumers — config.ini/slskd.yml are subPath mounts and do NOT
live-update: `kubectl -n lidarr rollout restart deploy/soularr deploy/slskd`.

**Lidarr DB backup** — `backup-cronjob.yaml` (sqlite3 `.backup` of `lidarr.db` → R2). NOT in
`kustomization.yaml` until you seal `lidarr-backup-r2` and add both lines (komga precedent). Music files
are re-acquirable → Longhorn/local snapshot only, never R2.

## Navidrome music migration (cutover order — do NOT sync the repoint first)

The Navidrome deployment is repointed from the Longhorn `navidrome-music` PVC to the shared local PV
`navidrome-music-local` (`/mnt/manga/music`). Old Longhorn PVC is kept (Retain) for rollback.

🔴 **HARD GATE — do NOT merge the `workloads/navidrome` repoint to the synced branch until the copy
below is done and verified.** ArgoCD auto-syncs on merge; if the repoint lands first, Navidrome
reschedules onto an empty `/mnt/manga/music` and serves an empty library (+ a full rescan churn).
There is no sync-wave protecting this — the merge order IS the gate. (`.incoming`/`.incomplete` are
dot-prefixed so Navidrome's scanner skips them and never indexes slskd's partial downloads.)

1. Copy current music to the disk (Navidrome still on Longhorn): park a pod holding the OLD
   `navidrome-music` PVC (the `_cutover/ingest-job.yaml` pattern) and `kubectl cp` / `tar` its `/music`
   into `/mnt/manga/music` on k3s-cp-1, or rsync host-side. Then `chown -R 1000:1000 /mnt/manga/music`.
2. Verify counts match (`du -sh`, file count) between the old PVC and `/mnt/manga/music`.
3. Merge/sync the `workloads/navidrome` repoint (pvc-music-local + deployment claimName change).
   Navidrome reschedules onto k3s-cp-1 and scans the populated dir.
4. Rollback = revert the deployment claimName to `navidrome-music` (the Longhorn PVC is retained).
5. After the rollback window closes and the new library is confirmed good, reclaim the orphaned Longhorn
   space: delete the retained `navidrome-music` PVC (it is no longer mounted) — `kubectl -n navidrome
   delete pvc navidrome-music` (it holds Longhorn replicas indefinitely otherwise).

## Escalation / depends-on

- **Storage:** node-local PV → k3s-cp-1 `/mnt/manga` disk (shared with komga manga library; SPOF).
- **Exposure:** Traefik IngressRoute + cert-manager (letsencrypt-prod, DNS-01) + CF Access (Google SSO)
  + the shared cloudflared tunnel (`761ca633…cfargotunnel.com`). Hosts: `${SECRET:DOMAIN_LIDARR}`,
  `${SECRET:DOMAIN_SLSKD}` (register in `internal/tokens.example.env`).
- **Secrets:** sealed-secrets controller (kubeseal). **Downstream:** Navidrome (serves the library).
- **External:** a valid Soulseek account (slskd login). No inbound port-forward (server relay).
