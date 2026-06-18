# ADR-0007: Self-scaffolded ArgoCD app-of-apps (bounded), not an adopted cluster template

Affected services: all (the GitOps control loop reconciles every workload)

> Decision record. Back-reference: [README → Decision records](../../README.md#decision-records-adrs).

## Context

[ADR-0001](ADR-0001-why-compose-to-k3s.md) fixed the engine — ArgoCD on k3s,
Git as source of truth. This decision is the next layer down: **author the
GitOps layout from scratch, or adopt a community cluster template?** Mature
templates exist (`onedr0p/cluster-template`, others) that ship a whole homelab
in one fork. The pull is real — they encode hundreds of hours of operational
detail. The cost is equally real for a **bus-factor-1** homelab: a layout you
didn't write is a layout you must reverse-engineer at 3am, and a portfolio whose
value is *visible reasoning* gains nothing from borrowed scaffolding.

## Decision

**Self-scaffold the decision layer; borrow only the mechanical layer**, via a
**bounded ArgoCD 3.4 app-of-apps**:

- **App-of-apps, explicitly bounded.** A root `Application` applied by one manual
  `kubectl apply -f bootstrap/root-app.yaml`, recursing into a **readable** set of
  children. The cap is deliberate: the layout stays understandable on roughly one
  screen — a root + a small number of children — because **unbounded
  self-scaffolding, not templates, is the real over-scope risk** here.
- **Kustomize for self-authored workloads; Helm `source` for vendor.** Apps you
  must understand (per-service manifests) are self-authored Kustomize; components
  that carry no understanding (Longhorn, cert-manager, Sealed Secrets) are
  referenced as upstream Helm charts directly — **no mirroring**.
- **Self-author what must be understood; lift what doesn't.** The app-of-apps
  shape and per-service Kustomize are self-written (~200 lines of YAML, not a
  framework). The ArgoCD install manifest and individual service-manifest
  patterns are lifted from reference repos. Reviewers score the **top-level ADR**
  — "evaluated community templates, deliberately built a minimal layout for
  learning + recoverability" — not code provenance.
- **Required ArgoCD settings:** `ServerSideApply=true` (large CRD annotations
  from cert-manager/Longhorn exceed the client-side apply limit) and
  `CreateNamespace=true`; sync waves order bootstrap (see below). ArgoCD
  **self-management is deferred** (Phase 2a, not Phase 1) — a self-managing root
  can sync-wave-self-destroy during bootstrap.

## Consequences

- **Proven across Epics 1–2.** The bounded app-of-apps brought up a 3-node
  cluster: sync waves **0** (Sealed Secrets + Longhorn) → **1** (cert-manager
  CRDs) → **2** (ClusterIssuer DNS-01) → **3** (workloads + IngressRoute) — the
  ordering exists because a `Certificate` applied before its CRD fails. Adding a
  service is adding one Application manifest under a `directory: { recurse: true }`
  source.
- Rollback is `git revert` + reconcile, never out-of-band `kubectl rollout undo`
  (the 3-line rule); self-heal reverts drift anyway. The control plane is
  rebuildable — if ArgoCD breaks, reinstall and desired state restores the cluster
  (the one exception is the Sealed Secrets key,
  [ADR-0004](ADR-0004-secrets-sealing-key.md)).
- All version pins live in Git, so upgrades flow through the GitOps path and are
  revertible (NFR14).
- The bound is a standing discipline: every new child Application is weighed
  against "does the root still read on one screen?" — ceremony Applications are an
  anti-pattern here.

## Rejected alternatives

- **Adopt `onedr0p/cluster-template` (Flux + Talos).** Not just a tool mismatch
  with the fixed ArgoCD/k3s stack: Flux's Kustomization dependency model and
  ArgoCD's app-of-apps sync-wave model are **different mental models**, so even
  copying patterns risks blending two paradigms. Retained only as a *pattern
  reference*, never an adopted scaffold. Rejected.
- **Wholesale fork of any homelab template.** ~1000 lines of someone else's layout
  to reverse-engineer at 3am directly attacks bus-factor-1 recoverability, and the
  portfolio analysis shows it adds **no reviewer value on its own**. Real k3s+ArgoCD
  reference repos are kept as pattern references for operational detail (Longhorn
  recurringjob shape, DNS-01 solver form, key-backup), not as scaffolds. Rejected.
- **Flux instead of ArgoCD.** Different paradigm from the fixed stack; no benefit
  that justifies relearning the reconcile model. Rejected.

## Exposure note

Safe to show publicly: the entire decision — self-scaffold vs template, the
bounded app-of-apps, Kustomize-vs-Helm split, sync-wave ordering, and the
template-evaluation reasoning. This *is* the reviewer signal and is meant to be
read. Not shown: the repo URL token, cluster destination addresses, and any node
IP — those stay tokenized in `internal/`. The layout itself (file/dir names) is
public by design; only real addresses are gated.
