# Runbook: karakeep (bookmark manager — multi-component with east-west isolation)

> Story 4.5. FOUR components — `karakeep-web` (+ workers), `karakeep-meilisearch`, `karakeep-chrome`,
> `karakeep-anytype-bridge` — are ONE logical service in the `karakeep` namespace / one ApplicationSet
> Application. Hybrid backup (AC1): web's `db.db` and the bridge's `bridge.sqlite` are dumped
> (`sqlite3 .backup`); meili is rebuildable (no dump). Cutover follows
> [stateful-cutover.md](stateful-cutover.md), SQLite variant. Public host `${SECRET:DOMAIN_KEEP}`
> (= keep.<public-zone> — NOT karakeep.*, Reconciliation 4).

## What it does

Self-hosted bookmark / read-it-later archive at `${SECRET:DOMAIN_KEEP}`. Four components, ONE namespace:

- **`karakeep-web`** (container port `3000`) — the bookmark manager + background workers + crawler.
  The ONLY public face (Traefik → `:3000`). SQLite in `/data/db.db` (bookmarks + read-state) on the
  RWO Longhorn PVC `karakeep-data` (also holds `queue.db` + `assets/`). `strategy: Recreate` +
  `terminationGracePeriodSeconds: 30` (SQLite WAL — never two pods on one WAL, AR14). Reaches meili
  `:7700` and chrome `:9222`; is reached by the bridge `:3000`.
- **`karakeep-meilisearch`** (`:7700`) — search index, gated by a master key. INTERNAL — reachable
  from `karakeep-web` ALONE (NetworkPolicy, AC2). Index is REBUILDABLE from `db.db`, but NOT
  automatically: reindex is incremental (only fires on bookmark create/update), so a fresh PVC
  `karakeep-meili` stays EMPTY until you run Admin → "Reindex all bookmarks" once (Reconciliation 5).
  No dump backup.
- **`karakeep-chrome`** (`:9222`) — headless Chrome for crawl/screenshot. Binds an UNAUTHENTICATED
  CDP on `0.0.0.0:9222` — the whole reason AC2 exists. INTERNAL — from `karakeep-web` ALONE.
  Stateless (no PVC). Fetches the bookmarked pages, so it needs egress 80/443.
- **`karakeep-anytype-bridge`** (`:8080`, uid 1000) — receives karakeep's "ai tagged" webhook and
  creates Anytype objects via `anytype-heart`. Owns a SECOND stateful SQLite, `/data/bridge.sqlite`
  on PVC `karakeep-bridge-data` — the Karakeep-ID→Anytype-object DEDUP map (Reconciliation 2). RWO,
  `Recreate` + grace 30s. An `initContainer` chowns `/data` to uid 1000 (AC3). INTERNAL — no ingress.

The east-west isolation (AC2) reproduces the Compose `karakeep-internal` net: only `karakeep-web`
can reach the master-key index (`:7700`) and the unauthenticated CDP (`:9222`) — NOT the bridge,
NOT the flat cluster network. See `networkpolicy.yaml` and the proof in Common failures #1.

## Health check (exact command → expected output)

```sh
# Public (post-cutover):
curl -fsS -o /dev/null -w '%{http_code}\n' https://${SECRET:DOMAIN_KEEP}/api/health        # -> 200

# All four pods Ready (ports the Compose healthchecks):
kubectl -n karakeep get deploy                                                              # -> 4x  READY 1/1
kubectl -n karakeep exec deploy/karakeep-web              -- wget -qO- http://127.0.0.1:3000/api/health  # -> ok
kubectl -n karakeep exec deploy/karakeep-meilisearch      -- wget -qO- http://127.0.0.1:7700/health      # -> {"status":"available"}
kubectl -n karakeep exec deploy/karakeep-chrome           -- nc -z 127.0.0.1 9222 && echo cdp-up          # -> cdp-up
kubectl -n karakeep exec deploy/karakeep-anytype-bridge   -- python -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8080/health',timeout=3)" && echo bridge-up  # -> bridge-up

# ArgoCD:
kubectl -n argocd get applications.argoproj.io karakeep \
  -o jsonpath='{.status.sync.status}/{.status.health.status}{"\n"}'                         # -> Synced/Healthy
```

## If DOWN do this (in order)

1. **web pod not Ready?** `kubectl -n karakeep describe pod -l app.kubernetes.io/name=karakeep-web`.
   On boot it opens SQLite (+ WAL replay after an unclean stop); the `startupProbe` (30×5s) covers that.
   (Boot does NOT rebuild the meili index — see step 2.) If it crash-loops, check `kubectl -n karakeep logs deploy/karakeep-web`.
