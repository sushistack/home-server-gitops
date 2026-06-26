---
title: 'Longhorn → local-path migration'
type: 'chore'
created: '2026-06-26'
status: 'done'
baseline_commit: '3e02fcbf975fce30d96f1bebfc418c21406888d9'
context:
  - infra/longhorn/README.md
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Longhorn consumes excessive resources (DaemonSet × 3 nodes + ~42 instance-manager pods for 20 PVCs) on a single-Proxmox-host cluster where 3-way replication has zero real durability benefit — all replicas share one physical disk.

**Approach:** Migrate all 20 Longhorn PVCs to k3s's built-in `local-path` provisioner (already installed, zero pod overhead), designate `k3s-cp-1` as the storage node, remove the Longhorn ArgoCD apps, and revert the Ansible bootstrap patch.

## Boundaries & Constraints

**Always:**
- Designate `k3s-cp-1` as the storage node for all local-path volumes (label: `storage-node=true`); all migration pods and all updated workloads must use `nodeSelector: {storage-node: "true"}` or equivalent nodeAffinity
- Migrate services one at a time (scale down → copy → swap → verify) to avoid data loss; do NOT bulk-switch
- Keep `argocd.argoproj.io/sync-options: Prune=false` on all new PVCs unchanged
- `reclaimPolicy: Retain` on the new local-path StorageClass (patch the StorageClass before creating any PVCs)

