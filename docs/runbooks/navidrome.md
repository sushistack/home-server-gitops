# Runbook: navidrome

> Self-hosted music server, migrated to k3s via the stateful-cutover machine (Story 4.3).
> **Hybrid data classes:** SQLite metadata `navidrome.db` (**DB-class** — play counts, scrobble
> state, library index; dumped to R2) + a regenerable music library (**file-class** — Longhorn
> snapshot only, never dumped). Cutover procedure + rollback:
> [stateful-cutover.md](stateful-cutover.md).

## What it does

`deluan/navidrome` (port 4533) behind Traefik on `${SECRET:DOMAIN_NAVIDROME}` (music.<zone>).
Serves the library on `/music` and keeps all durable metadata in SQLite under `/data`
(`navidrome.db` + WAL). Last.fm scrobbling is on (`ND_LASTFM_ENABLED=true`); the API key/secret
come from the `navidrome-lastfm` SealedSecret via `envFrom`. The library is fed by the yt-dlp /
Last.fm discovery pipeline (ytdlp-api + an n8n workflow) — both still on Compose and out of this
cutover's scope; they write to the same music volume only when migrated.

## Health check (exact command → expected output)

```
curl -fsS https://${SECRET:DOMAIN_NAVIDROME}/rest/ping      # → <subsonic-response ... status="ok">
```

In-cluster / ArgoCD: `kubectl get pods -n navidrome` → pod `Running`/`Ready`;
`argocd app get navidrome` → `Synced` + `Healthy`;
`kubectl get deploy navidrome -n navidrome -o jsonpath='{.spec.strategy.type}'` → `Recreate`.

## If DOWN do this (in order)

1. **Pod** — `kubectl get pods -n navidrome -o wide`; if not `Running`:
   `kubectl describe pod -n navidrome -l app.kubernetes.io/name=navidrome` (watch for `Multi-Attach`
   on a PVC — see Common failures).
2. **Logs** — `kubectl logs -n navidrome deploy/navidrome --tail=100` (DB lock / scan errors).
3. **PVC mounts** — `kubectl get pvc -n navidrome` → both `navidrome-data` and `navidrome-music`
   `Bound`; `kubectl exec -n navidrome deploy/navidrome -- sh -c 'ls -l /data/navidrome.db && du -sh /music'`.
4. **Config** — `kubectl exec -n navidrome deploy/navidrome -- env | grep ^ND_`; if `ND_LASTFM_APIKEY`
   is empty the `navidrome-lastfm` SealedSecret didn't unseal (controller / wrong ns).
5. **Public route** — confirm the `${SECRET:DOMAIN_NAVIDROME}` cloudflared route points at Traefik
   (`https://<node>:443`, `originServerName=${SECRET:DOMAIN_NAVIDROME}`). k3s is the sole production
   path (Compose retired 2026-06-19) — recover via R2 restore / `git revert` + ArgoCD sync, no flip-back.
6. **Egress** — if a NetworkPolicy baseline ever lands, confirm ns `navidrome` is allowed DNS :53
   (Last.fm scrobble + cert-manager). Without it scrobbling silently fails while the pod is `Healthy`.
7. **Restart / revert** — `kubectl rollout restart deploy/navidrome -n navidrome`; the real fix for
   bad config is `git revert` (GitOps; ArgoCD selfHeal re-converges manual drift).

## Common failures

- **`Multi-Attach error` on `navidrome-data` / `navidrome-music`** — an RWO Longhorn volume is held by
  one node and the backup CronJob (or a stray pod) landed elsewhere. The CronJob uses `podAffinity`
  to co-locate onto the navidrome pod's node; if it still trips, the pod was rescheduled — confirm
  both are on the same node (`kubectl get pod -n navidrome -o wide`). (Reconciliation 1.)
- **Crash-loop on boot after an unclean stop** — SQLite WAL replay can exceed the default liveness
  window; the `startupProbe` (30×5s) guards against this. If it still loops, the DB may be corrupt —
  restore from R2 (below).
- **Two pods on the RWO volume** — only ever happens if `strategy` drifts off `Recreate`. Never set
  RollingUpdate: two pods sharing one SQLite WAL is the named anti-pattern (AC6/AR14).
