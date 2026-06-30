# Langfuse — Seal Recipe & Deploy Checklist

This document covers the one-time operator steps to bring `langfuse` online.
The ArgoCD Application (`argocd/apps/langfuse.yaml`) and kustomize overlay
(`infra/langfuse/`) are committed but **will not sync correctly** until
`infra/langfuse/sealedsecret.yaml` contains real sealed values.

---

## Step 1 — Generate credentials

```bash
NEXTAUTH_SECRET=$(openssl rand -base64 32)
SALT=$(openssl rand -base64 32)
ENCRYPTION_KEY=$(openssl rand -hex 32)           # 256-bit hex (64 chars)
PG_PW=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 32)
CH_PW=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 32)
REDIS_PW=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 32)
MINIO_USER=langfuse
MINIO_PW=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 32)

# Print for reference (store in a password manager — you will need PG_PW for pg_dump)
echo "PG_PW=$PG_PW"
echo "CH_PW=$CH_PW"
echo "REDIS_PW=$REDIS_PW"
echo "MINIO_PW=$MINIO_PW"
```

## Step 2 — Seal the secret

The namespace `langfuse` does not need to exist yet — SealedSecrets are sealed
against namespace+name and the controller decrypts them after ArgoCD creates the ns.

```bash
kubectl create secret generic langfuse-secrets -n langfuse --dry-run=client -o yaml \
  --from-literal=nextauth-secret="$NEXTAUTH_SECRET" \
  --from-literal=salt="$SALT" \
  --from-literal=encryption-key="$ENCRYPTION_KEY" \
  --from-literal=postgresql-password="$PG_PW" \
  --from-literal=clickhouse-password="$CH_PW" \
  --from-literal=redis-password="$REDIS_PW" \
  --from-literal=minio-root-user="$MINIO_USER" \
  --from-literal=minio-root-password="$MINIO_PW" \
  | kubeseal --format yaml \
            --controller-name sealed-secrets \
            --controller-namespace sealed-secrets
```

Copy the output `spec.encryptedData` block and replace the PLACEHOLDER lines in
`infra/langfuse/sealedsecret.yaml`.

## Step 3 — Set DOMAIN_LANGFUSE token

Add to `internal/tokens.env`:
```
DOMAIN_LANGFUSE=langfuse.eli.kr
```

Confirm the render CMP substitutes it:
```bash
bin/render infra/langfuse/certificate.yaml | grep dnsNames -A1
bin/render infra/langfuse/ingressroute.yaml | grep Host
```

## Step 4 — Cloudflare setup

1. **DNS**: external-dns will auto-create the CNAME pointing to the CF Tunnel once
   IngressRoute is synced (the `external-dns.alpha.kubernetes.io/target` annotation).
2. **CF Access policy**: in the Cloudflare Zero Trust dashboard, add an Access
   Application for `https://langfuse.eli.kr` with a Google SSO policy (same config
   as Netdata / Lidarr). This gates the UI before Traefik even sees the request.

## Step 5 — OpenWrt LAN DNS override

Add a local DNS entry so cluster traffic uses the IngressRoute directly:
```
langfuse.eli.kr → 10.0.0.101
```
(same pattern as netdata/argocd/semaphore)

## Step 6 — Commit & sync

```bash
# After replacing PLACEHOLDER values in sealedsecret.yaml:
git add infra/langfuse/sealedsecret.yaml
git commit -m "feat(langfuse): seal credentials for initial deploy"
git push
# ArgoCD automated sync picks up the commit. Watch:
kubectl get pods -n langfuse -w
```

Expected healthy state:
```
langfuse-web-*          Running
langfuse-worker-*       Running
langfuse-postgresql-0   Running
langfuse-clickhouse-0   Running
langfuse-redis-master-0 Running
langfuse-minio-0        Running
```

## Step 7 — First login

1. Visit `https://langfuse.eli.kr`
2. Create the admin account (email + password)
3. Create a Project → copy **Public Key** and **Secret Key**
4. Disable signups: in `argocd/apps/langfuse.yaml` set `signUpDisabled: true`, commit + push

## Step 8 — Wire yt.flow

In the yt.flow environment (`.env` or Kubernetes Secret):
```
YTFLOW_LANGFUSE_HOST=https://langfuse.eli.kr
YTFLOW_LANGFUSE_PUBLIC_KEY=pk-lf-...
YTFLOW_LANGFUSE_SECRET_KEY=sk-lf-...
```

---

## Re-seal recipe (credential rotation)

Repeat Steps 1–2 with new values and commit. ArgoCD selfHeal replaces the
live Secret within one reconcile cycle. Restart pods if they cache the old creds:
```bash
kubectl rollout restart deployment -n langfuse
```
