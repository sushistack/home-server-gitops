---
title: 'Music auto-collection (Lidarr + slskd + soularr) on k3s'
type: 'feature'
created: '2026-06-23'
status: 'done'
baseline_commit: '239583236aed941facc5c689945c680eeb9f85d9'
context:
  - '{project-root}/workloads/komga/'
  - '{project-root}/workloads/navidrome/'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Navidrome's library is filled by hand. There is no automated pipeline that acquires lossless (FLAC) proper releases. Torrent/Usenet music indexers are weak for FLAC, so the source must be Soulseek.

**Approach:** Add one workload `workloads/lidarr/` (one namespace, three Deployments — the komga+suwayomi multi-component shape): **Lidarr** (library manager / wishlist), **slskd** (headless Soulseek download daemon = real FLAC source), **soularr** (loop that reads Lidarr wanted/missing → searches+downloads via slskd → triggers Lidarr import). The music library moves OFF Longhorn onto the existing node-local manga disk (`/mnt/manga/music`, k3s-cp-1) via a static `local` PV, shared read-write by Lidarr+slskd and (after migration) Navidrome — co-located on k3s-cp-1 by the local PV's nodeAffinity.

## Boundaries & Constraints

**Always:**
- Images digest-pinned (`@sha256`) with a re-resolve command + date comment above (komga `deployment-suwayomi.yaml` pattern).
- Every Deployment: resources requests+limits, startup/readiness/liveness probes, `TZ=Asia/Seoul`. SQLite-bearing apps use `strategy: Recreate`.
- App config/DB on Longhorn RWO PVCs (`Prune=false`+`Retain`). Music library on the static `local` PV only.
- Music library co-location via the `local` PV nodeAffinity (k3s-cp-1) — never RWX-Longhorn for the library.
- slskd completed-download dir is a child of the library volume (`/mnt/manga/music/.incoming`) so Lidarr import is a same-fs hardlink/instant move.
- Secrets only as sealed-secrets. This session commits **placeholder** SealedSecrets with the exact `kubeseal` command in the header; operator reseals with real values before first sync.
- Ingress: `traefik.io/v1alpha1` IngressRoute — one websecure(:443) route + one web(:80)→https redirect Middleware per host; cert-manager Certificate (DNS-01) → `secretName <app>-tls`; Host = `${SECRET:DOMAIN_<APP>}`. Lidarr(8686) + slskd(5030) both INTERNAL = CF Access (external-dns target annotation `761ca633-…cfargotunnel.com`). soularr has no route.
- Deliverable = manifests + runbook only. Validate with `kustomize build` render. NO cluster apply, NO disk/SSH ops, NO migration execution this session (all documented in the runbook for operator execution).

**Ask First:**
- Navidrome repoint cutover (committing the music-volume swap) — must NOT auto-sync before the data copy completes, or Navidrome serves an empty library. Stage/sequence per runbook; confirm before merging the repoint.
- Any `qm resize 101` / new disk — shared 200G manga disk has headroom (~90G used); only resize if the runbook check shows pressure.

**Never:**
- No plaintext secrets, no `traefik.containo.us` API, no `:latest`/floating tags, no RWX-Longhorn for the library, no inbound Soulseek port-forward (peer via server relay is fine for a homelab).
- Do not mount the media volume into soularr (it orchestrates via API only).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Wanted album exists on Soulseek | Lidarr monitors artist, album missing | soularr finds it on slskd, downloads FLAC to `/mnt/manga/music/.incoming`, Lidarr imports (hardlink) into library; Navidrome sees it | N/A |
| No FLAC match | Album missing, no lossless source | soularr leaves it wanted, no import, retries next cycle | log only; no crash |
| slskd creds missing/placeholder | SealedSecret not resealed | slskd fails Soulseek login | runbook step 1 reseal gates first sync |
| Disk full (shared with manga) | `/mnt/manga` near capacity | downloads fail | runbook: `qm resize 101` online grow |

</frozen-after-approval>

