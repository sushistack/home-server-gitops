# Runbook: n8n

> Workflow-automation engine, migrated to k3s via the stateful-cutover machine (Story 4.7).
> **CRITICAL** — single-writer SQLite (`database.sqlite`, DB-class, dumped to R2) plus an
> **irreplaceable encryption key** that decrypts every saved credential. Cut over under a
> **write-freeze + parallel Compose run** (RPO=0). Cutover procedure + rollback:
> [stateful-cutover.md](stateful-cutover.md).

## What it does

`n8nio/n8n:2.23.4` (port 5678) behind Traefik on `${SECRET:DOMAIN_N8N}` (n8n.<zone>). All durable
state lives in one RWO Longhorn PVC mounted at `/home/node/.n8n`: `database.sqlite` (workflows,
`credentials_entity`, executions, settings) + `config` (the encryption key) + `nodes/`/`storage/`.
Non-secret config (`N8N_HOST`, `WEBHOOK_URL`, `N8N_BASE_URL`, TZ) comes from the `n8n-config`
ConfigMap; the one secret — `N8N_ENCRYPTION_KEY` — comes from the `n8n-secrets` SealedSecret via
`envFrom`.

> 🔑 **The encryption key is the disaster gate.** n8n encrypts every row of `credentials_entity`
> with `N8N_ENCRYPTION_KEY`. In the original Compose deployment that key was **never set in `.env`** —
> n8n auto-generated it on first boot into the `data/n8n/config` file (`{"encryptionKey": "…"}`).
> The cutover seals that exact value as `N8N_ENCRYPTION_KEY` in `n8n-secrets`. **If the pod ever runs
> with a different key, every credential decrypts to unrecoverable garbage.** A credential that
> *opens and decrypts* in the UI is the proof the key migrated.

## Health check (exact command → expected output)

```
curl -fsS https://${SECRET:DOMAIN_N8N}/healthz      # → {"status":"ok"}
```

In-cluster / ArgoCD: `kubectl get pods -n n8n` → pod `Running`/`Ready`;
`argocd app get n8n` → `Synced` + `Healthy`;
`kubectl get deploy n8n -n n8n -o jsonpath='{.spec.strategy.type}'` → `Recreate`.

## If DOWN do this (in order)

1. **Pod** — `kubectl get pods -n n8n -o wide`; if not `Running`:
   `kubectl describe pod -n n8n -l app.kubernetes.io/name=n8n` (watch for `Multi-Attach` on the PVC —
   see Common failures).
2. **Logs** — `kubectl logs -n n8n deploy/n8n --tail=100` (DB lock, migration, or — the bad one —
   `Mismatching encryption keys` / credential-decrypt errors → STOP, do NOT let it rewrite data, see
   Common failures).
3. **PVC** — `kubectl get pvc -n n8n` → `n8n-data` `Bound`;
   `kubectl exec -n n8n deploy/n8n -- sh -c 'ls -l /home/node/.n8n/database.sqlite'`.
4. **Encryption key present** — `kubectl exec -n n8n deploy/n8n -- sh -c 'echo ${N8N_ENCRYPTION_KEY:+set}'`
   → `set`. If empty, the `n8n-secrets` SealedSecret didn't unseal (controller down / wrong ns) — fix
   that BEFORE the pod boots and auto-generates a fresh key into `config`.
5. **Public route** — confirm the `${SECRET:DOMAIN_N8N}` cloudflared route points at Traefik
   (`https://<node>:443`, `originServerName=${SECRET:DOMAIN_N8N}`). k3s is the sole production path
   (Compose retired 2026-06-19); recover via R2 restore / `git revert` + ArgoCD sync, not a flip-back.
6. **Webhooks dead but pod Healthy** — `WEBHOOK_URL`/`N8N_BASE_URL` wrong in `n8n-config`: every
   webhook node builds its callback from these; a wrong host silently breaks inbound triggers.
7. **Restart / revert** — `kubectl rollout restart deploy/n8n -n n8n`; the real fix for bad config is
   `git revert` (GitOps; ArgoCD selfHeal re-converges manual drift).

## Common failures

- **`Mismatching encryption keys` / credentials show as broken** — the pod is running with a
  different `N8N_ENCRYPTION_KEY` than the data was encrypted with. Re-seal the key from its true
  origin — the Compose `data/n8n/config` file, **NOT `.env`** (see header of
  `workloads/n8n/sealedsecret.yaml` for the exact command) — and re-deploy. Do not re-save
  credentials in the UI until the right key is in place (that would re-encrypt under the wrong key).
- **`Multi-Attach error` on `n8n-data`** — the RWO Longhorn volume is held by one node and the backup
  CronJob (or a stray pod) landed elsewhere. The CronJob uses `podAffinity` to co-locate onto the n8n
  pod's node; if it still trips, the app pod was rescheduled — confirm both are on the same node
  (`kubectl get pod -n n8n -o wide`). (Reconciliation 3.)
- **Crash-loop on boot after an unclean stop** — SQLite WAL replay can exceed the default liveness
  window; the `startupProbe` (30×5s) guards against it. If it still loops, the DB may be corrupt —
  restore from R2 (below).
