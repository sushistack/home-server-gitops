# Runbook: the stateful cutover machine

> 🏁 **HISTORICAL (Compose retired 2026-06-19, Story 5.4).** All Epic 4 cutovers are complete and
> **k3s is the sole production path.** The "Compose is the rollback" invariant below **no longer
> applies** — the Compose stack has been decommissioned, so there is nothing to flip back to.
> Present-day recovery is **k3s-native**: restore the per-service R2 dump
> (`homelab-k3s-services-backup/<service>/`) into a scratch namespace, or `git revert` the bad
> manifest commit and let ArgoCD re-sync. This doc is kept as the **record of how the migration was
> done** (the quiesce → verify → flip machine), not as a live rollback procedure. See
> [DECISIONS.md](../DECISIONS.md).

> The **reusable** quiesce → copy → verify → flip → rollback procedure for moving a
> stateful Compose service to k3s with **zero data loss**. Authored in Story 4.1; ntfy
> is its first worked instance (inline below). Stories 4.3–4.8 **copy this doc**, not
> reinvent steps. Service-parameterized on `<service>` / `<host>` / `<db-paths>` / `<ns>`.

**Invariant that made rollback free (cutover era — Compose now retired):** Compose was **never
stopped** during a cutover. The live Compose service kept serving its own volume the whole time; the
only switch was the per-host cloudflared route. "Ingress is the switch; Compose is the rollback."
held *during the migration* — it no longer does (Compose retired 2026-06-19). (FR4, NFR2)

**Hard entry gates (both must be `done` before ANY stateful cutover):** Epic 2 fully done
(multi-node, Longhorn, Sealed Secrets, **prod DNS-01 TLS**, **Gate 0**) **and** the Epic 3
Story 3.4 Validation Gate with no open "would lose data" finding. (epics.md Epic 4 entry; AR10/AR11)

---

## Pre-flight checklist (do not skip a line)

1. **Both entry gates green** (above). If 3.4 is not `done`, STOP.
2. **`home-server-gitops` manifests merged + ArgoCD `Synced`/`Healthy`** for `<service>`
   (Deployment, Service, PVC, ConfigMap, IngressRoute, Certificate, backup CronJob).
3. **PVC bound** — `kubectl get pvc -n <ns> <service>-data` → `Bound`.
4. **Backup actor has succeeded once** — trigger the CronJob and confirm an archive lands in
   `r2:homelab-k3s-services-backup/<service>/` **before** touching any data. This is the in-cutover
   fallback: if anything corrupts mid-move, you restore from this archive.
5. **Rollback path confirmed.** The house flip is a **cloudflared tunnel-ingress config push**
   (re-point the rule in the tunnel config) — near-instant, **no DNS TTL involved**, so there is
   nothing to pre-lower. *Only* if a `<host>` is fronted by a real DNS A/CNAME record (not the
   tunnel): pre-lower that record's TTL to the rollback window and wait out the old TTL first.
6. **Window announced** — the SLO is **≤10 min** of planned low-use disruption (NFR1).
7. **Render token registered** — the public host token (e.g. `DOMAIN_NTFY`) is present in the
   out-of-band `argocd-render-tokens` Secret **and** local `internal/tokens.env`, or the
   IngressRoute/Certificate render to a broken literal.

---

## The 6-step machine

### Step 1 — Confirm the rollback path (TTL only if it's a real DNS flip)
The house flip is a **cloudflared tunnel-ingress config push** — re-pointing the tunnel rule takes
effect in seconds, so rollback latency is the push propagation, **not** a DNS TTL, and there is
nothing to pre-lower. Only if `<host>` is served by a real DNS A/CNAME record (not the tunnel):
lower that record's TTL to the rollback window and **wait out the previous TTL** before flipping.

### Step 2 — Quiesce the source (online, lock-safe — NO `docker stop`, NO scale-down)
Take an **application-consistent online copy** from the **live Compose** service. The method is
by data class (this is the only step that differs per service):

| Data class | Quiesce command (run against the live Compose container/volume) |
|---|---|
| **SQLite** | `sqlite3 <db> ".backup <out>"` — lock-safe online backup; **no stop needed** (AR17) |
| **Postgres** | `pg_dump`/`pg_dumpall` → SQL file (4.6 miniflux) |
| **File-class / snapshot** | `tar`/`rsync` the volume; brief quiesce if the app writes non-atomically (4.3 navidrome media) |
| **BadgerDB / non-quiescent** | app-specific quiesce or stop-the-world snapshot (4.4 anytype) |