## Code Map

- `workloads/komga/deployment-suwayomi.yaml` -- multi-component + busybox `data-fix` chown initContainer + node-local PV mount (rw) — copy shape for slskd/lidarr.
- `workloads/komga/pvc-manga-local.yaml` -- static `local` PV + nodeAffinity + RWX + Retain + claimRef — copy for the music PV.
- `workloads/komga/{ingressroute,certificate,kustomization,pvc-config,backup-cronjob}.yaml` -- INTERNAL exposure, per-host cert, multi-component kustomization `labels:` block, Longhorn config PVCs, R2 sqlite backup actor.
- `workloads/navidrome/{deployment,pvc,kustomization}.yaml` -- current `navidrome-music` Longhorn PVC (migration source) + repoint target.
- `internal/tokens.example.env` -- DOMAIN_* registry (render fails closed on unregistered tokens).

## Tasks & Acceptance

**Execution:**
- [x] `workloads/lidarr/namespace.yaml` -- namespace `lidarr`.
- [x] `workloads/lidarr/pvc-music-local.yaml` -- static `local` PV `lidarr-music-local` (path `/mnt/manga/music`, k3s-cp-1, RWX, Retain, claimRef lidarr) + matching PVC — copy `pvc-manga-local.yaml`, path/names changed.
- [x] `workloads/lidarr/pvc-config.yaml` -- `lidarr-config` + `slskd-config` + `soularr-data` Longhorn RWO PVCs (`Prune=false`+`Retain`).
- [x] `workloads/lidarr/deployment-lidarr.yaml` -- `lscr.io/linuxserver/lidarr` digest-pinned; `PUID/PGID=1000`, TZ; `/config`(Longhorn) + `/music`(music PV, rw, root folder); port 8686; Recreate; HTTP probes on 8686.
- [x] `workloads/lidarr/deployment-slskd.yaml` -- `slskd/slskd` digest-pinned; UI 5030; `envFrom` slskd-soulseek secret; `/app`(Longhorn slskd-config) + music PV rw (download dir `/mnt/manga/music/.incoming`); busybox `data-fix` chown initContainer if image uid≠root; Recreate; HTTP probes on 5030.
- [x] `workloads/lidarr/deployment-soularr.yaml` -- `mrusse08/soularr` digest-pinned; no UI; in-process loop (interval via config/env); mount soularr-config secret at `/data/config.ini` + `soularr-data` PVC at `/data`; NO media mount; resources+limits; exec/startup guard (no port).
- [x] `workloads/lidarr/services.yaml` -- ClusterIP `lidarr`(8686) + `slskd`(5030).
- [x] `workloads/lidarr/ingressroute.yaml` -- lidarr + slskd both INTERNAL: per-host websecure route + one shared web→https redirect Middleware; external-dns target annotation; hosts `${SECRET:DOMAIN_LIDARR}` / `${SECRET:DOMAIN_SLSKD}`.
- [x] `workloads/lidarr/certificate.yaml` -- `lidarr-tls` + `slskd-tls` (letsencrypt-prod, DNS-01).
- [x] `workloads/lidarr/sealedsecret-slskd.yaml` -- `slskd-soulseek` (Soulseek username/password + API key consumed by soularr); **placeholder** encryptedData + `kubeseal` command in header.
- [x] `workloads/lidarr/sealedsecret-soularr.yaml` -- `soularr-config` (config.ini: Lidarr URL+API key, slskd URL+API key+download path); **placeholder** + `kubeseal` header.
- [x] `workloads/lidarr/backup-cronjob.yaml` -- online `sqlite3 .backup` of `lidarr-config` → R2 (komga actor verbatim, paths changed); references SealedSecret `lidarr-backup-r2`. Left OUT of kustomization until sealed.
- [x] `workloads/lidarr/kustomization.yaml` -- list resources; `labels:` block (`includeSelectors:false`, part-of: lidarr); backup-cronjob + its R2 secret commented out (komga precedent).
- [x] `workloads/lidarr/runbook.md` -- six H2s + disk prep (`mkdir/chown /mnt/manga/music/.incoming` on k3s-cp-1 via `ssh root@10.0.0.2`), kubeseal resealing (incl. 2-stage: Lidarr API key only exists after Lidarr first boot), and the Navidrome migration+cutover sequence.
- [x] `workloads/navidrome/pvc-music-local.yaml` -- new static `local` PV `navidrome-music-local` + PVC (same `/mnt/manga/music` path, claimRef navidrome) so Navidrome co-locates on k3s-cp-1 and shares the library.
- [x] `workloads/navidrome/deployment.yaml` -- repoint `music` volume from `navidrome-music` (Longhorn) → `navidrome-music-local`.
- [x] `workloads/navidrome/kustomization.yaml` -- add `pvc-music-local.yaml`; keep old `navidrome-music` PVC (Retain, data safety).
- [x] `internal/tokens.example.env` -- add `DOMAIN_LIDARR` + `DOMAIN_SLSKD` (blank placeholders + comment, INTERNAL hosts).

