# ADR-0002: Excalidraw is the Phase-1 throwaway pilot

Affected services: excalidraw

> Decision record. Back-reference: [README → Decision records](../../README.md#decision-records-adrs).

## Context

Phase 1 needs *one* service to prove the reusable deployment pattern — the
"golden path" — before any service whose loss or downtime would matter. The
pattern under test is the full chain: a manifest in Git → ArgoCD auto-sync →
health-gated rollout → host routing → TLS, plus the closed reconcile/`git revert`
loop. Whatever service pilots this gets deployed, deliberately broken, and
reverted on a throwaway cluster, so it must be safe to abuse. See
[ADR-0001](ADR-0001-why-compose-to-k3s.md) for the top-level Compose → k3s decision.

## Decision

Use **Excalidraw** as the Phase-1 pilot / test harness. It grades as
**Stateless / Disposable**: no database, no volumes, no PVC, no backup CronJob —
losing the pod loses nothing. It is HTTP-first, so it exercises the
ingress + non-production (staging) TLS path without dragging in stateful
concerns. Its Compose healthcheck (`nc -z localhost 80`) ports cleanly to a
Kubernetes TCP probe, so the health-gated rollout is faithful to the original.
It is therefore the right service to deliberately roll a bad version of and
revert, which is exactly AC1 of Story 1.6.

## Consequences

- Excalidraw is the first copy of the golden-path `_template/`; every later
  service inherits the same shape (deployment + service + ingressroute +
  certificate + kustomization, probes ported from the Compose healthcheck).
- It validates the reconcile → bad-rollout → `git revert` loop on a service whose
  failure is harmless — the bad-version demo cannot cause data loss.
- TLS here is **staging/non-production** (browser-untrusted, throwaway); promotion
  to production DNS-01 is a separate, later decision (Story 2.4), not Excalidraw's.
- Being disposable, it needs no runbook and no recovery drill — those start with
  the first durable/stateful service in later phases.

## Rejected alternatives

- **Pilot with a stateful service (e.g. a database-backed app).** Would entangle
  the pattern proof with storage, backups, and data-loss risk on a cluster meant
  to be wiped. Rejected — stateful cutovers are Phase 2c, after the pattern is proven.
- **Pilot with a critical service (e.g. the password vault).** Highest blast
  radius; never the first thing through an unproven pipeline. Rejected.
- **Skip a pilot, migrate services directly.** No safe surface to prove the loop,
  bad-version handling, and revert before it matters. Rejected.

## Exposure note

Safe to show publicly: that Excalidraw is the disposable pilot and why. The live
instance is reached via a tokenized host (`${SECRET:DOMAIN_DRAW}`); the real
domain, host, and IPs never appear in any tracked file or diagram, and the demo
clip is recorded against a logical name / `localhost` per the release checklist.
