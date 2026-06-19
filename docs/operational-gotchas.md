# Operational gotchas — hard-won traps

The ADRs say *why*, the runbooks say *how*. This file is the third thing: the
**traps** — behaviours that only showed up live, where the obvious move is the
wrong one. Each entry is *symptom → cause → what to actually do*, with a pointer
to the runbook/ADR that owns the full procedure.

Hosts/IPs are tokenized (`${SECRET:IP_K3S}`, `*.${SECRET:DOMAIN_ZONE}`, …) so
this doc stays inside the public-repo exposure gate — same convention as
`DECISIONS.md`. These are documentation tokens; this file is not render-active.

---

## ArgoCD / render CMP

- **A pushed `workloads/<svc>/` dir never appears as an Application.** The
  ApplicationSet git generator keeps listing the *old* `allPaths` until the
  repo-server re-fetches; annotating the *ApplicationSet* with `refresh=hard`
  does **not** bust it. Fix: hard-refresh any *existing* Application
  (`kubectl annotate application <any> -n argocd argocd.argoproj.io/refresh=hard --overwrite`)
  — that forces a repo-server git fetch and the generator sees the new dir
  within its ~3-min reconcile.

- **Render CMP is fail-closed, including on comments.** One unresolved
  `${SECRET:*}` anywhere in a render-active dir (a dir with `kustomization.yaml`)
  → `render-stdin.sh` exits 1 → app goes **`sync=Unknown`** (health stays
  `Healthy`, live objects keep serving the *last* rendered values). The scan
  reads comments too: `CIDR_NODES` and `IP_COMPOSE` are referenced only inside
  comments yet are mandatory. A not-yet-hard-refreshed app shows `Synced` from
  cache and only blows up on the next poll — latent landmine.

- **Never bulk-recreate `argocd-render-tokens` from a local `tokens.env`.** If
  the local file is a partial copy, `create secret --from-file=... | apply`
  silently drops the missing keys → every app referencing them breaks as above
  (real incident: 9 missing tokens broke 6 apps). Before recreating, **diff the
  keys**: live token names vs. `grep -rhoE '\$\{SECRET:[A-Z0-9_]+\}' workloads/ infra/`.
  Recover lost values from live IngressRoute `Host()` matches, NetworkPolicy
  ipBlocks, and the OpenWrt `local_dns_overrides`. After applying:
  `kubectl -n argocd rollout restart deploy argocd-repo-server` + hard-refresh
  affected apps.

- **No `manifest-lint` CI exists** — only `exposure-scan` + `adr-link-check`.
  Validate manifests yourself: `kubectl kustomize <dir>` + `kubectl apply --dry-run=server`.

- **No NetworkPolicy baseline** (`kubectl get netpol -A` → none). The cluster is
  effectively allow-all; any "service X can't reach Y" is **not** a netpol
  problem until a baseline is built. (Recorded in `DECISIONS.md`.)

- **Helm-source apps need their chart repo in the AppProject `sourceRepos`
  allowlist**, else `InvalidSpecError: repo ... is not permitted in project`.
  And the render CMP only touches dirs with a `kustomization.yaml`, so
  Helm-source apps get **no token substitution** — use short hostnames there.

See `argocd_render_cmp` lineage in `DECISIONS.md`, ADR-0006/0007.

## Secrets / Sealed Secrets

- **The controller lives in ns `sealed-secrets`, not `kube-system`.** Several
  in-repo `sealedsecret.yaml` OPERATOR-RECIPE comments say `kube-system` — they
  are **wrong** and produce "cannot get sealed secret service". Always:
  `kubeseal --format yaml --controller-name sealed-secrets --controller-namespace sealed-secrets`.

- **Seal from the LIVE source, never a local checkout.** During the n8n cutover
  the encryption key sealed from a local `configs/docker/data/.../config` was a
  *stale* value; sealing it would have made every n8n credential decrypt to
  unrecoverable garbage. Read the authoritative copy off the running service and
  re-verify before sealing. (Compose host is now retired — see *Historical*
  below — but the principle holds for any data/secret migration.)

- **R2 backup creds don't need minting per service** — re-seal the live
  `ntfy-backup-r2` Secret (ns `ntfy`) into `<svc>-backup-r2`; same bucket.