**Acceptance Criteria:**
- Given the filled manifests, when `kustomize build workloads/lidarr` runs, then it renders with no errors and emits 1 namespace, 3 Deployments, 2 Services, IngressRoutes+Certificates for lidarr+slskd only, and the local-PV + config PVCs.
- Given `kustomize build workloads/navidrome`, when rendered, then Navidrome's music volume binds `navidrome-music-local` and the old `navidrome-music` PVC is still present (Retain).
- Given the spec's "no apply" scope, when the session ends, then no cluster/SSH/disk/migration mutation was performed — only files written and render-validated.
- Given every IngressRoute, when inspected, then Host uses `${SECRET:DOMAIN_*}` (registered in tokens.example.env), carries the external-dns CF-tunnel target annotation, and has a paired web→https redirect.

## Design Notes

- **Cross-namespace library sharing:** a `local` PV has ONE claimRef/namespace. lidarr+slskd share one PVC (`lidarr-music-local`, ns lidarr, like komga+suwayomi). Navidrome (different ns) gets its OWN PV+PVC pointing at the SAME host path `/mnt/manga/music` — multiple `local` PVs may bind the same directory; nodeAffinity co-locates all consumers on k3s-cp-1.
- **Same-fs import:** library root `/mnt/manga/music`, slskd completed `/mnt/manga/music/.incoming` → Lidarr import hardlinks within one fs (instant, no copy).
- **Placeholder secrets:** committed SealedSecrets carry obvious placeholder `encryptedData` (valid YAML → render passes) + the exact `kubeseal` command; operator reseals before ArgoCD first sync. Lidarr API key is unknown until Lidarr boots once → soularr config is a documented 2-stage reseal.

## Verification

**Commands:**
- `kustomize build workloads/lidarr` -- expected: renders clean; 3 Deployments, lidarr+slskd Service/IngressRoute/Certificate, local PV + config PVCs.
- `kustomize build workloads/navidrome` -- expected: renders clean; music volume → `navidrome-music-local`; old PVC retained.
- `git grep -n 'containo.us' workloads/lidarr` -- expected: no matches.

**Manual checks:**
- Each `image:` line is `@sha256:` pinned with a dated re-resolve comment.
- No real secret values in any committed file (placeholders only).

## Suggested Review Order

**Storage & co-location (the design hinge — read first)**

