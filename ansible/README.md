# ansible — Phase 1 host layer

Brings the Phase 1 node from bare VM to "ArgoCD installed, repo registered", then
**stops** at the single manual GitOps entry point. Ansible owns the host layer only;
it does **not** own anything past `kubectl apply -f bootstrap/root-app.yaml`.

## Phase 1 VM shape (recorded in Git — Terraform Proxmox provider is deferred)

| Field   | Value |
|---------|-------|
| Host    | Proxmox `${SECRET:HOST_PROXMOX}` (`${SECRET:IP_PROXMOX}`) |
| VMID    | 101 |
| Name    | `${SECRET:HOST_CLUSTER_NODE}` |
| vCPU    | 2 |
| RAM     | 4096 MB |
| Disk    | 32 GB on `local-lvm` (lvmthin) |
| Bridge  | `vmbr1` (LAN bridge — `vmbr0` is OpenWrt's WAN side) |
| IP      | `${SECRET:IP_CLUSTER_NODE}/24`, gw `${SECRET:IP_LAN_GATEWAY}` (cloud-init static; also a matching OpenWrt DHCP lease) |
| OS      | Debian 13 (trixie) genericcloud amd64, cloud-init |

> **Throwaway** — see [`../bootstrap/README.md`](../bootstrap/README.md). No data-persistence
> guarantee; Phase 2a is a clean rebuild, never an in-place promotion. Never run a
> SQLite→etcd migration on this VM.

## Run

```sh
bin/render ansible/inventory.yml                              # -> rendered/ (real IP)
ansible-playbook -i rendered/ansible/inventory.yml ansible/playbook.yml
# private repo only: ARGOCD_REPO_TOKEN=… ansible-playbook -i … ansible/playbook.yml
```

Then the single manual line (the GitOps handoff):

```sh
kubectl apply -f bootstrap/root-app.yaml
```

The playbook is idempotent (k3s `creates:` guard, `helm upgrade --install`, `kubectl apply`).
