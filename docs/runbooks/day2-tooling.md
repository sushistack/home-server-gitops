# Runbook: Day-2 self-service tooling (Story 5.7 — opportunistic, post-DONE)

> Three **independent, internal-only** k3s Deployments via the golden path:
> **Semaphore** (clickable + schedulable Ansible runner for `configs/openwrt/`),
> **Heimdall** (app-launcher dashboard), **Beszel** (lightweight node CPU/mem/disk/net + history).
> Opportunistic post-DONE — fine to start, fine to **stop partway** (each is independent). No data
> migration, **no backup actors** (config is reproducible). [DECISIONS.md Story 5.7]

DEV authored + validated all manifests (`workloads/{semaphore,heimdall,beszel}/`), the tokens, the
versions pins, and this runbook. The steps below are **operator-run LIVE** — sealing the real
Semaphore secrets, configuring the Semaphore project, filling the Beszel agent key, and the
high-blast-radius OpenWrt DNS edit. Same DEV-authors / operator-runs split as the Epic 4 cutovers + 5.6.

---

## ✅ LIVE EXECUTION LOG — 2026-06-19 (platform bring-up done)

All three apps are deployed, **Synced/Healthy**, per-host **certs Ready**, and reachable on LAN over
HTTPS (200, valid cert): `semaphore.eli.kr`, `heimdall.eli.kr`, `beszel.eli.kr` → `10.0.0.101`.
OpenWrt DNS applied live + reconciled into `configs/openwrt/.../main.yml`.

What was done: sealed the 3 Semaphore secrets (`seal-secrets.sh`), added the 3 `DOMAIN_*` render
tokens to the live `argocd-render-tokens` Secret, applied the OpenWrt DNS overrides (surgical
`uci add_list`), filled the Beszel agent key.

🔴 **Gotchas found live (manifests already fixed):**
1. **kubeseal controller name** — this cluster's controller Service is `sealed-secrets`, not the
   kubeseal default `sealed-secrets-controller`; needs `--controller-name sealed-secrets`.
2. **Render tokens are a precondition** — without `DOMAIN_*` in the live `argocd-render-tokens` Secret
   the CMP fails `unresolved token(s)` and the app never syncs. The Secret's data key is `tokens.env`
   (a single env blob); append the 3 lines and `kubectl apply` (mount refreshes in ~60s).
3. **Semaphore image** — `v2.16.21` did not exist (placeholder); pinned real stable **v2.18.12**.
4. **Semaphore `enableServiceLinks: false`** — the Service named `semaphore` made k8s inject
   `SEMAPHORE_PORT=tcp://…`, which Semaphore reads as its own port → panic. Disabled service links.
5. **Semaphore DB = sqlite, NOT bolt** — BoltDB is deprecated and v2.18's terraform store panics
   `unknown store type`. Using `SEMAPHORE_DB_DIALECT=sqlite` (still embedded, no sidecar).
6. **Beszel agent crash-loops on a placeholder KEY** on 0.18 (parses keys at startup) — it is NOT
   "harmless until filled". The hub generates its keypair in its PVC; the agent's public KEY was
   derived by scaling the hub to 0, reading `/beszel_data/id_ed25519`, `ssh-keygen -y`, scaling back.

