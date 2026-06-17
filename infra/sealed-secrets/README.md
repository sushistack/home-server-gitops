# Sealed Secrets — workload secret encryption (Story 2.3)

Encrypts workload secrets so the **sealed** form is safe to commit to this
public repo; the controller decrypts them in-cluster into plain `Secret`s.
The Sealed Secrets Application is a vendor Helm `source` and therefore lives at
[`argocd/apps/sealed-secrets.yaml`](../../argocd/apps/sealed-secrets.yaml)
(wave 0), not here — there are no local manifests to put in `infra/`. This dir
holds the **OOB sealing-key export/restore runbook** (below) and the round-trip
proof — the load-bearing parts of this story.

Decision context: [`docs/DECISIONS.md`](../../docs/DECISIONS.md) and
[ADR-0004](../../docs/adr/ADR-0004-secrets-sealing-key.md).

## What is pinned / configured

- **Controller v0.37.0, chart 2.18.6** (Bitnami `sealed-secrets`), wave 0,
  namespace `sealed-secrets`, release/controller name `sealed-secrets`,
  `ServerSideApply=true` (large CRD). Pin lives in
  [`versions.yaml`](../../versions.yaml); the local `kubeseal` CLI is kept at
  the **same** v0.37.0.
- **Consumption contract: `envFrom: secretRef` ONLY.** No inline `env: ${VAR}`,
  no per-key `env: valueFrom` — both re-introduce the Compose empty-overwrite
  trap (AR22).
- **No `namePrefix` / `commonLabels`.** A SealedSecret is sealed against an exact
  `namespace/name`; Kustomize `namePrefix` rewrites the name and silently breaks
  decryption (AR27). Use the `labels:` field with the mandatory
  `app.kubernetes.io/{name,instance,part-of,managed-by}` set.

## ⚠ The sealing key IS the disaster surface

The controller's private key lives in **etcd**, as one or more `Secret`s in the
`sealed-secrets` namespace labeled `sealedsecrets.bitnami.com/sealed-secrets-key`
(the current one is `=active`). It is **NOT** captured by Longhorn PV backups
(Longhorn backs up volumes; this key is an etcd object). A cluster rebuild or
etcd loss destroys it, and **every SealedSecret ever sealed against it becomes
permanently undecryptable**. The OOB export below is therefore load-bearing, not
optional — **Gate 0 (Story 2.6) restores from it**; without it, Gate 0 fails.

## Operator runbook — export the sealing key out-of-band (AC2 / AR12)

> **Operator-run, against the live cluster.** Produces real key material. The
> only artifact that leaves the cluster is an **age-encrypted** `.age` file
> stored **off-host** (Plane 0). NEVER commit the plaintext key, and NEVER commit
> even the `.age` file — `internal/` is git-ignored and the exposure gate fails
> any commit carrying a raw key.

### 1. Export ALL sealing-key Secrets (not just the active one)

The controller rotates keys: it periodically adds a **new** active key and keeps
the old ones for decryption. A snapshot of only `=active` goes stale for
already-sealed secrets after a renewal — so export **all** of them in one file.

```sh
kubectl -n sealed-secrets get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > /tmp/ss-keys.yaml          # plaintext — /tmp only, shred after step 2

# Guard: a label typo / wrong namespace / not-yet-generated key makes `kubectl get`
# exit 0 with an EMPTY list (no error) — which would silently produce a useless export.
# Fail loudly instead. (The export is the entire DR anchor; an empty one is worse than none.)
test "$(kubectl -n sealed-secrets get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key -o name | wc -l)" -ge 1 \
  || { echo 'FATAL: no sealing-key Secrets matched — refusing to write an empty export'; exit 1; }
```

### 2. Age-encrypt and store off-host (Plane 0)

```sh
# Passphrase-based (simplest); or `age -r <recipient-pubkey>` for key-based.
# Second-resolution timestamp (NOT just %Y%m%d): two exports on the same day — e.g. an
# export right after a rotation re-export — must NOT collide on one filename and silently
# clobber the prior .age, which may be the only off-host copy of a key the new one omits.
age -p -o "sealed-secrets-keys.$(date +%Y%m%dT%H%M%S).yaml.age" /tmp/ss-keys.yaml
shred -u /tmp/ss-keys.yaml             # best-effort overwrite — see caveat below

# Move the .age ciphertext OFF this host to Plane 0 (e.g. password manager /
# offline media). It must NOT live only on a cluster node, and must NOT be
# committed (not even to internal/ in a pushed repo).
```

> **`shred` caveat (read it — this is the master key).** `shred` only reliably
> overwrites in place on a traditional journaled-off block filesystem. On `tmpfs`
> (RAM-backed `/tmp`, common on modern distros) and on copy-on-write filesystems
> (Btrfs/ZFS/overlay — k3s nodes often run overlay) it does **not** guarantee the
> plaintext is gone, and swap may already hold a copy. So treat the plaintext key
> as having existed on this host. Best practice: run the export on a host with an
> encrypted disk + disabled/encrypted swap, prefer a `tmpfs`/`ramfs` scratch dir
> you can `umount` (RAM cleared on unmount/reboot), and rely on the **age
> encryption + off-host move**, not `shred`, as the real protection.

