# Runbook: anytype

> Anytype sync backend, migrated to k3s (Story 4.4). **One logical service, two components:**
> `anytype` (any-sync-bundle: coordinator+sync+filenode+consensus, raw **TCP 33010 + QUIC/UDP
> 33020**) and `anytype-heart` (gRPC middleware + JSON REST **:31009**, internal-only). **File-class**
> store (BadgerDB/leveldb — NOT SQLite). Cutover machine + rollback: [stateful-cutover.md](stateful-cutover.md).

## What it does

Self-hosted Anytype sync. `any-sync-bundle` is the combined any-sync server (coordinator + sync +
filenode + consensus) speaking **raw TCP 33010** and **QUIC/UDP 33020** — *not* HTTP, so it is served
by Traefik **IngressRouteTCP/UDP** on dedicated entryPoints (`anytype-tcp` / `anytype-udp`), never an
HTTP ingress. `anytype-heart` is the gRPC middleware + JSON REST API on **:31009**, **internal-only**
(loopback in Compose → ClusterIP, no IngressRoute); cross-namespace consumers reach it at
`anytype-heart.anytype.svc.cluster.local:31009`.

**🔴 The node identity IS the data.** any-sync has a stable `peerId`/`networkId` (+ signing keys) that
lives in `/data/anytype` (BadgerDB + key files) and that **every client hardcodes**
(`anytype-client-config.yml`: `networkId: N4fe…`, node `peerId: 12D3KooW…`, addresses
`anytype.eli.kr:33010` + `quic://anytype.eli.kr:33020` + LAN `10.0.0.20`). Migration is a **data
copy, never a fresh init** — a new init mints a new peerId and *silently* orphans every client.

## Health check (exact command → expected output)

```
nc -z anytype.eli.kr 33010 && echo "tcp ok"                              # public raw-TCP edge listens
nc -zu anytype.eli.kr 33020 && echo "udp ok"                             # public QUIC/UDP edge (UDP probe is best-effort)
kubectl exec -n anytype deploy/anytype-heart -- nc -z anytype-heart.anytype.svc.cluster.local 31009 && echo "heart ok"
```

In-cluster / ArgoCD: `kubectl get pods -n anytype` → both pods `Running`/`Ready`;
`argocd app get anytype` → `Synced` + `Healthy`;
`kubectl get deploy -n anytype -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.strategy.type}{"\n"}{end}'`
→ both `Recreate`.

**Identity sanity (after any restart/restore):** the k3s any-sync logs / config must report the
SAME `peerId`/`networkId` the clients expect:
```
grep -E 'networkId|peerId' configs/docker/anytype-client-config.yml   # the expected identity
kubectl logs -n anytype deploy/anytype --tail=200 | grep -iE 'peerId|networkId'
```

## If DOWN do this (in order)

1. **Pods** — `kubectl get pods -n anytype -o wide`; if not `Running`,
   `kubectl describe pod -n anytype -l app.kubernetes.io/name=anytype` (watch for `Multi-Attach` on
   the RWO PVC — see Common failures; common right after a backup scaled the deploy down/up).
2. **Logs** — `kubectl logs -n anytype deploy/anytype --tail=100` and `… deploy/anytype-heart …`.
   A BadgerDB lock error means a previous pod didn't release `/data` — see Common failures.
3. **entryPoints + IngressRoutes** — confirm Traefik actually has the TCP/UDP entryPoints (they come
   from the k3s-owned HelmChartConfig, NOT ArgoCD):
   `kubectl -n kube-system get helmchartconfig traefik -o yaml | grep -A2 anytype`;
   `kubectl -n kube-system get svc traefik -o yaml | grep -E '33010|33020'` (ports published at the edge);
   `kubectl -n anytype get ingressroutetcp,ingressrouteudp`.
4. **Public edge forward** — confirm the **33010/TCP + 33020/UDP stream forward** (NPM Stream /
   port-forward — NOT the cloudflared HTTP tunnel) points at the Traefik entryPoints. To roll back:
   flip that forward back to the Compose host (Compose anytype is parked + serving) — see
   stateful-cutover.md.
5. **BadgerDB lock** — if a pod crash-loops on a lock, ensure only one pod holds `/data`
   (`strategy: Recreate` guarantees this; a stuck Terminating pod can still hold it —
   `kubectl delete pod -n anytype <pod> --grace-period=30`).
6. **Restart / revert** — `kubectl rollout restart deploy/anytype -n anytype`; the real fix for bad
   config is `git revert` (GitOps; ArgoCD selfHeal re-converges drift).

## Common failures

- **entryPoint not published** — `nc -z anytype.eli.kr 33010` fails but pods are `Healthy`: the
  Traefik HelmChartConfig wasn't applied (k3s auto-deploy dir) or the Service didn't get the
  33010/33020 ports. Re-check step 3; the HelmChartConfig is dropped by ansible into
  `/var/lib/rancher/k3s/server/manifests/traefik-config.yaml` on node 1.