- Static node-local PV → /mnt/manga/music on k3s-cp-1; nodeAffinity co-locates all consumers.
  [`pvc-music-local.yaml:15`](../../workloads/lidarr/pvc-music-local.yaml#L15)

- Navidrome's OWN PV at the SAME host path (one claimRef per ns) — how cross-ns sharing works.
  [`navidrome/pvc-music-local.yaml:12`](../../workloads/navidrome/pvc-music-local.yaml#L12)

**The three components**

- slskd: uid-1000 + data-fix chown /app; downloads into the shared volume for hardlink import.
  [`deployment-slskd.yaml:33`](../../workloads/lidarr/deployment-slskd.yaml#L33)

- Lidarr: library root /mnt/manga/music, PUID/PGID 1000, digest-pinned.
  [`deployment-lidarr.yaml:34`](../../workloads/lidarr/deployment-lidarr.yaml#L34)

- soularr: no UI, no media mount — orchestrates via API; config.ini from the SealedSecret.
  [`deployment-soularr.yaml:35`](../../workloads/lidarr/deployment-soularr.yaml#L35)

**slskd config & secrets**

- incomplete+downloads BOTH on the music volume (atomic rename); auth disabled (CF Access gates).
  [`configmap.yaml:25`](../../workloads/lidarr/configmap.yaml#L25)

- Placeholder SealedSecret + kubeseal header — reseal before first sync.
  [`sealedsecret-slskd.yaml:14`](../../workloads/lidarr/sealedsecret-slskd.yaml#L14)

**Exposure (both INTERNAL / CF Access)**

- websecure route + web→https redirect + CF-tunnel target annotation; hosts tokenized.
  [`ingressroute.yaml:19`](../../workloads/lidarr/ingressroute.yaml#L19)

**Navidrome migration (highest-risk — cutover ordering)**

- Repoint music volume to the shared local PV — must NOT sync before the data copy.
  [`navidrome/deployment.yaml:85`](../../workloads/navidrome/deployment.yaml#L85)

- HARD GATE: merge order is the only guard against an empty-library cutover.
  [`runbook.md:91`](../../workloads/lidarr/runbook.md#L91)

**Wiring & peripherals**

- Resources list + labels block; backup-cronjob deliberately excluded until R2 sealed.
  [`kustomization.yaml:8`](../../workloads/lidarr/kustomization.yaml#L8)

- DOMAIN_LIDARR / DOMAIN_SLSKD registered (render fails closed on unregistered tokens).
  [`tokens.example.env:31`](../../internal/tokens.example.env#L31)

## Review Findings (code review 2026-06-23)

### Decision-needed
- [x] [Review][Decision] RESOLVED → (b) split. Navidrome cutover had no technical gate (repoint shipped in the same commit as the lidarr workload). Resolution: the repoint (`navidrome/deployment.yaml`, `navidrome/kustomization.yaml`, `navidrome/pvc-music-local.yaml`) is now a SEPARATE stage-2 commit marked "merge AFTER data copy" — it physically cannot ArgoCD-sync before the lidarr workload + copy. [flagged by blind+edge]

### Patch (all applied)
- [x] [Review][Patch] soularr webui runs by default (`WEBUI_ENABLED:-true` in the image `run.sh`), contradicting the spec's "no UI" and running an unauthenticated web server in-pod — set `WEBUI_ENABLED=false`. [workloads/lidarr/deployment-soularr.yaml] [verified by image inspection]
- [x] [Review][Patch] soularr had no probe though the task asked for an "exec/startup guard" — added `startupProbe` exec `test -s /data/config.ini` (sh+test present; config path /data/config.ini confirmed; low risk, no crash-loop). [workloads/lidarr/deployment-soularr.yaml] [blind+edge+auditor]
- [x] [Review][Patch] disk-prep `mkdir` created only `.incoming` but the configmap also uses `.incomplete` — added `.incomplete` to the runbook disk-prep mkdir. [workloads/lidarr/runbook.md] [blind+edge]
- [x] [Review][Patch] retained old `navidrome-music` Longhorn PVC holds replicas/space indefinitely — added a "clean up after the rollback window" step to the runbook. [workloads/lidarr/runbook.md] [edge]

### Deferred
- [x] [Review][Defer] All media stacks (komga/suwayomi/lidarr/slskd/soularr/navidrome) are pinned to k3s-cp-1 by node-local PVs — single-node SPOF + resource contention; track in capacity monitoring. Pre-existing design consequence, not introduced by this change alone. [edge]
