# ADR-0001: Why Compose → k3s

Affected services: all

> Decision record. Back-reference: [README → Decision records](../../README.md#decision-records-adrs).

## Context

The home server ran ~14 services as a single Docker Compose stack on one host:
deploys were imperative (`docker compose up` on the box), there was no declarative
record of *desired* state, no health-gated rollout, and "what is running" could
only be answered by SSH-ing in. The same stack also doubles as a public portfolio:
the artifact a reviewer reads has to *be* the system, not a slide deck about it.
Compose gives neither a reconcile loop nor a narrative worth showing.

## Decision

Migrate to a **GitOps-reconciled k3s cluster**: Git is the single source of truth,
ArgoCD continuously reconciles the cluster to the committed manifests (auto-sync,
prune, self-heal), and every change — including rollback — is an ordinary Git
commit. k3s is the Kubernetes distribution (lightweight, single-binary, fits a
home node); ArgoCD is the GitOps engine; the repo is **public-default**, kept
safe by a two-layer exposure gate rather than by scrubbing.

Phase 1 is a deliberately **throwaway single-node** cluster used to prove the
reusable deployment pattern end-to-end (this is what Excalidraw pilots — see
[ADR-0002](ADR-0002-excalidraw-phase1-pilot.md)) before any durable or stateful
service moves.

## Consequences

- Rollback becomes `git revert` + reconcile — no out-of-band `kubectl rollout undo`
  (the [3-line rule](../../README.md#decision-records-adrs)); out-of-band drift is
  reverted by self-heal anyway.
- A bad image never stays live: the new pod fails its readiness probe, the old
  ReplicaSet keeps serving, and ArgoCD surfaces `Degraded`/`Progressing`.
- New operational surface to own: cluster bootstrap, ArgoCD, manifests, and a CI
  triad (exposure-scan + manifest-lint + adr-link-check).
- The repo is the product: docs, ADRs, and diagrams are first-class outputs, not
  end-of-project chores.
- Phase 1's cluster, certs, and secrets are throwaway and do **not** carry to the
  Phase 2a clean cluster.

## Rejected alternatives

- **Stay on Docker Compose.** No reconcile loop, no declarative desired state, no
  health-gated rollout, and a weak portfolio narrative. Rejected.
- **Adopt a community GitOps cluster template — `onedr0p/cluster-template`
  (Flux + Talos).** Rejected as an adopted scaffold: it is Flux + Talos, a
  tool/paradigm mismatch with the fixed ArgoCD/k3s stack. Flux's Kustomization
  dependency model and ArgoCD's app-of-apps sync-wave model are different mental
  models, so even copying patterns risks blending two paradigms. Also app-of-apps
  has no surface worth reinventing (~200 lines of YAML, not a framework), and a
  wholesale fork hurts bus-factor-1 recoverability. Retained only as a *pattern
  reference*, not a scaffold.
- **Full managed Kubernetes (cloud).** Cost and over-provisioning for a
  single-home workload; defeats the on-prem/learning purpose. Rejected.

## Exposure note

Safe to show publicly: the *shape* of the decision — Compose → GitOps on k3s,
ArgoCD reconcile/revert, the throwaway-Phase-1 strategy. Not shown: real
hostnames, IPs, the private wildcard domain, or topology specifics — those
exist only as `${SECRET:NAME}` tokens rendered at deploy time and are gated by
the exposure scan. Diagrams use role-based logical names only.