> SQLite online `.backup` is safe **while the source is serving** — that is why SQLite services
> get **no scale-to-0 and no Role** (architecture.md 636–640). Only file-class services that can't
> copy hot get a brief quiesce.

> **Note — cutover copy ≠ ongoing R2 backup.** The one-time cutover moves *all* of a service's data
> (incl. its media) to the Longhorn PVC. The recurring R2 backup CronJob is narrower — see
> "Backup scope" below: bulk media is **not** shipped to R2.

### Step 3 — Ingest the consistent copy into the Longhorn PVC (one-shot Job + rsync)
Apply the **throwaway** ingest Job (`workloads/<service>/_cutover/ingest-job.yaml`) — it mounts the
`<service>-data` PVC, receives the consistent copy from Step 2 (`kubectl cp` / rsync into the PVC),
and exits. **Keep it out of the ApplicationSet path** (not listed in `kustomization.yaml`) or ArgoCD
will fight you. `// the ingest Job is scaffolding — apply by hand, delete after.`

### Step 4 — Bring up the k3s pod against the populated PVC
The steady-state Deployment (1 replica, `strategy: Recreate`, `terminationGracePeriodSeconds: 30`
for the WAL-checkpoint flush — AR14) starts against the now-populated PVC and reaches `Ready`.

### Step 5 — VERIFY before any traffic flip
Prove the data survived **in-cluster, before** the public switch:
- durable-state row/byte count on k3s **==** source (the one 0-loss proof);
- `<health endpoint>` returns 200;
- an app-level round-trip works against the k3s pod (in-cluster, e.g. `kubectl run curl …`).

If verify fails: **do nothing to traffic.** Compose is still authoritative. Fix and re-ingest.

### Step 6 — Flip the per-host cloudflared route (the cutover switch)
Re-point the `<host>` cloudflared ingress rule **NPM → Traefik** (`https://<node>:443`,
`originServerName=<host>`, real LE-prod origin cert — same shape as the draw route, Story 2.4).
Confirm 200 from the public host and that downstream callers still work.

---

## Rollback — HISTORICAL (Compose retired 2026-06-19)

> During the Epic 4 cutovers, rollback was free because **Compose was never stopped**: flip the
> `<host>` cloudflared route back to NPM and resolvers returned to the still-serving Compose volume.
> That path **no longer exists** — Compose is decommissioned (Story 5.4). The text below is the
> historical record of the cutover-era rollback.
>
> **Present-day recovery (k3s is the sole production path):** there is no flip-back. Recover with
> k3s-native means — restore the per-service R2 dump (`homelab-k3s-services-backup/<service>/`) into a
> scratch namespace and verify, or `git revert` the offending manifest commit and let ArgoCD re-sync.

Compose was never stopped, so **there was nothing to restore**. To roll back (cutover era):

1. Flip the `<host>` cloudflared route **back to NPM** (Compose).
2. Within the pre-lowered TTL window, resolvers return to Compose; it is still serving its own
   live volume. Zero data reconstruction.

**Max rollback latency** = the cloudflared tunnel-config push propagation (seconds) for the house
tunnel flip, or the pre-lowered DNS TTL from Step 1 if `<host>` uses a real DNS record. (AC2, FR4, NFR2)

---

## Post-cutover 0-loss check (record the numbers)

- Re-count the durable state live on k3s; assert **== source** (record both counts).
- Confirm the planned window held **≤10 min** and there were **no non-window 5xx** on `<host>`.
- Confirm the backup CronJob still succeeds against the k3s PVC (the actor co-locates with the
  pod — see "the RWO multi-mount trap" below).

---

## The RWO multi-mount trap (every DB-class backup inherits this)

The `<service>-data` PVC is **RWO** — Longhorn attaches it to **one node**, held by the running
pod. A backup CronJob pod that mounts the same PVC on a **different** node fails with
`Multi-Attach error`. **House pattern (operator-confirmed 2026-06-18):** co-schedule the CronJob
onto the pod's node via `podAffinity` (`app.kubernetes.io/name: <service>`,
`topologyKey: kubernetes.io/hostname`), mount the PVC **read-write** (online `.backup` needs the
`-wal`/`-shm` files), and write the dump to an `emptyDir` `/scratch` — **never** back onto `/data`.
Do **not** scale the app to 0. (architecture.md 636–640; AR14/AR17)

