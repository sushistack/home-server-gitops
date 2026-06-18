# Decisions

Running log of load-bearing decisions. One line each; link the story.

## ytdlp-api migration (Story 3.1)

- 2026-06-18 | ytdlp-api deployed to k3s (golden-path proof: `_template/` copy → ApplicationSet →
  own namespace → internal-only ClusterIP → runbook → CI gates); Compose **PARKED not
  decommissioned** — functional decommission blocked on navidrome cutover (Story 4.3) + n8n
  cutover (Epic 4); `/downloads` is `emptyDir` scratch until the real music volume is wired at 4.3.
  Exposed internal-only (no IngressRoute) per Reconciliation 1. | no ADR
- 2026-06-18 | Found: **no cluster NetworkPolicy baseline exists** (`kubectl get netpol -A` → none);
  AC2's `infra/network-baseline/` (same-ns allow + DNS-egress :53) is unbuilt platform-wide.
  Recorded as a gap (Operator-confirmed) — NOT created inside this single-service story. ytdlp-api
  runs under k3s allow-all today; when the baseline lands it must select ns `ytdlp-api` with the
  DNS-egress allow or downloads break silently. | no ADR

## Disaster Recovery — Gate 0 (Story 2.6)

Affected services: the whole platform (the recovery chain underneath every service).
Exposure note: safe to show — the chain, the ≤1-step claim, and the result. No key
material, IP, or `*.<zone>` host appears; Plane 0 secrets stay off-repo.

- **Gate 0 PASSED on 2026-06-18 — the full bare-metal chain was proven once on
  throwaway dummy data.** VM re-provision → k3s re-bootstrap (etcd quorum=3) →
  sealing-key restore → ArgoCD root-app → Longhorn PV restore from R2 →
  **byte-level integrity (sha256) PASS**, and the restored sealing key
  (`adopted`, not regenerated) decrypted a pre-loss SealedSecret again. Runbook:
  [`docs/runbooks/bare-metal-recovery.md`](runbooks/bare-metal-recovery.md). (FR20, FR21, FR23, NFR6, NFR7)
- **No stateful service may cut over (Epic 4) until this chain has passed — it now has.**
  This was the gate; it is open. Future drills are **PV-restore-only, quarterly** —
  never the full bare-metal teardown again, because after Epic 4 the cluster holds
  real data. The one safe window for the destructive full drill was Gate 0 (no real
  data yet). (AR10)
- **Gate 0 scope = infra + Longhorn PV + the cluster-bound sealing key ONLY.** The
  data leg was a Longhorn-native backup of a *dummy* PVC to R2 (file-class,
  crash-consistent) — **no dependency on the per-service quiesce/backup actor**
  (that is Epic 4, a different mechanism for app-consistent dumps). This overrides
  the architecture's "Gate 0 depends on the quiesce actor" line. (AR10, AR12, epics Story 2.6 AC3)
- **Manual-step count, honest (NFR7):** steady-state cold boot = **1 step**
  (`kubectl apply -f bootstrap/root-app.yaml`). Full bare-metal = **2 load-bearing
  manual steps** — the sealing-key restore must precede root-app, and is
  deliberately NOT automated (automating it would put the age identity on-cluster,
  defeating the OOB Plane-0 design). VM provision + Ansible are scripted. (NFR7)
- **Sealing-key export is age key-based, not passphrase.** Re-exported during the
  drill encrypted to the operator's existing age recipient (`age1chmmudv…`), so
  restore is non-interactive (`age -d -i keys.txt`) and round-trip-verified against
  the live key before teardown. The old passphrase-based export is superseded.
  The age **identity file** is now a Plane 0 asset — keep it off-host + backed up. (AR12)
- **Nodes renamed `k3s-2a-1/2/3` → `k3s-cp-1/2/3`** during the rebuild. All three
  stay **control-plane + etcd + worker** (`cp` = control-plane, quorum=3): a
  descriptive `control-plane`/`worker-N` split would imply quorum=1 and lose
  control-plane HA at 3-node scale. (AR9)

## Secrets / Sealed Secrets (Story 2.3)

- **Sealing key is cluster-bound → Phase 1 sealed assets are undecryptable here.** Every
  SealedSecret is sealed against THIS Phase 2a cluster's public cert; the private key lives in
  etcd, not on a PV. Phase 1 held no real secrets (Excalidraw stateless), so nothing carries over
  — documented boundary, not a bug. ([ADR-0004](adr/ADR-0004-secrets-sealing-key.md), AR9)