2. **meili not Ready / web can't search?** `kubectl -n karakeep logs deploy/karakeep-meilisearch`.
   If the index was lost (or empty after cutover) it does NOT self-rebuild — bookmarks list fine but
   SEARCH returns 0 hits. Fix: Admin → Background Jobs → "Reindex all bookmarks" (re-enqueues every
   bookmark; verified 2026-06-19 cutover). Master-key mismatch shows as 403 from web → meili (check `MEILI_MASTER_KEY` in the
   `karakeep-secrets` Secret matches what web uses; both come from the same SealedSecret).
3. **chrome not Ready?** `kubectl -n karakeep logs deploy/karakeep-chrome`. Crawl/screenshot only
   (no bookmark loss). If web can't reach the CDP, check the NetworkPolicy DNS-egress (step 5) and
   the chrome-ingress-web-only policy.
4. **bridge not Ready?** `kubectl -n karakeep logs deploy/karakeep-anytype-bridge`. The bridge is
   FUNCTIONALLY OPTIONAL for "bookmarks served + isolated" — if it's down, bookmarks still serve;
   only the Anytype object sync stops. First-boot EACCES on `bridge.sqlite` = the initContainer
   chown didn't run/finish — confirm the `data-fix` initContainer succeeded. See also depends-on
   (anytype-heart must be reachable cross-ns).
5. **Anything resolves nothing / all egress fails?** The default-deny EGRESS policy is missing its
   DNS allow. Every pod needs egress to kube-dns `:53` (`networkpolicy.yaml`). This is the #1
   predictable failure under default-deny.
6. **Public host 5xx but pods Healthy?** Edge, not k3s — check the cloudflared route for
   `${SECRET:DOMAIN_KEEP}` (NPM↔Traefik) and `kubectl -n karakeep get certificate karakeep-tls` →
   Ready. k3s is the sole production path (Compose retired 2026-06-19); recover via R2 restore /
   `git revert` + ArgoCD sync, not a flip-back to NPM.

## Common failures

1. **East-west isolation broke (the AC2 invariant). The ONE runnable proof:**
   ```sh
   # From the BRIDGE pod and from ANOTHER namespace, chrome:9222 and meili:7700 must TIME OUT;
   # from karakeep-web they must CONNECT. DNS must still resolve everywhere.
   kubectl -n karakeep exec deploy/karakeep-anytype-bridge -- sh -c \
     'nc -w3 -zv karakeep-chrome.karakeep.svc.cluster.local 9222; nc -w3 -zv karakeep-meilisearch.karakeep.svc.cluster.local 7700'   # -> BOTH time out
   kubectl -n karakeep exec deploy/karakeep-web -- sh -c \
     'nc -w3 -zv karakeep-chrome.karakeep.svc.cluster.local 9222; nc -w3 -zv karakeep-meilisearch.karakeep.svc.cluster.local 7700'   # -> BOTH connect
   ```
   If the bridge CAN reach chrome/meili, someone added a blanket same-namespace ingress allow that
   selects chrome/meili — the Reconciliation 3 trap. NetworkPolicies are ADDITIVE; remove the blanket
   allow (chrome/meili must be selected ONLY by `chrome-ingress-web-only` / `meili-ingress-web-only`,
   which admit `karakeep-web` alone).
2. **Login fails / redirect loop / "session" errors.** `NEXTAUTH_URL` must equal the external host
   (`https://${SECRET:DOMAIN_KEEP}`) or NextAuth's cookie domain mismatches. It is tokenized in
   `karakeep-config`; confirm the render CMP substituted the real host (Reconciliation 4 — it is
   keep.*, NOT karakeep.*).
3. **AI auto-tagging returns nothing / 400 from the model.** `INFERENCE_OUTPUT_SCHEMA=json` is
   LOAD-BEARING — DeepSeek has no `json_schema` strict mode, only `json_object`. Do NOT drop it
   (`karakeep-config`; memory karakeep_deepseek). Also check `OPENAI_API_KEY` (the DeepSeek key) in
   `karakeep-secrets`.
4. **Duplicate Anytype objects appear after cutover.** The bridge's `bridge.sqlite` dedup map was
   lost (Reconciliation 2). Restore it from R2 (Backup/restore) — losing it makes the next sync
   re-create objects that already exist.
5. **Bridge can't reach anytype-heart.** Cross-namespace: the bridge egress allow targets
   `namespaceSelector(anytype)+podSelector(anytype-heart):31009`. If anytype later gets a default-deny
   INGRESS policy, it must also admit the karakeep bridge. Confirm `anytype-heart` is Ready in ns
   `anytype` (`kubectl -n anytype get deploy anytype-heart`).
6. **Image won't pull (`ghcr.io/sushistack/*` bridge).** `imagePullSecret` `ghcr-sushistack` missing
   or the PAT expired — re-seal it (`sealedsecret.yaml` recipe). The other three images are public.