- **Sealing-key restore MUST precede the root-app sync (DR).** Apply the key
  Secret first; if the root-app syncs first, the controller generates a *fresh*
  key and every SealedSecret becomes permanently undecryptable. The key's
  out-of-band export is age **key-based** (not passphrase). See ADR-0004 +
  `runbooks/bare-metal-recovery.md`.

- **Canon: SOPS-in-git + age-key SealedSecret delivery; no per-app secret
  stores.** A second secret system doubles the backup/access/audit/rotation
  surface. Single age recipient across openwrt/oracle/cluster → 0 new keys, one
  DR path. Keep the offline age identity as a break-glass — automation must
  never make the laptop *permanently* unnecessary.

## Edge / `*.${SECRET:DOMAIN_ZONE}` routing

- **Internal-only is gated by the ABSENCE of a public DNS record (NXDOMAIN), not
  by a cloudflared rule.** The tunnel has a `*.${SECRET:DOMAIN_ZONE} →
  https://${SECRET:IP_K3S}:443` wildcard, so the instant anyone creates a public
  DNS record (or a DNS wildcard) for an internal host, it's exposed to the
  internet. `ipAllowList` does **not** save you — cloudflared egresses from a LAN
  IP, so a `10.0.0.0/24` allow rule admits internet-via-tunnel traffic.
  Internal-only recipe: IngressRoute + DNS-01 cert, **no** CF tunnel rule,
  **never** a public DNS record, LAN reaches it via OpenWrt DNS override. To
  close it hard at the edge, add `<host> → http_status:404` *before* the
  wildcard.

- **"Internal IP works, the domain 403s" ≈ always the tunnel path.** A LAN
  browser hitting the public host goes out to the CF edge → cloudflared → the
  source IP the backend sees is cloudflared's, which fails an Internal-Only ACL.
  Fix: add the LAN-side OpenWrt DNS override so LAN bypasses the tunnel.

- **`cloudflared` runs IN k3s now** (`infra/cloudflared`, 2-replica, same
  tunnel/token via SealedSecret). The circular dependency (the edge lives inside
  the cluster it fronts) is accepted: post-NPM, every public host is behind k3s
  Traefik anyway, so k3s-down = service-down regardless. During a k3s outage,
  recover proxmox/openwrt/kvm via their LAN IPs.

- **Edge flip = insert before the wildcard (first-match wins).** Add
  `{"hostname":"<host>","service":"https://${SECRET:IP_K3S}:443","originRequest":{"noTLSVerify":true}}`
  *before* the `*.${SECRET:DOMAIN_ZONE}` rule via the CF `cfd_tunnel`
  configurations API. IDs are decoded from `TUNNEL_TOKEN` (token in
  `internal/cf-tunnel.env`, scoped to tunnel-edit only). LAN side is separate:
  OpenWrt dnsmasq `address=/<host>/${SECRET:IP_K3S}`.

## OpenWrt DNS overrides (during cutovers)

