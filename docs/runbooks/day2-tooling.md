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

> 🔴 `SEMAPHORE_ACCESS_KEY_ENCRYPTION` MUST be generated **once** and preserved forever. It encrypts
> the access keys stored in BoltDB — re-running the `head -c32 /dev/urandom` below on a later RESEAL
> orphans every stored key. On any future reseal, reuse the SAME value, don't regenerate it.

```sh
# admin bootstrap + access-key encryption (the encryption key MUST stay stable — see warning above):
kubectl create secret generic semaphore-admin -n semaphore \
  --from-literal=SEMAPHORE_ADMIN=admin \
  --from-literal=SEMAPHORE_ADMIN_NAME=admin \
  --from-literal=SEMAPHORE_ADMIN_EMAIL=admin@eli.kr \
  --from-literal=SEMAPHORE_ADMIN_PASSWORD='<choose-a-strong-one>' \
  --from-literal=SEMAPHORE_ACCESS_KEY_ENCRYPTION="$(head -c32 /dev/urandom | base64)" \
  --dry-run=client -o yaml | kubeseal --controller-namespace sealed-secrets --format yaml \
  > /tmp/ss-admin.yaml   # paste encryptedData into workloads/semaphore/sealedsecret-admin.yaml

# SSH key for root@10.0.0.1 (OpenWrt — HIGH blast radius) + ubuntu@Oracle:
kubectl create secret generic semaphore-ssh -n semaphore \
  --from-file=id_ed25519=/path/to/semaphore_ansible_ed25519 \
  --dry-run=client -o yaml | kubeseal --controller-namespace sealed-secrets --format yaml \
  > /tmp/ss-ssh.yaml     # → workloads/semaphore/sealedsecret-ssh.yaml

# the sops AGE key (the SAME single cluster DR identity age1chmmudv… — 0 new keys, gate0-dr):
kubectl create secret generic semaphore-age -n semaphore \
  --from-file=keys.txt=/path/to/age/keys.txt \
  --dry-run=client -o yaml | kubeseal --controller-namespace sealed-secrets --format yaml \
  > /tmp/ss-age.yaml     # → workloads/semaphore/sealedsecret-age.yaml
```

Paste each `encryptedData` block into the matching stub file, then **uncomment the three
`sealedsecret-*.yaml` lines in `workloads/semaphore/kustomization.yaml`** and commit. ArgoCD syncs →
the pod starts. (`kubectl kustomize workloads/semaphore` must still build after uncommenting.)

### 1b. 🔴 The runner needs the `sops` binary

`community.sops` (in `configs/openwrt/requirements.yml`) shells out to the **`sops` CLI** to decrypt
`group_vars/*.sops.yaml`. The stock `semaphoreui/semaphore` image ships `ansible-core` but may **not**
ship `sops`/`age`. If a `--check` run fails at the decrypt step, either (a) point Semaphore at a custom
runner image that adds `sops` + `age`, or (b) add a task-bootstrap step that installs them. Confirm
before trusting any template.

### 1c. Configure the project (Semaphore UI / API)

1. **Repository**: `https://github.com/sushistack/home.server` (or its SSH URL), path used by templates
   = `configs/openwrt/`. Branch `master`.
2. **Key Store / SSH**: the SSH key is mounted at `/keys/ssh/id_ed25519`. Either set the inventory to
   `ansible_ssh_private_key_file=/keys/ssh/id_ed25519`, or register it as a Login-With-Key entry. The
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
- **NOT built (AC3e, Plane 0):** no agent is force-installed on the Proxmox host or the `storage` LXC.
  If wanted, install the `beszel-agent` binary there by hand (optional operator step).

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
