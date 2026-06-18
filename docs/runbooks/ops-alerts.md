# Runbook: ops-alerts (NFR15a critical alerting)

> A single k8s-native poller (`CronJob ops-alerter`, ns `ops-alerts`) that reads cluster state via
> the apiserver every 15 min and publishes to in-cluster ntfy on four **critical** conditions.
> **NOT a monitoring stack** — no Prometheus/Alertmanager/Grafana (Story 4.2, AC4). Manifests:
> [`infra/ops-alerts/`](../../infra/ops-alerts/). Depends on ntfy (Story 4.1, the alert channel).

## What it does

Polls `*/15 * * * *` (Asia/Seoul) and `curl`s a high-priority (`X-Priority: 5`) message to the ntfy
`alerts` topic on any of the four DONE-blocking conditions (**FR27, NFR15a**):

- **(a) cert expiry** — a cert-manager `Certificate` with `.status.notAfter` ≤ 14 days out. A
  *backstop* (cert-manager auto-renews at ~2/3 life), so a hit means renewal is failing, not normal. (NFR10)
- **(b) storage ≥ 80%** — any Longhorn node disk where `1 - storageAvailable/storageMaximum ≥ 0.80`.
- **(c) stateful service down** — a Deployment/StatefulSet with `readyReplicas < desired`, scoped to
  namespaces that carry a `<service>-backup` CronJob (the Story 4.1 backup-actor convention = "this
  is a stateful service"). Orthogonal to uptime-kuma's HTTP probes — see Escalation.
- **(d) backup/restore Job failure** — any Job named `*-backup*` or `*-restore*` with `status.failed ≥ 1`
  (CronJob-spawned backups and one-off cutover restore Jobs alike).

Read-only `ClusterRole` (`get,list` on certificates / longhorn nodes / deployments+statefulsets /
jobs+cronjobs); no writes, no secret reads. ntfy token via `envFrom` from the `ops-alerts-secrets`
SealedSecret (write-only on the `alerts` topic).

**No state/dedupe:** a persistent condition re-fires every 15 min (intended nagging for a
bus-factor-1 homelab). Add a sentinel ConfigMap only if it proves noisy.

## Health check (exact command → expected output)

```
kubectl get cronjob ops-alerter -n ops-alerts        # SUSPEND=False, LAST SCHEDULE recent (≤15m)
# force an immediate poll and read its log:
kubectl create job --from=cronjob/ops-alerter ops-alerter-manual -n ops-alerts
kubectl wait --for=condition=complete job/ops-alerter-manual -n ops-alerts --timeout=120s
kubectl logs -n ops-alerts job/ops-alerter-manual    # → "ops-alerter poll complete" (no FATAL, no ERROR)
kubectl delete job ops-alerter-manual -n ops-alerts
```

ArgoCD: `kubectl get app ops-alerts -n argocd` → `Synced` + `Healthy`.

## If DOWN do this (in order)

1. **CronJob scheduling** — `kubectl get cronjob ops-alerter -n ops-alerts`; if `SUSPEND=True` or
   `LAST SCHEDULE` is stale, the controller stopped scheduling. Check `concurrencyPolicy: Forbid`
   isn't wedged on a stuck pod: `kubectl get jobs,pods -n ops-alerts`.
2. **Last run log** — `kubectl logs -n ops-alerts job/<last-job>`:
   - `FATAL: kube-apiserver unreachable` → the egress NetworkPolicy apiserver allow is missing/wrong (step 4).
   - `ERROR: ntfy publish failed` → ntfy unreachable or the token lacks topic write (steps 4–5).
3. **SealedSecret materialized** — `kubectl get secret ops-alerts-secrets -n ops-alerts` exists and
   carries `NTFY_TOKEN`. If absent, the sealed-secrets controller hasn't unsealed it (check the
   controller; the SealedSecret is sealed to name+ns `ops-alerts-secrets`/`ops-alerts`).
