# bootstrap

`root-app.yaml` is the **single manual entry point** of the whole GitOps loop.
Everything after it reconciles.

## Bootstrap order (reproducible — NFR12/NFR13)

1. **Provision the VM** on Proxmox `${SECRET:HOST_PROXMOX}` — VM shape recorded in
   [`../ansible/README.md`](../ansible/README.md). (Terraform Proxmox provider is deferred.)
2. **Ansible host layer** (`../ansible/`): install **k3s v1.35.5+k3s1** as a `server`
   (default **SQLite** datastore, bundled Traefik + local-path, `--tls-san ${SECRET:IP_CLUSTER_NODE}`;
   **no** `--cluster-init`, **no** `--disable=traefik`) → install **ArgoCD** (chart `9.5.21`,
   appVersion `v3.4.3`) via Helm → inject the ArgoCD **repository Secret directly** (AR4).
3. **The single manual line** (Ansible does not own this):
   ```sh
   kubectl apply -f bootstrap/root-app.yaml
   ```
4. The root app recurses `argocd/`, adopts the `homelab` AppProject + `workloads`
   ApplicationSet, and self-reconciles. Phase 1 has **no** `infra/` children
   (sealed-secrets/Longhorn/cert-manager are Phase 2a) and `workloads/*` is empty until
   Story 1.3 — an empty/near-empty child set that is **Synced/Healthy** is the correct end state.

ArgoCD does **not** manage itself in Phase 1 (no Application points at ArgoCD —
deferred to Story 2.1; enabling it now risks sync-wave self-destroy, AR5).

## Throwaway boundary (AR9 — read this)

This cluster is **throwaway**. The **SQLite** datastore and **local-path-provisioner**
carry **no** data-persistence guarantee, and **nothing here is a migration target**.

Phase 2a is a **clean bootstrap of a new multi-node cluster**, *not* an in-place promotion
of this VM. No SQLite→etcd migration is ever attempted here (that path doesn't exist —
embedded etcd would require `--cluster-init`, which Phase 1 deliberately omits).