**Ask First:**
- If any workload has a pre-existing nodeAffinity or podAntiAffinity that conflicts with k3s-cp-1, halt and ask which node to use instead
- If rsync shows data > declared PVC size (shouldn't happen but verify), halt before proceeding with that service

**Never:**
- Delete the old Longhorn PVC until the new workload is verified healthy on the new local-path PVC
- Re-create the Longhorn ArgoCD apps after removal
- Move backup to scope — Longhorn R2 backup is deferred (app-level dumps already cover vaultwarden, ntfy; remaining services noted in deferred-work)

</frozen-after-approval>

## Code Map

- `argocd/apps/longhorn.yaml` — ArgoCD Application for Longhorn Helm chart (wave 0); remove
- `argocd/apps/longhorn-backup.yaml` — ArgoCD Application for longhorn-backup infra; remove
- `infra/longhorn-backup/` — RecurringJob, BackupTarget, SealedSecret CRs; entire dir removed
- `versions.yaml` — `longhorn:` block; remove after migration complete
- `ansible/playbook.yml` — Play 0 (iSCSI prereqs) + local-path un-default patch; revert both
- `workloads/*/pvc*.yaml` (20 files) — change `storageClassName: longhorn` → `local-path`; add nodeAffinity via workload spec (see Design Notes)
- `argocd/projects/homelab.yaml` — verify no longhorn-specific project rules remain

## Tasks & Acceptance

**Execution:**

- [x] `ansible/playbook.yml` -- remove Play 0 (open-iscsi/iscsid/multipathd tasks) entirely; update the local-path StorageClass patch task to re-enable default instead of removing it -- iSCSI is only needed for Longhorn V1 engine; local-path needs to become sole default again
- [ ] *(operator: kubectl)* -- label `k3s-cp-1` with `storage-node=true`; patch `local-path` StorageClass reclaimPolicy to Retain -- must be done on live cluster before any PVC migration
- [ ] *(operator: kubectl per service)* -- for each of the 20 PVCs: scale workload to 0 replicas, create new PVC (`storageClassName: local-path`) with `nodeSelector: {storage-node: "true"}` in a migration pod, rsync `/old-data/ /new-data/`, delete migration pod, update workload manifest (next task), scale up, verify -- one service at a time; order: low-risk first (uptime-kuma, komga, suwayomi, semaphore, lidarr, slskd, soularr, miniflux, navidrome, n8n, netdata-state, netdata-cache, calibre, karakeep, anytype-heart, anytype, ntfy, vaultwarden)
- [x] `workloads/*/pvc*.yaml` (all 20) -- change `storageClassName: longhorn` → `storageClassName: local-path` -- matches the new provisioner
- [x] `workloads/*/deployment*.yaml` -- nodeSelector not required; local-path provisioner automatically sets nodeAffinity on the PV when migration pod runs on k3s-cp-1 — all future pods are pinned via PV nodeAffinity
- [x] `argocd/apps/longhorn.yaml` -- deleted
- [x] `argocd/apps/longhorn-backup.yaml` -- deleted
- [x] `infra/longhorn-backup/` -- deleted entire directory
- [x] `versions.yaml` -- removed `longhorn:` block
- [x] `infra/ops-alerts/configmap.yaml` -- replaced Longhorn disk check with k8s DiskPressure condition check
- [x] `infra/ops-alerts/rbac.yaml` -- removed `longhorn.io` ClusterRole rule
- [x] `argocd/projects/homelab.yaml` -- removed `charts.longhorn.io` sourceRepo

**Acceptance Criteria:**
- Given all PVCs migrated, when `kubectl get pvc -A | grep longhorn`, then no results
- Given Longhorn apps removed, when `kubectl -n longhorn-system get pods`, then namespace not found or no pods
- Given vaultwarden migrated to local-path, when vaultwarden pod starts on k3s-cp-1, then login succeeds and vault data intact
- Given ntfy migrated, when `kubectl exec ntfy -- ls /var/lib/ntfy/`, then auth.db and cache.db present
- Given local-path is sole default, when `kubectl get sc`, then exactly one default StorageClass (`local-path`)
- Given Ansible playbook updated, when playbook re-run on clean node, then no iSCSI packages installed and local-path is default

## Design Notes

**Migration pod template** (reuse for each service; substitute `<OLD-PVC>` and `<NEW-PVC>`):
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: migrate-<service>
  namespace: <service-ns>
spec:
  nodeSelector:
    storage-node: "true"
  restartPolicy: Never
  containers:
  - name: migrate
    image: alpine:3.20
    command: ["sh", "-c", "apk add rsync && rsync -av /old/ /new/ && echo DONE"]
    volumeMounts:
    - name: old; mountPath: /old
    - name: new; mountPath: /new
  volumes:
  - name: old
    persistentVolumeClaim: {claimName: <OLD-PVC>}
  - name: new
    persistentVolumeClaim: {claimName: <NEW-PVC>}
```

**Order rationale:** vaultwarden and ntfy last (highest-stakes); netdata-cache (10Gi) and calibre-data (10Gi) are the slowest rsync — budget ~5 min each.

**Backup gap:** Longhorn R2 RecurringJob is removed. App-level DB dumps (vaultwarden, ntfy, miniflux) continue to run. Services without app-level dumps (semaphore, komga, suwayomi, anytype, karakeep) temporarily have no offsite backup until a follow-up rclone CronJob spec is implemented.

## Spec Change Log

review-01: `reclaimPolicy: Delete` on default local-path SC risked data loss on PVC deletion. Added `local-path-retain` StorageClass as a GitOps-managed resource (`infra/local-path/`) and updated all PVCs to use it. Known-bad avoided: operator kubectl patch getting skipped post-rebuild. KEEP: `WaitForFirstConsumer` on the new SC for auto node-affinity.

review-01: `nfs-common` was erroneously removed from Ansible Play 0. Restored as Play 0 with only `nfs-common` (no iSCSI). Known-bad avoided: `/mnt/music` and `/mnt/manga` NFS mounts silently failing on fresh k3s installs.

## Verification

**Commands:**
- `kubectl get pvc -A -o wide | grep longhorn` -- expected: no output
- `kubectl -n longhorn-system get pods` -- expected: no namespace or empty
- `kubectl get sc` -- expected: `local-path` is the default, `local-path-retain` is present (non-default)
- `kubectl get sc local-path-retain -o jsonpath='{.reclaimPolicy}'` -- expected: `Retain`

## Suggested Review Order

**Storage provisioner (lead with design intent)**

- New GitOps-managed StorageClass — `reclaimPolicy: Retain` + `WaitForFirstConsumer` for node pinning
  [`storageclass.yaml:1`](../../infra/local-path/storageclass.yaml#L1)

- ArgoCD Application — wave 0, must exist before any workload PVC binds
  [`local-path.yaml:1`](../../argocd/apps/local-path.yaml#L1)

- All 20 PVCs: single-line change from `longhorn` → `local-path-retain`
  [`vaultwarden/pvc.yaml:18`](../../workloads/vaultwarden/pvc.yaml#L18)

**Ansible bootstrap**

- Play 0 restored with `nfs-common` only (iSCSI removed, NFS kept for music/manga mounts)
  [`playbook.yml:19`](../../ansible/playbook.yml#L19)

- Local-path now asserted as default (not un-defaulted); annotation flipped `false` → `true`
  [`playbook.yml:183`](../../ansible/playbook.yml#L183)

**Alerting and RBAC**

- Disk check: Longhorn API → k8s `DiskPressure` condition on nodes
  [`configmap.yaml:94`](../../infra/ops-alerts/configmap.yaml#L94)

- `longhorn.io` ClusterRole rule removed; comment updated
  [`rbac.yaml:1`](../../infra/ops-alerts/rbac.yaml#L1)

**Cleanup**

- Longhorn ArgoCD apps deleted; README updated with operator namespace-cleanup runbook
  [`longhorn/README.md:1`](../../infra/longhorn/README.md#L1)

**Commands:**
- `kubectl get pvc -A -o wide | grep longhorn` -- expected: no output
- `kubectl -n longhorn-system get pods` -- expected: no namespace or empty
- `kubectl get sc` -- expected: `local-path` is the only `(default)` entry
- `kubectl get nodes --show-labels | grep storage-node` -- expected: k3s-cp-1 has `storage-node=true`
