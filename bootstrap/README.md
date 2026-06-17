# bootstrap

`root-app.yaml` is the **single manual entry point** of the whole GitOps loop.
Everything after it reconciles.

## Bootstrap order — Phase 2a, 3-node embedded etcd (reproducible — NFR12/NFR13)

1. **Provision three VMs** on Proxmox `${SECRET:HOST_PROXMOX}` — shapes recorded in
   [`../ansible/README.md`](../ansible/README.md). (Terraform Proxmox provider is deferred.)
2. **Ansible host layer** (`../ansible/`) — three plays, all `server` role, **embedded etcd**:
   - node 1: **k3s v1.35.5+k3s1** with `--cluster-init` (initializes etcd), bundled Traefik +
     `--tls-san` (all three node IPs); **no** `--disable=traefik`.
   - nodes 2 & 3: join with `--server https://<node1>:6443` + the shared node-token, as `server`
     (**NOT** agent) → etcd **quorum=3, never 2**.
   - then on node 1, once: install **ArgoCD** (chart `9.5.21`, appVersion `v3.4.3`) via Helm →
     inject the ArgoCD **repository Secret** directly → inject the **Cloudflare DNS-01 token**
     Secret (`cloudflare-dns01-token`, ns `cert-manager`) directly (AR4 — never via Sealed Secrets).
3. **The single manual line** (Ansible does not own this):
   ```sh
   kubectl apply -f bootstrap/root-app.yaml
   ```
4. The root app recurses `argocd/` and adopts: the `homelab` AppProject, the `workloads`
   ApplicationSet (re-applies the **Epic 1 Excalidraw** manifests with ~one sync — the payoff of
   clean-bootstrap + GitOps), and `argocd/apps/*`. **Story 2.1 ENABLES ArgoCD self-management**:
   `argocd/apps/argocd.yaml` is adopted here (manual-sync, self-destroy-safe), so future ArgoCD
   upgrades flow through GitOps and are git-revertible (AR5/NFR14).

## Sync-wave ordering (AR3 — convention declared here; some slots reserved for later stories)

The app-of-apps children carry an `argocd.argoproj.io/sync-wave` annotation so infra reconciles
in dependency order as it is added:

| Wave | Component                                   | Lands in        |
|------|---------------------------------------------|-----------------|
| 0    | sealed-secrets, Longhorn                    | Stories 2.3, 2.2 (**reserved** — not authored here) |
| 1    | cert-manager (CRDs)                         | Story 1.5 (`argocd/apps/cert-manager.yaml`) |
| 2    | ClusterIssuer                               | Story 1.5 / promoted to prod in 2.4 (`argocd/apps/cluster-issuer.yaml`) |
| 3    | workloads + IngressRoute (Excalidraw, …)    | `argocd/applicationsets/workloads.yaml` |

Story 2.1 only puts the **convention** in place; it does NOT author the wave-0 Longhorn /
sealed-secrets Applications (those are 2.2 / 2.3). The ArgoCD self-app sits at wave `-1`
(platform-of-platform) but is manual-sync, so the wave is informational.

## Throwaway boundary (AR9 — the Phase 1 VM)

The Phase 1 single-node VM (SQLite + local-path) was **throwaway** — no
data-persistence guarantee, never a migration target. It held no real data, so it is **deleted up
front** and its VMID (101) reused for Phase 2a node 1. Phase 2a is a **clean bootstrap of a new
multi-node cluster** rebuilt from Git, *not* an in-place promotion. No SQLite→etcd migration is
ever attempted (that path doesn't exist — embedded etcd requires `--cluster-init`).