### 3. Restore path (exercised in Gate 0 / Story 2.6)

The restored key MUST land **before** the controller's first start. If the
controller starts first and finds no key it **generates a fresh one**, and every
existing SealedSecret becomes permanently undecryptable. This is a hard ordering
constraint, and it fights this Application's own `automated:{prune,selfHeal}`
sync policy ([`argocd/apps/sealed-secrets.yaml`](../../argocd/apps/sealed-secrets.yaml)):
the instant ArgoCD's root-app reconciles, wave-0 `sealed-secrets` auto-syncs and
the controller comes up. So the key has to be in place **before ArgoCD can sync
this app** — you cannot rely on racing `kubectl apply` against an
already-running auto-sync.

**Clean rebuild (Gate 0) — restore the key BEFORE bootstrapping ArgoCD:**

```sh
# Do this on the fresh cluster while ArgoCD / the root-app is NOT yet installed.
age -d sealed-secrets-keys.YYYYMMDDTHHMMSS.yaml.age > /tmp/ss-keys.yaml
kubectl create namespace sealed-secrets --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f /tmp/ss-keys.yaml     # restore key(s) into the controller namespace
shred -u /tmp/ss-keys.yaml             # best-effort only — see the shred caveat in step 2

# Capture the restored key fingerprint so you can prove adoption (not regeneration) below.
kubectl -n sealed-secrets get secret -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort > /tmp/keys.before

# ONLY NOW bootstrap ArgoCD + the root-app. Wave-0 sealed-secrets syncs, the
# controller starts, finds the existing key(s), and adopts them.
```

**If ArgoCD is already running** (partial rebuild — controller not yet up but the
app could self-heal at any moment), suspend auto-sync first so it cannot start the
controller from under you:

```sh
kubectl -n argocd patch application sealed-secrets --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'   # pause auto-sync
# ...run the create-namespace + apply-key block above...
kubectl -n argocd patch application sealed-secrets --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'  # resume
```

**Verify adoption, not regeneration** (the failure this whole step exists to catch):

```sh
# Wait for the controller, then confirm the live key set == what you restored.
kubectl -n sealed-secrets rollout status deploy/sealed-secrets
kubectl -n sealed-secrets get secret -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort > /tmp/keys.after
diff /tmp/keys.before /tmp/keys.after \
  && echo 'OK: controller adopted the restored key(s)' \
  || echo 'DANGER: key set changed — controller may have generated a fresh key; STOP and investigate'
# Final proof: a previously-sealed SealedSecret materializes its Secret again.
```

### Rotation caveat — re-export after renewal

Default controller key renewal keeps old keys but adds a new `active` one. **Pick
one and stick to it:** (a) re-run the export after every renewal, (b) always
export ALL `sealed-secrets-key` Secrets (step 1 already does this — so a fresh
export after each renewal is the simplest discipline), or (c) disable rotation if
a single stable key is preferred. We export ALL keys each time and re-export on
renewal.

## Operator runbook — prove the round-trip (AC1 / FR24, FR25)

> Throwaway smoke test: a one-key SealedSecret consumed by a test pod via
> `envFrom: secretRef`, torn down after. Proves controller → `Secret` →
> workload. Commit only the **sealed** form if you keep any of it; never the
> plaintext `Secret`.

```sh
# 0. fetch THIS cluster's public cert (sealing is offline; decryption is controller-side)
kubeseal --fetch-cert \
  --controller-namespace sealed-secrets --controller-name sealed-secrets > /tmp/pub-cert.pem

# 1. create a plaintext Secret locally, seal it (NEVER apply the plaintext)
kubectl create secret generic demo-secrets \
  --from-literal=DEMO_KEY=it-works --namespace default \
  --dry-run=client -o yaml \
  | kubeseal --cert /tmp/pub-cert.pem --format yaml > /tmp/demo-sealedsecret.yaml

# 2. apply the SEALED form; the controller materializes a Secret of the same name+ns
kubectl apply -f /tmp/demo-sealedsecret.yaml
kubectl -n default get sealedsecret demo-secrets
kubectl -n default get secret demo-secrets          # appears once reconciled

# 3. consume via envFrom: secretRef ONLY (the contract under test)
kubectl -n default run ss-probe --image=busybox:1.36 --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"p","image":"busybox:1.36","command":["sh","-c","echo $DEMO_KEY; sleep 5"],"envFrom":[{"secretRef":{"name":"demo-secrets"}}]}]}}'
kubectl -n default logs ss-probe        # MUST print: it-works

# 4. tear down (throwaway)
kubectl -n default delete pod ss-probe sealedsecret/demo-secrets secret/demo-secrets
```

Note on "re-seal Epic 1 SealedSecrets": there are **none** — the Epic 1
Excalidraw manifests are stateless and carry no SealedSecret, so nothing from
Phase 1 needs re-sealing here.
