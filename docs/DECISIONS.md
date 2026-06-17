# Decisions

Running log of load-bearing decisions. One line each; link the story.

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
