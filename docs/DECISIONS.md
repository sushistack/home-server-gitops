# Decisions

Running log of load-bearing decisions. One line each; link the story.

## Vaultwarden cutover (CRITICAL, LAST) + project DONE audit (Story 4.8)

- 2026-06-19 | **Vaultwarden cut over to k3s — the LAST stateful service.** Same SQLite write-freeze
  machine as ntfy/navidrome/n8n: `docker compose stop` (single-writer freeze) → online
  `sqlite3 .backup` + carry **`rsa_key.pem`** (JWT signing — lose it = mass re-auth) + attachments →
  ingest into the `vaultwarden-data` Longhorn PVC (pre-populated BEFORE the app existed, to dodge the
  ApplicationSet selfHeal/empty-init race — `automated{selfHeal}` can't be paused on an appset-managed
  Application) → ArgoCD app generated (commit e5b5a08) → **verify-before-flip: db.sqlite3 sha256
  byte-identical to source, users 1==1, ciphers 515==515, /alive+web 200, vaultwarden-tls LE-prod
  Ready** → flip CF tunnel (`vault.eli.kr→10.0.0.101:443` before `*.eli.kr→NPM`, API PUT) + OpenWrt
  LAN override (10.0.0.20→10.0.0.101, uci). Public (CF edge) + LAN both 200. **Window ≈6 min ≤10,
  RPO=0.** Backup actor proven (R2 `…/vaultwarden/`) + verified restore in a scratch ns. Compose
  vaultwarden **PARKED** (restarted, localhost 200) as the rollback net; `vaultwarden-backup` left
  stopped so it can't stop the parked container. [ADR-0009](adr/ADR-0009-vaultwarden-critical-last.md),
  [runbook](runbooks/vaultwarden.md), [DONE.md](DONE.md)
- 2026-06-19 | **Project DoD audited ([DONE.md](DONE.md)).** All 9 application services + platform on
  ArgoCD Synced/Healthy (only the `argocd` self-app is intentionally OutOfSync), Gate 0 + per-service
  verified restores, ADRs linked (CI green), exposure gate green, NFR15a verified. **One open DoD line:
  the self-heal demo clip (clip 2) is recording-pending (operator-deferred, Story 3.3).** DONE is
  declared **subject to the operator accepting that deferral** (AC4: optional polish must not block
  DONE). **Epic 5 / Phase 3 is optional, post-DONE; Compose is PARKED not retired (retire = Story 5.4)
  — the dual-run rollback net stays until then.**
- 2026-06-19 | ⚠️ **Found (operator follow-up): `argocd-render-tokens` Secret has a pre-existing
  newline-corruption** — `CLOUDFLARE_DNS01_TOKEN`'s value runs into `DOMAIN_NTFY=notify.eli.kr` with no
  separator (a clean `DOMAIN_NTFY` line also exists below it). Harmless to rendering (cert-manager uses
  its own `cloudflare-dns01-token` Secret in ns cert-manager) but it pollutes that token value. Left
  untouched during the vault cutover (didn't want to risk the DNS token); operator should re-split the
  line. `DOMAIN_VAULTWARDEN=vault.eli.kr` was appended cleanly below it.

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
  Public flip: CF tunnel ingress edited via API (`keep → https://10.0.0.101:443` inserted before the
  `*.eli.kr→NPM` wildcard) → 200 from outside. LAN flip: OpenWrt local-DNS override (NEW entry
  `keep → 10.0.0.101`, draw pattern) → direct path 200 with the LE-prod `keep.eli.kr` cert. Compose
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
  edited via API (`rss → https://10.0.0.101:443` inserted before the `*.eli.kr→NPM` wildcard;
  cloudflared first-match → k3s), verified 200 from outside. LAN: OpenWrt local-DNS override
  `rss 10.0.0.20→10.0.0.101` (draw pattern). **Rollback rehearsed** at the tunnel (remove rule →
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
  workflows load from the R2 tar). Public flip: CF tunnel ingress `n8n.eli.kr → https://10.0.0.101:443`
  inserted before `*.eli.kr→NPM`; LAN: OpenWrt override `n8n 10.0.0.20→10.0.0.101`; `n8n.eli.kr`=200
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
  architecture's flagged NFR15 partial-gap (architecture.md 867–869). Runbook:
  [ops-alerts.md](runbooks/ops-alerts.md). (FR27, NFR15, AC3)
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
