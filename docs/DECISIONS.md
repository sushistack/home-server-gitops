# Decisions

Running log of load-bearing decisions. One line each; link the story.

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

## TLS / cert-manager (Story 1.5)

- **Phase 1 certs are NON-PRODUCTION and THROWAWAY.** The draw host (`${SECRET:DOMAIN_DRAW}`)
  is served from a `letsencrypt-staging` ClusterIssuer (LE staging + Cloudflare DNS-01). These certs are
  browser-untrusted (staging chains to a fake root) and, with the `excalidraw-tls` Secret and
  any sealing assets, **do NOT carry to the Phase 2a clean cluster** — Story 2.4 re-issues real
  DNS-01 **production** certs against a fresh ClusterIssuer on a new cluster. (AR8, AR9)
- **Staging → prod swap point** is `workloads/excalidraw/certificate.yaml` +
  `infra/cluster-issuer/clusterissuer.yaml`: promotion is a one-line ACME-URL swap
  (`acme-staging-v02` → `acme-v02`) plus least-privilege Cloudflare token scoping. Nothing
  structural changes — the DNS-01 solver shape proven here is the production shape. (AC2, Story 2.4)
- **Production Let's Encrypt is FORBIDDEN in Phase 1**: the wildcard for the public zone shares a
  weekly LE duplicate-certificate rate limit a repeatedly-rebuilt throwaway cluster would burn. (AR8)
- **Cloudflare DNS-01 token is a plain bootstrap Secret** (`cloudflare-dns01-token`, ns
  `cert-manager`), injected directly by Ansible — NOT a SealedSecret (Sealed Secrets does not
  exist in Phase 1; this avoids the bootstrap circular dependency). (AR4)
- **Phase 1 REUSES the existing OpenWrt DDNS Cloudflare token** (`cloudflare_ddns_api_token`,
  already scoped `DNS:Edit` on the public zone) rather than minting a dedicated one. Accepted
  blast-radius trade-off for a throwaway; **Story 2.4 issues a dedicated least-privilege token**
  for cert-manager when promoting to production. (NFR11)
