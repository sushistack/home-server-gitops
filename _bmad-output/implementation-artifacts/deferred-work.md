# Deferred Work

Source: `docs/public-host-automation.md` — public-host automation migration (split 2026-06-22).
Active work this session: **Stage 1 — external-dns (Cloudflare)**. Below are the deferred siblings.

## Stage 0 — dnsmasq wildcard collapse
- **Repo:** `homelab-network` (`ansible/host_vars/gateway.yml` → `local_dns_overrides`), NOT this repo.
- 21 single-host `*.eli.kr → 10.0.0.101` lines → one `/eli.kr/10.0.0.101` wildcard.
- Zero dependency, ★★★ ROI. Handle directly in homelab-network. Runbook 0 in the doc.

## Stage 2 — Tunnel config-as-code
- This repo: `infra/cloudflared/` token-mode → `credentials-file` + in-cluster ConfigMap (catch-all to Traefik).
- Depends on nothing hard, but the internal/public gate logic assumes Stage 1's external-dns. Do after Stage 1. Runbook 2.

## Stage 3 (optional) — CF Access mTLS default-deny
- CF Zero Trust dashboard / Terraform (homelab-network/oracle pattern), not this repo's manifests.
- Only worth it for "reach internal hosts without wg1". Runbook 3.

## Netdata workload — step-04 review defers (surfaced 2026-06-22)
- **Child MACHINE_GUID not persisted.** Children mount no volume for `/var/lib/netdata`, so a child restart can regenerate its guid → the parent may register it as a NEW node and fragment that node's history. Low impact (parent retains the old series for the retention window; children restart rarely). If it bites: mount a per-node hostPath/PVC for `/var/lib/netdata` or pin a stable MACHINE_GUID per node.
- **AR29 digest cutover — swap BOTH manifests together.** `netdata-parent` (deployment) and `netdata-children` (daemonset) pin the SAME `netdata/netdata` image; `version-lint` checks each manifest independently, so it would NOT catch parent/child drifting to different digests. When swapping to `@sha256` at cutover, update both in the same PR.
- **Children have no readiness probe.** With `[web] mode = none` there is no port/HTTP to probe; a wedged-but-running netdata (e.g. bad stream key) reports healthy. Container crashes are still restarted by k8s. If silent metric gaps appear, add an `exec: pidof netdata` readiness probe.

## Pre-existing (not netdata) — trade-monitor version-lint failure
- `bin/version-lint` is RED on master: `versions.yaml` `trade-monitor` still points at `workloads/trade-monitor/cronjob.yaml`, but commit `036772f` renamed it to `deployment.yaml`. One-line fix (`manifest:` path), unrelated to netdata — fix in a separate PR so CI goes green.

## Deferred from: homepage service widgets (2026-06-25)

- **Navidrome widget credentials scope:** Navidrome has no read-only role or scoped API token — `HOMEPAGE_VAR_NAVIDROME_USER/PASSWORD` exposes a reusable account password. Mitigation options: dedicated low-privilege account with a long random password, or wait for Navidrome to add API key support. `music.eli.kr` is publicly accessible (CF tunnel, no CF Access) so this is a real exposure.

## Deferred from: Longhorn → local-path migration (2026-06-26)

- **Offsite backup replacement.** Longhorn R2 RecurringJob removed. Services with app-level DB dumps (vaultwarden, ntfy, miniflux) are covered. Services WITHOUT offsite backup: semaphore, komga, suwayomi, anytype, karakeep. Implement a rclone CronJob that syncs `/var/lib/rancher/k3s/storage/` to R2 on k3s-cp-1.
- **longhorn-system namespace cleanup.** Post-merge, operator must manually delete the namespace and CRDs (see `infra/longhorn/README.md`). ArgoCD does NOT cascade-delete resources when the Application is removed.
- **ArgoCD PVC sequencing.** Merging this branch before all PVC migrations complete will cause ArgoCD OutOfSync on workload apps (immutable `storageClassName` field). Operator must complete all 20 PVC migrations BEFORE merging this PR, or temporarily disable ArgoCD auto-sync on affected apps during the migration window.
- **DiskPressure alerting regression.** Old check fired at 80% disk usage; new check (k8s DiskPressure condition) fires at ~10–15% free space remaining. Acceptable for a homelab; revisit with node-exporter if proactive alerting matters.
- **local-path PVC re-creation risk.** If a `local-path-retain` PVC is ever deleted and re-created, the new PV will provision on whichever node the first pod schedules on (no static node constraint). `WaitForFirstConsumer` on the StorageClass helps but does not guarantee k3s-cp-1 without a nodeSelector on the deployment. Add nodeSelector to high-stakes workloads (vaultwarden, ntfy) if needed.

## Deferred from: code review of spec-music-lidarr (2026-06-23)

- All media stacks (komga/suwayomi/lidarr/slskd/soularr/navidrome) are pinned to k3s-cp-1 via node-local PVs → single-node SPOF + resource contention. Track in capacity monitoring (netdata/ops-alerts); revisit if the node gets tight or HA becomes a requirement.