**Remaining = in-app UI config only (each app's own first-run, by design):**
- **Semaphore** (§1c): log in `admin` / password in operator's `~/.semaphore-admin-pw`; create the
  project + repo + static inventory + key + the `--check` drift template (the review-gated apply
  template stays a deliberate human setup — BITE 1).
- **Beszel** (§3): first-run create admin in the hub UI, then **Add System** ×3 (`10.0.0.101–103`,
  port `45876`). Agents are already running and listening.
- **Heimdall**: tiles — optional, deferred to Story 5.8.

---

## 0. Preconditions

- Project **DONE** (Story 4.8, `docs/DONE.md`). Opportunistic — no gate.
- `argocd app list` Synced/Healthy; `bin/render --selftest` OK; `bin/version-lint` OK (4 new pins).
- All three are **INTERNAL-only** (operator tooling): NO cloudflared tunnel rule + a LAN-only OpenWrt
  DNS override → `10.0.0.101`. Externally NXDOMAIN. NOT an `ipAllowList` (cloudflared egresses from a
  LAN IP, so an allowlist would admit internet-via-tunnel — the absence of a public route is the gate).
- Register the three render tokens in the out-of-band token source (`internal/tokens.env` +
  the `argocd-render-tokens` Secret the CMP reads): `DOMAIN_SEMAPHORE`, `DOMAIN_HEIMDALL`,
  `DOMAIN_BESZEL` — each `<name>.eli.kr` (internal zone).
- 🔴 **Image tags in `versions.yaml` + the manifests are PLACEHOLDERS.** Before sync, confirm the exact
  current stable tag for each (semaphore / heimdall / beszel / beszel-agent) and swap to `@sha256`
  digests (AR29) — same PR, `bin/version-lint` enforces the mirror. Each manifest comment carries the
  `docker buildx imagetools inspect …` command.

---

## 1. Semaphore — seal secrets + configure the project  (Task 1b, LIVE)

Semaphore stores its project/templates in BoltDB (configured post-deploy via UI/API), so it needs the
secrets sealed and the project wired by hand. **Until the secrets are sealed the pod can't start** — it
sits in `CreateContainerConfigError` (the `envFrom: semaphore-admin` secret is missing) and the
Semaphore Application shows **Degraded** in ArgoCD. That is the EXPECTED state until step 1a below, not
a fault — don't chase it.

### 1a. Seal the three secrets (controller ns `sealed-secrets`)

**No NEW keys are created** — the two SSH keys and the age key already exist and already work; we only
seal copies for the in-cluster runner:
- **OpenWrt** `root@10.0.0.1` (HIGH blast radius): the workstation key that already opens it. Confirm
  which one with `ssh -v root@10.0.0.1 'echo ok' 2>&1 | grep 'Offering\|Server accepts'` — typically
  `~/.ssh/id_ed25519`.
- **Oracle** `ubuntu@217.142.236.162`: `~/.ssh/oracle_proxy`.
- **age**: the existing cluster DR identity `age1chmmudv…` (gate0-dr) — its private `keys.txt`
  (usually `~/.config/sops/age/keys.txt`). **0 new keys.**

A helper script does all three seals in place — run it from a workstation with `kubectl` + `kubeseal`:

```sh
cd workloads/semaphore
./seal-secrets.sh ~/.ssh/id_ed25519 ~/.ssh/oracle_proxy ~/.config/sops/age/keys.txt
# prompts once for the admin password; writes sealedsecret-{admin,ssh,age}.yaml with real ciphertext.
```

> 🔴 The script generates `SEMAPHORE_ACCESS_KEY_ENCRYPTION` **once**. It encrypts the access keys
> stored in BoltDB — on any future RESEAL, reuse the SAME value (don't regenerate), or every stored
> key is orphaned. Recover the existing value with:
> `kubectl -n semaphore get secret semaphore-admin -o jsonpath='{.data.SEMAPHORE_ACCESS_KEY_ENCRYPTION}' | base64 -d`

Then **uncomment the three `sealedsecret-*.yaml` lines in
`workloads/semaphore/kustomization.yaml`**, verify `kubectl kustomize workloads/semaphore` still
builds, and commit+push. ArgoCD syncs → the pod starts.

(Manual equivalent if you'd rather not run the script: `kubectl create secret generic … --dry-run=client
-o yaml | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml`
for each (the controller service is named `sealed-secrets`, not the kubeseal default
`sealed-secrets-controller`) — `semaphore-admin`
with the 5 admin literals, `semaphore-ssh` with `--from-file=openwrt=<key> --from-file=oracle=<key>`,
`semaphore-age` with `--from-file=keys.txt=<key>` — then overwrite the matching stub file.)

### 1b. 🔴 The runner needs the `sops` binary

`community.sops` (in `configs/openwrt/requirements.yml`) shells out to the **`sops` CLI** to decrypt
`group_vars/*.sops.yaml`. The stock `semaphoreui/semaphore` image ships `ansible-core` but may **not**
ship `sops`/`age`. If a `--check` run fails at the decrypt step, either (a) point Semaphore at a custom
runner image that adds `sops` + `age`, or (b) add a task-bootstrap step that installs them. Confirm
before trusting any template.

### 1c. Configure the project (Semaphore UI / API)

1. **Repository**: `https://github.com/sushistack/home.server` (or its SSH URL), path used by templates
   = `configs/openwrt/`. Branch `master`.
2. **SSH keys** — both are mounted under `/keys/ssh/` (from the `semaphore-ssh` secret):
   `/keys/ssh/openwrt` (root@10.0.0.1) and `/keys/ssh/oracle` (ubuntu@Oracle). The repo
   `inventory.yml` sets no key file (it relies on the workstation's ssh-agent, absent in the pod), so
   give Semaphore a **static inventory** that points each host at its key — create it in the Semaphore
   UI (Inventory → type: Static, paste):
   ```yaml
   all:
     children:
       openwrt:
         hosts:
           gateway: { ansible_host: 10.0.0.1, ansible_user: root,
                      ansible_ssh_private_key_file: /keys/ssh/openwrt }
       oracle:
         hosts:
           oracle-proxy: { ansible_host: 217.142.236.162, ansible_user: ubuntu, ansible_become: true,
                           ansible_ssh_private_key_file: /keys/ssh/oracle }
   ```
   (Or register each key as a Login-With-Key Key Store entry sourced from the mounted file.) The
   **source stays the SealedSecret/git** — never hand-type the SOPS app secrets into the Key Store
   (Reconciliation 4). The age key is already mounted at `/keys/age/keys.txt`; the Deployment exports
   `SOPS_AGE_KEY_FILE` so `community.sops` decrypts at play runtime — nothing to paste.
3. **Install collections** as a setup step (first run): `ansible-galaxy collection install -r
   configs/openwrt/requirements.yml` (`ansible.cfg` already sets `collections_path=./.ansible/collections`).
4. **Templates** (the two-stance split — Reconciliation 1 / BITE 1):
   - **DEFAULT / SCHEDULED — drift check (the sanctioned easy button):**
     `ansible-playbook -i inventory.yml playbook-apply.yml --check --diff --limit openwrt`
     Schedule it (e.g. daily). Acceptance = **0 changed / 0 failed** (zero-drift baseline). Any
     `changed` → someone touched LuCI/UCI: stop and investigate (dovetails with 5.1 drift alerting).
   - **LIVE APPLY — review-required, NOT scheduled, NOT one-click:**
     `ansible-playbook -i inventory.yml playbook-apply.yml --diff --limit openwrt`
     Operator reviews the preceding `--check` diff task output first, then triggers manually.
     🔴 **If a bad apply cuts OpenWrt, recover at the CLI** (`configs/openwrt/Makefile` from a
     workstation) — k3s rides on the gateway, so "click Run again in Semaphore" may be unreachable.

### 1d. Prove it before trusting apply

A `--check --diff` run against `openwrt` reporting **0 changed / 0 failed** proves SSH + age decrypt +
collections all work end-to-end. Only then is the apply template trustworthy.

---

## 2. Heimdall — nothing to seal

Base Heimdall needs no secret. After sync + the DNS step (§4), the UI loads on LAN at `DOMAIN_HEIMDALL`.
Populating tiles is optional (Story 5.8 item 4) — capture the tile list in that runbook for
reproducibility (there is **no backup actor**: the layout is re-clickable config, not data).

---

## 3. Beszel — fill the agent key (after the hub boots)

The manifests wire Beszel's **SSH connection mode**: the agent LISTENs on `:45876` and the hub DIALS
each node (no `TOKEN`/`HUB_URL`). The agent `KEY` is the **hub's public key**, unknown until the hub
generates it on first boot. (If you instead pick a WebSocket-mode setup, the agent dials out and needs
`KEY` + `TOKEN` + `HUB_URL` — change `daemonset-agent.yaml` env accordingly.)

1. After the hub pod is Healthy, open its UI (`DOMAIN_BESZEL` after §4, or `kubectl -n beszel
   port-forward svc/beszel 8090:8090` before DNS), create the admin user, **Add System** → copy the
   shown public key.
2. Paste it into `workloads/beszel/configmap-agent-key.yaml` (`data.KEY`), commit → ArgoCD syncs.
3. Restart the agents to pick it up: `kubectl -n beszel rollout restart daemonset/beszel-agent`.
4. In the hub, add each node (`10.0.0.101–103`) with port `45876`. Expect a pod per node
   (`kubectl -n beszel get ds beszel-agent`) reporting CPU/mem/disk/net + history.
- **Optional (AC3d)** `shoutrrr → ntfy` hub alerts: configure in the hub UI (Settings → Notifications)
  reusing the existing ntfy topic. Not a manifest.
### 3a. Beszel agent on the Proxmox host (Plane 0) — optional operator step

Not GitOps-managed (the hypervisor is outside k3s and outside `ansible/inventory.yml`). Same SSH
connection model as the in-cluster agents: the binary LISTENs on `:45876`, the hub DIALS it, and the
`KEY` is the **same hub public key** already in `workloads/beszel/configmap-agent-key.yaml` — so no new
key. Division of labour: Netdata covers per-pod/k8s detail, Beszel covers node-level + this non-k8s host.

Run on the Proxmox host as root. Pinned to the **same `beszel-agent` version as `versions.yaml`**
(`0.18.7`); bump both together when the in-cluster DaemonSet bumps.

```sh
VER=0.18.7
# static linux/amd64 binary from the pinned release (the filename is unversioned; the /vVER/ path pins it)
curl -fsSL "https://github.com/henrygd/beszel/releases/download/v${VER}/beszel-agent_linux_amd64.tar.gz" \
  | tar -xzf - -C /usr/local/bin beszel-agent
chmod +x /usr/local/bin/beszel-agent
useradd -r -M -s /usr/sbin/nologin beszel 2>/dev/null || true   # unprivileged service user

# KEY MUST equal data.KEY in workloads/beszel/configmap-agent-key.yaml (the hub's public key).
cat >/etc/systemd/system/beszel-agent.service <<'UNIT'
[Unit]
Description=Beszel Agent
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/beszel-agent
Environment="LISTEN=45876"
Environment="KEY=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINWEtsmihIfFNqV8abX3+tm2JTDJpM/ruX+LvRO3i5rH"
User=beszel
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload && systemctl enable --now beszel-agent
ss -lntp | grep 45876        # expect beszel-agent LISTENing
```

Then: allow inbound `:45876` to the Proxmox host from the hub (confirm the hub pod egresses to the
Proxmox LAN IP — k3s SNATs pod egress to the LAN, so it should reach it), and in the hub UI **Add
System** → `<Proxmox LAN IP>` port `45876`. The `storage` LXC can be added the same way if wanted.

> Faster alternative (not version-pinned — installs the latest agent + sets up the user/systemd itself):
> `curl -sL https://get.beszel.dev | sh -s -- -k "<hub public key>" -p 45876`. Prefer the pinned manual
> install above to stay aligned with the `versions.yaml` SSOT.

---

## 4. 🔴 OpenWrt LAN DNS override — STAGED (Task 4 / 4b, high-blast-radius)

> **NOT written to `configs/openwrt/.../main.yml` by dev.** The home.server working tree currently
> carries 5.6's UNCOMMITTED `local_dns_overrides` edits (comics/comics-admin/book → `.101` + the
> `komga`→`storage` lease rename). To avoid racing that in-flight edit, the 5.7 override is staged
> **here** only. The operator applies it in a coordinated window **after** 5.6's OpenWrt edit lands —
> append these three lines to `local_dns_overrides` (do NOT rewrite the block):

```yaml
  - "/semaphore.eli.kr/10.0.0.101"   # Story 5.7: Semaphore on k3s, INTERNAL-only (no CF route — LAN-only). node 1; ServiceLB binds :80/:443 on every node → Traefik → semaphore.
  - "/heimdall.eli.kr/10.0.0.101"    # Story 5.7: Heimdall on k3s, INTERNAL-only (no CF route — LAN-only). → Traefik → heimdall.
  - "/beszel.eli.kr/10.0.0.101"      # Story 5.7: Beszel hub on k3s, INTERNAL-only (no CF route — LAN-only). → Traefik → beszel.
```

### Apply (operator)

Per memory `openwrt_dns_apply_drift`: a full `playbook-apply` during a cutover window is risky (repo↔live
drift both directions). For three additive entries, the surgical path is safest:

```sh
# on the gateway (ssh root@10.0.0.1):
uci add_list dhcp.@dnsmasq[0].address='/semaphore.eli.kr/10.0.0.101'
uci add_list dhcp.@dnsmasq[0].address='/heimdall.eli.kr/10.0.0.101'
uci add_list dhcp.@dnsmasq[0].address='/beszel.eli.kr/10.0.0.101'
uci commit dhcp && /etc/init.d/dnsmasq reload
```

Then reconcile the repo: commit the three lines above into `main.yml` so a later full apply is
zero-drift. (If you prefer the playbook: `--check --diff` → review → `--diff`, but only once the repo
SSOT matches all live overrides — see the 5.5/5.6 drift notes.)

### Verify (operator)

- Each host resolves **on LAN** → `10.0.0.101`: `nslookup semaphore.eli.kr 10.0.0.1` (repeat heimdall, beszel).
- Each is **NXDOMAIN externally** (no CF tunnel rule): `dig +short semaphore.eli.kr @1.1.1.1` → empty.
- Per-host `letsencrypt-prod` cert **Ready**: `kubectl get certificate -A | grep -E 'semaphore|heimdall|beszel'`.
- UIs reachable on LAN over HTTPS (valid cert). Heimdall PVC survives a pod restart (tiles persist).
- ArgoCD Synced/Healthy for all three apps.

---

## Notes / non-goals

- **No backup CronJob / R2 actor** for any of the three (config is reproducible — DECISIONS.md).
- Cluster is **allow-all today** (no default-deny NetworkPolicy). If a baseline ever lands: Semaphore
  needs egress to `10.0.0.1:22` + Oracle `:22` + DNS; Beszel hub↔agent on `:45876`. Note it, don't build it.
- **Zero-config fallback** if the DNS window is contentious: `kubectl port-forward` reaches any of the
  three without the OpenWrt edit. The ingress/cert/DNS is additive, not a blocker.
