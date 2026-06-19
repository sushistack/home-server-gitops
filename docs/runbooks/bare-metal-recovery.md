# Runbook: bare-metal recovery (cold boot from nothing)

Affected services: the whole k3s platform (sealed-secrets, Longhorn, cert-manager,
all workloads). Depends on Plane 0 staying up: Proxmox host + OpenWrt router.

> Named recovery runbook for **Gate 0** (Story 2.6). The full chain below was
> proven end-to-end on throwaway dummy data on **2026-06-18** — see
> [DECISIONS.md → Gate 0](../DECISIONS.md#disaster-recovery--gate-0-story-26).
> **No stateful service may cut over (Epic 4) until this chain has passed.**

## 1. What this does

Rebuilds the cluster from **nothing but Git + two off-host secrets** after total
loss of the three k3s VMs (or etcd). It restores, in order: the VM substrate →
k3s with embedded etcd (quorum=3) → the **sealing key** (so existing
SealedSecrets decrypt again) → the GitOps stack (one `kubectl apply`) → any
Longhorn PV from its off-site R2 backup. Byte-level integrity is verified by
checksum.

**Scope boundary (Plane 0 invariant).** "Bare metal" here = the **three k3s node
VMs**. The Proxmox hypervisor and the OpenWrt router stay up — household internet
and this recovery path must NOT depend on the cluster. Re-imaging the physical
Proxmox host is a separate, manual boundary, **out of scope** for this repeatable
drill.

**Two off-host (Plane 0) secrets this depends on — without them recovery is impossible:**
- the **age identity** (`~/.config/sops/age/keys.txt`, recipient
  `age1chmmudv…`) that decrypts the sealing-key export;
- the **age-encrypted sealing-key export** (`internal/sealed-secrets-keys.*.yaml.age`),
  stored off-host (password manager / offline media), never committed.

## 2. Health check (is it actually up?)

```sh
kubectl get nodes                       # expect: 3× Ready, roles control-plane,etcd
kubectl get nodes -l node-role.kubernetes.io/etcd=true --no-headers | wc -l   # expect: 3 (quorum)
kubectl -n argocd get applications      # expect: all Synced/Healthy
                                        #   (argocd self-app may show OutOfSync — it is manual-sync, by design)
kubectl -n sealed-secrets get secret -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o name                               # expect: the SAME key name as before loss (adopted, not regenerated)
kubectl -n longhorn-system get nodes.longhorn.io   # expect: all Ready
```

If all green, you are done. If DOWN, go to §3.

## 3. If DOWN — recover in this order (deterministic boot order)

> Order is load-bearing. The sealing-key restore MUST land **before** the
> root-app sync, or the controller generates a fresh key and every existing
> SealedSecret becomes permanently undecryptable.

```
Proxmox host  →  OpenWrt router  →  k3s VMs  →  etcd quorum=3  →  [SEALING-KEY RESTORE]  →  ArgoCD root-app  →  workloads
   (Plane 0, already up — do NOT rebuild as part of this drill)
```

1. **Provision the 3 VMs** on Proxmox `${SECRET:HOST_PROXMOX}` from the Ubuntu
   24.04 cloud image — automated (see §5 "VM provisioning"). Names
   `k3s-cp-1/-2/-3` (all control-plane+etcd, quorum=3 — *never* 1 CP + 2 workers,
   that is quorum=1 and drops control-plane HA). VMIDs 101/102/103, IPs
   `${SECRET:IP_CLUSTER_NODE_A}/B/C`, MACs `BC:24:11:00:01:0x` (match OpenWrt
   static leases), scsi0 32G OS + scsi1 100G Longhorn disk.

2. **Ansible host layer** — one command, idempotent:
   ```sh
   bin/render ansible/inventory.yml
   ANSIBLE_HOST_KEY_CHECKING=False CLOUDFLARE_DNS01_TOKEN=… \
     ansible-playbook -i rendered/ansible/inventory.yml ansible/playbook.yml
   ```
   Brings up k3s v1.35.x (`--cluster-init` embedded etcd, quorum=3), Longhorn
   prereqs, ArgoCD, and injects bootstrap Secrets (ArgoCD repo + Cloudflare
   DNS-01 token). **It stops before the GitOps handoff.** Confirm
   `kubectl -n argocd get applications` is EMPTY and the `sealed-secrets`
   namespace does NOT exist yet — that is the window for step 3.

3. **★ Restore the sealing key (the one extra manual step beyond the ≤1-step cold boot — see §6):**
   ```sh
   kubectl create namespace sealed-secrets --dry-run=client -o yaml | kubectl apply -f -
   age -d -i ~/.config/sops/age/keys.txt internal/sealed-secrets-keys.<TS>.yaml.age \
     | kubectl apply -f -
   kubectl -n sealed-secrets get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o name  # record it
   ```

4. **The single GitOps manual step (NFR7):**
   ```sh
   kubectl apply -f bootstrap/root-app.yaml
   ```
   app-of-apps recurses and self-syncs in waves: **0** sealed-secrets + Longhorn
   → **1** cert-manager CRDs → **2** ClusterIssuer → **3** workloads. The
   sealed-secrets controller starts at wave 0, finds the key from step 3, and
   **adopts** it. Verify adoption (key name unchanged) and that a previously
   sealed Secret materializes:
   ```sh
   kubectl -n sealed-secrets rollout status deploy/sealed-secrets
   kubectl apply -f <a-known-pre-loss SealedSecret>; kubectl -n <ns> get secret <name>   # must materialize
   ```

5. **Restore PVs from R2** (per volume that needs data — see §5).

6. **Re-apply the edge-proxy EndpointSlices (5.8).** ArgoCD's `resource.exclusions`
   drops `discovery.k8s.io/EndpointSlice`, so the 5 NPM-replacement edge hosts
   (`jellyfin`/`immich`/`proxmox`/`openwrt`/`kvm`) come back with their Service +
   IngressRoute synced but **zero endpoints → Traefik returns 503** until the static
   slices are applied out of band:
   ```sh
   bash workloads/edge-proxies/apply-endpoints.sh   # idempotent; needs internal/tokens.env (IP_*)
   ```
   Verify: `kubectl -n edge-proxies get endpointslices` shows one per host, then each
   host serves (200/302) through Traefik. (uptime-kuma is a real in-cluster workload —
   not affected; only the selector-less edge Services need this.)

### 3a. Cold-boot leg (power-cycle — etcd SURVIVES, the everyday outage path)

> This leg is what a **power outage** triggers, and is distinct from the bare-metal
> rebuild above. The 3 k3s VMs and etcd **survive a clean power-cycle**, so there is
> **NO sealing-key restore** (that step exists only when etcd is lost — §3.3 above).
> Tested + measured under Story 5.2; the bare-metal leg (§3.1–3.5) stands for etcd loss.

**Deterministic boot order (enforced at the hypervisor, not improvised):**

```
Proxmox host (Plane 0)  →  OpenWrt router VM  →  3× k3s node VMs  →  etcd quorum 3/3 re-forms  →  ArgoCD reconciles  →  workloads (sync waves 0→3)
   onboot=1                 startup order=1        startup order=2,up=S (onboot=1)
   (boots first, outside    (household internet     (staggered: etcd must reach quorum
    the cluster)             first; no cluster dep)   BEFORE Longhorn/wave-0 storage wakes)
```

The single load-bearing rule: **Longhorn (wave 0) must not be scheduled before etcd is
healthy** — else storage flaps while the datastore is still electing. The `up=S` stagger
on the node VMs (declared in §5) plus k3s/ArgoCD readiness gating enforces it. The exact
`order`/`up=S` values are the SSOT in §5; do not "optimise" the stagger away — it is what
prevents the single-host etcd-quorum race (3 members starting at once on one host).

**Per-layer stall map — if convergence stalls, find the layer, run the check, take the action:**

| Layer (in boot order) | Check (is THIS layer the stall?) | If stalled, do exactly this |
|---|---|---|
| **Proxmox host** | host does not POST / no console | This is the **host-reimage boundary** — out of cold-boot scope. Power + OOB console (NanoKVM); if the host itself is lost, you are in the full bare-metal leg (§3.1), not cold boot. |
| **OpenWrt router VM** | no household DNS/DHCP; `qm status <router-vmid>` ≠ running | `qm start <router-vmid>`. Confirm `onboot=1` + **lowest** `startup order`. Router must NOT wait on the cluster (Plane 0 invariant) — if it does, that dependency is the bug. |
| **a k3s node VM** | `kubectl get nodes` shows <3 Ready; `qm status` of the missing VMID | `qm start` the missing VM; confirm `onboot=1`. If the VM is up but NotReady: SSH in, `systemctl status k3s` (init node) / `k3s-agent`→no, all are `server`; check disk/`iscsid`. |
| **etcd quorum** | `kubectl get nodes -l node-role.kubernetes.io/etcd=true --no-headers \| wc -l` < 3, or apiserver unreachable | The single-host **race**: members started too close together. Increase `up=S` in §5 and re-cycle. If one member is wedged, restart `k3s` on the lagging node only. **Never run at 2** — fix to 3 or you have lost control-plane HA. |
| **ArgoCD** | `kubectl -n argocd get applications` OutOfSync/Missing, or argocd pods not Running | Wait for etcd + apiserver first (ArgoCD cannot reconcile without them). Then `kubectl -n argocd rollout status deploy/argocd-application-controller`. **The ≤1 manual step, if any is needed:** `kubectl apply -f bootstrap/root-app.yaml` (idempotent — safe to re-run). |
| **a workload** | pod Pending/CrashLoop; its PVC not Bound | Almost always **Longhorn woke before etcd settled** — the volume re-attaches on its own once etcd is healthy. Confirm `kubectl -n longhorn-system get nodes.longhorn.io` all Ready, then delete the stuck pod to force a clean reschedule. If it recurs every boot, the `up=S` stagger is too short. |

**Measured manual-step count (NFR7):** `<MEASURED — pending operator cold-boot drill, Story 5.2 Task 3>`
(target ≤1; the only candidate step is the idempotent `kubectl apply -f bootstrap/root-app.yaml`
above — ArgoCD `automated{selfHeal}` should make even that unnecessary on a power-cycle. Record
the real number from the drill here; if >1, list each extra step honestly.)

## 4. Common failures

| Symptom | Cause | Fix |
|---|---|---|
| Every SealedSecret stuck, Secrets never materialize | Controller came up **before** the key was restored → generated a fresh key | The fresh key cannot decrypt old SealedSecrets. Delete the controller's auto-generated key, apply the correct exported key, restart the controller. If the export is also stale/lost → unrecoverable; re-seal everything. **Prevent: always do §3.3 before §3.4.** |
| `age: no identity matched any of the recipients` | Wrong/old export, or wrong age identity | Use the export encrypted to `age1chmmudv…`; confirm `keys.txt` is the matching identity. |
| etcd won't form / only 1 member | A node joined as **agent** not **server**, or only 2 nodes up | All three must join as `server` (quorum=3). Never run at 2. |
| Longhorn volumes won't attach | iscsid not running / multipathd grabbed the device | Ansible Play 0 handles this; re-run it. Verify `systemctl is-active iscsid`, `multipathd` masked. |
| BackupTarget `available=false` | R2 creds/endpoint wrong, or region rejected | Secret keys `AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY/AWS_ENDPOINTS`; URL `s3://<bucket>@us-east-1/<path>` (R2 ignores region but the SDK needs a valid-looking one). |
| `draw.<zone>` 502 at the edge | cloudflared origin points at a dead node | Origin must point at a live Phase-2a node `:443`; Traefik answers on every node IP. |
| **Cold boot:** etcd quorum won't form, or volumes flap on every power-cycle | Single-host **race** — 3 etcd members started too close together, or Longhorn woke before etcd was healthy | Increase the `up=<S>` stagger on the node VMs (§5) and re-cycle; the stagger holds wave-0 storage back until etcd is electing-done. See the §3a per-layer stall map. |

## 5. Backup / restore — exact commands

**VM provisioning (substrate rebuild).** Destroy + recreate the three VMs from
the Ubuntu cloud image (run on the Proxmox host). Per node: `qm stop` + `qm
destroy --purge` → `qm create` (4 vCPU, 8 GiB, `virtio` NIC on `vmbr1` with the
node's MAC, `virtio-scsi-single`, serial console) → `qm importdisk` the cloud
image to scsi0 + resize 32G → add scsi1 100G (Longhorn) → ide2 cloudinit →
cloud-init `ciuser=root` + sshkeys + static `ipconfig0` → `qm start`. This is the
reproducible substrate definition (Terraform Proxmox provider is deferred);
keep it next to `ansible/`.

**Cold-boot start-order — the declared SSOT (Story 5.2, AC1).** After power-on the
host must bring the VMs up in a fixed order with no operator at the console, so set
these per-VM keys as part of the substrate definition (native Proxmox feature — do
NOT build an orchestration daemon). Verify exact key syntax against the installed PVE
version before applying:

```sh
# Plane 0 router first, then the k3s nodes after a stagger so etcd forms quorum
# BEFORE Longhorn (wave 0) wakes. up=S = wait S seconds after THIS vm starts before
# starting the next ordered VM. S is tuned empirically in the drill (start at up=30 → 60).
qm set <router-vmid>  --onboot 1 --startup order=1
qm set <k3s-cp-1-vmid> --onboot 1 --startup order=2,up=<S>
qm set <k3s-cp-2-vmid> --onboot 1 --startup order=2,up=<S>
qm set <k3s-cp-3-vmid> --onboot 1 --startup order=2,up=<S>
```

> **HIGH-BLAST-RADIUS (`configs/proxmox/`, Plane 0).** Never apply directly. Dry-run /
> show the diff (`qm config <vmid> | grep -E 'onboot|startup'` before & after), get
> explicit operator approval, and state the rollback **before** applying. **Rollback:**
> `qm set <vmid> --delete startup` (and `--onboot 0` if it was unset) restores the prior
> behaviour. A mistake here also touches the household-internet boot path (the router VM).

**Sealing key — export (do this on the live cluster; re-export after any key renewal):**
```sh
kubectl -n sealed-secrets get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > /tmp/ss-keys.yaml
test "$(kubectl -n sealed-secrets get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o name | wc -l)" -ge 1 \
  || { echo 'FATAL: empty export — refusing'; exit 1; }
age -r age1chmmudv… -o "internal/sealed-secrets-keys.$(date +%Y%m%dT%H%M%S).yaml.age" /tmp/ss-keys.yaml
shred -u /tmp/ss-keys.yaml          # best-effort; see caveat below
# Move the .age OFF this host (Plane 0). Verify it round-trips:
age -d -i ~/.config/sops/age/keys.txt internal/sealed-secrets-keys.*.yaml.age | diff - <(kubectl -n sealed-secrets get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml)
```
Sealing-key **restore** is §3.3.

**Longhorn PV — backup (file-class / crash-consistent, fine for static data; app-consistent dumps are Epic 4):**
```sh
# Configure BackupTarget once (per cluster):
kubectl -n longhorn-system create secret generic r2-backup-cred \
  --from-literal=AWS_ACCESS_KEY_ID=… --from-literal=AWS_SECRET_ACCESS_KEY=… --from-literal=AWS_ENDPOINTS=https://<acct>.r2.cloudflarestorage.com
kubectl -n longhorn-system patch backuptarget default --type merge \
  -p '{"spec":{"backupTargetURL":"s3://<bucket>@us-east-1/<path>","credentialSecret":"r2-backup-cred"}}'
# Snapshot + back up a volume:
kubectl apply -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: Snapshot
metadata: {name: <snap>, namespace: longhorn-system}
spec: {volume: <pv-name>, createSnapshot: true}
EOF
kubectl apply -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: Backup
metadata: {name: <bkp>, namespace: longhorn-system, labels: {backup-volume: <pv-name>}}
spec: {snapshotName: <snap>, backupMode: full}
EOF
```

**Longhorn PV — restore into a new volume + verify integrity:**
```sh
# Re-point BackupTarget at the same R2 path on the rebuilt cluster (as above); Longhorn lists the backups.
BURL=$(kubectl -n longhorn-system get backups.longhorn.io <bkp> -o jsonpath='{.status.url}')
kubectl apply -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata: {name: <restored>, namespace: longhorn-system}
spec: {fromBackup: "$BURL", numberOfReplicas: 3, size: "<bytes>", frontend: blockdev}
EOF
# Wait restoreRequired=false, then expose via a static PV (csi volumeHandle=<restored>,
# storageClassName longhorn-static) + PVC, mount, and compare sha256 against the pre-loss checksum.
```

## 6. Manual-step count (NFR7, honest) + escalation

- **Steady-state cold boot** (cluster already provisioned + keyed, just powered
  off — the §3a power-cycle leg): **1 deterministic manual step** — `kubectl apply -f
  bootstrap/root-app.yaml` — and **possibly 0** once ArgoCD `automated{selfHeal}`
  reconciles on its own after etcd+API are back. Tested + measured under Story 5.2:
  **`<MEASURED — pending operator cold-boot drill, Story 5.2 Task 3>`** (verified over
  2–3 repeated power-cycles to confirm the single-host etcd-quorum race does not stall
  convergence). The load-bearing rule that makes this deterministic: the `up=<S>`
  stagger (§5) holds the k3s node VMs so **etcd reaches quorum before Longhorn (wave 0)
  wakes** — do not optimise the stagger away, or the storage layer flaps while the
  datastore is still electing. Meets NFR7 (≤1). Record the real number above after the drill.
- **Full bare-metal recovery**: **2 load-bearing manual steps** — (a) the
  sealing-key restore (§3.3), then (b) root-app (§3.4). The key-restore is
  **deliberately not automated**: automating it would require the age identity
  to live on a cluster node, which defeats the OOB / Plane 0 design. VM
  provisioning + Ansible are scripted, not counted as discrete manual judgement.
- **Edge-proxy slices (5.8):** one extra out-of-band `bash
  workloads/edge-proxies/apply-endpoints.sh` (§3 step 6) on a full rebuild — it is a
  scripted, idempotent re-apply (like provisioning), not a judgement step, but the 5
  edge hosts stay 503 until it runs. ArgoCD cannot own these (EndpointSlice is excluded).

**Rotation caveat.** The sealed-secrets controller can renew its key (adds a new
`active`, keeps old ones). A stale export then cannot decrypt anything sealed
since. Discipline: export **all** keys every time, and **re-export after any
renewal**. Verify the export round-trips (§5) before trusting it.

**`shred` caveat.** On `tmpfs`/CoW/overlay filesystems `shred` does not guarantee
erasure and swap may hold a copy. Treat the plaintext key as having existed on
the host; rely on the **age encryption + off-host move**, not `shred`.

**Escalation / depends-on.** This runbook is the cold-boot foundation; the fully
automated + tested cold-boot is **Story 5.2**. Plane 0 (Proxmox, OpenWrt) is
assumed up — if the hypervisor itself is lost, that is the separate manual
host-reimage boundary, not this drill.