---

## Backup scope — what goes to R2 (and what does NOT)

The per-service backup CronJob ships only the **small, durable, hard-to-reproduce state** to R2 —
databases + config (ntfy `auth.db`, navidrome `navidrome.db`, miniflux `pg_dump`, karakeep's DB).

**Bulk media is EXCLUDED from R2 by design** — music, video, photos, large bookmarked assets are
**not** pushed to the cloud:
- shipping 100s of GB every cycle is slow + costly, and the media is usually reproducible or
  sourced elsewhere;
- it stays protected by **Longhorn replication** (multi-node copies) for availability;
- if it genuinely needs a backup, that's a **separate, local/cold, low-frequency** job — never the
  ≤6 h per-service R2 CronJob.

Mechanism: the CronJob only mounts/dumps the **DB + config** paths and simply does not touch the
media volume. e.g. **navidrome (4.3)** backs up `navidrome.db` (playlists / play counts / users /
annotations) to R2 and leaves the music library on Longhorn. The dedicated services bucket
(`homelab-k3s-services-backup`) therefore stays tiny — DB dumps, not media.

---

## TLS per cutover (host cert, not a shared wildcard)

Each workload issues its **own per-host** Certificate (`<service>-tls`, dnsName `<host>`) from the
`letsencrypt-prod` DNS-01 ClusterIssuer into its **own namespace**. We do **not** share
excalidraw's wildcard Secret across namespaces — Traefik cross-namespace `secretName` needs
`allowCrossNamespace=true` (non-default, discouraged), and 7 duplicate wildcard issuances would
burn the LE 5-duplicates/week limit on a rebuild. A per-host cert is self-contained, GitOps-native,
and distinct (no duplicate-limit collision). `// ponytail: per-host cert is the copyable default;
switch to a shared wildcard + reflector only if issuance volume ever bites.`

---

## Worked instance: ntfy (Story 4.1 — the lowest-risk reference)

| Machine slot | ntfy value |
|---|---|
| `<service>` / `<ns>` | `ntfy` / `ntfy` |
| `<host>` | `${SECRET:DOMAIN_NTFY}` (rendered at sync; `notify.<public-zone>`) |
| `<db-paths>` | `/var/cache/ntfy/auth.db` (**durable**) + `/var/cache/ntfy/cache.db` (transient, 12h TTL) |
| Data class | SQLite → `sqlite3 .backup` (both DBs), no stop |
| Durable-state 0-loss proof | `auth.db` user/token/ACL row counts k3s == source |
| Health | `curl -fsS https://<host>/v1/health` → `{"healthy":true}` |

- **Step 2:** `sqlite3 /var/cache/ntfy/auth.db ".backup /tmp/auth.db"` and same for `cache.db`,
  run against the live Compose `ntfy` container (`docker exec`). Both DBs for a consistent pair.
- **Step 3:** `kubectl -n ntfy cp` the two `.backup` files into the PVC via the ingest Job
  (`workloads/ntfy/_cutover/ingest-job.yaml`).
- **Step 5 verify:** in the k3s pod, `sqlite3 /var/cache/ntfy/auth.db "select count(*) from user;"`
  (and tokens/ACLs) must equal the source counts; `/v1/health` 200; publish→subscribe round-trips.
- **cache.db is transient:** losing ≤12h of cached push messages is acceptable; the 0-loss
  assertion is **only** about `auth.db` (users/tokens/ACLs). cache.db divergence in-window is benign.
- **Backup actor:** `workloads/ntfy/backup-cronjob.yaml` (`ntfy-backup`, ≤6h) replaces the Compose
  `offen/docker-volume-backup` sidecar → `r2:homelab-k3s-services-backup/ntfy/`.
- **Rollback (cutover era — no longer available):** flip `<host>` cloudflared back to NPM; Compose
  ntfy still served its SQLite. Compose retired 2026-06-19 → recovery is now R2 restore / `git revert`.

> **Chicken-and-egg:** ntfy is the alert channel for Story 4.2. Until 4.2 lands, there is **no
> alert on ntfy's own failure** — watch the cutover manually. (epics.md Story 4.2)
