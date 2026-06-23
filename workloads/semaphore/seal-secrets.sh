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
#   ./seal-secrets.sh <openwrt-ssh-key> <oracle-ssh-key> <age-keys.txt> <jellyfin-ssh-key>
# Example (typical workstation paths):
#   ./seal-secrets.sh ~/.ssh/id_ed25519 ~/.ssh/oracle_proxy ~/.config/sops/age/keys.txt ~/.ssh/id_ed25519
#   (the jellyfin key is whatever opens root@<jellyfin-host>; reuse id_ed25519 if that's the one.)
set -euo pipefail

NS=semaphore
CTRL_NS=sealed-secrets                      # memory kubeseal-controller-ns (NOT kube-system)
CTRL_NAME=sealed-secrets                    # the controller SERVICE name (default is
                                            # sealed-secrets-controller — this cluster's is sealed-secrets)
DIR="$(cd "$(dirname "$0")" && pwd)"

USAGE="usage: seal-secrets.sh <openwrt-ssh-key> <oracle-ssh-key> <age-keys.txt> <jellyfin-ssh-key>"
OPENWRT_KEY="${1:?$USAGE}"
ORACLE_KEY="${2:?$USAGE}"
AGE_KEY="${3:?$USAGE}"
JELLYFIN_KEY="${4:?$USAGE}"

for f in "$OPENWRT_KEY" "$ORACLE_KEY" "$AGE_KEY" "$JELLYFIN_KEY"; do
  [ -f "$f" ] || { echo "✗ not found: $f" >&2; exit 1; }
done
command -v kubeseal >/dev/null || { echo "✗ kubeseal not on PATH" >&2; exit 1; }
command -v kubectl  >/dev/null || { echo "✗ kubectl not on PATH"  >&2; exit 1; }

# age key sanity: it must be the PRIVATE key file (AGE-SECRET-KEY...), not a public recipient.
grep -q "AGE-SECRET-KEY" "$AGE_KEY" || { echo "✗ $AGE_KEY has no AGE-SECRET-KEY line — wrong file?" >&2; exit 1; }

existing_secret_value() {
  local key="$1"
  kubectl -n "$NS" get secret semaphore-admin \
    -o "jsonpath={.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null || true
}

# Re-sealing must preserve Semaphore's admin password and access-key encryption key when the live
# secret already exists. SEMAPHORE_ACCESS_KEY_ENCRYPTION encrypts access keys stored in BoltDB;
# regenerating it orphans stored access keys.
ADMIN_PW="${SEMAPHORE_ADMIN_PASSWORD:-$(existing_secret_value SEMAPHORE_ADMIN_PASSWORD)}"
if [ -z "$ADMIN_PW" ]; then
  read -rsp "Choose a Semaphore admin password: " ADMIN_PW; echo
fi
[ -n "$ADMIN_PW" ] || { echo "✗ empty password" >&2; exit 1; }

ENC_KEY="${SEMAPHORE_ACCESS_KEY_ENCRYPTION:-$(existing_secret_value SEMAPHORE_ACCESS_KEY_ENCRYPTION)}"
if [ -z "$ENC_KEY" ]; then
  ENC_KEY="$(head -c32 /dev/urandom | base64)"
fi

seal() { kubeseal --controller-name "$CTRL_NAME" --controller-namespace "$CTRL_NS" --format yaml; }

echo "→ sealing semaphore-admin"
kubectl create secret generic semaphore-admin -n "$NS" \
  --from-literal=SEMAPHORE_ADMIN=admin \
  --from-literal=SEMAPHORE_ADMIN_NAME=admin \
  --from-literal=SEMAPHORE_ADMIN_EMAIL=admin@eli.kr \
  --from-literal=SEMAPHORE_ADMIN_PASSWORD="$ADMIN_PW" \
  --from-literal=SEMAPHORE_ACCESS_KEY_ENCRYPTION="$ENC_KEY" \
  --dry-run=client -o yaml | seal > "$DIR/sealedsecret-admin.yaml"

# All SSH keys land in ONE secret, as files under /keys/ssh/ in the pod:
#   /keys/ssh/openwrt → root@10.0.0.1   /keys/ssh/oracle → ubuntu@Oracle   /keys/ssh/jellyfin → root@jellyfin
# The Semaphore inventory points each host at its file (see runbook §1c / media-stack runbook §4).
echo "→ sealing semaphore-ssh (openwrt + oracle + jellyfin)"
kubectl create secret generic semaphore-ssh -n "$NS" \
  --from-file=openwrt="$OPENWRT_KEY" \
  --from-file=oracle="$ORACLE_KEY" \
  --from-file=jellyfin="$JELLYFIN_KEY" \
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
