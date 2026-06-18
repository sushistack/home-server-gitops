# Runbook: miniflux (RSS reader — the one Postgres-backed service)

> Story 4.6. App (`miniflux`) + DB (`miniflux-db`) are ONE logical service in the `miniflux`
> namespace / one ArgoCD Application. Backup/restore is **logical `pg_dump`/`pg_restore`**, NOT a
> tar/volume snapshot. Cutover follows [stateful-cutover.md](stateful-cutover.md), Postgres variant.

## What it does

Self-hosted RSS/Atom reader at the public host `${SECRET:DOMAIN_RSS}`. Stores feeds, entries,
read/unread state, and the admin user in Postgres. Two components:

- **`miniflux`** (app) — single stateless Go binary, container port `8080`. Fetches feeds outbound
  over HTTP/HTTPS on a schedule (this is why the NetworkPolicy must allow egress 80/443 — see Common
  failures). Reaches the DB by FQDN `miniflux-db.miniflux.svc.cluster.local:5432` via `DATABASE_URL`
  (in the `miniflux-secrets` SealedSecret).
- **`miniflux-db`** (Postgres 18) — `strategy: Recreate` + `terminationGracePeriodSeconds: 30` on its
  RWO Longhorn PVC `miniflux-db-data` (single-writer-on-one-PGDATA; never two postgres on one data
  dir). Internal-only ClusterIP, no IngressRoute — never publicly exposed.

All durable state is in Postgres; the app pod holds nothing. `RUN_MIGRATIONS=1` (idempotent schema
migration on boot), `CREATE_ADMIN=0` (admin lives in the restored DB — must not be recreated).

## Health check (exact command → expected output)

```sh
# Public (post-cutover):
curl -fsS -o /dev/null -w '%{http_code}\n' https://${SECRET:DOMAIN_RSS}/healthcheck      # -> 200

# In-cluster app health (ports the Compose `miniflux -healthcheck auto`):
kubectl -n miniflux exec deploy/miniflux -- /usr/bin/miniflux -healthcheck auto # -> "OK"

# DB liveness (ports the Compose `pg_isready`):
kubectl -n miniflux exec deploy/miniflux-db -- pg_isready -U miniflux -d miniflux  # -> "... accepting connections"

# ArgoCD:
kubectl -n argocd get applications.argoproj.io miniflux \
  -o jsonpath='{.status.sync.status}/{.status.health.status}{"\n"}'             # -> Synced/Healthy
```

## If DOWN do this (in order)

1. **App pod not Ready?** `kubectl -n miniflux describe pod -l app.kubernetes.io/name=miniflux`.
   On boot the app connects to Postgres + runs migrations; the `startupProbe` (30×5s) covers that.
   If it crash-loops on DB connection, check the DB first (step 2) — the app retries with backoff.
2. **DB pod not Ready?** `kubectl -n miniflux logs deploy/miniflux-db`. RWO PVC: if the pod is
   `Pending` with a volume/attach error, the Longhorn volume is still attached to a dead node —
   confirm only one `miniflux-db` pod exists (`Recreate` guarantees this) and let it reschedule.
3. **`DATABASE_URL` / password wrong?** App logs show auth failures. Confirm `miniflux-secrets`
   decrypted: `kubectl -n miniflux get secret miniflux-secrets` exists (the SealedSecret controller
   creates it). If the secret is missing, the SealedSecret failed to decrypt — see Common failures.
4. **Public host 5xx but pods Healthy?** The issue is the edge, not k3s — check the cloudflared
   tunnel route for `${SECRET:DOMAIN_RSS}` (NPM↔Traefik) and the `miniflux-tls` cert (`kubectl -n miniflux get
   certificate miniflux-tls` → Ready). Rollback = flip the tunnel route back to NPM (Compose).
5. **Feeds not refreshing but app up?** Almost always egress — see Common failures #1.

## Common failures

