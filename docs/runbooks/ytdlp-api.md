# Runbook: ytdlp-api

> Internal yt-dlp HTTP API. Migrated to k3s via the golden-path template (Story 3.1).
> **Internal-only** — no public `*.<zone>` host; consumed in-cluster by FQDN. The FR11/FR12
> external-host leg is **N/A — internal service** (Reconciliation 1, Operator-confirmed 2026-06-18).

## What it does

Internal yt-dlp HTTP API (`nbr23/youtube-dl-server`, Flask, port 8080). n8n triggers
`ytsearch1:` audio downloads (Last.fm-discovery profile: bestaudio → mp3 extract + embed
metadata/thumbnail). Downloads land in navidrome's music library; cross-run dedup is via the
metadata DB (`/downloads/.ydl-metadata.db`) + the yt-dlp archive. No UI auth, no secrets.

**On k3s today this is a golden-path *deployment* proof, not a functional cutover:** `/downloads`
is an `emptyDir` scratch volume (it owns no data — the real music library is navidrome's Longhorn
volume, wired at navidrome's Epic 4 cutover, Story 4.3). n8n (the caller) is still on Compose, so
the live functional path runs on **Compose ytdlp-api**, which is PARKED not decommissioned.

## Health check (exact command → expected output)

In-cluster (the Service has no external host):

```
kubectl run curl --rm -it --image=curlimages/curl --restart=Never -n ytdlp-api -- \
  curl -fsS -o /dev/null -w '%{http_code}\n' http://ytdlp-api.ytdlp-api.svc.cluster.local:8080/
```

Expected: `200` (the youtube-dl-server UI HTML). ArgoCD: `argocd app get ytdlp-api` →
`Synced` + `Healthy`; `kubectl get pods -n ytdlp-api` → pod `Running`/`Ready`.

## If DOWN do this (in order)

1. **Pod status** — `kubectl get pods -n ytdlp-api`; describe if not `Running`:
   `kubectl describe pod -n ytdlp-api -l app.kubernetes.io/name=ytdlp-api`.
2. **Logs** — `kubectl logs -n ytdlp-api deploy/ytdlp-api --tail=100` (look for config-load or
   extractor errors).
3. **Config mount** — confirm `/app_config/config.yml` is present:
   `kubectl exec -n ytdlp-api deploy/ytdlp-api -- cat /app_config/config.yml`. If missing, the
   `ytdlp-api-config` ConfigMap / volume mount regressed.
4. **DNS egress / outbound** — yt-dlp must resolve + reach YouTube. If a cluster default-deny
   NetworkPolicy baseline ever lands (see Common failures / **N/A today**), confirm the
   `ytdlp-api` namespace is selected by it **with the DNS-egress (kube-dns :53) allow** — without
   it, downloads silently fail while the pod stays `Healthy`.
5. **Restart** — `kubectl rollout restart deploy/ytdlp-api -n ytdlp-api`. ArgoCD `selfHeal` will
   re-converge any manual drift; the real fix for a bad change is `git revert` (GitOps).

## Common failures

- **DNS egress blocked** — *only once a cluster default-deny baseline exists.* **N/A today:**
  `kubectl get netpol -A` → none, so k3s allow-all means outbound works. When the baseline lands,
  a missing `:53`/egress allow on this namespace kills downloads silently (#1 predictable failure).
- **Image pull / digest** — image is pinned by digest (`@sha256:5b4cc20…`). A bad/removed digest
  → `ImagePullBackOff`. Re-pin via PR.
- **Stale yt-dlp extractor** — the bundled yt-dlp rots when YouTube changes its site; downloads
  start failing with extractor errors though the pod is `Healthy`. **Fix:** re-inspect
  `nbr23/youtube-dl-server:latest`, bump the digest via PR. Treat this as a recurring maintenance
  cadence, not a one-off — it is the most common real-world failure for this service.
- **Download path / permissions on `/downloads`** — on k3s it's an `emptyDir` (ephemeral): a pod
  restart loses the dedup DB → re-downloads. Acceptable for the scratch proof; resolved at the
  navidrome cutover (Story 4.3) when `/downloads` becomes navidrome's real volume.

## Backup/restore commands

**N/A — stateless, owns no data.** The music library belongs to **navidrome** and is backed
up/restored there (Story 4.3). `/downloads` here is `emptyDir` scratch — nothing to back up.

## Escalation / depends-on

- **Consumed by n8n** (the only caller; triggers `ytsearch1:` downloads). n8n is CRITICAL and
  stays on **Compose until Epic 4** — do not re-point it at the k3s Service yet.
- **Writes into navidrome's music volume.** navidrome migrates in **Epic 4 (Story 4.3)**; that is
  where ytdlp-api's real `/downloads` target (a Longhorn volume) is wired. Until then the live
  functional chain (n8n → ytdlp → navidrome) runs entirely on Compose.
- **Compose ytdlp-api is PARKED, not decommissioned** (see `docs/DECISIONS.md`). Functional
  decommission rides along with the navidrome cutover.