- **Two pods on the RWO volume** — only ever happens if `strategy` drifts off `Recreate`. Never set
  RollingUpdate: two pods sharing one SQLite WAL is the named anti-pattern (AC5/AR14).
- **A workflow node that shelled out to Docker** — the Compose container mounted `/var/run/docker.sock`;
  k3s has no docker socket (mounting one is a privilege escalation — deliberately dropped,
  Reconciliation 4). A workflow using an "Execute Command"/Docker node breaks and needs a
  k8s-native rewrite; credential/HTTP/cron workflows are unaffected.

## Backup/restore commands

**Steady-state backup (AC4):** an `n8n-backup` CronJob (ns `n8n`, `30 */6 * * *`) takes an online
`sqlite3 .backup` of `/home/node/.n8n/database.sqlite` (mounted at `/data`) and uploads to
`r2:homelab-k3s-services-backup/n8n/` (replaces the Compose offen sidecar — same cadence, 30-day
retention, `n8n-` prefix). Credential: the per-namespace `n8n-backup-r2` SealedSecret. Online +
lock-safe → **no scale-down** (steady-state RPO is ≤6h, not 0 — distinct from the cutover
write-freeze; see [stateful-cutover.md](stateful-cutover.md) + ADR-0010).

> The recurring backup dumps `database.sqlite` only. The **encryption key** is independently sealed
> in `n8n-secrets` (and also lives in `config` on the PVC) — so a DB-only restore is recoverable as
> long as `n8n-secrets` is intact. Keep both.

**Run a backup on demand:**
```
kubectl create job -n n8n --from=cronjob/n8n-backup n8n-backup-manual
kubectl logs -n n8n job/n8n-backup-manual -f
rclone lsl r2:homelab-k3s-services-backup/n8n/ | tail   # confirm it landed (~MBs)
```

**Restore the DB (verified at least once before close — Task 5):**
```
# 1. fetch + unpack the chosen archive
rclone copy r2:homelab-k3s-services-backup/n8n/n8n-<ts>.tar.gz /tmp/
tar -C /tmp -xzf /tmp/n8n-<ts>.tar.gz                # -> /tmp/database.sqlite

# 2. suspend autosync FIRST (selfHeal:true would revert --replicas=0 mid-restore and the re-spawned
#    pod + ingest pod would both want the RWO PVC -> Multi-Attach / racing writers), then scale to 0.
argocd app set n8n --sync-policy none
kubectl scale deploy/n8n -n n8n --replicas=0
kubectl apply -f workloads/n8n/_cutover/ingest-job.yaml   # re-use the ingest pod for PVC write access
pod=$(kubectl -n n8n get pod -l job-name=n8n-ingest -o name | head -1)
kubectl -n n8n cp /tmp/database.sqlite "${pod#pod/}:/home/node/.n8n/database.sqlite"
# drop any stale WAL/SHM left by the prior pod — otherwise SQLite replays those frames over the
# freshly restored main DB on first open (divergence/corruption). The .backup archive is self-contained.
kubectl -n n8n exec "${pod#pod/}" -- rm -f /home/node/.n8n/database.sqlite-wal /home/node/.n8n/database.sqlite-shm
kubectl -n n8n exec "${pod#pod/}" -- chown 1000:1000 /home/node/.n8n/database.sqlite
kubectl -n n8n delete -f workloads/n8n/_cutover/ingest-job.yaml

# 3. bring n8n back, re-enable autosync, verify it decrypts (the real test, not just row counts)
kubectl scale deploy/n8n -n n8n --replicas=1
argocd app set n8n --sync-policy automated --self-heal
kubectl exec -n n8n deploy/n8n -- sqlite3 /home/node/.n8n/database.sqlite \
  "select count(*) from credentials_entity; select count(*) from workflow_entity;"
# then in the UI: open a credential -> it must decrypt (proves N8N_ENCRYPTION_KEY matches the data)
```

## Escalation / depends-on

- **Depends on:** Longhorn (`n8n-data` PVC), Traefik + cert-manager (`n8n-tls`, `letsencrypt-prod`),
  the `DOMAIN_N8N` render token, the `n8n-secrets` (encryption key) and `n8n-backup-r2` SealedSecrets,
  and the SealedSecrets controller (ns `sealed-secrets`).
- **Secret source (AR24, collapsed 2026-06-19):** `n8n-secrets` is now the **sole source of truth**
  for the encryption key — the Compose origin (`data/n8n/config`) was retired with the stack (Story
  5.4), so the dual-run "verified copy" window is closed. To rotate, re-seal from the in-cluster live
  value — command in the header of `workloads/n8n/sealedsecret.yaml`.
- **Compose n8n RETIRED 2026-06-19 (Story 5.4)** — k3s is the sole production path; there is no
  Compose rollback. Recovery is k3s-native: restore from R2 (`homelab-k3s-services-backup/n8n/`) into
  a scratch ns, or `git revert` + ArgoCD sync. See [DECISIONS.md](../DECISIONS.md). n8n still runs the
  household automation workflows — now solely on k3s.
