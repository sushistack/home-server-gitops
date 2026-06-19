# Runbook: GitOps upgrade & rollback discipline

> The **reusable** procedure for upgrading any platform/component version and rolling it
> back — **without** a hand-run `kubectl`/`helm`. Authored in Story 5.3. Every version pin
> lives in [`versions.yaml`](../../versions.yaml) (the SSOT); upgrades flow through a PR and
> revert with `git revert` + a sync. This is **discipline + proof**, not new infrastructure —
> the reconcile/revert mechanism is inherent from Epic 1.

## What it does

Makes "what is on what version" answerable from one file and every version change
**revertible as an ordinary commit**:

- **Version SSOT** — all pins live in [`versions.yaml`](../../versions.yaml): platform charts
  (k3s, ArgoCD, Longhorn, cert-manager, sealed-secrets) and the workload image registry.
  `bin/version-lint --list` prints the whole inventory; `bin/version-lint` fails CI if a
  manifest's image drifts from the ref pinned in `versions.yaml`.
- **The 3-line rule** — an upgrade is **(1)** a PR, **(2)** applied **one component at a time**,
  **(3)** with app health confirmed **green before the next** component is touched.
- **Differential policy** — **conservative on etcd/k3s** (lag a release, read the
  changelog/breaking-changes first; the multi-node-on-one-host etcd-quorum race makes k3s the
  highest blast radius), **current on ArgoCD** (CRDs stay `argoproj.io/v1alpha1` even on 3.x, so
  a chart bump won't silently break refs).
- **Renovate proposes, never merges** — [`renovate.json`](../../renovate.json) opens one PR per
  available component upgrade against `versions.yaml`/the manifests; a human reviews and merges.
- **Rollback = `git revert` + sync** — never a manual `kubectl rollout undo` / `helm rollback`
  (out-of-band drift is reverted by ArgoCD self-heal anyway). See **Backup/restore** below.

## Health check (exact command → expected output)

"Green" for a component = its ArgoCD `Application` is **`Synced` AND `Healthy`**:

```sh
# whole platform at a glance:
kubectl -n argocd get applications
#   NAME           SYNC STATUS   HEALTH STATUS
#   <component>    Synced        Healthy        <- the bar to clear before the next component

# one component (with argocd CLI, if installed):
argocd app get <component>          # -> Sync Status: Synced / Health Status: Healthy

# confirm the running version actually changed (example: a workload image):
kubectl -n <ns> get deploy <app> -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

# confirm the pin matches the SSOT (no drift):
bin/version-lint
```

Plus the app's own probe (e.g. `curl -fsS https://${SECRET:DOMAIN_<SVC>}/...`) — see that
service's runbook. The **`argocd` self-app is intentionally `OutOfSync`** (manual-sync
self-management guard, ADR/argocd.yaml) — that is expected, not a failure.

## If DOWN do this (in order)

An upgrade went bad (app `Degraded`/`OutOfSync`, or the new version misbehaves). **Roll back
through Git — do not hand-edit the cluster.**

1. **Identify the upgrade commit** — `git log --oneline -- versions.yaml workloads/ argocd/apps/`
   (or the Renovate PR merge commit).
2. **Revert it** — `git revert <upgrade-commit-sha>` → push to `master`.
3. **Reconcile** — ArgoCD auto-syncs `master` (`targetRevision: HEAD`, ≤ ~2 min, NFR16). To force
   it immediately:
   ```sh
   argocd app sync <component>
   # no CLI:
   kubectl -n argocd patch application <component> --type merge \
     -p '{"operation":{"sync":{"revision":"HEAD"}}}'
   ```
4. **Confirm green again** — re-run the Health check above; the **prior** version is now `Healthy`.
5. **Health-gate caught it for you?** A bad image often never goes live — the rollout is
   health-gated, the old pod keeps serving, the Application shows `Degraded` but traffic is fine.
   You still revert (so Git matches reality), but there was no outage.
6. **Never** `kubectl rollout undo` / `helm rollback` / `kubectl set image` — that creates drift
   ArgoCD self-heal will fight, and it isn't recorded in Git. The revert IS the rollback.

## Common failures

- **Reverted in Git but the cluster didn't change** — auto-sync is off for that app (e.g. the
  `argocd` self-app is manual). Sync it explicitly (step 3). Confirm `spec.syncPolicy.automated`
  exists for normal workloads.
- **`bin/version-lint` red on a Renovate PR** — Renovate bumped the manifest image (or app
  `targetRevision`) but not the `versions.yaml` mirror. Bump both **in the same PR** (the lint is
  the forcing function). The image customManager + the chart `# renovate:` hints are configured to
  do this automatically; if a new workload isn't covered, add it to the `versions.yaml` registry.
- **A digest-only image gets no Renovate PR** — `name@sha256:` with no tag is immutable and not
  trackable (no tag to follow). Re-pin as `name:<tag>@sha256:<digest>` to make it trackable. Honest
  ceiling, by design (max-pinned).
- **k3s/etcd upgrade stalls a node / breaks quorum** — this is exactly why k3s is *conservative*
  and **never the demo component**. Treat as the bare-metal-recovery domain, not a routine bump:
  [bare-metal-recovery.md](bare-metal-recovery.md). Lag a release; read the changelog first.
- **Longhorn `pre-upgrade` hook deadlocks the sync** — known trap, the checker is disabled in the
  app values (`preUpgradeChecker.jobEnabled: false`); our upgrade path is a GitOps version bump,
  not an in-cluster `helm upgrade`, so we never depend on it.
- **Two components bumped in one PR** — violates the 3-line rule (you can't tell which broke).
  Split the PR; one component at a time.

## Backup/restore commands

**Rollback IS the restore here — it is `git revert` + a sync, nothing to un-tar:**

```sh
git revert <upgrade-commit-sha>        # 1. inverse commit
git push origin master                 # 2. (PR it if you want the review gate)
argocd app sync <component>            # 3. or wait ≤2 min for auto-sync; or the kubectl patch above
kubectl -n argocd get applications     # 4. confirm Synced + Healthy on the prior version
```

For a component that also holds **data** (a chart upgrade that migrates a DB/volume), the data
restore is the per-service backup actor + Longhorn/Gate-0 chain — **out of scope for a version
revert** (a version revert changes the *spec*, not the data). See that service's runbook and
[bare-metal-recovery.md](bare-metal-recovery.md). For a stateless component (the AC5 demo class)
the revert is the whole story.

## Escalation / depends-on

- **Depends on:** ArgoCD reconciling `master` (`targetRevision: HEAD`); the exposure gate +
  `bin/version-lint` + `bin/adr-link-check` CI passing before merge;
  [`versions.yaml`](../../versions.yaml) as the SSOT; [`renovate.json`](../../renovate.json) for
  drift PRs.
- **Differential-policy escalation:** an **etcd/k3s** bump is never routine — pair with
  [bare-metal-recovery.md](bare-metal-recovery.md) and lag a release. An **ArgoCD** bump is
  current-policy and low-risk (API version unchanged on 3.x).
- **Version-drift alerting** (a pin is behind upstream) is **Story 5.1 / NFR15b**, not this
  runbook — this runbook makes upgrades *flow and revert*; 5.1 makes drift *alert*.
- **Decision log:** every upgrade performed is recorded one line in
  [DECISIONS.md](../DECISIONS.md).
