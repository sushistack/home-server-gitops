# Definition of Done — audit & declaration

> Story 4.8 capstone. Each box is evidenced, not asserted (epics.md Story 4.8 AC3 / PRD DoD).
> Audited 2026-06-19 after the Vaultwarden cutover (the last stateful service).

## (a) All in-scope services run via ArgoCD (`Synced`/`Healthy`, 1 Application ↔ 1 namespace)

`kubectl -n argocd get applications` — all **Healthy**; all **Synced** except the `argocd`
self-app (intentionally `OutOfSync`, Healthy — ArgoCD self-management is a **documented exclusion**,
deferred to avoid a sync-wave self-destroy while standing up the platform; see README "What was
deliberately excluded").

**Migrated application services (9), all Synced/Healthy:**
excalidraw · ytdlp-api · ntfy · navidrome · anytype · karakeep · miniflux · n8n · **vaultwarden**

**Platform components via ArgoCD (Synced/Healthy):** cert-manager · cluster-issuer · longhorn ·
sealed-secrets · ops-alerts · root.

Documented exclusions (NOT regressions): jellyfin/immich (shared iGPU passthrough + large local
media — would regress on a k3s VM), and the opportunistic LXC consolidation (trade-monitor /
komga / calibre) — both explicitly Epic 5.6 / out-of-scope per the architecture.

## (b) Gate 0 passed + every stateful service has a verified restore

- **Gate 0 PASSED 2026-06-18** — full bare-metal recovery chain proven on dummy data
  ([DECISIONS.md → Gate 0](DECISIONS.md), [bare-metal-recovery.md](runbooks/bare-metal-recovery.md)).
- **Per-service verified restore (R2 dump → integrity/row-count == source):**
  ntfy (users 2==2) · navidrome (306|201|607|1) · anytype (peerId/networkId round-trip) ·
  karakeep · miniflux (feeds 9, users 1, entries) · n8n (6 creds decrypt + 25 wf) ·
  **vaultwarden (users 1, ciphers 515, rsa_key.pem present — restored into a scratch ns 2026-06-19).**

## (c) ≥1 ADR per service-with-a-decision + top-level ADR-0001; ADR↔README links green in CI

Cross-cutting ADR-0001..0007 + service ADRs [ADR-0008 (miniflux)](adr/ADR-0008-miniflux-postgres-logical-dump.md),
[ADR-0009 (vaultwarden)](adr/ADR-0009-vaultwarden-critical-last.md),
[ADR-0010 (n8n)](adr/ADR-0010-n8n-write-freeze-cutover.md). `adr-link-check` CI green (bidirectional).

## (d) ≥2 demo artifacts pass the release-checklist human gate — ⚠️ 1 of 2 PUBLISHED

- **Clip 1 — closed loop (push→deploy→bad-version-held→revert):** ✅ published (README).
- **Clip 2 — self-heal (pod-kill / node-drain→reschedule):** ⏳ **recording PENDING.** The *behavior*
  is proven live (pod self-heal to replica count; node-drain reschedule + Longhorn re-attach ~12s;
  health-gated bad rollout held), but the screen-recorded clip was **deferred per operator**
  (Story 3.3 decision; tracked in [deferred-work.md](../_bmad-output/implementation-artifacts/deferred-work.md)).
  **This is the one open DoD line item.**

## (e) Exposure gate passes (full-history scan CI + human gate)

`exposure-scan` (gitleaks, full history) green; render-time `${SECRET:*}` tokens + two-layer gate
([ADR-0006](adr/ADR-0006-exposure-model.md)). Vaultwarden manifests scanned clean.

## (f) NFR15a critical alerting verified end-to-end

Story 4.2: single ntfy poller (`*/15` CronJob) — cert-expiry / storage≥80% / stateful-down /
backup-restore-Job-failure, proven by a deliberate failure ([ops-alerts.md](runbooks/ops-alerts.md)).

---

## Declaration

**Engineering scope is complete: all 9 application services + platform run on GitOps-reconciled
k3s, every stateful service has a verified restore, Gate 0 passed, exposure gate + NFR15a green,
ADRs linked.** The Vaultwarden cutover (the last, CRITICAL service) completed LIVE 2026-06-19 with
RPO=0.

**The single open DoD item is (d): the self-heal demo clip (clip 2) is not yet recorded** — its
behavior is proven live but the recording was operator-deferred. **Project DONE is declared subject
to the operator accepting that deferral** (consistent with AC4: optional polish must not become the
reason the project never ends), **or** held until clip 2 is published. Operator decision recorded in
[DECISIONS.md](DECISIONS.md).

## (AC4) Phase 3 / Epic 5 is optional, post-DONE

Epic 5 (NFR15b full-ops alerting, tested cold-boot, upgrade discipline, Compose retirement) is
**opt-in steady-state maturity, NOT a DONE blocker** — it must not become the reason the project
never ends. **Compose is PARKED, not retired**, at DONE — retirement is Story 5.4; the dual-run
rollback safety net stays until then.