- **Sealing key = Plane 0, exported OOB, age-encrypted, off-host.** It is NOT in Longhorn PV
  backups (etcd object); losing it makes every SealedSecret permanently undecryptable. The export
  is what Gate 0 (Story 2.6) restores. Export ALL keys, re-export on rotation. (AR12)
- **Bootstrap-vs-workload split.** Only **workload** secrets flow through Sealed Secrets; bootstrap
  creds (ArgoCD repo access, Cloudflare DNS-01 token) are **Ansible-injected plain Secrets** —
  keeping them out avoids the bootstrap circular dependency. (AR4)
- **Consumption is `envFrom: secretRef` only; no `namePrefix`/`commonLabels`.** Inline `${VAR}`/
  `valueFrom` re-introduce the Compose empty-overwrite trap; name rewriting breaks the seal's
  exact `namespace/name` binding. Controller v0.37.0 / chart 2.18.6, wave 0. (AR22, AR27, AR6)

## Storage / Longhorn (Story 2.2)

- **Longhorn v1.12.0, V1 data engine pinned explicitly** (`defaultDataEngine: v1`) — V2 went
  *GA* in v1.12.0, so an unset engine risks landing on V2. Default StorageClass, `Retain`,
  3 replicas. ([ADR-0003](adr/ADR-0003-longhorn-single-host-storage.md), AR6)
- **Single-host SPOF stated honestly, not hidden.** 3 VMs on 1 Proxmox host with 1 disk →
  replicas guard VM/disk loss + pod mobility, **NOT host loss** (one failure domain). Host-loss
  durability is the Gate-0 restore chain (Story 2.6), not replication. (AR13)
- **`local-path` un-defaulted at bootstrap** so `longhorn` is the sole default (two defaults =
  binding error); patched in the Ansible host layer so it survives a clean rebuild. (AR15)
- **Vendor chart = Helm `source`, wave 0, `ServerSideApply=true`** (large CRDs); not mirrored,
  not Kustomized — same pattern as cert-manager. (AR1, AR3, AR7)

## Documentation-as-product (Story 1.6)

- **Two seed ADRs against the fixed template** ([ADR-0001](adr/ADR-0001-why-compose-to-k3s.md)
  Compose → k3s; [ADR-0002](adr/ADR-0002-excalidraw-phase1-pilot.md) Excalidraw as the
  throwaway Phase-1 pilot). Template is frozen — Context / Decision / Consequences /
  Rejected alternatives / Exposure note + `Affected services:` — because ≥15 ADRs will
  use it and retemplating is expensive. (AR33)
- **ADR↔README links are bidirectional, enforced by `adr-link-check` CI**
  (`bin/adr-link-check`, a repo-local script — no link-checker dependency). The CI triad
  is now exposure-scan + manifest-lint + adr-link-check. (AR37)
- **Diagrams: commit BOTH Mermaid source AND exported SVG; PNG forbidden.** Role-based
  logical names only — the SVG text is scanner-readable, raster is not. (AR35)
- **README first screen is fixed-shape and first-class:** one sentence → before/after
  diagram → demo clip → ADR links, with a first-class "what was deliberately excluded"
  section. Not an end-of-project chore. (FR30, FR31)

## TLS / cert-manager — PRODUCTION promotion (Story 2.4)

- **TLS is now PRODUCTION Cloudflare DNS-01 on the Phase 2a cluster.** The 1.5 staging issuer
  was the rehearsal; the swap point fired exactly as designed — a one-line ACME-URL change
  (`acme-staging-v02` → `acme-v02`) plus a fresh prod account key, on the SAME DNS-01 Cloudflare
  solver. ClusterIssuer is now `letsencrypt-prod`; the staging issuer was pruned (ArgoCD
  `prune: true`). (FR12, AR19, NFR10)
- **One wildcard `*.<public zone>` Certificate, not per-host.** DNS-01 issues wildcards natively
  (HTTP-01 cannot — this is *why* DNS-01 is mandated). One production issuance covers draw today
  and every *single-label* Epic 3/4 cutover host via the same `excalidraw-tls` Secret — lowest LE
  rate-limit pressure as services migrate. Browser-trusted (ISRG root), `CN=*.<zone>`, 90-day leaf.
  Caveat: `*.<zone>` covers exactly one label — the apex `<zone>` and nested `a.b.<zone>` hosts are
  NOT covered and would need their own SAN/cert. (AR19, AR26)
- **Cloudflare token finalized to a DEDICATED least-privilege token.** Minted fresh, scoped
  exactly `Zone:DNS:Edit` on the public zone only (no account perms, no other zones) — replaces
  the DDNS token 1.5 reused. Still an Ansible-injected plain bootstrap Secret
  (`cloudflare-dns01-token`, ns `cert-manager`), never sealed, never in Git. (NFR11, AR4)
