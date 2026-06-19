#!/usr/bin/env bash
# Story 5.7 — Semaphore secret-sealing helper (OPERATOR-LIVE, Task 1b).
#
# Seals the 3 Semaphore secrets against the LIVE sealed-secrets controller and writes the real
# SealedSecret manifests IN PLACE (overwriting the PLACEHOLDER stubs). Run from a workstation that
# has kubeconfig + kubeseal pointed at the cluster. After it finishes, uncomment the 3
# sealedsecret-*.yaml lines in kustomization.yaml and commit+push — ArgoCD then starts the pod.
#
# Nothing here is a NEW key: the SSH keys + age key already exist and already work; we only seal
# copies for the in-cluster runner. The age key is the existing cluster DR identity (gate0-dr).
#
# Usage:
#   ./seal-secrets.sh <openwrt-ssh-key> <oracle-ssh-key> <age-keys.txt>
# Example (typical workstation paths):
#   ./seal-secrets.sh ~/.ssh/id_ed25519 ~/.ssh/oracle_proxy ~/.config/sops/age/keys.txt
set -euo pipefail

NS=semaphore
CTRL_NS=sealed-secrets                      # memory kubeseal-controller-ns (NOT kube-system)
DIR="$(cd "$(dirname "$0")" && pwd)"

OPENWRT_KEY="${1:?usage: seal-secrets.sh <openwrt-ssh-key> <oracle-ssh-key> <age-keys.txt>}"
ORACLE_KEY="${2:?usage: seal-secrets.sh <openwrt-ssh-key> <oracle-ssh-key> <age-keys.txt>}"
AGE_KEY="${3:?usage: seal-secrets.sh <openwrt-ssh-key> <oracle-ssh-key> <age-keys.txt>}"

for f in "$OPENWRT_KEY" "$ORACLE_KEY" "$AGE_KEY"; do
  [ -f "$f" ] || { echo "✗ not found: $f" >&2; exit 1; }
done
command -v kubeseal >/dev/null || { echo "✗ kubeseal not on PATH" >&2; exit 1; }
command -v kubectl  >/dev/null || { echo "✗ kubectl not on PATH"  >&2; exit 1; }

# age key sanity: it must be the PRIVATE key file (AGE-SECRET-KEY...), not a public recipient.
grep -q "AGE-SECRET-KEY" "$AGE_KEY" || { echo "✗ $AGE_KEY has no AGE-SECRET-KEY line — wrong file?" >&2; exit 1; }

read -rsp "Choose a Semaphore admin password: " ADMIN_PW; echo
[ -n "$ADMIN_PW" ] || { echo "✗ empty password" >&2; exit 1; }

# Generated ONCE, here. It encrypts the access keys stored in BoltDB — if you ever RESEAL the admin
# secret later, reuse the SAME value (kubectl -n semaphore get secret semaphore-admin \
#   -o jsonpath='{.data.SEMAPHORE_ACCESS_KEY_ENCRYPTION}' | base64 -d) — regenerating orphans them.
ENC_KEY="$(head -c32 /dev/urandom | base64)"

seal() { kubeseal --controller-namespace "$CTRL_NS" --format yaml; }

echo "→ sealing semaphore-admin"
kubectl create secret generic semaphore-admin -n "$NS" \
  --from-literal=SEMAPHORE_ADMIN=admin \
  --from-literal=SEMAPHORE_ADMIN_NAME=admin \
  --from-literal=SEMAPHORE_ADMIN_EMAIL=admin@eli.kr \
  --from-literal=SEMAPHORE_ADMIN_PASSWORD="$ADMIN_PW" \
  --from-literal=SEMAPHORE_ACCESS_KEY_ENCRYPTION="$ENC_KEY" \
  --dry-run=client -o yaml | seal > "$DIR/sealedsecret-admin.yaml"

# Both SSH keys land in ONE secret, as two files under /keys/ssh/ in the pod:
#   /keys/ssh/openwrt  → root@10.0.0.1   /keys/ssh/oracle → ubuntu@Oracle
# The Semaphore inventory points each host at its file (see runbook §1c).
echo "→ sealing semaphore-ssh (openwrt + oracle)"
kubectl create secret generic semaphore-ssh -n "$NS" \
  --from-file=openwrt="$OPENWRT_KEY" \
  --from-file=oracle="$ORACLE_KEY" \
  --dry-run=client -o yaml | seal > "$DIR/sealedsecret-ssh.yaml"

echo "→ sealing semaphore-age"
kubectl create secret generic semaphore-age -n "$NS" \
  --from-file=keys.txt="$AGE_KEY" \
  --dry-run=client -o yaml | seal > "$DIR/sealedsecret-age.yaml"

cat <<EOF

✅ Sealed → sealedsecret-{admin,ssh,age}.yaml (real ciphertext, safe to commit).

Next:
  1. Uncomment the 3 'sealedsecret-*.yaml' lines in kustomization.yaml.
  2. kubectl kustomize workloads/semaphore   # must still build
  3. git add -A workloads/semaphore && git commit && git push   # ArgoCD syncs → pod starts
  4. Configure the Semaphore project (runbook §1c), then run the --check drift template (§1d).

Note: SEMAPHORE_ACCESS_KEY_ENCRYPTION was generated once. On any future reseal, reuse the same value.
EOF