- **`imagePullBackOff` on anytype-heart** — the `ghcr-sushistack` imagePullSecret is missing/expired
  in ns `anytype` (heart is the PRIVATE image; the any-sync-bundle is public and needs none).
- **peerId/networkId mismatch after a bad restore** — clients silently stop syncing (no error). The
  `/data` copied in did NOT carry the original identity (or someone let it re-init). Restore the
  correct archive; verify the identity round-trips (Health check) BEFORE flipping the edge.
- **QUIC/UDP blocked at the edge** — sync still works over TCP 33010 but slower / flakier on mobile.
  Confirm the public forward passes **UDP** 33020, not just TCP, and that `IngressRouteUDP` exists.
- **`Multi-Attach error` on a `*-data` PVC** — RWO volume held by one node while another pod
  (usually the scale-to-0 backup, or a rescheduled app pod) wants it elsewhere. The backup CronJob
  uses `podAffinity` to co-locate; if it persists, confirm pod node placement
  (`kubectl get pod -n anytype -o wide`).

## Backup/restore commands

**File-class — real backup, NOT N/A.** Two `*-backup` CronJobs (ns `anytype`, ≤6h, offset :30/:40)
do a **scale-to-0 quiesce** (BadgerDB has no online dump): co-schedule onto the app pod's node, then
`kubectl scale deploy/<x> --replicas=0`, wait for the pod to stop, `tar` `/data`, upload to
`r2:homelab-k3s-services-backup/{anytype,anytype-heart}/`, and a `trap` scales the app back to 1 on any
exit. RBAC: the `anytype-backup` SA + Role (`deployments/scale: patch`). Credential: the per-ns
`anytype-backup-r2` SealedSecret.

**Run a backup on demand:**
```
kubectl create job -n anytype --from=cronjob/anytype-backup anytype-backup-manual
kubectl logs -n anytype job/anytype-backup-manual -f
rclone lsl r2:homelab-k3s-services-backup/anytype/ | tail
```

**Restore — the identity MUST round-trip (this is not ordinary data):**
```
# 1. fetch + unpack the chosen archive
rclone copy r2:homelab-k3s-services-backup/anytype/anytype-<ts>.tar.gz /tmp/
mkdir -p /tmp/anytype-restore && tar -C /tmp/anytype-restore -xzf /tmp/anytype-<ts>.tar.gz

# 2. suspend autosync FIRST — selfHeal:true would revert --replicas=0 back to 1 mid-restore and the
#    re-spawned pod + ingest pod would both want the RWO PVC (Multi-Attach / racing writers).
argocd app set anytype --sync-policy none
kubectl scale deploy/anytype -n anytype --replicas=0

# 3. re-use the cutover ingest pod for write access to the RWO PVC, copy /data in
kubectl apply -f workloads/anytype/_cutover/ingest-job.yaml
pod=$(kubectl -n anytype get pod -l job-name=anytype-ingest -o name | head -1)
kubectl -n anytype cp /tmp/anytype-restore/. "${pod#pod/}:/data-anysync/"
kubectl -n anytype delete -f workloads/anytype/_cutover/ingest-job.yaml

# 4. bring anytype back, re-enable autosync, and VERIFY identity preserved
kubectl scale deploy/anytype -n anytype --replicas=1
argocd app set anytype --sync-policy automated --self-heal
kubectl logs -n anytype deploy/anytype --tail=200 | grep -iE 'peerId|networkId'   # == the expected identity
```
(`anytype-heart` restores the same way against `anytype-heart-data` → `/data-heart/`.)

## Escalation / depends-on

- **heart consumers (still on Compose this story):** `karakeep-anytype-bridge` (Story 4.5) and `n8n`
  (Story 4.7) call heart's REST :31009. They reach it cross-namespace by the FQDN
  `anytype-heart.anytype.svc.cluster.local:31009` (in `anytype-config`). Until they migrate they hit
  the **Compose** heart, so don't decommission Compose.
- **Depends on:** Longhorn (the two RWO PVCs), the **k3s-owned Traefik HelmChartConfig** (the
  TCP/UDP entryPoints — outside ArgoCD), the `anytype-secrets` + `anytype-backup-r2` SealedSecrets,
  the `ghcr-sushistack` imagePullSecret, and the public 33010/33020 stream forward.
- **⚠️ No ntfy alert on backup failure until Story 4.2 lands** — a torn/failed scale-to-0 backup is
  not yet alerted (NFR15a). Watch the CronJobs manually until 4.2.
- **Compose anytype/anytype-heart are PARKED, not decommissioned** (the rollback) until the operator
  retires them deliberately (Story 5.4). See [stateful-cutover.md](stateful-cutover.md).
