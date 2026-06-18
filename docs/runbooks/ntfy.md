# Runbook: ntfy

> One-way push notification hub, migrated to k3s via the stateful-cutover machine (Story 4.1 —
> the FIRST stateful cutover). **DB-class** (SQLite `auth.db` durable + `cache.db` transient).
> Cutover procedure + rollback: [stateful-cutover.md](stateful-cutover.md).

## What it does

Push hub: **Kuma + n8n → ntfy → mobile apps** (background push relayed via the `ntfy.sh`
upstream, FCM/APNs). `binwiederhier/ntfy serve`, port 80, behind Traefik on
`${SECRET:DOMAIN_NTFY}`. Auth is `deny-all` by default; users/tokens/ACLs live in
`auth.db`, cached messages in `cache.db` (12h TTL). Publishers (Kuma/n8n) authenticate with a
client-side token — that is *their* config, not ntfy's (ntfy itself holds no app secret).

## Health check (exact command → expected output)

```
curl -fsS https://${SECRET:DOMAIN_NTFY}/v1/health      # → {"healthy":true}
```

In-cluster / ArgoCD: `kubectl get pods -n ntfy` → pod `Running`/`Ready`;
`argocd app get ntfy` → `Synced` + `Healthy`;
`kubectl get deploy ntfy -n ntfy -o jsonpath='{.spec.strategy.type}'` → `Recreate`.

## If DOWN do this (in order)

1. **Pod** — `kubectl get pods -n ntfy`; if not `Running`:
   `kubectl describe pod -n ntfy -l app.kubernetes.io/name=ntfy` (watch for `Multi-Attach`
   on the PVC — see Common failures).
2. **Logs** — `kubectl logs -n ntfy deploy/ntfy --tail=100`.
3. **PVC mount** — `kubectl get pvc -n ntfy ntfy-data` → `Bound`;
   `kubectl exec -n ntfy deploy/ntfy -- ls -l /var/cache/ntfy` shows `auth.db` + `cache.db`.
4. **Config** — `kubectl exec -n ntfy deploy/ntfy -- cat /etc/ntfy/server.yml`; if the host/base-url
   is wrong, the render token (`DOMAIN_NTFY`) was not substituted.
5. **Public route** — confirm the `${SECRET:DOMAIN_NTFY}` cloudflared route points at Traefik
   (`https://<node>:443`, `originServerName=${SECRET:DOMAIN_NTFY}`). To roll back: flip it to NPM
   (Compose ntfy is still parked + serving its own SQLite) — see stateful-cutover.md.
6. **Egress** — if a NetworkPolicy baseline ever lands, confirm ns `ntfy` is allowed DNS :53 +
   egress to `ntfy.sh`; without it background push silently dies while the pod stays `Healthy`.
7. **Restart / revert** — `kubectl rollout restart deploy/ntfy -n ntfy`; the real fix for bad config
   is `git revert` (GitOps; ArgoCD selfHeal re-converges manual drift).

## Common failures

- **`Multi-Attach error` on `ntfy-data`** — the RWO Longhorn volume is held by one node and the
  backup CronJob (or a stray pod) landed elsewhere. The CronJob uses `podAffinity` to co-locate
  onto the ntfy pod's node; if it still trips, the pod was rescheduled — confirm both are on the
  same node (`kubectl get pod -n ntfy -o wide`). (Reconciliation 1 / stateful-cutover.md.)
- **Upstream `ntfy.sh` egress blocked** — mobile apps get no notification while backgrounded,
  though direct/foreground delivery works and the pod is `Healthy`. Allow egress to `ntfy.sh`.
- **`auth-default-access: deny-all` lockout** — a publish/subscribe with no/invalid token gets 403.
  This is by design; fix the publisher's token (`auth.db` ACL), not the server.
- **Stale image pin / bad digest** — `ImagePullBackOff`; re-pin via PR.

## Backup/restore commands

**DB-class — real backup, NOT N/A.** A `ntfy-backup` CronJob (ns `ntfy`, ≤6h) takes an online
`sqlite3 .backup` of both DBs and uploads to `r2:homelab-k3s-backup/ntfy/` (replaces the Compose
offen sidecar). Credential: the per-namespace `ntfy-backup-r2` SealedSecret.

**Run a backup on demand:**
```
kubectl create job -n ntfy --from=cronjob/ntfy-backup ntfy-backup-manual
kubectl logs -n ntfy job/ntfy-backup-manual -f
# verify it landed:
rclone lsl r2:homelab-k3s-backup/ntfy/ | tail
```

**Restore (auth.db is the durable state; cache.db is disposable):**
```
# 1. fetch the chosen archive from R2 and unpack
rclone copy r2:homelab-k3s-backup/ntfy/ntfy-<ts>.tar.gz /tmp/
tar -C /tmp -xzf /tmp/ntfy-<ts>.tar.gz          # -> /tmp/auth.db, /tmp/cache.db

# 2. quiesce the pod so nothing holds the SQLite WAL, then copy into the PVC
kubectl scale deploy/ntfy -n ntfy --replicas=0
#    (re-use the cutover ingest pod to get write access to the RWO PVC)
kubectl apply -f workloads/ntfy/_cutover/ingest-job.yaml
pod=$(kubectl -n ntfy get pod -l job-name=ntfy-ingest -o name | head -1)
kubectl -n ntfy cp /tmp/auth.db "${pod#pod/}:/data/auth.db"
kubectl -n ntfy delete -f workloads/ntfy/_cutover/ingest-job.yaml

# 3. bring ntfy back and verify the user/token count
kubectl scale deploy/ntfy -n ntfy --replicas=1
kubectl exec -n ntfy deploy/ntfy -- sqlite3 /var/cache/ntfy/auth.db "select count(*) from user;"
```

## Escalation / depends-on

- **⚠️ ntfy is the alert channel for Story 4.2.** Until 4.2 lands there is **no alert on ntfy's
  own failure** (chicken-and-egg) — watch ntfy manually, especially during/just after cutover.
- **Publishers:** Kuma (uptime alerts) + n8n (workflow notifications). Both stay on Compose until
  their own Epic 4 cutovers; they reach ntfy via the public host, so the cloudflared flip is
  transparent to them.
- **Depends on:** Longhorn (PVC), Traefik + cert-manager (`ntfy-tls`, `letsencrypt-prod`),
  the `DOMAIN_NTFY` render token, the `ntfy-backup-r2` SealedSecret.
- **Compose ntfy is PARKED, not decommissioned** (the rollback) until the operator retires it
  deliberately. See [stateful-cutover.md](stateful-cutover.md).
