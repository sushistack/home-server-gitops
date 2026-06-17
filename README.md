# home-server-gitops

A ~14-service home server migrated from a single Docker Compose host to a
**GitOps-reconciled k3s cluster** — Git is the source of truth, ArgoCD
continuously reconciles the cluster to what's committed, and rollback is just
`git revert`. Built in the open, public-default, kept safe by mechanism (not by
scrubbing).

## Before / after

![Excalidraw: Docker Compose host → ArgoCD-reconciled k3s](docs/diagrams/excalidraw-before-after.svg)

*Before:* imperative `docker compose up` on one host. *After:* `git push` →
ArgoCD auto-sync → health-gated rollout on k3s, with `git revert` as the rollback
path. Diagram source: [`excalidraw-before-after.mmd`](docs/diagrams/excalidraw-before-after.mmd).

## Demo — the closed loop (push → live → bad version held → revert)

[▶ Demo clip #1: Excalidraw reconcile / bad-version hold / revert](docs/demo/excalidraw-loop.mp4)

A merge rolls a new version live in ~2 min; a deliberately broken image never
becomes live (the old pod keeps serving, ArgoCD shows `Degraded`); a `git revert`
restores the prior state. Recorded against logical names only, behind the
[release checklist](docs/RELEASE-CHECKLIST.md) human gate.

## Why k3s over Compose

Compose had no declarative desired state, no reconcile loop, and no health-gated
rollout — and it made a weak portfolio. GitOps on k3s gives a Git-as-truth
control loop where every change (including rollback) is an ordinary commit, and
the repo itself *is* the documented product. Full rationale:
[ADR-0001](docs/adr/ADR-0001-why-compose-to-k3s.md).

## Decision records (ADRs)

Load-bearing decisions live in [`docs/adr/`](docs/adr/) (fixed template:
Context / Decision / Consequences / Rejected alternatives / Exposure note;
each lists `Affected services:`). ADR↔README links are bidirectional and enforced
by the [`adr-link-check`](.github/workflows/adr-link-check.yml) CI gate.

- [ADR-0001 — Why Compose → k3s](docs/adr/ADR-0001-why-compose-to-k3s.md)
- [ADR-0002 — Excalidraw is the Phase-1 throwaway pilot](docs/adr/ADR-0002-excalidraw-phase1-pilot.md)

One-line decision log: [`docs/DECISIONS.md`](docs/DECISIONS.md).

The **3-line rule:** rollback is `git revert` + reconcile — never an out-of-band
`kubectl rollout undo`; out-of-band drift is reverted by self-heal anyway.

## What was deliberately excluded

These are scoping decisions, not oversights:

- **Single-host SPOF.** Phase 1 is one node — if the box dies, the cluster is
  down. Durable multi-node + proven recovery is Phase 2a, not pretended here.
- **Throwaway cluster + certs.** Phase 1 is disposable: the cluster, its
  `letsencrypt-staging` (browser-untrusted) certs, and any secrets do **not**
  carry to the Phase 2a clean cluster. Production DNS-01 TLS comes later.
- **No persistent storage / backups yet.** Only stateless services are here.
  Longhorn, Sealed Secrets, and the full backup/recovery chain are later phases.
- **ArgoCD self-management deferred.** ArgoCD is bootstrapped, not yet managing
  its own upgrades via GitOps.
- **Stateful & critical services not migrated.** Databases, the password vault,
  etc. move only after the pattern is proven and zero-data-loss cutovers exist.

---

## Exposure gate (how it stays public-safe)

**Public-safe by mechanism, not by scrubbing.** Tracked files reference every
sensitive value ONLY as a `${SECRET:NAME}` token. Real values live in the
git-ignored `internal/tokens.env` and are injected at render time into git-ignored
output — so no tracked file ever holds a real hostname, IP, domain, or secret.

- **Layer 1 — automatic.** `gitleaks` (`.gitleaks.toml`) allowlists the
  `${SECRET:NAME}` token shape and denies raw IPs / private domains / internal
  hostnames / secrets. Pre-commit hook (working tree) + CI over the **full git
  history**.
- **Layer 2 — human.** [`docs/RELEASE-CHECKLIST.md`](docs/RELEASE-CHECKLIST.md)
  gates the artifacts the scanner can't read (demo clips, diagrams, screenshots).

## Local setup

```sh
pip install pre-commit && pre-commit install        # enable the commit-time gate
cp internal/tokens.example.env internal/tokens.env  # then fill REAL values (git-ignored)
bin/render <file>                                   # -> rendered/<file> (git-ignored)
```

Layout: `bootstrap/` (app-of-apps root), `argocd/` (projects, apps, appsets),
`infra/` (cluster-wide infra), `workloads/` (per-service manifests + golden-path
`_template/`).
