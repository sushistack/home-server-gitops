# Runbook: vaultwarden

> Self-hosted password vault (Bitwarden-compatible), migrated to k3s via the stateful-cutover
> machine (Story 4.8 — **CRITICAL, the LAST service**). **Single-writer SQLite** (`db.sqlite3` + WAL)
> on one Longhorn RWO PVC; everything under `/data` is durable. Cutover procedure + rollback:
> [stateful-cutover.md](stateful-cutover.md).

## What it does

`vaultwarden/server` (port 80) behind Traefik on `${SECRET:DOMAIN_VAULTWARDEN}` (vault.<zone>).
All durable state lives under `/data` on the `vaultwarden-data` PVC: `db.sqlite3` (+ WAL — users,
ciphers, org keys), **`rsa_key.pem`/`rsa_key.pub`** (JWT signing keys — losing them forces every
client/device to re-auth), `attachments/` + `sends/` (durable user files), `config.json`
(admin-panel settings); `icon_cache/` is regenerable. `WEBSOCKET_ENABLED=true` serves push
notifications on `/notifications/hub` over the **same port 80**. `ADMIN_TOKEN` (admin panel) comes
from the `vaultwarden-secrets` SealedSecret via `envFrom`; everything else from the
`vaultwarden-config` ConfigMap. `SIGNUPS_ALLOWED=false` (closed instance).

## Health check (exact command → expected output)

```
curl -fsS https://${SECRET:DOMAIN_VAULTWARDEN}/alive      # → an ISO-8601 UTC timestamp, HTTP 200
```

In-cluster / ArgoCD: `kubectl get pods -n vaultwarden` → pod `Running`/`Ready`;
`argocd app get vaultwarden` → `Synced` + `Healthy`;
`kubectl get deploy vaultwarden -n vaultwarden -o jsonpath='{.spec.strategy.type}'` → `Recreate`.

> NOTE: Compose ran with `healthcheck: disable: true` (docker-compose.yml:83-84). The k3s workload
> adds `/alive` readiness+liveness+startup probes anyway (AR31) — a genuine improvement at cutover.

## If DOWN do this (in order)

1. **Pod** — `kubectl get pods -n vaultwarden -o wide`; if not `Running`:
   `kubectl describe pod -n vaultwarden -l app.kubernetes.io/name=vaultwarden` (watch for
   `Multi-Attach` on the PVC — see Common failures).
2. **PVC attach** — `kubectl get pvc -n vaultwarden` → `vaultwarden-data` `Bound`;
   `kubectl exec -n vaultwarden deploy/vaultwarden -- sh -c 'ls -l /data/db.sqlite3 /data/rsa_key.*'`.
3. **Logs** — `kubectl logs -n vaultwarden deploy/vaultwarden --tail=100` (DB lock / WAL / cert errors).
4. **SealedSecret materialized** — `kubectl get secret vaultwarden-secrets -n vaultwarden`; if absent,
   the SealedSecret didn't unseal (controller down / sealed to wrong cluster-or-ns) → the pod has no
   `ADMIN_TOKEN` and won't start. Re-seal per AC2 (origin = Compose `.env` during overlap).
5. **Public route** — confirm the `${SECRET:DOMAIN_VAULTWARDEN}` cloudflared route points at Traefik
   (`https://<node>:443`, `originServerName=${SECRET:DOMAIN_VAULTWARDEN}`). **To roll back: flip it to
   NPM** (Compose vaultwarden is PARKED + still serving its own SQLite) — see stateful-cutover.md.
6. **Restart / revert** — `kubectl rollout restart deploy/vaultwarden -n vaultwarden`; the real fix
   for bad config is `git revert` (GitOps; ArgoCD selfHeal re-converges manual drift).

## Common failures

- **`Multi-Attach error` on `vaultwarden-data`** — the RWO Longhorn volume is held by one node and
  the backup CronJob (or a stray pod) landed elsewhere. The CronJob uses `podAffinity` to co-locate
  onto the vaultwarden pod's node; if it still trips, confirm both are on the same node
  (`kubectl get pod -n vaultwarden -o wide`). (Story 4.1 Reconciliation 1.)
- **Two pods on the RWO WAL** — only ever happens if `strategy` drifts off `Recreate`. NEVER set
  RollingUpdate: two pods sharing one SQLite WAL **corrupts the vault** — the named anti-pattern
  (AR14). `terminationGracePeriodSeconds: 30` must stay (WAL checkpoint flush). Highest-stakes data.
