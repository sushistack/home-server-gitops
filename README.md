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

## Demo — live behavior

**Clip 1 — the closed loop (push → live → bad version held → revert):**

https://github.com/user-attachments/assets/08bcab1f-e96b-4cfb-9f76-9d003e3db96e

A merge rolls a new version live in ~2 min; a deliberately broken image never
becomes live (the old pod keeps serving, ArgoCD shows `Degraded`); a `git revert`
restores the prior state. Recorded against logical names only, behind the
[release checklist](docs/RELEASE-CHECKLIST.md) human gate.

**Clip 2 — self-heal (pod-kill / node-drain → reschedule):** *recording pending.*
The behavior is already proven live (pod self-heal to replica count; node-drain
reschedule + Longhorn re-attach in ~12 s; health-gated bad rollout held) — the
screen-recorded clip is captured and gated after the stateful cutovers land, so it
shows the full platform rather than a Phase-2 slice.

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
- [ADR-0003 — Longhorn on a single host: replicas guard VM/disk loss, not host loss](docs/adr/ADR-0003-longhorn-single-host-storage.md)
- [ADR-0004 — Sealed Secrets: the sealing key is a cluster-bound Plane 0 asset](docs/adr/ADR-0004-secrets-sealing-key.md)
- [ADR-0005 — Traefik + cert-manager DNS-01, cloudflared per-host cutover](docs/adr/ADR-0005-ingress-tls.md)
- [ADR-0006 — One public-default repo, render-time tokens + a two-layer gate](docs/adr/ADR-0006-exposure-model.md)
- [ADR-0007 — Self-scaffolded ArgoCD app-of-apps (bounded), not an adopted template](docs/adr/ADR-0007-gitops-tool.md)
- [ADR-0008 — Miniflux cutover: Postgres logical dump/restore, not a volume snapshot](docs/adr/ADR-0008-miniflux-postgres-logical-dump.md)
- [ADR-0009 — Vaultwarden cutover: CRITICAL, last, with a Bitwarden-Cloud availability fallback](docs/adr/ADR-0009-vaultwarden-critical-last.md)
- [ADR-0010 — n8n cutover: write-freeze + parallel run, encryption key sealed explicitly](docs/adr/ADR-0010-n8n-write-freeze-cutover.md)

One-line decision log: [`docs/DECISIONS.md`](docs/DECISIONS.md).

The **3-line rule:** an upgrade is a PR → one component at a time → app health green
before the next; rollback is `git revert` + reconcile — never an out-of-band
`kubectl rollout undo` (out-of-band drift is reverted by self-heal anyway). Version pins
live in one SSOT ([`versions.yaml`](versions.yaml)); the full upgrade/rollback procedure,
the differential policy (conservative on etcd/k3s, current on ArgoCD), and the
Renovate drift-PR setup are in the
[upgrade & rollback runbook](docs/runbooks/upgrade-rollback.md).

## Architecture diagrams

Logical names only (real addresses live in the git-ignored `internal/`); each has
committed source + exported SVG.

**Platform (C4 container view)** — the layer boundary, in-cluster planes, and
external services. Source: [`platform-c4-container.mmd`](docs/diagrams/platform-c4-container.mmd).

![Platform C4: layer boundary, in-cluster planes, external services](docs/diagrams/platform-c4-container.svg)

**GitOps bootstrap & sync-wave flow** — one manual `kubectl apply`, then sync
waves 0→3 and the steady-state reconcile/`git revert` loop. Source:
[`platform-gitops-flow.mmd`](docs/diagrams/platform-gitops-flow.mmd).

![GitOps bootstrap and sync-wave flow](docs/diagrams/platform-gitops-flow.svg)

## What was deliberately excluded

These are scoping decisions, not oversights — each names where the reasoning lives:

- **Hardware HA — software self-heal is real, host redundancy is not.** The cluster
  is three k3s node VMs, but all three run on **one Proxmox host with effectively one
  disk**. *Software*-level self-healing is proven live: a killed pod restarts to its
  replica count, a node-VM going down reschedules its pods onto a healthy node and
  Longhorn re-attaches the volume with data intact (≤5 min, NFR3), and a bad rollout
  is health-gate-held so the prior good version keeps serving. But a **host reboot /
  PSU / single-disk failure takes all three VMs — and all Longhorn replicas — down
  together**: one host is one failure domain, so this is *not* hardware HA. Durability
  against host loss is the off-host bare-metal restore chain (Gate 0), not replication.
  Full reasoning: [ADR-0003](docs/adr/ADR-0003-longhorn-single-host-storage.md).
- **An adopted GitOps scaffold (onedr0p / Flux + Talos).** Rejected in favour of a
  self-scaffolded, bounded app-of-apps so every layer is understood and owned, not
  inherited — sized to ~14 services, not a generic fleet.
  [ADR-0007](docs/adr/ADR-0007-gitops-tool.md).
- **A public/private mirror split.** One public-default repo kept safe by render-time
  token substitution and a two-layer gate — not by scrubbing a separate mirror, which
  rots and leaks on the first missed commit. [ADR-0006](docs/adr/ADR-0006-exposure-model.md).
- **ArgoCD self-management.** ArgoCD is bootstrapped manually and not yet managing its
  own upgrades via GitOps — deferred to Phase 2a to avoid a sync-wave self-destroy
  risk while the platform is still being stood up.
- **Full operational alerting.** Only the critical alert slice (NFR15a) is in scope to
  declare the platform done; version-drift and broader operational alerting (NFR15b)
  are explicit Phase-3 day-2 work.
- **Stateful & critical services.** Databases, the password vault, and other stateful
  apps move only after the pattern is proven and zero-data-loss cutovers exist — that
  cutover work is in progress, so only stateless services are reconciled here today.

---

## Deploy a service (the golden path)

Adding service #N is a copy-and-adapt, not a design exercise:

1. **Copy the template.** [`workloads/_template/`](workloads/_template/) is the
   golden path — `namespace` / `deployment` / `service` / `kustomization` /
   `application` (the ArgoCD `Application`) / `backup-cronjob` + a
   [`runbook.md`](workloads/_template/runbook.md) skeleton. Copy it to
   `workloads/<service>/` and fill in the blanks.
2. **Follow a worked example.** [`workloads/ytdlp-api/`](workloads/ytdlp-api/) is a
   real service migrated through that template, with its operations
   [runbook](docs/runbooks/ytdlp-api.md) (what it does → health check → if-DOWN →
   common failures → backup/restore → escalation).
3. **Know the bootstrap order.** [`bootstrap/README.md`](bootstrap/README.md) is the
   single manual entry point (`root-app.yaml`) and the exact provision → ArgoCD →
   `kubectl apply` → sync-wave sequence everything else reconciles from.

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