4. **Egress NetworkPolicy** — `kubectl get netpol ops-alerter-egress -n ops-alerts`. It MUST allow
   egress to: kube-dns `:53`, the kube-apiserver (`0.0.0.0/0` `:443`+`:6443`), and ntfy ns `:80`.
   This is the #1 predictable failure once `network-baseline` default-deny lands (see Common failures).
5. **ntfy token ACL** — confirm the publish token still has write on the topic:
   `kubectl exec -n ntfy deploy/ntfy -- ntfy access ops-alerter` → `write-only access to topic alerts`.
6. **Manual run** — re-run the health-check manual job; a green "poll complete" = recovered.

## Common failures

- **Egress blocked (apiserver)** — every check reads nothing. The script's `kubectl get --raw=/readyz`
  preflight turns this into a loud `FATAL` + a Failed Job rather than silent no-ops. Fix: the
  apiserver egress allow in `ops-alerter-egress`.
- **Egress blocked (ntfy)** — reads succeed but `curl` to `ntfy.ntfy.svc.cluster.local:80` fails;
  log shows `ERROR: ntfy publish failed`. Fix: the ntfy ns `:80` egress allow (and, if ntfy ever
  gains a restrictive ingress policy, an allow-from-`ops-alerts` there — AR21).
- **Token lacks topic write** — ntfy returns 403; `ERROR: ntfy publish failed`. Re-grant:
  `ntfy access ops-alerter alerts write`.
- **CronJob not scheduled** — `SUSPEND=True`, or a hung pod under `concurrencyPolicy: Forbid`
  suppressing later runs. `activeDeadlineSeconds: 180` bounds a hung run (→ Failed, visible).
- **Alert flapping / noise** — a persistent real condition nags every 15 min (by design). If a
  *transient* readiness blip is noisy, scope (c) tighter or add a dedupe sentinel ConfigMap.

## Backup/restore commands

**N/A — owns no data; stateless poller.** State is the manifests in
[`infra/ops-alerts/`](../../infra/ops-alerts/) (GitOps) + the ntfy `ops-alerter` token (durable in
ntfy's `auth.db`, backed up by the `ntfy-backup` CronJob). Nothing to back up here.

## Escalation / depends-on

- **Depends on ntfy (Story 4.1)** — ntfy is the alert channel. If ntfy is down, alerts are silently
  lost (the poller's `curl` just fails). Recover ntfy first ([ntfy.md](ntfy.md)).
- **Overlaps with uptime-kuma — NOT a duplicate.** Kuma (Compose/LAN) probes **public HTTP
  endpoints** (`*.<public zone>`) and pushes to ntfy. This poller checks **cluster workload readiness**
  (`readyReplicas < desired`) — it catches a down pod even when the public endpoint is cached/healthy
  or internal-only. Do not re-implement Kuma's HTTP checks here. Whether Kuma is retired for a
  Prometheus/ntfy pipeline is an Epic 5 (NFR15b / Phase 3) decision, not this slice's.
- **🔴 Self-monitoring gap (recorded honestly):** in-cluster alerting has a single point of failure —
  **ntfy itself.** This poller cannot alert on ntfy's own outage (chicken-and-egg handed over by
  Story 4.1 Task 6). **ntfy-down is detected out-of-band by uptime-kuma** (it probes `${SECRET:DOMAIN_NTFY}`).
  A second independent channel (e.g. a healthchecks.io dead-man's-switch the CronJob pings each run,
  so silence = alert) is the correct fix but is **NFR15b / Phase-3 scope** — deliberately not built here.

## NFR15 split (AC3 — resolves the PRD timing gap)

- **NFR15a is DONE-blocking and lands here (Epic 4):** cert-expiry + storage-80% + stateful/workload-
  down + backup/restore-job-failure, via this ntfy poller.
- **NFR15b is Epic 5 / Phase 3:** full ops alerting incl. component/version-drift and the remaining
  steady-state conditions, plus the ntfy-self-monitoring fix above. This explicitly resolves the
  architecture's flagged NFR15 partial-gap (architecture.md lines 867–869). Also in
  [DECISIONS.md](../DECISIONS.md).
