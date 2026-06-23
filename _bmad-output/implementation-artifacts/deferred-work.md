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

## Deferred from: code review of spec-music-lidarr (2026-06-23)

- All media stacks (komga/suwayomi/lidarr/slskd/soularr/navidrome) are pinned to k3s-cp-1 via node-local PVs → single-node SPOF + resource contention. Track in capacity monitoring (netdata/ops-alerts); revisit if the node gets tight or HA becomes a requirement.