- **Scrobbles not appearing on Last.fm** — `ND_LASTFM_ENABLED` true but key/secret empty/invalid
  (SealedSecret), or egress to `ws.audioscrobbler.com` blocked. Pod stays `Healthy` regardless.
- **Stale image pin / bad digest** — `ImagePullBackOff`; re-pin via PR.

## Backup/restore commands

**Hybrid (AC1):**
- **DB-class — real R2 backup.** A `navidrome-backup` CronJob (ns `navidrome`, `5 */6 * * *`) takes an
  online `sqlite3 .backup` of `/data/navidrome.db` and uploads to
  `r2:homelab-k3s-services-backup/navidrome/` (replaces the Compose offen sidecar). Credential: the
  per-namespace `navidrome-backup-r2` SealedSecret. **The music PVC is never mounted by the CronJob,
  so the library is structurally excluded from the dump.**
- **File-class — Longhorn snapshot, NOT R2.** The music library (`navidrome-music`) is protected by a
  Longhorn **recurring snapshot** (crash-consistent, no quiesce) — it is regenerable (yt-dlp/Last.fm)
  and far too large to ship to R2 every 6h. Configure once in the Longhorn UI / a `RecurringJob` CR
  selecting the `navidrome-music` volume (e.g. daily snapshot, retain 7). Restore = revert the volume
  to a snapshot from the Longhorn UI. (stateful-cutover.md "Backup scope".)

**Run a DB backup on demand:**
```
kubectl create job -n navidrome --from=cronjob/navidrome-backup navidrome-backup-manual
kubectl logs -n navidrome job/navidrome-backup-manual -f
rclone lsl r2:homelab-k3s-services-backup/navidrome/ | tail   # confirm it landed (DB only, ~MBs)
```

**Restore the DB (the durable state; music is reproducible):**
```
# 1. fetch + unpack the chosen archive
rclone copy r2:homelab-k3s-services-backup/navidrome/navidrome-<ts>.tar.gz /tmp/
tar -C /tmp -xzf /tmp/navidrome-<ts>.tar.gz          # -> /tmp/navidrome.db

# 2. suspend autosync FIRST (selfHeal:true would revert --replicas=0 mid-restore and the re-spawned
#    pod + ingest pod would both want the RWO PVC -> Multi-Attach / racing writers), then scale to 0.
argocd app set navidrome --sync-policy none
kubectl scale deploy/navidrome -n navidrome --replicas=0
kubectl apply -f workloads/navidrome/_cutover/ingest-job.yaml   # re-use the ingest pod for PVC write access
pod=$(kubectl -n navidrome get pod -l job-name=navidrome-ingest -o name | head -1)
kubectl -n navidrome cp /tmp/navidrome.db "${pod#pod/}:/data/navidrome.db"
kubectl -n navidrome delete -f workloads/navidrome/_cutover/ingest-job.yaml

# 3. bring navidrome back, re-enable autosync, verify the row count
kubectl scale deploy/navidrome -n navidrome --replicas=1
argocd app set navidrome --sync-policy automated --self-heal
kubectl exec -n navidrome deploy/navidrome -- sqlite3 /data/navidrome.db "select count(*) from media_file;"
```

## Escalation / depends-on

- **Depends on:** Longhorn (both PVCs + the music snapshot RecurringJob), Traefik + cert-manager
  (`navidrome-tls`, `letsencrypt-prod`), the `DOMAIN_NAVIDROME` render token, the `navidrome-backup-r2`
  and `navidrome-lastfm` SealedSecrets.
- **Companions (NOT migrated by this story):** `ytdlp-api` + the n8n Last.fm discovery workflow stay
  on Compose; they feed the music library and have no durable state of their own. Navidrome serves
  fine without them — only new-music discovery pauses until they migrate.
- **Compose navidrome RETIRED 2026-06-19 (Story 5.4)** — k3s is the sole production path; there is no
  Compose rollback. Recovery is k3s-native: restore from R2 (`homelab-k3s-services-backup/navidrome/`)
  into a scratch namespace, or `git revert` + ArgoCD sync. The music library lives on Longhorn (not
  R2). See [DECISIONS.md](../DECISIONS.md).