- **A full OpenWrt `playbook-apply` mid-cutover is dangerous** — `local_dns_overrides`
  in `defaults/main.yml` is enforced as an *exact list*, and it drifts from the
  live router both ways during a migration:
  - *Repo-stale*: a story `uci`-flips the live router but forgets `main.yml` → a
    full apply **reverts the cutover**.
  - *Repo-ahead*: staged-but-not-live overrides → a full apply points LAN at k3s
    **before the pods exist** = outage.
  Safe pattern for one override: edit `main.yml` for the SSOT, then apply
  surgically on the live gateway only —
  `ssh root@<gateway> 'uci add_list/del_list dhcp.@dnsmasq[0].address="/host/ip"; uci commit dhcp; /etc/init.d/dnsmasq reload'`.
  (Note: Plane-0 config is moving to the private `homelab-network` repo; these
  paths become `ansible/...` there. Don't edit the frozen `home.server` copy.)

## Stateful cutover

- **An online copy of a SQLite app is stale even with zero user activity.**
  Background workers (queue/crawl/index) mutate the db on a timer — the md5
  changed between a parallel-run copy and the cutover window with no user
  action. The authoritative copy must be taken **after quiescing** the source
  (`docker stop` / scale writers to 0). Verify **byte-identity with `md5sum` on
  both sides**, not a row count. See `runbooks/stateful-cutover.md`.

- **Dev/operator split.** The dev agent authors *all* GitOps artifacts in this
  repo and validates with kustomize + `--dry-run=server`. The **LIVE flip is
  operator-run** in an announced ≤10-min window (quiesce → ingest → verify →
  flip edge → park). Stories end `in-progress`, not `review`.

- **R2 bucket name: `homelab-k3s-services-backup/<svc>/`.** Story files say
  `home-server-backups/<svc>/` — that's **wrong**; use the dedicated
  k3s-services bucket (creds `internal/r2-k3s.env`).

- **Cutover is forward-only — no rollback** (operator decision). 0-loss is
  proven in-cluster *before* the flip, so the "parked Compose / NPM fallback"
  rollback nets in the story files are dead letters; tear them down with the
  stack, don't wait out a TTL.

- **Hazard: parallel dev agents share one gitops working copy** → git ref races
  (commits orphan when another agent switches branches). Recover with
  `git branch -f <branch> <sha>`; commit objects survive. Consider per-agent
  worktrees.

### n8n specifics

- **Workflows hardcode old Compose service names** (they live in the DB/PVC, not
  git) → `getaddrinfo ENOTFOUND` after cutover. Fix: `n8n export:workflow`,
  rewrite the host to the cross-ns FQDN, `n8n import:workflow`. Two traps:
  (1) import **auto-deactivates** the workflow → `n8n update:workflow --active=true`;
  (2) neither import nor update is seen until `kubectl rollout restart deploy/n8n`
  (Recreate, boots >120s). Grep `export:workflow --all` for other stale hosts.

- **"My workflows disappeared" after cutover is a display-layer problem, not
  data loss.** DB/CLI/public-API counts were correct the whole time. Two causes:
  a stray local `n8nio/n8n:latest` on a dev PC showing an empty UI, and the k3s
  UI's `/rest` returning 0 due to the front-end service-worker/session cache
  (`Ctrl+Shift+R` doesn't clear the SW — log out / unregister SW). **Include one
  real UI login in the cutover done-check** — count-only verification misses
  this. See `runbooks/n8n.md`.

## Storage / Longhorn

- **One 200G root disk per node; Longhorn uses `default-disk`
  (`/var/lib/longhorn`) only.** The old dedicated `sdb` was removed (operator
  chose single-disk simplicity). `storage-minimal-available-percentage=25`
  reserves 25% for OS/etcd. Node RAM is 16G.

- **Detached-volume replicas are NOT moved by disk eviction.** When emptying a
  Longhorn disk, failed/stopped replicas of detached volumes must be deleted by
  hand (`kubectl delete replicas.longhorn.io ...`) before the disk converges to
  zero.

- **`default-replica-count=3` + `replica-replenishment-wait-interval=600`** — a
  long degraded window after a reboot is *normal* (lowering it triggers full
  rebuilds on every routine blip). After a maintenance reboot, manually deleting
  failed/stopped replicas forces immediate rebuild.

- **New PVC stuck `Pending` / "volume not ready for workloads"** → check
  `kubectl -n longhorn-system get volumes.longhorn.io` for `robustness=faulted` +
  a node `ReplicaSchedulingFailure` (insufficient schedulable storage).

- **The manga PV is node-local on one node = no replicas, SPOF** (operator
  accepted; re-downloadable, file-class). Don't touch that node's extra disk.

- **Thin-pool overprovision alert is host-local.** Proxmox `local-lvm` thin is
  overprovisioned with autoextend protection off; `thinpool-alert.timer` on the
  Proxmox host (not k3s — it'd die with a full pool) fires ntfy
  `homelab-critical` at ≥85%.

See ADR-0003, `runbooks/bare-metal-recovery.md`.

## Historical (Compose era — host now retired)

The standalone Docker host (LXC `docker`, `${SECRET:IP_COMPOSE}`) was destroyed
in Story 5.10 once cloudflared — its last service — moved into k3s. There is no
live Compose host anymore. Lessons retained because they shaped the platform:

- **App + infra Compose shared one project** (same external `home-network`), so
  a file-scoped `compose down` could kill Plane-0 services (cloudflared). Rule
  was: stop/rm by explicit container name, never by file.

- **Infra CD recreated `:latest` images every deploy**, so cloudflared briefly
  restarted on unrelated deploys — verify by public-host `curl`, not container
  uptime.

- **Portainer 2.27+ `--trusted-origins` takes a bare hostname only** (no
  scheme/port), or it FTL-loops under `restart: unless-stopped`.