7. **Backup CronJob fails on `apk`/`rclone`.** Installs the tools at runtime over 80/443 (`backup-egress`
   NP allows it). If a future network-baseline tightens egress, allow the alpine CDN + R2 or bake a
   pinned `sqlite+rclone` image (noted in `backup-cronjob.yaml`).

## Backup/restore commands

Two `sqlite3 .backup` CronJobs (`backup-cronjob.yaml`), online + lock-safe (NO scale-down), → R2
`homelab-k3s-services-backup/karakeep/`. `karakeep-backup-web` dumps `db.db` (`20 */6`);
`karakeep-backup-bridge` dumps `bridge.sqlite` (`35 */6`). meili is NOT dumped (rebuildable). `assets/`
ride Longhorn replication (not shipped every 6h — large regenerable crawl snapshots).

```sh
# Manual one-off (trigger a Job from a CronJob):
kubectl -n karakeep create job --from=cronjob/karakeep-backup-web    karakeep-backup-web-manual
kubectl -n karakeep create job --from=cronjob/karakeep-backup-bridge karakeep-backup-bridge-manual
# core commands inside them:
sqlite3 /data/db.db        ".backup /scratch/db.db"        && rclone copy /scratch/karakeep-<ts>.tar.gz        r2:homelab-k3s-services-backup/karakeep/
sqlite3 /data/bridge.sqlite ".backup /scratch/bridge.sqlite" && rclone copy /scratch/karakeep-bridge-<ts>.tar.gz r2:homelab-k3s-services-backup/karakeep/
```

**Restore** — fetch the archive from R2, untar, and copy the `.db` back onto the (stopped) target's
PVC. SQLite restore = file copy with the app quiesced (NOT a live overwrite):

```sh
rclone copy r2:homelab-k3s-services-backup/karakeep/karakeep-<ts>.tar.gz . && tar xzf karakeep-<ts>.tar.gz
kubectl -n karakeep scale deploy/karakeep-web --replicas=0       # quiesce the writer
# park a helper pod mounting karakeep-data, `kubectl cp db.db` onto /data/db.db, then:
kubectl -n karakeep scale deploy/karakeep-web --replicas=1
```

> **CUTOVER EXECUTED LIVE 2026-06-19.** Quiesced prod → re-ingested a post-quiesce consistent copy
> (db.db drifts under background workers, so the authoritative copy is taken AFTER `docker stop`) →
> **0-loss verified byte-identical** (`db.db` md5 `2b32ba8b…` == live; `bridge.sqlite` `f07fc0b2…`
> == live; 66 bookmarks served, `/api/health` ok). AC2 isolation proven (chrome/meili blocked from
> the bridge + another ns, reachable from web). Edge flipped: CF tunnel `keep → https://${SECRET:IP_K3S}:443`
> (before the `*.${SECRET:DOMAIN_ZONE}→NPM` wildcard) + OpenWrt LAN override `keep → ${SECRET:IP_K3S}`; both paths 200,
> LE-prod `keep.${SECRET:DOMAIN_ZONE}` cert valid. Compose karakeep **PARKED** (all 5 containers exited; rollback =
> remove the CF ingress rule + `docker start`).

## Escalation / depends-on

- **Depends on:** Longhorn (PVCs `karakeep-data`, `karakeep-bridge-data`, `karakeep-meili`),
  cert-manager + `letsencrypt-prod` (`karakeep-tls`), the SealedSecrets controller (decrypts
  `karakeep-secrets` / `karakeep-backup-r2` / `ghcr-sushistack`), the cloudflared tunnel (public
  route for `${SECRET:DOMAIN_KEEP}`), outbound internet egress (DeepSeek inference + chrome page
  fetch + R2 backup), and **`anytype-heart` in ns `anytype`** (Story 4.4, on k3s) for the bridge —
  Reconciliation 1. The bridge is OPTIONAL for the core bookmarks-served-and-isolated ACs; don't
  block the whole service on it.
- **Cutover (historical):** [stateful-cutover.md](stateful-cutover.md) — SQLite data class (`.backup`
  dump → file restore, NOT rsync of a live WAL). **Compose karakeep (all 5 containers) RETIRED
  2026-06-19 (Story 5.4)** — k3s is the sole production path; no Compose rollback. Recovery is
  k3s-native: restore from R2 (`homelab-k3s-services-backup/karakeep/`) into a scratch ns, or
  `git revert` + ArgoCD sync. See [DECISIONS.md](../DECISIONS.md).
- **Alerting:** backup-failure surfaces via the ntfy poller (Story 4.2, ops-alerts, watches for
  Failed Jobs cluster-wide); `activeDeadlineSeconds` makes a hung backup a visible Failed Job.
