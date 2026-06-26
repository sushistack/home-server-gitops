# Longhorn — removed

Longhorn was removed in favour of k3s's built-in `local-path` provisioner (`rancher.io/local-path`).
See [`infra/local-path/`](../local-path/) for the replacement StorageClass (`local-path-retain`).

## Operator cleanup required (post-merge, on live cluster)

```sh
# 1. Verify all workload PVCs migrated off Longhorn
kubectl get pvc -A | grep longhorn   # expect: no results

# 2. Remove Longhorn namespace + CRDs (ArgoCD does NOT cascade-delete after app removal)
kubectl delete namespace longhorn-system
kubectl get crd | grep longhorn.io | awk '{print $1}' | xargs kubectl delete crd

# 3. Confirm local-path-retain StorageClass is present and Healthy in ArgoCD
kubectl get sc local-path-retain
```
