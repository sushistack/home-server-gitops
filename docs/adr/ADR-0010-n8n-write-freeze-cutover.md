# ADR-0010: n8n cutover — write-freeze + parallel run, encryption key sealed explicitly

Affected services: n8n (one of the two CRITICAL services; vaultwarden 4.8 follows this exact procedure)

> Decision record. Back-reference: [README → Decision records](../../README.md#decision-records-adrs).

## Context

n8n is **CRITICAL** and migrated second-to-last (only vaultwarden is later). Two properties make its
data move different from every Low/Med cutover before it:

1. **RPO must be 0.** For ntfy (4.1) / navidrome (4.3) the cutover quiesce is an **online
   `sqlite3 .backup` of the live writer** — lock-safe, and losing a few seconds of in-flight writes is
   acceptable. n8n's AC3 demands **zero data loss**: no write may occur between the consistent copy and
   the ingress flip.
2. **An irreplaceable encryption key.** n8n encrypts every row of `credentials_entity` with
   `N8N_ENCRYPTION_KEY`. In this deployment that key was **never set in `.env`** — n8n auto-generated
   it on first boot into the `data/n8n/config` file. It is the **one** thing that decrypts the
   credentials, and there is no recovery if it is lost or replaced.

The data itself is a single SQLite file (`database.sqlite`), so the file-class machine (copy the data
dir into a Longhorn PVC via a one-shot ingest Job) applies — unlike miniflux's logical Postgres dump
(ADR-0008). The novelty is purely the **quiesce mechanism** and the **key handling**.

## Decision

- **Cutover quiesce = WRITE-FREEZE, not a live `.backup`.** The Compose n8n is **stopped**
  (`docker compose stop n8n`) for the copy → verify → flip window, so no invisible parallel write can
  occur. The consistent copy (`sqlite3 .backup` of the now-static DB + the full `data/n8n/` tree) is
  ingested into the `n8n-data` PVC via the one-shot `_cutover/ingest-job.yaml`. **Learning-first is
  explicitly suspended — zero data loss wins (AC1).** RPO = 0 because writes were impossible during
  the window.
- **Steady-state backup stays an online `.backup` — no scale-down.** The recurring `n8n-backup`
  CronJob runs `sqlite3 .backup` against the **live** k3s pod (lock-safe), because steady-state RPO is
  ≤6h, not 0. **Do not conflate the two mechanisms.** Same SQLite-class backup actor as navidrome:
  podAffinity co-location onto the RWO node, dump to an `emptyDir`, `rclone` → R2 (no quiesce).
- **The encryption key is sealed EXPLICITLY as `N8N_ENCRYPTION_KEY`.** Its true origin is the Compose
  `data/n8n/config` file — the **AR24 documented exception** (the dual-run rule's "origin = `.env`"
  does not hold for n8n). Setting it via the SealedSecret (env wins over the file, and is
  deterministic) makes the key survive a fresh PVC / a lost `config` / an rsync miss. **A credential
  that decrypts in the UI on k3s — before the ingress flip — is the proof the key migrated.**
  **Update 2026-06-19:** Compose retired (Story 5.4); the Compose `config`-file origin is gone — the
  `n8n-secrets` SealedSecret is now the **sole source** for the key (see DECISIONS.md).
- **Parallel run / reversible rollback.** Compose n8n + n8n-backup stay **PARKED** (stopped, never
  `down`); rollback is the cloudflared route for `${SECRET:DOMAIN_N8N}` flipped back to NPM within the
  pre-lowered TTL. The flip never tears Compose down — same machine as every Epic 4 cutover.
- **Drop the docker.sock mount.** Compose mounted `/var/run/docker.sock` into n8n (historically for
  the offen backup sidecar's label-based `docker stop`); k3s has no docker socket and mounting one is
  a privilege escalation. Dropped. Workflows that shell out to Docker break and need a k8s-native
  rewrite; credential/HTTP/cron workflows are unaffected.

## Consequences

- **A real, planned write outage** for the cutover window (≤10 min) — the only Epic 4 cutover (with
  vaultwarden) where the source is *stopped* rather than backed up live. Acceptable: n8n's automation
  workflows tolerate a brief pause; silent split-brain on credentials does not.
- **A verified restore** (login + a credential **decrypts** + a workflow loads, from the R2 backup)
  is required once before close — recorded in [n8n.md](../runbooks/n8n.md).
- The encryption-key origin is a **documented rotation nuance**: a future operator must re-seal from
  `data/n8n/config`, not `.env` (command in the `sealedsecret.yaml` header + the runbook).
- vaultwarden (4.8) reuses this ADR's procedure verbatim — write-freeze + parallel run; it is the only
  other CRITICAL service.

## Rejected alternatives

- **Online `sqlite3 .backup` of the live writer for the cutover** (the Low/Med reflex). Lock-safe but
  NOT RPO=0 — in-flight writes between the copy and the flip would be lost. Rejected for a CRITICAL
  service: AC1/AC3 require write-freeze.
- **Rely on the migrated `config` file for the encryption key** (don't set the env). Works *if* the
  rsync carries `config` and the PVC is never reset — but one stray fresh-PVC and every credential is
  unrecoverable. The explicit env is cheap insurance. Rejected.
- **Tear down Compose at flip time** (no parallel run). Removes the rollback target. Rejected — Compose
  stays parked until Epic 5.
- **Keep the docker.sock mount for parity.** A severe privilege escalation in k3s for a Compose-only
  artifact. Rejected.

## Exposure note

Safe to show publicly: the mechanism — write-freeze vs online backup, why RPO=0 needs a stopped
writer, the explicit encryption-key seal + decrypt-before-flip proof, parallel-run rollback, dropped
docker.sock. Not shown: the real `n8n.<zone>` host (token `${SECRET:DOMAIN_N8N}` only), the encryption
key, or the R2 credential — all sealed or render-time substituted.