1. **Feeds stop refreshing (app healthy, no new entries).** The default-deny NetworkPolicy is
   blocking the app's outbound feed fetch. The app needs **egress 80/443 to the internet + DNS:53**
   (`networkpolicy.yaml` NP2). Same class of trap as ytdlp-api's YouTube egress (Story 3.1). Verify:
   `kubectl -n miniflux exec deploy/miniflux -- wget -qO- https://example.com >/dev/null && echo ok`.
2. **Postgres major mismatch on restore.** `pg_restore` from a newer server into an older client (or
   vice-versa across majors) errors or silently drops objects. The DB, the backup CronJob, and the
   restore Job are ALL `postgres:18` — keep them on the same major (AR29 pin). If you bump the DB
   major, bump the backup/restore images in the same PR.
3. **SealedSecret won't decrypt** (`miniflux-secrets`/`miniflux-backup-r2` Secret never appears).
   The SealedSecret is sealed to `name+namespace`; a rename or namespace change breaks it. Re-seal
   with the recipe in `sealed-secret.yaml` against the live controller.
4. **Backup CronJob fails on `apt-get`/`rclone`.** The job installs rclone at runtime over 80/443 to
   the Debian mirror (NP4 allows it). If a future network-baseline tightens egress, allow the mirror
   + R2 or bake a pinned `postgres18+rclone` image (noted in `backup-cronjob.yaml`).
5. **Two postgres pods / corrupt PGDATA.** Must never happen — the Deployment is `strategy: Recreate`
   (old pod torn down before new). If you ever see two, you've reintroduced RollingUpdate. Revert.

## Backup/restore commands

**Backup** — `miniflux-backup` CronJob (`backup-cronjob.yaml`), every 6h, logical `pg_dump -Fc` over
the network (online-consistent via MVCC — no quiesce/scale-down), → `r2:homelab-k3s-services-backup/miniflux/`:

```sh
# What the CronJob runs (manual one-off: trigger a Job from the CronJob):
kubectl -n miniflux create job --from=cronjob/miniflux-backup miniflux-backup-manual
# core command inside it:
pg_dump -Fc -h miniflux-db.miniflux.svc.cluster.local -U miniflux -d miniflux -f /scratch/miniflux-<ts>.dump
rclone copy /scratch/miniflux-<ts>.dump r2:homelab-k3s-services-backup/miniflux/
```

**Restore** — logical `pg_restore` (NOT a volume copy). Fetch a dump from R2 into a `postgres:18`
client pod and restore into the target DB:

```sh
rclone copy r2:homelab-k3s-services-backup/miniflux/miniflux-<ts>.dump .
# into a running client/db pod (PGPASSWORD from miniflux-secrets):
pg_restore --clean --if-exists --no-owner \
  -h miniflux-db.miniflux.svc.cluster.local -U miniflux -d miniflux miniflux-<ts>.dump
```

### Verified restore (AC1 — record the result here at cutover)

> **STATUS: PENDING operator execution.** Restore the dump into a scratch Postgres (or the k3s DB
> pre-traffic) and confirm `feeds`/`entries` counts match the source. Record the command + the two
> counts below once run — this is the AC1 "verified restore at least once".
>
> ```
> # date: <fill> | source feeds=<n> entries=<m> | restored feeds=<n> entries=<m>  -> MATCH
> ```

## Escalation / depends-on

- **Depends on:** Longhorn (PVC `miniflux-db-data`), cert-manager + `letsencrypt-prod` (the
  `miniflux-tls` cert), the SealedSecrets controller (decrypts both secrets), the cloudflared tunnel
  (public route for `${SECRET:DOMAIN_RSS}`), and **outbound internet egress** (feed fetch).
- **Cutover/rollback:** [stateful-cutover.md](stateful-cutover.md) — Postgres is the `pg_dump`/`pg_restore`
  data class (dump→restore, NOT rsync). Compose miniflux + miniflux-db stay **PARKED** (rollback =
  flip the `${SECRET:DOMAIN_RSS}` tunnel route back to NPM; Compose never torn down).
- **Alerting:** until full alerting lands (Epic 4.2/5.1), watch the cutover manually — there is no
  automated page on miniflux failure yet.