- **Renewal is automatic, no manual handling.** cert-manager default `renewBefore` (~2/3 of the
  90-day leaf) → auto-renews ~30 days before expiry. Proven now via a forced `cmctl renew`: a fresh
  cert (new serial) re-issued and re-served with the old Secret held Ready throughout (no outage,
  zero manual cert steps). Cert-expiry *alerting* (ntfy) is out of scope — Epic 4 / Story 4.2. (NFR10)
- **cloudflared tunnel origin repointed to the Phase 2a node + origin TLS verify ON.** The 1.5
  origin (`https://<phase1-node>:443`, No-TLS-Verify ON for the untrusted staging cert) pointed at
  the now-dead Phase 1 node → CF edge 502. Repointed to a Phase 2a node's `:443` (Traefik
  klipper-lb answers on every node IP), **No-TLS-Verify OFF** + `originServerName: <draw host>`
  now that the origin cert is real and publicly trusted.
  LAN clients hit the node directly (real LE cert); internet clients via CF edge → tunnel → origin.
  Single node IP is a SPOF (HA is Story 2.5). (operator step, AR19)

## TLS / cert-manager (Story 1.5)

- **Phase 1 certs were NON-PRODUCTION and THROWAWAY.** (Superseded by the Story 2.4 promotion
  above; kept as the historical Phase-1 record.) The draw host (`${SECRET:DOMAIN_DRAW}`)
  was served from a `letsencrypt-staging` ClusterIssuer (LE staging + Cloudflare DNS-01). Those certs were
  browser-untrusted (staging chains to a fake root) and, with the `excalidraw-tls` Secret and
  any sealing assets, **did NOT carry to the Phase 2a clean cluster** — Story 2.4 re-issued real
  DNS-01 **production** certs against a fresh ClusterIssuer on a new cluster. (AR8, AR9)
- **Staging → prod swap point** is `workloads/excalidraw/certificate.yaml` +
  `infra/cluster-issuer/clusterissuer.yaml`: promotion is a one-line ACME-URL swap
  (`acme-staging-v02` → `acme-v02`) plus least-privilege Cloudflare token scoping. Nothing
  structural changes — the DNS-01 solver shape proven here is the production shape. (AC2, Story 2.4)
  **→ DONE: the swap fired in Story 2.4 (see the PRODUCTION promotion section above).**
- **Production Let's Encrypt is FORBIDDEN in Phase 1**: the wildcard for the public zone shares a
  weekly LE duplicate-certificate rate limit a repeatedly-rebuilt throwaway cluster would burn. (AR8)
- **Cloudflare DNS-01 token is a plain bootstrap Secret** (`cloudflare-dns01-token`, ns
  `cert-manager`), injected directly by Ansible — NOT a SealedSecret (Sealed Secrets does not
  exist in Phase 1; this avoids the bootstrap circular dependency). (AR4)
- **Phase 1 REUSES the existing OpenWrt DDNS Cloudflare token** (`cloudflare_ddns_api_token`,
  already scoped `DNS:Edit` on the public zone) rather than minting a dedicated one. Accepted
  blast-radius trade-off for a throwaway; **Story 2.4 issues a dedicated least-privilege token**
  for cert-manager when promoting to production. (NFR11)

## Cross-cutting ADR set completed (Story 3.2)

- **The cross-cutting ADR set is now complete (6 decision-unit ADRs).** Added
  the three remaining cross-cutting records against the fixed template; the set
  is `why-compose-to-k3s` ([ADR-0001](adr/ADR-0001-why-compose-to-k3s.md)),
  `storage` ([ADR-0003](adr/ADR-0003-longhorn-single-host-storage.md)),
  `secrets` ([ADR-0004](adr/ADR-0004-secrets-sealing-key.md)),
  `ingress-tls` ([ADR-0005](adr/ADR-0005-ingress-tls.md)),
  `exposure-model` ([ADR-0006](adr/ADR-0006-exposure-model.md)),
  `gitops-tool` ([ADR-0007](adr/ADR-0007-gitops-tool.md)). The excalidraw
  service ADR ([ADR-0002](adr/ADR-0002-excalidraw-phase1-pilot.md)) is separate
  (decision-unit, not service-unit). No ceremony per-service ADR added. (AR33, FR31)
- **Platform diagrams added (source + SVG).** `platform-c4-container` (layer
  boundary + in-cluster planes + external services) and `platform-gitops-flow`
  (bootstrap → sync waves 0→3 → reconcile loop), adapted from architecture.md's
  Mermaid. Logical names only; PNG forbidden, orphan SVG forbidden. (AR35)