- **Crash-loop on boot after an unclean stop** — SQLite WAL replay can exceed the default liveness
  window; the `startupProbe` (30×5s) guards against this. If it still loops, the DB may be corrupt →
  restore from R2 (below).
- **Every client suddenly logged out / re-auth prompt** — `rsa_key.pem/.pub` was lost or not carried
  in the ingest. The JWT signing key is load-bearing; restore the keys from the R2 bundle.
- **Cold-boot backup-before-init race** — if the backup CronJob fires before the pod has opened the
  DB on a fresh boot it can dump an empty/partial `/data` (deferred-work.md:59). Steady-state probes
  + `Recreate` make this rare; verify the first post-boot backup landed with a sane row count.
- **Stale image pin / bad digest** — `ImagePullBackOff`; re-pin via PR.

## Backup/restore commands

**Backup actor (AC3b / NFR5):** a `vaultwarden-backup` CronJob (ns `vaultwarden`, `50 */6 * * *`)
takes an online `sqlite3 .backup` of `/data/db.sqlite3` **plus** the durable companions
(`rsa_key.*`, `config.json`, `attachments/`, `sends/`; `icon_cache/` excluded), tars them, and
uploads to `r2:homelab-k3s-services-backup/vaultwarden/`. Credential: the per-namespace
`vaultwarden-backup-r2` SealedSecret. Online + lock-safe → **no scale-down, no quiesce** (this also
closes the Compose torn-snapshot gap, deferred-work.md:58-59).

**Run a backup on demand:**
```
kubectl create job -n vaultwarden --from=cronjob/vaultwarden-backup vaultwarden-backup-manual
kubectl logs -n vaultwarden job/vaultwarden-backup-manual -f
rclone lsl r2:homelab-k3s-services-backup/vaultwarden/ | tail   # confirm it landed
```

**Verified restore (NFR6) — into a scratch namespace (Task 4 evidence):**
```
# 1. fetch + unpack the chosen archive
rclone copy r2:homelab-k3s-services-backup/vaultwarden/vaultwarden-<ts>.tar.gz /tmp/
mkdir -p /tmp/vw && tar -C /tmp/vw -xzf /tmp/vaultwarden-<ts>.tar.gz   # -> db.sqlite3, rsa_key.*, ...

# 2. integrity check — must be ≥1 user and match the source count
sqlite3 /tmp/vw/db.sqlite3 "select count(*) from users; select count(*) from ciphers;"

# 3. spin a scratch vaultwarden against the restored /data and confirm a real login + read of a
#    known entry (the load-bearing proof). Tear the scratch ns down afterwards.
```

**Restore into the live PVC** (DB + keys are the durable state): suspend autosync FIRST
(`argocd app set vaultwarden --sync-policy none` — selfHeal would revert `--replicas=0` mid-restore
and race the RWO PVC), scale to 0, re-use `workloads/vaultwarden/_cutover/ingest-job.yaml` for PVC
write access, `kubectl cp` the restored tree into `/data`, then scale back to 1 and re-enable
autosync. (Same shape as the navidrome restore.)

## Escalation / depends-on

- **Depends on:** Longhorn (the `vaultwarden-data` PVC), Traefik + cert-manager (`vaultwarden-tls`,
  `letsencrypt-prod`), the `DOMAIN_VAULTWARDEN` render token, the `vaultwarden-secrets` and
  `vaultwarden-backup-r2` SealedSecrets.
- **Bitwarden-Cloud emergency fallback (availability, NOT a backup substitute):** a one-way weekly
  mirror to Bitwarden Cloud exists (`spec-vaultwarden-bitwarden-cloud-sync.md`, GH Actions Sunday
  01:00 UTC). If `vault.<zone>` is down, a client can switch its server URL to `vault.bitwarden.com`
  (separate master password) for read access. It is **≤7 days stale** — the R2 dumps (≤6h) are the
  authoritative backup. The sync runs against the live source; **leave it targeting whichever side
  is authoritative during the Compose/k3s overlap** (default: as-is until Compose is retired in 5.4).
- **Compose vaultwarden is PARKED, not decommissioned** (the rollback) until the operator retires it
  deliberately in Epic 5 / Story 5.4 (`docker compose stop vaultwarden vaultwarden-backup`, never
  `down`). See [stateful-cutover.md](stateful-cutover.md).
