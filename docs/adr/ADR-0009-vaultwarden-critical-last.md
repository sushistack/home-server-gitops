# ADR-0009: Vaultwarden cutover — CRITICAL, migrated last, with a Bitwarden-Cloud availability fallback

Affected services: vaultwarden (the password vault — the highest-criticality store in the migration)

> Decision record. Back-reference: [README → Decision records](../../README.md#decision-records-adrs).

## Context

Vaultwarden is the **password vault** — the single highest-stakes datastore in the
platform. Its durable state is **single-writer SQLite** (`db.sqlite3` + WAL), the
same class as ntfy/navidrome (SQLite `.backup`, not the Postgres logical dump of
[ADR-0008](ADR-0008-miniflux-postgres-logical-dump.md)). Mechanically the cutover is
identical to the other SQLite cutovers and to the n8n CRITICAL precedent (Story 4.7):
write-freeze → online `sqlite3 .backup` → ingest into a Longhorn PVC → verify →
flip the cloudflared route, with Compose kept running in parallel as the rollback.
What makes vaultwarden a distinct decision is **not** the mechanism but the
**risk posture**: a torn vault or a lost signing key is not a degraded feature, it
is every user locked out of every credential. Built on the stateful machine +
backup actor founded by Story 4.1 (ntfy) and the TLS/cutover mechanism in
[ADR-0005](ADR-0005-ingress-tls.md).

## Decision

Treat vaultwarden as the **last** cutover and harden the SQLite machine for the
highest-criticality data:

- **Migrate it last, after every other stateful service is `done` and verified.**
  The procedure is only allowed to touch the vault once it has been proven on six
  lower-stakes services (ntfy → navidrome → anytype → karakeep → miniflux → n8n).
  This is a hard ordering gate (AR36), not a preference — Vaultwarden going last
  also makes its dual-run drift window the shortest of any service.
- **`Recreate` + `terminationGracePeriodSeconds: 30` are non-negotiable.** Two pods
  on one SQLite WAL corrupts the vault (AR14); the grace period flushes the WAL
  checkpoint on shutdown (ports Compose `stop_grace_period: 30s`).
- **`rsa_key.pem`/`.pub` are carried as load-bearing data, not regenerated.** They
  are the JWT signing keys — re-initializing them forces every client/device to
  re-authenticate. They travel in the `/data` ingest **and** in every R2 backup
  bundle alongside `db.sqlite3`, `config.json`, `attachments/`, `sends/`
  (`icon_cache/` is the only regenerable dir, excluded). This is broader than the
  navidrome DB-only dump because, unlike a regenerable music library, **all** of
  vaultwarden's `/data` is durable.
- **`ADMIN_TOKEN` follows the dual-run secret rule (AC2 / AR24), no exception.**
  Unlike n8n — whose encryption key lives in a `data/n8n/config` file — vaultwarden's
  only app secret is a normal `.env` var, so the "origin = Compose `.env` during
  overlap; the SealedSecret is a verified copy until Compose retires (Story 5.4)"
  rule applies cleanly. Consumed `envFrom: secretRef` only (AR22).
- **Bitwarden-Cloud is an availability fallback, NOT a backup.** A one-way weekly
  mirror to Bitwarden Cloud lets a client switch its server URL for read access if
  `vault.<zone>` is down. It is ≤7 days stale; the R2 dumps (≤6h) remain the
  authoritative backup. It is surfaced only in the runbook escalation row.

## Consequences

- The online `sqlite3 .backup` + write-freeze **closes the Compose torn-snapshot
  gap by design** (the live Compose backup had `healthcheck: disable: true` and a
  historically-missing quiesce label → a hot `tar` could tear under write load,
  deferred-work.md:58-59). The k3s path is strictly safer — a genuine "why k3s is
  better here" point.
- A **verified restore** (R2 dump → scratch namespace → `select count(*)` matches
  source → real login) is required once before close — it is Vaultwarden's
  per-service entry in the project Definition of Done. Recorded in
  [vaultwarden.md](../runbooks/vaultwarden.md).
- **Reversible:** Compose vaultwarden + vaultwarden-backup stay **PARKED**; rollback
  is the cloudflared route for `${SECRET:DOMAIN_VAULTWARDEN}` flipped back to NPM
  within the pre-lowered TTL (Compose never torn down — same machine as every Epic 4
  cutover).
- The backup bundle is larger than a DB-only dump (it carries attachments/sends);
  attachments are typically small, but the retention/upload cost scales with them.

## Rejected alternatives

- **Migrate vaultwarden earlier / not last.** Rejected — the whole point is to move
  the highest-stakes data only after the procedure is proven on everything else (AR36).
- **DB-only backup (like navidrome).** Would drop `rsa_key.*`, `attachments/`,
  `sends/` — i.e. force mass re-auth and lose user files on restore. Rejected; all of
  `/data` (minus `icon_cache/`) is durable here.
- **Hot `tar`/`cp` of a live `db.sqlite3`** (the Compose sidecar's old behavior).
  Can tear mid-WAL. Rejected in favor of the online lock-safe `sqlite3 .backup`.
- **Treat Bitwarden-Cloud as the backup** and skip R2 dumps. Rejected — it is a
  stale, one-way availability mirror, not a restorable, fresh, integrity-checked backup.
- **`RollingUpdate` to avoid a brief outage on deploy.** Rejected outright — two
  pods on the vault's WAL is the named corruption anti-pattern (AR14).

## Exposure note

Safe to show publicly: the mechanism — SQLite `.backup` + write-freeze, last-by-design
ordering, the `rsa_key` carry, the dual-run `ADMIN_TOKEN` rule, and the Bitwarden-Cloud
availability fallback. Not shown: the real `vault.<zone>` host (token
`${SECRET:DOMAIN_VAULTWARDEN}` only), the `ADMIN_TOKEN`, or the R2 credential — all
sealed or render-time substituted. The exposure scan fails any real host, IP, or secret
pasted here.
