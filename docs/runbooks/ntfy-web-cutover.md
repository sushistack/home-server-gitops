# Runbook — ntfy web UI cutover

Goal: move the **ntfy API server** off its old host (`${SECRET:DOMAIN_NTFY_WEB}`, which now serves
the UI) onto `${SECRET:DOMAIN_NTFY}`, and serve the **redesigned web UI**
(`workloads/ntfy-web`, image `ghcr.io/sushistack/ntfy-web`) at `${SECRET:DOMAIN_NTFY_WEB}`.

The UI is a static SPA; its baked `/config.js` has `base_url: https://${SECRET:DOMAIN_NTFY}`, so it
calls the API cross-origin. The API server (`workloads/ntfy`) is otherwise unchanged.

> Token map: `${SECRET:DOMAIN_NTFY}` = API host (the NEW host after this cutover);
> `${SECRET:DOMAIN_NTFY_WEB}` = UI host (the host the API used to live on).

## Already in git (additive, revertible — no live effect yet)

- `workloads/ntfy-web/` — Deployment/Service/IngressRoute/Certificate (host `${SECRET:DOMAIN_NTFY_WEB}`).
- `DOMAIN_NTFY_WEB` in `internal/tokens.env` (the UI host). `DOMAIN_NTFY` still = the old host.
- ntfy-web repo: `Dockerfile`, `deploy/`, GHCR CI workflow.

## Prerequisites

1. **Build the image.** Push ntfy-web `main` → CI publishes `ghcr.io/sushistack/ntfy-web`.
   Make the GHCR package **public** (else add an imagePullSecret to the Deployment).
2. **Pin the digest.** `docker buildx imagetools inspect ghcr.io/sushistack/ntfy-web:latest`,
   put the `@sha256:…` into `workloads/ntfy-web/deployment.yaml` (replaces `__FILL_AFTER_FIRST_PUSH__`).
3. **Cloudflare (out-of-band):** the tunnel currently maps `${SECRET:DOMAIN_NTFY_WEB}` → Traefik.
   Add a tunnel hostname `${SECRET:DOMAIN_NTFY}` → same Traefik origin (`https://<node>:443`,
   `originServerName=${SECRET:DOMAIN_NTFY}`). Keep `${SECRET:DOMAIN_NTFY_WEB}` → Traefik (it will now
   hit the UI).

## Token delivery (the render CMP, not just the local file)

`internal/tokens.env` is git-ignored — the render CMP reads the live `argocd-render-tokens` Secret
(data key `tokens.env`) in the `argocd` namespace. The token changes below must land in BOTH the local
file AND that Secret, or the app fails `unresolved token(s)` and never syncs:

```sh
B64=$(base64 -w0 internal/tokens.env)
kubectl -n argocd patch secret argocd-render-tokens --type merge -p "{\"data\":{\"tokens.env\":\"$B64\"}}"
# mount refreshes in ~60s
```

Specifically: set `DOMAIN_NTFY` to the new host and ADD `DOMAIN_NTFY_WEB` (the UI host).

## Cutover (ordered to avoid a publisher outage)

> ⚠️ Publishers (uptime-kuma monitor, n8n workflows, any `NTFY_BASE_URL`) currently POST to the old
> host (`${SECRET:DOMAIN_NTFY_WEB}`). Once that host serves the **static UI**, those publishes 404.
> Repoint them **before** flipping the UI in.

1. **Bring the API up on the new host.** Set `DOMAIN_NTFY` to the new host in `internal/tokens.env`
   AND the render-tokens Secret. Commit/sync. ntfy server now answers on `${SECRET:DOMAIN_NTFY}`
   (ingressroute + cert + base-url all follow the token). Verify:
   `curl -fsS https://${SECRET:DOMAIN_NTFY}/v1/health` → `{"healthy":true}`.
   *At this point the old host still points at the API too (Cloudflare), so publishers keep working.*
2. **Repoint publishers** to `https://${SECRET:DOMAIN_NTFY}` (runtime, in each app — NOT in this repo):
   - uptime-kuma: the ntfy notification + the http monitor that probes the host.
   - n8n: any ntfy nodes / `NTFY_BASE_URL` env.
   - any other token-holders.
   Confirm a test publish lands.
3. **Flip the UI in.** Sync `workloads/ntfy-web` with the real image digest. Cloudflare
   `${SECRET:DOMAIN_NTFY_WEB}` now resolves to the `ntfy-web` IngressRoute. Verify
   `https://${SECRET:DOMAIN_NTFY_WEB}` loads the UI and it talks to `${SECRET:DOMAIN_NTFY}`
   (open a topic, publish from the UI).

## Rollback

- UI bad → `git revert` the `ntfy-web` digest bump (RollingUpdate maxUnavailable:0 means the old
  ReplicaSet kept serving; nothing went down).
- API host move bad → revert `DOMAIN_NTFY` to the old host (in the Secret + local file) and re-point
  publishers back.

## Notes

- **CORS:** ntfy's API sends permissive CORS, so the cross-origin UI→API call works (proven in dev,
  where `config.js base_url` already pointed at the remote server).
- **Web push:** disabled in `deploy/config.js` (`enable_web_push:false`). To enable, copy the server's
  VAPID `web_push_public_key` into that file and rebuild.
