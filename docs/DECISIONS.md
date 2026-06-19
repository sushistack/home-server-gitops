# Decisions

Running log of load-bearing decisions. One line each; link the story.

## Standalone application LXCs consolidated onto k3s (Story 5.6, Epic 5 / Phase 3 — opportunistic)

- 2026-06-19 | **Opportunistic, post-DONE cleanup — NOT a gate, NOT a Compose cutover.** These guests
  (#203 komga+Suwayomi, #204 calibre-web, #205 trade-monitor) were NEVER in the Compose stack (LXC
  #202), so none of the Epic 4 write-freeze / dual-run / R2-actor machinery applies to *moving the
  apps* — only the GitOps *shapes* (ApplicationSet, golden-path Deployment+ingress, render-CMP tokens,
  SQLite Recreate+startupProbe) are reused. Data migrates by plain copy (small config DBs + the 90G
  manga — NFS was infeasible, see below). **EXECUTED LIVE 2026-06-19** (agent, operator-granted access):
  all 4 apps on k3s, parity verified (operator-confirmed working after 3 post-flip fixes — see below),
  public+LAN flipped, **#203/#204/#205 all destroyed**. The 90G manga now lives ONLY on k3s-cp-1's local
  disk (no replica — re-downloadable via Suwayomi). Epic 5 stayed optional; did not gate completion. | Story 5.6
- 2026-06-19 | **trade-monitor → k8s `CronJob`** (`* * * * *`, `Asia/Seoul`, Forbid, `activeDeadline
  55s` mirroring the LXC `timeout 55`). Stateless: ConfigMap (no PVC), no Service/ingress/SealedSecret,
  outbound-only (Binance + Yahoo + LaMetric internet + LAN displays 10.0.0.200–206). Image built in
  the **trade.monitor repo** (its own Dockerfile + GHCR CI — `home.server` is not touched, Reconciliation
  3), consumed by digest. Pod CoreDNS can't resolve the dnsmasq lease names, so the ConfigMap rewrites
  `crypto-*`/`ulanzi`/`stock-snp500` → static IPs (Reconciliation 4). #205 decommissioned after parity. | Story 5.6
- 2026-06-19 | **90G manga library OFF Longhorn — node-local PV on k3s-cp-1 (NOT NFS — the
  Reconciliation 6 plan was infeasible).** Longhorn's 3× sync replication + tight node disk make 90G a
  bad fit (memory `longhorn-node-storage`). The intended fix (repurpose #203 into an in-place NFS server,
  zero-copy) **FAILED at execution**: #203 is an UNPRIVILEGED LXC — kernel `nfsd` is unavailable, and
  userspace `nfs-ganesha`'s VFS FSAL needs `open_by_handle_at`, which the kernel gates behind
  CAP_DAC_READ_SEARCH **in the initial userns** (an unprivileged container can NEVER hold it →
  `vfs_open_by_handle: Operation not permitted`, confirmed live). Privileged-convert (rootfs uid-shift,
  invasive), host-NFS (Plane 0 daemon), unfsd (NFSv3, unmaintained) were the alternatives. **Operator
  chose node-local copy:** a dedicated 200G disk on k3s-cp-1 (`/mnt/manga`, ext4, UUID-mounted), 90G
  rsync'd from #203 (12663 files verified == source), exposed as a static `local` PV (RWX). komga ro +
  Suwayomi rw, both PINNED to k3s-cp-1 by the local-PV nodeAffinity. **Cost accepted: no replication /
  no HA** (the node or its disk is a SPOF) — fine, the library is non-critical + re-downloadable via
  Suwayomi, and #203 was a single box with no HA either. Grows online (`qm resize`+`resize2fs`). #203 is
  therefore fully decommissioned too (no storage role). (supersedes Reconciliation 6) | Story 5.6
- 2026-06-19 | **komga + Suwayomi = two Deployments, one namespace, one shared library** (Reconciliation
  5 — #203 ran BOTH, not just komga). Config DBs (komga `database.sqlite`/`tasks.sqlite`, Suwayomi data
  dir) on small Longhorn PVCs (reading progress — precious, tiny); the library on NFS. **calibre's ~4G
  library goes on Longhorn** (Reconciliation 7 — too small to hit the bottleneck; lets #204 be FULLY
  decommissioned, no NFS dependency). Exposure PRESERVED per app, **verified vs live NPM 2026-06-19**:
  komga PUBLIC (`comics.*`, no ACL), calibre PUBLIC (`book.*` SINGULAR, no ACL), Suwayomi INTERNAL
  (`comics-admin.*`, NPM `allow 10.0.0.0/24+10.8.0.0/24 deny all`). Internal-only on k3s = NO cloudflared
  tunnel rule + LAN-only DNS override — NOT an ipAllowList (cloudflared egresses from a LAN IP `10.0.0.20`,
  so a `10.0.0.0/24` allow would ADMIT internet-via-tunnel; "no tunnel rule" is the only correct gate).
  No SealedSecret (these apps need no API key). | Story 5.6
- 2026-06-19 | **jellyfin (#200) / immich (#201) EXPLICITLY EXCLUDED** (AC3). They share the host iGPU
  via LXC device passthrough (`/dev/dri/renderD128`+`card0`), which a k3s **VM** node cannot replicate
  without exclusive VFIO (steals the iGPU from the other guest + host), and they hold large local media
  → moving them forces CPU-only transcoding + Longhorn-bound media I/O = a real regression for no GitOps
  payoff. They remain dedicated LXCs. | Story 5.6
- 2026-06-19 | **Plane-0-adjacent edits — APPLIED LIVE (AS-BUILT):** (1) **OpenWrt** LAN DNS overrides
  `comics`/`comics-admin`/`book`.eli.kr → `10.0.0.101` (uci add/del_list + dnsmasq reload, surgical — not
  a full playbook apply). The `komga`→`storage` lease rename was **dropped** (node-local means #203 is NOT
  a storage box — it's retired). (2) **Cloudflare tunnel** ingress: `comics` + `book` → `https://10.0.0.101:443`
  inserted before the `*.eli.kr` wildcard (cfd_tunnel API PUT); `comics-admin` deliberately gets NO rule
  (internal). (3) **Proxmox** (guest-level only, AC4-ok): added a 200G disk to k3s-cp-1, `pct destroy` #204/#205,
  `pct destroy` #203 (after operator confirmed working). Proxmox host config, OpenWrt routing/DoH, Oracle/WireGuard otherwise untouched. | Story 5.6

## Compose stack RETIRED — k3s is the sole production path (Story 5.4, Epic 5 / Phase 3)

- 2026-06-19 | **The legacy Compose application stack was retired (decommissioned, not merely
  parked).** All 9 migrated app services + their `offen` backup sidecars + Compose-only scaffolding
  (`karakeep-anytype-bridge-data-fix` init, `karakeep-internal` bridge) were removed from
  `home.server` `configs/docker/docker-compose.yml`, from the CD path (`.github/workflows/deploy.yml`
  + `.github/scripts/deploy.js` no longer materialize their `.env*` or `docker compose up` the app
  stack), and the app/backup `.env` templates (`.env.apps.template`, `.env.backup.template`) were
  deleted so the Compose `.env` secret origin **ceases to exist**, and the 34 orphan app `ENV_*`
  GitHub repo secrets were deleted (only `ENV_TZ`/`ENV_HOMEPAGE_ALLOWED_HOSTS`/`ENV_CLOUDFLARE_TUNNEL_TOKEN`
  + the `VW_*`/`BW_*` cloud-sync secrets remain). The live app containers on `${SECRET:IP_COMPOSE}` were
  removed by **explicit `docker stop`→`docker rm` per container name** — NOT `docker compose down`, since
  the app + infra share one compose project (`home-network`) and a file-scoped `down` would have taken
  cloudflared (Plane 0) with it. Volumes kept (cold copy); infra stack untouched + healthy; every public
  host verified serving from k3s. | Story 5.4
- 2026-06-19 | **Preconditions met (HARD GATE).** Project **DONE** declared 2026-06-19 (Story 4.8 —
  all migrated services live on k3s, ArgoCD `Synced`/`Healthy`, Gate 0 + per-service verified
  restores, NFR15a alerting proven; see [DONE.md](DONE.md)). **k3s trust** certified by the operator
  as the explicit Story 5.4 judgment gate (operator decision 2026-06-19). Retiring Compose **removes
  the documented rollback path** — this is the point of no easy return, taken deliberately.
- 2026-06-19 | **AR24 dual-run source-of-truth collapsed.** The SealedSecrets are now the **single
  source of truth** (no longer "a verified copy of the Compose `.env`"). The SealedSecrets themselves
  did not change — only their documented authority. Runbooks + ADR-0009/0010 AR24 notes flipped. | AR24
- 2026-06-19 | **Rollback doctrine struck.** "Ingress is the switch; Compose is the rollback" no
  longer holds — `stateful-cutover.md` is marked HISTORICAL, every per-service runbook's "roll back
  to NPM/Compose" step is replaced with k3s-native recovery (restore the per-service R2 dump
  `homelab-k3s-services-backup/<svc>/` into a scratch namespace, or `git revert` + ArgoCD sync). | NFR12
- 2026-06-19 | **Plane 0 untouched.** OpenWrt, Proxmox, Oracle, and the cloudflared tunnel were not
  modified; the CD self-hosted runner on `${SECRET:IP_COMPOSE}` survives. The infra Compose stack
  (`docker-compose.infra.yml`: portainer/NPM/homepage/uptime-kuma/cloudflared) **stays live** — those
  platform services are out of scope here (their retirement is Story 5.5). This closes the Epic 5 /
  Phase 3 dual-run window; remaining Epic 5 stories stay optional. | Story 5.4

## GitOps upgrade & rollback discipline (Story 5.3, Epic 5 / Phase 3)

- 2026-06-19 | **Version SSOT completed + made enforceable.** All pins now answerable from one
  file — [`versions.yaml`](../versions.yaml): platform charts (k3s, ArgoCD, Longhorn, cert-manager,
  sealed-secrets) **plus** a new **workload image registry** (14 images). No image-templating layer
  exists (the render CMP only substitutes `${SECRET:*}` hostnames) and building one for ~14 images
  is overkill, so the deploy-time value stays inline in each manifest and `versions.yaml` mirrors
  it — `bin/version-lint` makes the file **authoritative** (fails CI if a manifest drifts from the
  pin, blocks any `:latest`, asserts chart pins are referenced in `argocd/apps`). Sanctioned
  mirror-with-lint; upgrade path is a Kustomize `images:` transformer if it ever chafes. | **no ADR**
  (the SSOT + 3-line rule were already architecture decisions; recorded here + in the runbook).
- 2026-06-19 | **Renovate added, automerge OFF.** [`renovate.json`](../renovate.json) opens one PR
  per component (never a mega-PR) against `versions.yaml`/the manifests; differential policy encoded
  in `packageRules` — **conservative on etcd/k3s** (30-day soak), **current on ArgoCD** (no soak,
  CRDs stay `v1alpha1` on 3.x). **Traefik disabled** (ArgoCD must not manage the k3s-bundled
  Traefik). Validated with `renovate-config-validator --strict`. Honest ceiling: digest-only pins
  (`name@sha256:` with no tag) aren't Renovate-trackable — pin `name:<tag>@sha256:` to track. | no ADR
- 2026-06-19 | **Upgrade/rollback proven end-to-end (AC5), `ytdlp-api`** (internal-only, stateless —
  lowest blast radius). **Upgrade:** PR re-pinned the image (manifest + `versions.yaml` registry, one
  commit, lint green) → push `master` → **ArgoCD auto-synced** (no manual sync) → health-gated
  rollout → new pod `Synced/Healthy` (`5fd8f89`). **Rollback:** `git revert 5fd8f89` → push →
  auto-reconciled back to the prior digest, `Synced/Healthy` (`a6d282b`) — **no `kubectl rollout
  undo` / `helm rollback`**. The revert IS the rollback. | no ADR | runbook:
  [upgrade-rollback.md](runbooks/upgrade-rollback.md)

## Cold-boot ordering — tested + deterministic (Story 5.2, Epic 5 / Phase 3)

Exposure note: safe to show — boot order, the stagger rationale, the ≤1-step claim, and the
measured result. No key material, IP, or `*.<zone>` host; the live `qm` apply uses real VMIDs
only on the host (off-repo).

- **Cold-boot start-order is enforced at the hypervisor, not improvised.** Per-VM Proxmox
  `onboot=1` + `startup order=N,up=S`: OpenWrt router VM `order=1` (household internet first,
  no cluster dependency — Plane 0), the three k3s node VMs `order=2,up=<S>` staggered so **etcd
  reaches quorum=3 BEFORE Longhorn (wave 0) wakes**. Native Proxmox feature — no custom
  orchestration daemon (AR3). Declared as the SSOT in the VM substrate def
  ([bare-metal-recovery.md §5](runbooks/bare-metal-recovery.md)); the live `qm set` is the
  operator's high-blast-radius apply (`configs/proxmox/`, Plane 0 — dry-run/diff/rollback/approval).
  (FR23, NFR7, AR3)
- **This is the everyday power-cycle path, NOT Gate 0.** etcd survives a clean power-cycle, so the
  cold-boot leg needs **no sealing-key restore** (that is the bare-metal/etcd-loss leg, Story 2.6).
  Cold-boot leg + per-layer stall map hardened in
  [bare-metal-recovery.md §3a](runbooks/bare-metal-recovery.md). (FR23, NFR7, AR34)
- **Manual-step count (NFR7, honest):** `<TESTED DETERMINISTIC AS OF <DATE> — manual steps =
  <MEASURED>, verified over <N> repeated power-cycles; pending operator cold-boot drill (Story 5.2
  Task 3)>`. Target ≤1 (the only candidate step is the idempotent `kubectl apply -f
  bootstrap/root-app.yaml`; likely 0 once ArgoCD selfHeal reconciles). If >1, the extra step is
  recorded here as a known limitation rather than papered over. (NFR7, FR23)

## Vaultwarden cutover (CRITICAL, LAST) + project DONE audit (Story 4.8)

- 2026-06-19 | **Vaultwarden cut over to k3s — the LAST stateful service.** Same SQLite write-freeze
  machine as ntfy/navidrome/n8n: `docker compose stop` (single-writer freeze) → online
  `sqlite3 .backup` + carry **`rsa_key.pem`** (JWT signing — lose it = mass re-auth) + attachments →
  ingest into the `vaultwarden-data` Longhorn PVC (pre-populated BEFORE the app existed, to dodge the
  ApplicationSet selfHeal/empty-init race — `automated{selfHeal}` can't be paused on an appset-managed
  Application) → ArgoCD app generated (commit e5b5a08) → **verify-before-flip: db.sqlite3 sha256
  byte-identical to source, users 1==1, ciphers 515==515, /alive+web 200, vaultwarden-tls LE-prod
  Ready** → flip CF tunnel (`vault.${SECRET:DOMAIN_ZONE}→${SECRET:IP_K3S}:443` before `*.${SECRET:DOMAIN_ZONE}→NPM`, API PUT) + OpenWrt
  LAN override (${SECRET:IP_COMPOSE}→${SECRET:IP_K3S}, uci). Public (CF edge) + LAN both 200. **Window ≈6 min ≤10,
  RPO=0.** Backup actor proven (R2 `…/vaultwarden/`) + verified restore in a scratch ns. Compose
  vaultwarden **PARKED** (restarted, localhost 200) as the rollback net; `vaultwarden-backup` left
  stopped so it can't stop the parked container. [ADR-0009](adr/ADR-0009-vaultwarden-critical-last.md),
  [runbook](runbooks/vaultwarden.md), [DONE.md](DONE.md)
- 2026-06-19 | **Project DoD audited ([DONE.md](DONE.md)).** All 9 application services + platform on
  ArgoCD Synced/Healthy (only the `argocd` self-app is intentionally OutOfSync), Gate 0 + per-service
  verified restores, ADRs linked (CI green), exposure gate green, NFR15a verified. **One open DoD line:
  the self-heal demo clip (clip 2) is recording-pending (operator-deferred, Story 3.3).** **PROJECT
  DONE declared 2026-06-19 — operator accepted the clip-2 deferral as non-blocking** (AC4: optional
  polish must not block DONE). **Epic 5 / Phase 3 is optional, post-DONE; Compose is PARKED not retired (retire = Story 5.4)
  — the dual-run rollback net stays until then.**
- 2026-06-19 | ⚠️ **Found (operator follow-up): `argocd-render-tokens` Secret has a pre-existing
  newline-corruption** — `CLOUDFLARE_DNS01_TOKEN`'s value runs into `DOMAIN_NTFY=notify.${SECRET:DOMAIN_ZONE}` with no
  separator (a clean `DOMAIN_NTFY` line also exists below it). Harmless to rendering (cert-manager uses
  its own `cloudflare-dns01-token` Secret in ns cert-manager) but it pollutes that token value. Left
  untouched during the vault cutover (didn't want to risk the DNS token); operator should re-split the
  line. `DOMAIN_VAULTWARDEN=vault.${SECRET:DOMAIN_ZONE}` was appended cleanly below it.

## Anytype cutover — non-HTTP TCP/UDP edge + file-class BadgerDB quiesce (Story 4.4)

- 2026-06-18 | anytype migrated to k3s as **one logical service / two components / one namespace**
  under a **hand-written ArgoCD Application** (`argocd/apps/anytype.yaml`, excluded from the workloads
  ApplicationSet) — the documented exception, because any-sync is **raw TCP 33010 + QUIC/UDP 33020**,
  NOT HTTP: it is served by Traefik **IngressRouteTCP/UDP** on dedicated entryPoints declared via a
  **k3s-owned HelmChartConfig** (`infra/traefik/`, dropped by ansible into k3s's auto-deploy dir —
  OUTSIDE ArgoCD, same boundary as the Traefik controller). The public flip is the **33010/33020
  stream forward (NPM Stream / port-forward) NPM→Traefik**, NOT the cloudflared HTTP split.
  Store is **BadgerDB/leveldb (file-class, NOT SQLite)** with no online dump → backup is a **scale-to-0
  CronJob** (co-schedule on the app node, `kubectl scale --replicas=0`, tar `/data` → R2, trap scales
  back up) needing a `deployments/scale: patch` Role — NOT the `sqlite3 .backup` path. **🔴 The node
  identity (peerId/networkId + keys) IS the data**, hardcoded by every client → cutover is a **copy of
  `/data`, never a fresh init**; identity must round-trip and is verified before the edge flip.
  `anytype-heart` (REST :31009) is internal-only (ClusterIP, FQDN for 4.5/4.7 consumers); private
  heart image → `ghcr-sushistack` imagePullSecret; public any-sync-bundle → none; both pinned by
  digest. **Manifests + Traefik entryPoints + file-class backup actor + runbook authored & validated;
  the LIVE quiesce+copy+identity-verify + TCP/UDP edge flip + sealing real MNEMONIC/R2 creds + pinning
  the live heart digest are operator-run** (≤10min window). Compose anytype/anytype-heart **PARKED not
  decommissioned** (rollback = flip the stream forward back; Story 5.4 does the functional retire).
  | [runbook](runbooks/anytype.md)

## Karakeep cutover — multi-component with east-west isolation (Story 4.5)

- 2026-06-19 | karakeep migrated to k3s as **one logical service / FOUR components / one namespace**
  via the **workloads ApplicationSet** (HTTP, no TCP/UDP exception — unlike anytype). **East-west
  isolation (AC2) reproduces the Compose `karakeep-internal` net** WITHOUT a blanket same-ns allow
  (the Reconciliation 3 trap — NetworkPolicies are additive): chrome (unauthenticated CDP :9222) and
  meili (master-key index :7700) each get a **targeted ingress policy admitting `karakeep-web` ALONE**,
  so the in-ns bridge + flat network are denied; web ingress is left open (Traefik) per the miniflux
  precedent. **Hybrid backup (AC1):** web `db.db` AND the bridge's **second SQLite `bridge.sqlite`
  (the dedup map — Reconciliation 2; losing it re-emits duplicate Anytype objects)** are dumped via
  online `sqlite3 .backup` → R2 (two CronJobs, RWO podAffinity); **meili is rebuildable** (fresh PVC,
  reindex — no dump); `assets/` ride Longhorn replication. Bridge perms via **initContainer chown**
  (AC3, not a cross-pod dep); private bridge image → `ghcr-sushistack` imagePullSecret; all four
  images pinned by digest. Host is **keep.\*, NOT karakeep.\*** (Reconciliation 4 — NextAuth cookie
  domain). Bridge → `anytype-heart` cross-ns (Reconciliation 1, anytype on k3s since 4.4); bridge is
  optional for the core ACs. **CUTOVER EXECUTED LIVE 2026-06-19:** base applied → ingest job →
  4 pods Ready → **AC2 isolation PROVEN** (from the bridge pod AND from another namespace,
  chrome:9222 + meili:7700 are BLOCKED; from karakeep-web both CONNECT; DNS resolves everywhere;
  bridge→`anytype-heart.anytype.svc:31009` reachable cross-ns). Window: quiesced prod (db.db drifts
  even with no user action — background workers write, so the authoritative copy is taken
  post-quiesce), re-ingested the fresh consistent copy, **0-loss verified byte-identical**
  (`db.db` md5 `2b32ba8b…` == live; `bridge.sqlite` `f07fc0b2…` == live; 66 bookmarks served).
  Public flip: CF tunnel ingress edited via API (`keep → https://${SECRET:IP_K3S}:443` inserted before the
  `*.${SECRET:DOMAIN_ZONE}→NPM` wildcard) → 200 from outside. LAN flip: OpenWrt local-DNS override (NEW entry
  `keep → ${SECRET:IP_K3S}`, draw pattern) → direct path 200 with the LE-prod `keep.${SECRET:DOMAIN_ZONE}` cert. Compose
  karakeep (5 containers) **PARKED** (all exited; rollback = remove the CF rule + start Compose).
  ArgoCD adopts on git push. | [runbook](runbooks/karakeep.md)

## Miniflux cutover — Postgres logical dump (Story 4.6)

- 2026-06-18 | miniflux migrated to k3s as the **one Postgres service** — backup/restore + cutover
  ingest are **logical `pg_dump -Fc`/`pg_restore` over the network**, NOT a tar/rsync of
  `/var/lib/postgresql` and NOT a Longhorn volume snapshot (Reconciliation 1). `pg_dump` is
  online-consistent (MVCC) so the backup CronJob needs **no quiesce, no scale-down, no PVC mount, no
  podAffinity** — the RWO multi-mount trap is SQLite/file-specific. App+DB are one Application in the
  `miniflux` ns; `DATABASE_URL` (FQDN host + password) lives in the SealedSecret; app egress 80/443 is
  opened for feed fetch (default-deny otherwise stops refresh). Client/server pinned `postgres:18`
  (AR29). **DEPLOYED LIVE to k3s as a parallel run (2026-06-18):** manifests merged (PR #6) → ArgoCD
  `miniflux` Synced/Healthy; SealedSecrets sealed against the live key; `DOMAIN_RSS` render token
  registered; **0-loss verified** (live `pg_dump`→k3s `pg_restore`: feeds 9==9, users 1==1,
  entries==dump); **backup actor proven** (`pg_dump`→`r2:homelab-k3s-services-backup/miniflux/`,
  through the default-deny NetworkPolicy); all 3 nodes serve `${SECRET:DOMAIN_RSS}` at :443 with the
  prod cert (HTTP 200). **CUTOVER COMPLETE — public + LAN flipped.** Public: CF tunnel ingress
  edited via API (`rss → https://${SECRET:IP_K3S}:443` inserted before the `*.${SECRET:DOMAIN_ZONE}→NPM` wildcard;
  cloudflared first-match → k3s), verified 200 from outside. LAN: OpenWrt local-DNS override
  `rss ${SECRET:IP_COMPOSE}→${SECRET:IP_K3S}` (draw pattern). **Rollback rehearsed** at the tunnel (remove rule →
  NPM/Compose → re-add, 200 throughout). Final 0-loss: k3s `9|1|566|51` == Compose. Compose
  miniflux + miniflux-db **PARKED** (still live = the data fallback; operator retired the NPM proxy
  host for rss, so the tunnel-only rollback layer is intentionally dropped — full decommission rides
  Epic 5 Story 5.4). | [ADR-0008](adr/ADR-0008-miniflux-postgres-logical-dump.md)

## n8n cutover — CRITICAL: write-freeze + parallel run, encryption key sealed (Story 4.7)

- 2026-06-19 | n8n migrated to k3s as the **first CRITICAL cutover** (vaultwarden 4.8 follows the same
  procedure). Single-writer **SQLite** (`database.sqlite`), so it uses the file-class ingest machine
  (copy → `n8n-data` RWO PVC via `_cutover/ingest-job.yaml`), **but** the cutover quiesce is a
  **WRITE-FREEZE** — Compose n8n is **stopped** for the copy→verify→flip window (RPO=0), NOT an online
  `.backup` of a live writer (Reconciliation 2; ADR-0010). Learning-first explicitly suspended (AC1).
  The **steady-state `n8n-backup` CronJob stays an online `sqlite3 .backup` with no scale-down**
  (≤6h RPO) — same SQLite-class actor as navidrome (podAffinity to the RWO node, emptyDir scratch,
  `rclone`→`r2:homelab-k3s-services-backup/n8n/`, 30-day retention, `n8n-` prefix). **🔑 The
  encryption key is the disaster gate:** n8n auto-generated `N8N_ENCRYPTION_KEY` into the Compose
  `data/n8n/config` file (NOT `.env`) — it decrypts every `credentials_entity` row; it is sealed
  **explicitly** in `n8n-secrets` (env wins, deterministic, survives a fresh PVC) and a credential
  must **decrypt** on k3s before the flip (AR24 documented exception — rotation re-seals from `config`,
  not `.env`). Dropped the Compose `/var/run/docker.sock` mount (privilege escalation in k3s;
  Reconciliation 4) + homepage/offen labels. Public host tokenized `${SECRET:DOMAIN_N8N}`; per-host
  prod cert `n8n-tls`. **Manifests + sealed secrets (encryption key + R2 cred, sealed against the live
  cluster key) + runbook + ADR authored & validated** (`kubectl kustomize` 12 objects, `bin/render`
  resolves the token, render selftest extended for digit-bearing names). **CUTOVER EXECUTED LIVE
  2026-06-19:** ArgoCD `n8n` Synced/Healthy on an empty PVC → write-freeze (`docker compose stop n8n
  n8n-backup`) → full `data/n8n/` tree ingested (scale-0 + tar-stream + chown) → **RPO=0 verified**
  (k3s `creds 6 / workflows 25 / active 2 / execs 54` == frozen source, exact) → **all 6 credentials
  DECRYPT** on k3s (n8n export:credentials --decrypted: SSH key, DeepSeek/Discord/ntfy/Anytype/
  RocketChat — encryption key migrated) → backup actor proven (n8n-2026-…​tar.gz → R2
  `homelab-k3s-services-backup/n8n/`) → **verified restore** in a scratch ns (6 creds decrypt + 25
  workflows load from the R2 tar). Public flip: CF tunnel ingress `n8n.${SECRET:DOMAIN_ZONE} → https://${SECRET:IP_K3S}:443`
  inserted before `*.${SECRET:DOMAIN_ZONE}→NPM`; LAN: OpenWrt override `n8n ${SECRET:IP_COMPOSE}→${SECRET:IP_K3S}`; `n8n.${SECRET:DOMAIN_ZONE}`=200
  with the LE-prod `n8n-tls` cert. **🔴 Live key differed from a stale local working-copy key —
  re-sealed from the LIVE host; also sealed the workflow `$env.*` bag (ANYTYPE_BEARER etc.) the live
  container actually had.** Compose n8n + n8n-backup **PARKED** (Exited 0, rollback = flip cloudflared
  back to NPM; functional retire rides Epic 5 Story 5.4). | [ADR-0010](adr/ADR-0010-n8n-write-freeze-cutover.md)

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

## First stateful cutover — ntfy (Story 4.1)

- **2026-06-18 | ntfy cut over to k3s — the FIRST stateful cutover.** Founds the reusable
  cutover machine ([stateful-cutover.md](runbooks/stateful-cutover.md)) + the k8s-native backup
  actor (per-ns `ntfy-backup` CronJob → R2, replacing the offen sidecar). Online `sqlite3 .backup`
  of `auth.db`+`cache.db` from the live Compose source → Longhorn PVC; **0-loss verified**
  (users 2==2, token 1==1); public route flipped NPM→Traefik via the cloudflared tunnel ingress
  (config push, near-instant — no DNS TTL). **Compose ntfy is PARKED, not decommissioned** —
  rollback was *exercised* (remove the notify tunnel rule → Compose serves again, health 200),
  not assumed. (FR4/FR16/FR17/FR19, NFR1/NFR2/NFR4, AR14/AR16–AR19)
- **k3s service app-data backups → dedicated R2 bucket `homelab-k3s-services-backup`**, separate
  from Longhorn volume backups (`homelab-k3s-backup`) and legacy Compose backups
  (`home-server-backups`). Bucket-scoped R2 token ⇒ rclone `no_check_bucket=true`.
- **Bulk media is NEVER backed up to R2** (music/video/photos) — Longhorn replication + optional
  local/cold backup only; the per-service CronJob ships DB/config, not media.
- **TLS per cutover = per-host cert** (`<svc>-tls` from `letsencrypt-prod`), not a shared wildcard.
  4.3–4.8 inherit all of the above.

## Critical operational alerting — NFR15a slice (Story 4.2)

- **2026-06-18 | NFR15a critical alerting (cert-expiry / storage-80% / stateful-workload-down /
  backup-restore-job-failure) is DONE here via a single ntfy poller** (`infra/ops-alerts/`, a
  `*/15` `CronJob` reading cluster state via read-only RBAC → `curl` to the in-cluster ntfy `alerts`
  topic, `X-Priority: 5`). **NFR15b** (component/version-drift + full steady-state ops alerting + the
  ntfy-self-monitoring fix) is **deferred to Epic 5 / Phase 3** — this explicitly resolves the
  architecture's flagged NFR15 partial-gap (architecture.md 867–869). **NFR15b closed 2026-06-19
  (Story 5.1) — see below.** Runbook: [ops-alerts.md](runbooks/ops-alerts.md). (FR27, NFR15, AC3)
- **Minimal poller, NOT a monitoring stack (AC4).** No kube-prometheus-stack / Alertmanager /
  Grafana — observability is explicitly Phase 3. Read CRD status directly via kubectl (cert-manager
  `Certificate.status.notAfter`, Longhorn `nodes.longhorn.io` disk usage) instead of scraping metrics.
  Phase 3 can replace this with a real pipeline + an Alertmanager ntfy receiver if volume ever justifies it.
- **"Stateful service" = has a `<service>-backup` CronJob.** Check (c) scopes workload-readiness to
  those namespaces (ties to the Story 4.1 backup-actor convention; self-enrolls each 4.3–4.8 cutover),
  so disposable workloads (ytdlp-api) don't generate noise. Orthogonal to uptime-kuma's HTTP probes —
  the two monitors are NOT duplicates (Kuma = public HTTP from LAN; this = in-cluster pod readiness).
- **ntfy self-monitoring is a known, accepted gap.** The alert channel cannot alert on its own
  outage; ntfy-down is detected out-of-band by uptime-kuma. A second independent dead-man's-switch
  channel is the correct fix but is NFR15b/Phase-3 scope — deliberately not built in this slice.
- **No per-slice ADR.** The split is recorded here + in the runbook (AC3 accepts "ADR/runbook +
  DECISIONS.md"); a dedicated ADR would be ceremony for a four-condition slice and is not warranted.

## Full operational alerting — NFR15b slice CLOSED (Story 5.1)

- **2026-06-19 | NFR15b full-ops alerting closed — version/config drift added to `ops-alerter`;
  NFR15 condition set now complete.** Extends the 4.2 poller (no second poller — AC4 still binds)
  with: **(e)** ArgoCD `Application` drift (`OutOfSync` = config/version drift; `Degraded`/`Missing`/
  `Unknown` health) covering every ArgoCD-managed component in one CR read; **(f)** k3s node version
  drift vs the `versions.yaml` pin (`K3S_PINNED_VERSION`, baked at author time — the cluster can't
  read Git); **(g)** node `NotReady` (shares the (f) `nodes` read; SPOF/health signal, pairs with
  cold-boot 5.2). RBAC delta: +`get,list` on `applications.argoproj.io` + core `nodes` (same actor,
  read-only). NetworkPolicy unchanged (both reads hit the apiserver, already allowed). Verified
  end-to-end 2026-06-19: a real `OutOfSync` app → ntfy alert received → revert; zero baseline noise.
  Runbook: [ops-alerts.md](runbooks/ops-alerts.md). (FR27, FR29, NFR12, NFR15b, AC1–3)
- **Let ArgoCD be the drift detector — don't rebuild a version table.** ArgoCD already computes
  live-vs-desired for everything it manages and exposes it as `Application.status.sync`/`.health`,
  so the drift check is one CR read, ~10 lines of shell. Only k3s (which ArgoCD does *not* manage —
  k3s owns Traefik + its own version) needs a separate `kubeletVersion`-vs-pin compare.
- **`DRIFT_SYNC_IGNORE` excludes benign steady-state OutOfSync (default `argocd`).** The self-managed
  `argocd` app is *perpetually* `OutOfSync` on its own CMs/Secrets (a Helm/SSA self-diff, not drift);
  alerting on it would fire every poll and violate AC3's no-noise rule. **Health is never ignored** —
  a `Degraded`/`Missing` argocd is still a real alert. (Empty env = the `argocd` default, not
  "ignore nothing" — use a non-matching sentinel to alert on all apps.)
- **"Newer upstream version available" is NOT alerted here — that's Renovate's PR path.** This slice
  detects *config drift* (live ≠ Git pin), not *update availability*. No upstream registry/Helm-repo
  polling from the cluster (would duplicate Renovate + add egress surface). (architecture.md 654, 884)
- **No metrics stack (AC4 still binds).** NFR15b does NOT unlock kube-prometheus-stack/Alertmanager/
  Grafana; it's +3 branches on the existing kubectl poller. **ntfy self-monitoring gap is unchanged**
  (uptime-kuma covers ntfy liveness out-of-band) — deliberately not fixed in this slice.
- **No per-slice ADR** (consistent with 4.2) — recorded here + in the runbook; AC3 accepts that.

## Infra-stack retirement + Phase-3 monitoring decision (Story 5.5)

- **2026-06-19 | portainer + homepage retired from `docker-compose.infra.yml`; NPM / uptime-kuma /
  cloudflared kept.** Downstream of 5.4 (app Compose stack already retired) — that is what makes
  portainer redundant. **portainer** removed: its only role was managing the now-retired Compose app
  stack → fully superseded by the ArgoCD UI + `kubectl`. **homepage** removed: its ~12 links were
  folded into the existing **Karakeep** (`keep.eli.kr`, on k3s) — **no replacement dashboard service
  is introduced** (AC1). The homepage runtime config dir + its CD special-case (`deploy.js`) +
  `ENV_HOMEPAGE_ALLOWED_HOSTS` / `HOMEPAGE_ALLOWED_HOSTS` / `PORTAINER_PORT` / `HOMEPAGE_PORT` env
  vars were pruned so a `push to master` cannot recreate them. (home.server repo; FR27, AC1)
- **uptime-kuma KEPT as the external/LAN HTTP monitor — this resolves the architecture's Phase-3
  observability flag (architecture.md 162–164).** Kuma provides the *public-URL / edge* perspective
  the in-cluster ntfy poller (4.2/5.1) is structurally blind to: it catches a **healthy pod whose
  public `*.eli.kr` URL is broken at cloudflared / Traefik / DNS / cert**. The two are complementary,
  not duplicates (Kuma = public HTTP probe from LAN; ops-alerter = in-cluster pod/CRD state). **No
  duplicate cluster-internal monitoring is built that is blind to Kuma** — i.e. the Phase-3 choice
  "keep Kuma vs. stand up Prometheus" is resolved **keep Kuma**; the metrics-stack option stays
  deferred (consistent with 4.2/5.1 AC4). (AC2, NFR15)
- **NPM KEPT — out of scope, do not "helpfully" remove.** Traefik absorbs the NPM role only *per
  migrated host* (each `*.eli.kr` host has a cloudflared rule → k3s `10.0.0.101` inserted *before* the
  `*.eli.kr` wildcard → NPM fallback). NPM is still the **wildcard fallback edge** and fronts the kept
  infra UIs publicly (`kuma.eli.kr`); removing it would break `kuma.eli.kr`. Its eventual full
  retirement is a *separate* concern. (architecture.md 145, 158–164)
- **Plane 0 untouched.** cloudflared (public tunnel) lives in this same compose file but is Plane 0
  and stays running; `docker compose -f docker-compose.infra.yml up -d` leaves NPM/cloudflared
  unchanged (only uptime-kuma recreates, to drop its orphan `HOMEPAGE_ALLOWED_HOSTS` env). Nothing
  under OpenWrt / Oracle / Proxmox was touched. (AC3)
- **Cleanup status (updated 2026-06-19 code review):**
  - `docker rm -f portainer homepage` on `10.0.0.20` — **done** (LIVE 2026-06-19; host now runs only
    cloudflared/NPM/uptime-kuma).
  - `ENV_HOMEPAGE_ALLOWED_HOSTS` GitHub repo secret — **deleted**.
  - **OpenWrt LAN DNS overrides `home.eli.kr` + `portainer.eli.kr` (→ `10.0.0.20`) — done.** Both
    pointed at the now-dead containers. Removed from `local_dns_overrides`
    (`configs/openwrt/roles/openwrt-base/defaults/main.yml`) and applied **surgically** on the live
    gateway (`uci del_list` + `dnsmasq reload`), **not** a full `playbook-apply` — the repo SSOT had
    drifted from live (5.6's comics/comics-admin/books staged ahead at `.101`; vault/n8n repo-stale
    at `.20`), so a blanket apply would have reverted live cutovers / prematurely flipped un-migrated
    hosts. The vault/n8n repo staleness was fixed to `.101` in the same pass (live was already `.101`).
  - Karakeep link migration — **cancelled** (operator decision 2026-06-19; the 12 links are preserved
    in git history at `97caeec~1:configs/docker/data/homepage/{bookmarks,services}.yaml`, no data loss).
  - NPM `portainer.eli.kr` + homepage proxy-host entries — **left as-is / moot**: NPM itself is slated
    for retirement, so cleaning these inert entries (backends already down) isn't worth a separate pass.

## Day-2 self-service tooling on the platform — Semaphore + Heimdall + Beszel (Story 5.7, Epic 5 / Phase 3 — opportunistic)

- 2026-06-19 | **Heimdall REVERSES 5.5's "no replacement dashboard."** 5.5 retired the Compose
  `homepage` and folded its links into Karakeep, explicitly introducing *no* replacement dashboard.
  5.7 brings a dashboard back — but as a NEW, GitOps-managed `Deployment` on the platform, **not** by
  un-retiring `homepage` (that Compose service stays dead). Operator decision. **Karakeep overlap
  noted**: Heimdall = at-a-glance app-launcher tiles (+ optional live status); Karakeep =
  bookmark/read-later manager. The 5.5 links already live in Karakeep — re-adding them as Heimdall
  tiles is an optional operator nicety (Story 5.8 item 4), not required. | Story 5.7 (reverses 5.5 AC1c)
- 2026-06-19 | **Beszel = lightweight node-resource monitoring, explicitly NOT Prometheus and NOT a
  duplicate.** Three monitoring perspectives now exist: uptime-kuma (external/LAN HTTP up/down, sees
  `*.eli.kr` edge breakage), the ntfy poller (in-cluster ArgoCD Synced/Healthy + k3s version/node
  drift, 4.2/5.1), and **Beszel** (node CPU/mem/disk/net + HISTORY — the gap `kubectl top` leaves: no
  history, no UI). Beszel stays **within** the arch's lightweight-monitoring stance (Go binaries +
  SQLite); the heavy Prometheus/Grafana/node-exporter stack stays rejected (NFR15 = ntfy alerting). A
  fourth, kuma-blind cluster-internal monitor was NOT built (the 5.5 AC2 warning) — Beszel is a
  different layer, not a duplicate. | Story 5.7 (fills the 5.5 AC2 / architecture.md 162–164 gap)
- 2026-06-19 | **Semaphore manages Plane 0 (OpenWrt) FROM INSIDE k3s — the sanctioned easy path is the
  drift CHECK, not a one-click apply.** OpenWrt is the high-blast-radius gateway the cluster's own LAN
  rides on; a web "Run" button doing a LIVE `playbook-apply.yml --diff` would bypass the mandated
  `--check --diff → human review → approval` discipline and could cut the network that serves Semaphore
  itself (circular dependency). So the **default/scheduled** template is `--check --diff` (scheduled
  drift detection — complements 5.1 drift alerting); the **LIVE apply** template exists but is
  documented review-required, operator-triggered, NOT scheduled, NOT one-click. **Recovery from a bad
  apply is the CLI** (workstation ssh / `configs/openwrt/Makefile`), never "click Run again." | Story 5.7
- 2026-06-19 | **Secrets stay SOPS-in-git; the age key is delivered as a SealedSecret — Semaphore's
  built-in Key Store is deliberately NOT used.** The Ansible secrets remain SOPS-encrypted in git
  (`group_vars/*.sops.yaml`); Semaphore consumes them by being handed the **age key as a SealedSecret**
  (the same delivery every other pod secret uses) and decrypting at play runtime via `community.sops`.
  Rationale = minimal operational *overhead*, not minimal install effort: (1) **one secret-management
  surface**, not two — migrating into Semaphore's store forks the SSOT and doubles backup/audit/rotation
  surface; (2) **zero new keys** — the SOPS recipient `age1chmmudv…` is the SAME age identity the cluster
  DR/backup already uses; (3) **break-glass preserved** — secrets stay decryptable from the workstation
  Makefile if Semaphore/the cluster is down (Semaphore must never be the *only* thing that can decrypt);
  (4) KMS/Vault is the enterprise-canonical next step but overkill for a single operator on a running
  age scheme — revisit only if secret access spreads beyond the operator. | Story 5.7
- 2026-06-19 | **No backup actors for these three (deliberate, unlike 5.6).** Semaphore (run history +
  project config), Heimdall (tile layout), and Beszel (pairings + short-horizon metrics) hold only
  **reproducible config** — losing it costs minutes of re-clicking, not data loss. So no R2 backup
  CronJob, no backup actor. (Contrast 5.6's komga/calibre reading-progress DBs, which got R2 actors.)
  | Story 5.7

## Final legacy teardown + R2 monitor + ntfy topic split + full NPM retirement (Story 5.8, Epic 5 / Phase 3 — opportunistic)

- 2026-06-19 | **Rollback net torn down — forward-only, the net's whole purpose is now served.** 5.4
  kept the parked app Compose volumes + `*.retired-5.4` files AS the rollback net; the migration is
  DONE with restores verified from R2 in scratch namespaces (Epic 4), and the operator's stance is
  forward-only (memory `cutover_no_rollback`), so removing the net is correct — but irreversible, on
  the live shared-project host. Deleted by **explicit volume name** (never `compose down -v` —
  cloudflared/Plane 0 shares the project). | Story 5.8 (AC1)
- 2026-06-19 | **Full NPM retirement — the interim "keep NPM" decision is REVERSED.** NPM fronted SIX
  hosts (`jellyfin`/`immich`/`proxmox`/`openwrt`/`kvm` + `kuma`), not three. All six move to Traefik:
  **kuma becomes a real k3s workload** (PVC + R2 backup actor, data byte-verified per
  `cutover_data_consistency`); the **five stateless externals are EndpointSlice-fronted** (headless
  Service + manual EndpointSlice → external IP:port, per-host Certificate + IngressRoute — zero
  migration, k3s just reverse-proxies them). Then **NPM container + volume are deleted** and the legacy
  CF DNS token **`ca7e70a5` is revoked** (cert-manager keeps `3b2b473a`). This completes
  `architecture.md:145` (Traefik absorbs the NPM role) and is the deferred completion of 5.5's charter;
  the original memory `cloudflare_dns_tokens` note ("retire NPM token after Compose") is **restored**.
  Accepted gap: in-cluster kuma can't be its own out-of-band watcher for a total k3s outage → one
  external ping (Cloudflare Health Check / free monitor) covers it; recovery for proxmox/openwrt/kvm
  during a k3s outage is the **LAN IP**, not the public host (documented in the runbook). cloudflared untouched;
  NPM/token deleted ONLY after all six verify on Traefik. | Story 5.8 (AC6)
- 2026-06-19 | **R2 backup monitoring folded INTO the ops-alerter — not a new system.** The `*/15`
  poller (4.2/5.1) gains three R2 checks via the reused bucket-scoped cred (reseal of `ntfy-backup-r2`):
  per-bucket **capacity** (before the ~10 GB free tier), per-`<svc>/` **freshness** (newest object stale
  ⇒ a backup actor silently broke), and per-`<svc>/` **rotation** (oldest object too old ⇒ retention
  failing — the blind spot 4.8 left behind `\|\| true`). A standalone monitor Deployment would
  re-litigate NFR15's deliberate rejection of a heavy metrics stack. `rclone size` + one recursive
  `lsjson` per bucket; no Cloudflare GraphQL analytics. No NetworkPolicy delta (the existing
  `0.0.0.0/0:443` egress already covers R2 + the apk CDN). | Story 5.8 (AC2)
- 2026-06-19 | **ntfy split by CONCERN, not per-app (answering the operator's "앱 별?").** Three topics:
  `homelab-critical` (NFR15a stateful/backup failures + R2 — wake me), `homelab-ops` (NFR15b drift/health
  — review when convenient), `homelab-monitor` (Beszel node-resource — glance). **Per-app topics (15 of
  them) deliberately NOT done**: 15 subscriptions of mostly-silence is management noise, not value.
  Per-app filtering stays available **within** a topic via the app-name title prefix the alerts already
  carry + ntfy tags/priority. ntfy is `deny-all`, so the existing token user is granted `wo` on the new
  topics via `ntfy access` (no server.yml change, no SealedSecret reseal — same user, more grants). |
  Story 5.8 (AC3)
- 2026-06-19 | **edge-proxies EndpointSlices are applied OUT OF BAND, not by ArgoCD (discovered live).**
  ArgoCD's default `resource.exclusions` (argocd-cm) excludes BOTH core/v1 `Endpoints` and
  `discovery.k8s.io/EndpointSlice` — the standard default that stops ArgoCD watching control-plane
  endpoint churn. So the manual EndpointSlices fronting the 5 external hosts can't be GitOps-synced
  (they show ExcludedResourceWarning). Rather than un-excluding the kind cluster-wide (which would
  make ArgoCD watch every endpoint object in the cluster — the noise the exclusion exists to prevent),
  the 5 slices are applied via `workloads/edge-proxies/apply-endpoints.sh` (render + kubectl apply).
  They're static (one backend IP each) and a selector-less Service never prunes them, so they persist;
  the script is re-run after a cluster rebuild. The Service/Certificate/IngressRoute stay ArgoCD-managed.
  | Story 5.8 (AC6b)
- 2026-06-19 | **uptime-kuma is INTERNAL-only, not public (operator decision, post-cutover).** The
  cutover initially gave kuma a public cloudflared rule, but a monitoring dashboard shouldn't be
  internet-facing. Fix: removed kuma's cloudflared ingress rule + changed the `*.eli.kr` wildcard from
  Traefik to **default-deny `http_status:404`** (only kuma relied on the wildcard; the public apps have
  explicit rules; the internal-only services — semaphore/heimdall/beszel/traefik/comics-admin — are
  NXDOMAIN so were never exposed by the wildcard). Result: kuma external = 404, LAN = served via the
  OpenWrt `.101` override → Traefik. kuma now matches the 5.7 internal-only pattern. The external
  uptime watcher (AC6e) therefore targets `notify.eli.kr` (public), not kuma. (Optional cleanup: delete
  the kuma.eli.kr public DNS record for NXDOMAIN parity — needs Zone:DNS:Edit.) | Story 5.8 (AC6a/6e)
- 2026-06-19 | **proxmox / openwrt / kvm are INTERNAL-only (operator decision, post-cutover).** These
  three are sensitive infra UIs (hypervisor root / gateway admin / hardware+power control). They were
  public via NPM before (public DNS + NPM conf), but on review the operator locked them to LAN-only:
  removed their cloudflared ingress rules → external = 404 (wildcard default-deny), LAN served via the
  OpenWrt `.101` override → Traefik (their edge-proxies Service/EndpointSlice/Certificate/IngressRoute
  stay — they front LAN traffic). Remote access is WireGuard/LAN, not the public edge. jellyfin + immich
  stay PUBLIC (media, own auth — operator's call). (Optional: delete their public DNS records for
  NXDOMAIN parity.) | Story 5.8 (AC6b)
- 2026-06-19 | **Heimdall tile list lives in the runbook (reproducibility, honoring 5.7's claim).** 5.7
  shipped Heimdall with no backup actor on the claim its config is "trivially reproducible." Hand-clicking
  tiles and walking away would quietly break that, so the **runbook tile-list (or an exported JSON) is the
  deliverable** and the clicking just applies it. No tile-as-code automation (YAGNI for one operator). |
  Story 5.8 (AC4)
- 2026-06-20 | **cloudflared (Plane 0) moved INTO k3s; the standalone docker LXC (10.0.0.20) is
  retired.** cloudflared was the last service on the docker LXC after 5.8. Relocated as a 2-replica
  infra Deployment (`infra/cloudflared`, soft anti-affinity, `/ready` probe, `maxUnavailable:0`) on
  the SAME tunnel/token (sealed) — Cloudflare load-balances all connections so the .20↔k3s overlap was
  zero-downtime; verified the edge serves from k3s alone before stopping .20. Then the `homelab-docker`
  self-hosted runner was stopped, the home.server infra CD disabled (`deploy.yml` push-trigger removed +
  `if:false`), and **LXC 202 destroyed**. Accepted circular-dependency (edge inside the cluster it fronts):
  post-5.8 every public host already routes through Traefik in k3s, so a k3s outage takes services down
  regardless; proxmox/openwrt/kvm recovery during an outage is the LAN IP (5.8 AC6e). This partially
  supersedes Story 5.9's cloudflared-CD migration (no Compose CD left to move); 5.9's OpenWrt/Oracle/
  Proxmox→private-repo + Ansible refactor still stands. | Story 5.10 (AC2/3/4)
- 2026-06-20 | **k3s nodes grown to 16 GB RAM + a single 200 GB Longhorn disk each.** The "Longhorn
  dying" symptom was RAM pressure under the 5.8 churn (nodes were 8 GB) + the 600 s replica-replenishment
  wait leaving volumes "degraded" after blips — not disk capacity (sdb was 5% used). Rolling reboots to
  16 GB; the existing 100 GB Longhorn disk (`sdb`) grown online to 200 GB (`resize2fs`, raw ext4). Left
  `replica-replenishment-wait-interval` at 600 s (lowering it causes more full rebuilds on routine
  reboots); after each maintenance reboot, delete genuinely-failed replicas to force immediate rebuild.
  `default-disk` on the 31 GB root stays unschedulable (correct — keeps Longhorn off the OS disk). | Story 5.10 (AC1)
- 2026-06-20 | **k3s storage simplified to a single 200 GB root disk per node (operator: don't separate).**
  Initially Story 5.10 grew the dedicated Longhorn disk (`sdb`) to 200 GB, but the operator preferred one
  disk over a separate Longhorn disk. So the **root (`scsi0`) was grown 32→200 GB online** (growpart +
  resize2fs; root partition is last) and Longhorn now uses only its `default-disk` on the root; `sdb` was
  evicted and removed on all nodes. Safe on these etcd control-plane nodes because Longhorn's
  `storage-minimal-available-percentage=25` keeps 25% (≈50 GB) free for OS/etcd. The actual "Longhorn
  dying" cause was the 30 GB root filling (containerd images + the default-disk's reserved space) → root
  was 77–82% full; now 15–17%. komga's cp-1 local-volume (`/mnt/manga`, 200 GB `sdc`) is untouched. | Story 5.10 (disk)
- 2026-06-20 | **Longhorn volume-level offsite backup enabled (R2 `homelab-k3s-backup`).** All 3 k3s
  nodes are VMs on a single Proxmox host → Longhorn's 3 replicas share one failure domain, so a host
  loss takes everything; the app-level DB dumps cover critical DB state offsite but the dump-less
  services (semaphore/heimdall/beszel/suwayomi) had none. `infra/longhorn-backup/` configures the v1.12
  BackupTarget CR + a daily→12h RecurringJob (retain 10 = 5 days, incremental, ~3.5 GiB first-full over
  16 vols). **Media excluded** (navidrome-music, calibre ebook files — re-acquirable; calibre's DBs are
  still dumped to services-backup) via a job-less `no-offsite` Longhorn group, keeping total R2 ≈ 5.8 GiB
  under the 8 GiB ops-alerter threshold / 10 GiB free tier. Verified end-to-end (one-off backup → R2
  Completed). The legacy `home-server-backups` bucket (Compose-era, 59 GB) was deleted by the operator. | Story 5.10 (backup)
