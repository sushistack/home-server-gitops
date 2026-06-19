# Runbook: standalone-LXC consolidation (Story 5.6 — opportunistic, post-DONE)

> Migrate the standalone application LXCs the k3s platform can absorb without a hardware/storage
> regression: **trade-monitor (#205)** → a `CronJob`; **komga + Suwayomi (#203)** and **calibre-web
> (#204)** → `Deployment`s. The 90G manga library stays in place — **#203 is repurposed into the
> `storage` NFS server** (zero copy). **jellyfin (#200) / immich (#201) are EXCLUDED** (iGPU
> passthrough a k3s VM can't replicate without a VFIO regression). This is opportunistic: fine to
> start, fine to stop. NOT a Compose cutover (these were never in LXC #202). [DECISIONS.md Story 5.6]

> ✅ **EXECUTED LIVE 2026-06-19** (agent, operator-granted SSH+kubeconfig). **AS-BUILT differs from §2
> below:** the in-place NFS plan was **infeasible** — #203 is an unprivileged LXC, so kernel `nfsd` is
> unavailable and userspace `nfs-ganesha`'s VFS FSAL hits `open_by_handle_at` EPERM (needs
> CAP_DAC_READ_SEARCH in the initial userns). **Pivoted to node-local:** a dedicated 200G disk on
> k3s-cp-1 (`/mnt/manga`, ext4, UUID-mounted), 90G rsync'd from #203 (12663 files == source), static
> `local` PV (RWX, nodeAffinity k3s-cp-1; komga ro / suwayomi rw — both pinned there, no replication/HA,
> accepted). config DBs ingested to Longhorn (komga 228M SQLite, suwayomi 137M H2, calibre app.db+183M).
> trade-monitor image needed **fonts-dejavu-core** (PIL `ImageFont` needs the system TTF, else tiny
> text). Flip: OpenWrt uci (comics/comics-admin/book → 10.0.0.101) + CF tunnel API (comics+book before
> the wildcard; comics-admin NO rule = internal). #204/#205 destroyed; #203 stopped (retained as the
> sole 90G manga backup — destroy when comfortable). §2/§3 below are the original (NFS) plan, kept for
> context; node-local is the as-built. The 90G has NO replica — that is the one durability caveat.

DEV authored + validated all manifests (`workloads/{trade-monitor,komga,calibre}/`), the trade.monitor
image build (Dockerfile + CI), tokens, and this runbook.

---

## 0. Preconditions

- Project **DONE** (Story 4.8). Opportunistic — no gate.
- **Exposure mapping — VERIFIED against live NPM 2026-06-19** (`/opt/docker/data/nginx-proxy-manager/nginx/proxy_host/`):
  - **komga = `comics.eli.kr`** (16.conf → 10.0.0.30:25600, no IP-ACL) — **PUBLIC**. `DOMAIN_KOMGA`.
  - **Suwayomi = `comics-admin.eli.kr`** (17.conf → 10.0.0.30:4567, `allow 10.0.0.0/24; allow 10.8.0.0/24;
    deny all`) — **INTERNAL**. `DOMAIN_SUWAYOMI`. On k3s: NO CF tunnel rule + LAN-only DNS override
    (NOT an ipAllowList — cloudflared egresses from 10.0.0.20, so a LAN allow would leak internet-via-tunnel).
  - **calibre = `book.eli.kr`** (SINGULAR; 20.conf → 10.0.0.31:8083, no IP-ACL) — **PUBLIC**. `DOMAIN_CALIBRE`.
- Register the three tokens in the out-of-band `argocd-render-tokens` Secret + `internal/tokens.env`
  (the render CMP substitutes them): `DOMAIN_KOMGA`, `DOMAIN_SUWAYOMI`, `DOMAIN_CALIBRE`.

---

## 1. Build + publish the trade-monitor image (trade.monitor repo)

1. Push the new `Dockerfile` + `.github/workflows/build.yml` + the `requirements.txt` change (drop
   `python-crontab`, add `requests`) to `github.com/sushistack/trade.monitor` master.
2. CI publishes `ghcr.io/sushistack/trade.monitor:0.1.0` + `:sha-<sha>` + a digest (printed in the job
   summary).
3. **Mark the GHCR package PUBLIC** (Settings → Packages → trade.monitor → Change visibility) so the
   `trade-monitor` namespace needs no pull secret. (If you keep it private: seal `ghcr-sushistack`
   into ns `trade-monitor` and add `imagePullSecrets` to `cronjob.yaml`.)
4. **Pin the digest (AR29):** swap `image: …:0.1.0` → `…@sha256:<digest>` in
   `workloads/trade-monitor/cronjob.yaml` AND `versions.yaml` (same PR — `bin/version-lint`).
5. Likewise confirm + digest-pin the upstream tags: `gotson/komga`, `ghcr.io/suwayomi/tachidesk`,
   `lscr.io/linuxserver/calibre-web` (each manifest comment carries the `imagetools inspect` command).

---

## 2. Repurpose #203 → the `storage` NFS server (HIGH-BLAST-RADIUS)

On the Proxmox host (`pct exec 203`), apps already inventoried (komga.jar :25600, suwayomi.jar :4567,
shared `/mnt/manga` 90G):

```sh
# a. Stop the LXC apps (so the authoritative manga + DBs are quiesced before copy)
pct exec 203 -- systemctl stop komga suwayomi      # (whatever the unit names are; confirm with `systemctl list-units`)

# b. Install + export NFS — LEAST-PRIVILEGE to the 3 k3s nodes only (not the whole LAN)
pct exec 203 -- apt-get install -y nfs-kernel-server
pct exec 203 -- sh -c 'cat >/etc/exports <<EOF
/mnt/manga 10.0.0.101(rw,sync,no_subtree_check) 10.0.0.102(rw,sync,no_subtree_check) 10.0.0.103(rw,sync,no_subtree_check)
EOF'
pct exec 203 -- exportfs -ra
pct exec 203 -- systemctl enable --now nfs-kernel-server
```

> Suwayomi writes as uid 1000 over NFS → make `/mnt/manga` writable by it. Either `chown -R 1000:1000
> /mnt/manga` (if komga's files are owned compatibly) or add `all_squash,anonuid=1000,anongid=1000` to
> the export. Confirm komga can still READ after any chown.

```sh
# c. Rename the guest komga -> storage (IP 10.0.0.30 is MAC-bound, stays)
pct set 203 --hostname storage
pct exec 203 -- sh -c 'echo storage >/etc/hostname; sed -i "s/\bkomga\b/storage/g" /etc/hosts'
```

**Rollback:** `exportfs -ua` + stop `nfs-kernel-server` + `pct set 203 --hostname komga`; the apps are
still installed on #203 (not removed until you're satisfied) so they can be restarted.

### Node-side NFS client

Every k3s VM node needs the client or the kubelet mount fails:

```sh
for n in 10.0.0.101 10.0.0.102 10.0.0.103; do ssh $n 'sudo apt-get install -y nfs-common'; done
# verify a manual mount from one node BEFORE wiring pods:
ssh 10.0.0.101 'sudo mkdir -p /mnt/t && sudo mount -t nfs4 10.0.0.30:/mnt/manga /mnt/t && ls /mnt/t && sudo umount /mnt/t'
```

---

## 3. OpenWrt edits (HIGH-BLAST-RADIUS — file EDITED, LIVE apply pending)

> DEV has now EDITED `configs/openwrt/.../main.yml` (lease `komga`→`storage` + the three DNS overrides
> below, each marked `🔴 APPLY ONLY AT CUTOVER`). The **live apply is still gated**: run
> `ansible-playbook … --check --diff` first, show, approve — and only flip the DNS overrides at the
> cutover moment (after the k3s pods are up + parity passes), else LAN points at k3s before komga is
> serving = outage. Live flip is `uci add_list` + `dnsmasq reload` (the keep.eli.kr pattern).

The diff already in the file:

**`dhcp_static_leases`** (line ~346) — rename the lease (cosmetic; IP is MAC-bound):
```diff
-  - name: komga
+  - name: storage
     mac: 'bc:24:11:a3:70:10'
     ip: '10.0.0.30'
```

**`local_dns_overrides`** — flip komga's host to k3s, flip Suwayomi's internal host to k3s, add the new
internal calibre host (all → node 1, ServiceLB binds :443 on every node — the draw/keep pattern):
```diff
-  - "/comics.eli.kr/10.0.0.20"
-  - "/comics-admin.eli.kr/10.0.0.20"
+  - "/comics.eli.kr/10.0.0.101"        # Story 5.6: komga -> k3s (was NPM 10.0.0.20)
+  - "/comics-admin.eli.kr/10.0.0.101"  # Story 5.6: Suwayomi -> k3s, INTERNAL-only (was NPM)
+  - "/book.eli.kr/10.0.0.101"          # Story 5.6: calibre -> k3s, PUBLIC (host is SINGULAR `book`; was NPM 20.conf, no IP-ACL)
```
Optional (cosmetic, after decommission): drop the dead `calibre` (.31) + `trade-monitor` (.32) leases.
**Do NOT touch the 10.0.0.200–206 leases** (the trade-monitor display targets STAY).

```sh
cd configs/openwrt && ansible-playbook -i inventory site.yml --check --diff   # show, get approval
ansible-playbook -i inventory site.yml                                        # apply, then dnsmasq reloads
```
**Rollback:** revert the diff + re-apply (re-points the hosts to NPM/old name).

---

## 4. Migrate the config DBs (small copy) + deploy

> The 90G manga is NOT copied (it's served in place via NFS). Only the small config DBs move.

```sh
# komga DB + tasks (from #203's old komga config dir) -> komga-config PVC
#   live path: /var/lib/komga/.komga/{database,tasks}.sqlite  ->  PVC /config/{database,tasks}.sqlite
# suwayomi data dir -> suwayomi-config PVC  (set server.downloadsPath=/manga in the migrated server.conf!)
#   live: /var/lib/suwayomi/.local/share/Tachidesk/*  ->  PVC /home/suwayomi/.local/share/Tachidesk/*
# calibre app.db + library -> calibre-data PVC
#   live (#204 docker): /data/calibre-web/* -> PVC subPath config/ ; /data/books/* -> PVC subPath books/
```
Pre-populate each PVC BEFORE the app's first sync (the appset selfHeal/empty-init race — same trap as
the Epic 4 cutovers: ingest into the PVC, then let ArgoCD generate the Application). Push the manifests;
the `workloads` ApplicationSet generates `trade-monitor`, `komga`, `calibre`.

Public flip for **komga + calibre** (only Suwayomi is internal — no CF route): edit the cloudflared
tunnel ingress, insert `comics.eli.kr` AND `book.eli.kr` → `https://10.0.0.101:443` (each with its own
`originServerName`) BEFORE the `*.eli.kr → NPM` wildcard. (Same recipe as keep/rss; memory `cf-tunnel-flip`.)
Both preserve their prior PUBLIC NPM exposure; comics-admin (Suwayomi) gets NO rule = internal.

---

## 5. Verify parity BEFORE decommissioning (the AC1/AC2 bar)

```sh
kubectl -n trade-monitor get cronjob,jobs        # fires <55s; check a Job's logs for both Binance + Yahoo uploads
kubectl -n komga get pods,pvc                     # komga + suwayomi Running; komga-manga-nfs Bound
kubectl -n calibre get pods,pvc
# komga: library scans the NFS manga, manga opens, reading progress matches the LXC
# suwayomi: can DOWNLOAD (rw NFS works) and the download appears in komga
# calibre: lists books, an ebook opens, metadata intact
curl -fsS -o /dev/null -w '%{http_code}\n' https://comics.eli.kr/            # 200 (public + LAN)
curl -fsS -o /dev/null -w '%{http_code}\n' https://comics-admin.eli.kr/      # 200 on LAN, NXDOMAIN/refused off-LAN
curl -fsS -o /dev/null -w '%{http_code}\n' https://book.eli.kr/              # 200 (public + LAN; SINGULAR `book`)
# trade-monitor: charts refresh on 10.0.0.201-206 + the ulanzi ticker (10.0.0.200) updates
```

---

## 6. Decommission (ONLY after Section 5 holds)

```sh
pct stop 205 && pct destroy 205     # trade-monitor
pct stop 204 && pct destroy 204     # calibre-web
# #203 is NOT destroyed — it IS the `storage` NFS server now. Once komga/suwayomi parity is confirmed,
# you may `apt-get remove` the old komga/suwayomi packages on #203 (optional cleanup; the NFS export stays).
```
Touch nothing else under `configs/proxmox/` host config (AC4).

Then: enable the optional backup CronJobs if wanted (seal `komga-backup-r2` / `calibre-backup-r2`
against the live key — reuse the live R2 cred — and uncomment them in the kustomizations). Update memory
`lan-devices` (#203 komga→storage/NFS, #204/#205 gone, apps on k3s) and append the `DECISIONS.md` record
(done by DEV).

---

## Common failures

1. **komga/suwayomi pod `ContainerCreating`, NFS mount times out** — node missing `nfs-common`, or the
   export doesn't list that node's IP, or a firewall blocks 2049. Check `dmesg`/`kubectl describe pod`.
2. **Suwayomi downloads land on Longhorn, not visible in komga** — `server.downloadsPath` in the
   migrated `server.conf` still points at the old LXC path. Set it to `/manga` (the NFS mount).
3. **calibre "library not found"** — the migrated `app.db` references a path other than `/books`. Fix
   the library path in calibre-web Settings, or mount the library where `app.db` expects it.
4. **trade-monitor Jobs all `Failed`** — image not pulled (GHCR still private → mark public or add the
   pull secret), or the 55s budget blown on cold start (Reconciliation 2 → consider the warm-Deployment
   fallback), or a display device unreachable (it logs per-host and exits 1 if any upload failed).
