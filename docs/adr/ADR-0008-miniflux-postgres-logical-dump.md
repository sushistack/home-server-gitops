# ADR-0008: Miniflux cutover — Postgres logical dump/restore, not a volume snapshot

Affected services: miniflux (the only Postgres-backed service in the migration)

> Decision record. Back-reference: [README → Decision records](../../README.md#decision-records-adrs).

## Context

Miniflux is the **one** service whose durable state is a **PostgreSQL database**,
not a SQLite file (ntfy/navidrome/karakeep) or a file-class volume. Every other
Epic 4 cutover copies the data by moving *files* — `sqlite3 .backup` of a DB
file, or `tar`/`rsync` of a directory — and ingests them into a Longhorn PVC
([stateful-cutover.md](../runbooks/stateful-cutover.md) Step 3). Applying that
"copy the data dir" reflex to Postgres is wrong: rsyncing `/var/lib/postgresql`
between a Compose `postgres:18` and a freshly-`initdb`'d k3s `postgres:18` is
fragile to initdb/version/locale differences and torn pages, and it defeats the
reason this service was called out separately. The architecture is explicit:
"Postgres restore is `pg_dump`/logical, not a tar/volume snapshot." Built on the
TLS/cutover mechanism in [ADR-0005](ADR-0005-ingress-tls.md) and the stateful
machine + backup actor founded by Story 4.1 (ntfy).

## Decision

Treat miniflux's data move — both the recurring backup **and** the cutover
ingest — as **logical Postgres dump/restore over the network**:

- **Backup actor = `pg_dump -Fc` → R2**, not a file/volume copy. The
  `miniflux-backup` CronJob runs `pg_dump` as a **network client** against
  `miniflux-db.miniflux.svc.cluster.local:5432` and uploads the custom-format
  dump to `r2:homelab-k3s-services-backup/miniflux/`. Custom format (`-Fc`)
  enables selective `pg_restore`. `pg_dump` is **online-consistent via MVCC**, so
  — unlike the SQLite/file backups — there is **no quiesce, no scale-down, and no
  PVC mount / podAffinity** (the RWO multi-mount trap is file-specific and does
  not apply to a network dump).
- **Cutover ingest = `pg_dump` (live Compose) → `pg_restore` (k3s)**, NOT an
  rsync of the data dir. The k3s Postgres PVC still exists (Postgres needs durable
  storage) but is initialized **empty** and loaded **logically**.
- **Client major == server major (18).** The DB, the backup CronJob, and the
  one-shot restore Job are all `postgres:18` so the `pg_dump`/`pg_restore` client
  matches the server major — the AR29 carve-out keeps `postgres:18` as a major tag
  (not digest-pinned).
- **App + DB are one logical service in one namespace / one Application.** The app
  reaches the DB by **FQDN**, and the connection string `DATABASE_URL` lives in
  the `miniflux-secrets` **SealedSecret** (it carries the password — so it is
  secret-class, even though AC2 frames the FQDN as "config"); the FQDN host inside
  that URL satisfies the FQDN intent without leaking the password to a ConfigMap.
- **App egress is explicitly opened.** Miniflux is an RSS fetcher; the default-deny
  NetworkPolicy allows the **app** pod egress to 80/443 + DNS (the DB pod gets
  none, only ingress from the app/backup on 5432) — forgetting this silently stops
  feed refresh.

## Consequences

- The backup/restore path is **smaller and simpler than the SQLite one**: no node
  co-location, no scale-to-0, no `-wal`/`-shm` handling — just a network client
  and a credential. The trade is two new egress paths to keep open (DB:5432 for
  the dump, 80/443 for the rclone install + R2 upload).
- A **verified logical restore** (feeds/entries counts match source) is required
  once before close — recorded in [miniflux.md](../runbooks/miniflux.md).
- **Reversible:** Compose miniflux + miniflux-db stay **PARKED**; rollback is the
  cloudflared tunnel route for `${SECRET:DOMAIN_RSS}` flipped back to NPM (Compose never torn
  down — same machine as every Epic 4 cutover).
- Cutover ordering has a sharp edge: the app must **not** initialize the schema on
  an empty DB before the restore runs (`RUN_MIGRATIONS=1`). The restore uses
  `pg_restore --clean --if-exists` and the operator pauses the app during ingest —
  documented in `_cutover/restore-job.yaml` + the runbook.

## Rejected alternatives

- **rsync/tar of `/var/lib/postgresql` into the PVC** (the SQLite/file-class
  reflex). Fragile to initdb/version/locale/torn-page differences across two
  separately-initialized clusters; not application-consistent. Rejected — this is
  the entire reason miniflux is a distinct cutover.
- **Longhorn volume snapshot of the DB PVC** as the backup. A block snapshot of a
  live Postgres data dir is crash-consistent at best and version-coupled; a logical
  dump is portable, selectively restorable, and verifiable by row counts. Rejected.
- **Splitting `DATABASE_URL` into a ConfigMap host + a Secret password.** Buys
  nothing and risks drift between two sources of truth; the whole URL lives in the
  SealedSecret. Rejected (Reconciliation 2).
- **One namespace per component (separate app/db Applications).** Breaks the
  "one Application ↔ one logical service" rule — deploy/rollback/backup would no
  longer be scoped to the unit. Rejected.

## Exposure note

Safe to show publicly: the mechanism — logical `pg_dump`/`pg_restore`, why not a
volume snapshot, client/server major match, app+db in one namespace, FQDN-in-the-
SealedSecret, and the feed-fetch egress allow. Not shown: the real `rss.<zone>`
host (token `${SECRET:DOMAIN_RSS}` only), the DB password, or the R2 credential —
all sealed or render-time substituted. The exposure scan fails any real host, IP,
or secret pasted here.
