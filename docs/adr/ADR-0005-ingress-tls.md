# ADR-0005: Traefik + cert-manager DNS-01, cloudflared per-host cutover

Affected services: all (every host served over TLS) — plus the Anytype non-HTTP exception

> Decision record. Back-reference: [README → Decision records](../../README.md#decision-records-adrs).

## Context

Every public service needs HTTPS, and the public zone is a **wildcard
`*.<zone>`** served behind a single Cloudflare tunnel. Two facts constrain the
choice. First, an ACME **HTTP-01** challenge proves control of one hostname by
serving a token over port 80 — it **cannot issue a wildcard**, because there is
no single host to answer for `*`. Only **DNS-01** (prove control of the zone by
writing a TXT record) can. Second, the migration is incremental: the old
reverse proxy (NPM) keeps serving most of `*.<zone>` while services move to k3s
one at a time, so the public edge must be able to route **per host** to either
the old proxy or the new cluster. A flag-day cutover of all ~14 services at once
is exactly the blast radius this migration is built to avoid. See
[ADR-0001](ADR-0001-why-compose-to-k3s.md) for the top-level Compose → k3s
decision this builds on.

## Decision

Serve in-cluster ingress with **Traefik (k3s-bundled, `traefik.io/v1alpha1`
API) + cert-manager issuing via Cloudflare DNS-01**, and keep **cloudflared as
the public entry with per-host cutover**:

- **Traefik is owned by k3s** (installed via its bundled HelmChart CR), so
  **ArgoCD does NOT manage Traefik** — putting it under app-of-apps would fight
  k3s for ownership of the same resource. ArgoCD manages the `IngressRoute`s and
  cert-manager, not the proxy itself.
- **cert-manager + Cloudflare DNS-01** issues certs; DNS-01 is mandatory because
  it is the only challenge type that can mint the wildcard. The Cloudflare token
  is **least-privilege scoped** to the DNS-01 zone and injected by Ansible as a
  plain bootstrap Secret (see [ADR-0004](ADR-0004-secrets-sealing-key.md) for why
  bootstrap creds are not sealed).
- **cloudflared stays the public entry**, routing **per host**: only the
  cut-over host points at Traefik while the rest of `*.<zone>` stays on NPM,
  flipped service-by-service. This is the cutover switch — one host at a time,
  each independently revertible.
- **Anytype is the documented exception:** it is **not HTTP** (raw TCP + QUIC/UDP),
  so it needs `IngressRouteTCP` + `IngressRouteUDP` on dedicated entryPoints —
  an HTTP `IngressRoute` cannot serve it. This is the one hand-written deviation
  from the golden-path template.

## Consequences

- **Proven in production (Epic 2, Story 2.4).** Phase 1 used a throwaway
  `letsencrypt-staging` issuer (browser-untrusted); Story 2.4 promoted to **real
  Let's Encrypt production DNS-01** on the Phase 2a cluster. The promotion was a
  one-line ACME-URL swap (`acme-staging-v02` → `acme-v02`) plus the dedicated
  least-privilege token — the DNS-01 solver *shape* proven in staging was the
  production shape, so nothing structural changed.
- The wildcard cert is scoped to **single-label hosts** (`<svc>.<zone>`), and one
  shared `Secret` (`excalidraw-tls`) backs every single-label Epic 3/4 cutover
  host — lowest Let's Encrypt duplicate-certificate rate-limit pressure on a
  cluster that may be rebuilt.
- LAN clients hit a node IP directly (real LE cert, Traefik klipper-lb answers on
  every node IP); internet clients traverse CF edge → tunnel → origin with origin
  TLS verify **ON** (`originServerName` set) now that the cert is publicly trusted.
- `IngressRoute` uses `apiVersion: traefik.io/v1alpha1` — the old
  `traefik.containo.us` group is removed in Traefik v3, and the wrong group
  fails silently.
- A single origin node IP behind the tunnel is a SPOF; compute self-heal across
  nodes is [ADR-0003](ADR-0003-longhorn-single-host-storage.md) / Story 2.5, but
  the single physical host remains the hard ceiling.

## Rejected alternatives

- **ACME HTTP-01.** Cannot issue the wildcard `*.<zone>` — there is no single
  host to answer for `*`, and per-host certs for ~14 services multiply rate-limit
  and rotation surface. Rejected.
- **ingress-nginx (or any non-bundled ingress).** k3s already ships Traefik; a
  second ingress controller is operational weight and an ownership fight for no
  gain on a single-operator homelab. Rejected.
- **ArgoCD-managed Traefik.** k3s owns Traefik via a HelmChart CR; having ArgoCD
  also reconcile it produces a two-writer conflict on the same resource. Rejected
  — ArgoCD manages routes and cert-manager, never the proxy.
- **Flag-day cutover (all hosts to Traefik at once).** Maximum blast radius, no
  per-service revert. The per-host cloudflared split exists precisely to avoid it.
  Rejected.

## Exposure note

Safe to show publicly: the mechanism — Traefik + cert-manager, **why DNS-01**
(wildcard), cloudflared per-host cutover, the Anytype TCP/UDP exception, and the
staging→prod promotion shape. Not shown: the real wildcard domain or any
`<svc>.<zone>` host (tokens `${SECRET:DOMAIN_*}` only), node IPs, or the
Cloudflare token — all live in the git-ignored `internal/` and are render-time
substituted. The exposure scan fails any real host or IP pasted into this ADR or
a diagram label.
