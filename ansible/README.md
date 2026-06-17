# ansible — Phase 2a host layer (3-node, embedded etcd)

Brings **three** net-new VMs from bare to "k3s etcd quorum=3 + ArgoCD installed + repo &
Cloudflare-token Secrets injected", then **stops** at the single manual GitOps entry point.
Ansible owns the host layer only; it does **not** own anything past
`kubectl apply -f bootstrap/root-app.yaml`.

> **Clean bootstrap, NOT an in-place promotion (AR9).** These are three brand-new VMs. The Phase 1
> single-node SQLite VM held no real data, so it is **deleted up front** and its VMID 101 reused for
> node 1 here — the cluster is rebuilt from Git, never migrated in place. No SQLite→etcd migration.

## Phase 2a VM shapes (recorded in Git — Terraform Proxmox provider is deferred)

Three identical nodes, all **control-plane + worker** (`server` role). VM sizing is finalized here
(Phase 2a is where compute topology is decided); each node gets headroom **and a separate data
disk anticipating Longhorn** (Story 2.2 does the Longhorn host prep — this story only attaches the
disk so it exists).

| Field    | node 1 (init)              | node 2                     | node 3                     |
|----------|----------------------------|----------------------------|----------------------------|
| Host     | Proxmox `${SECRET:HOST_PROXMOX}` (`${SECRET:IP_PROXMOX}`) | ← same | ← same |
| VMID     | 101                        | 102                        | 103                        |
| Name     | `k3s-2a-1`                 | `k3s-2a-2`                 | `k3s-2a-3`                 |
| vCPU     | 4                          | 4                          | 4                          |
| RAM      | 8192 MB                    | 8192 MB                    | 8192 MB                    |
| OS disk  | 32 GB on `local-lvm` (lvmthin) | ← same                 | ← same                     |
| Data disk| 100 GB on `local-lvm` (Longhorn — Story 2.2 formats/uses it) | ← same | ← same |
| Bridge   | `vmbr1` (LAN bridge — `vmbr0` is OpenWrt's WAN side) | ← same        | ← same                     |
| IP       | `${SECRET:IP_CLUSTER_NODE_A}/24` | `${SECRET:IP_CLUSTER_NODE_B}/24` | `${SECRET:IP_CLUSTER_NODE_C}/24` |
| Gateway  | `${SECRET:IP_LAN_GATEWAY}` (cloud-init static; matching OpenWrt DHCP leases) | ← same | ← same |
| Role     | `--cluster-init` (initializes etcd) | join as `server`  | join as `server`           |
| OS       | Debian 13 (trixie) genericcloud amd64, cloud-init | ← same        | ← same                     |

VMIDs 101–103 (the Phase 1 throwaway VMID 101 is destroyed and reused). Roles, not install order, matter:
node 1 inits etcd, nodes 2/3 join as **server** (NOT agent) so etcd reaches **quorum=3, never 2**.

## Run

```sh
bin/render ansible/inventory.yml                              # -> rendered/ (real IPs)

# CLOUDFLARE_DNS01_TOKEN: Cloudflare API token, Zone:DNS:Edit on the public zone ONLY (NFR11).
# Injected as Secret cloudflare-dns01-token (ns cert-manager) for the Story 2.4 ClusterIssuer.
CLOUDFLARE_DNS01_TOKEN=… \
  ansible-playbook -i rendered/ansible/inventory.yml ansible/playbook.yml
# private repo only: also set ARGOCD_REPO_TOKEN=…
```

Then the single manual line (the GitOps handoff):

```sh
kubectl apply -f bootstrap/root-app.yaml
```

The playbook is idempotent (k3s `creates:` guard, `helm upgrade --install`, `kubectl apply` of
dry-run YAML). Re-running converges; it does not re-init etcd or duplicate joins.

## Verify (operational evidence — keep real IPs/hostnames out of any committed clip, AR26)

```sh
kubectl get nodes -o wide        # 3× Ready, roles control-plane,etcd,master
kubectl -n kube-system get pods   # traefik present; no etcd churn
# on a node: etcd member count == 3
sudo k3s etcd-snapshot ls          # or: kubectl -n kube-system exec … etcdctl member list
argocd app list                    # root + excalidraw Synced/Healthy; argocd self-app present
argocd repo list                   # repo Successful
kubectl -n cert-manager get secret cloudflare-dns01-token   # present (Ansible-injected)
```
