---
title: 'Always-on Anki host on Proxmox LXC (AnkiConnect + self-hosted sync)'
type: 'feature'
created: '2026-06-29'
status: 'ready-for-dev'
context:
  - '{project-root}/ansible/README.md'
  - '{project-root}/docs/runbooks/'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** `english-quest` (n8n) needs an always-on AnkiConnect HTTP API to push cards, but Anki is a stateful GUI pet — forcing it into k3s means Xvfb/VNC/PVC/SealedSecret machinery, a memory-leak restart fight, and it competes for the cluster's fixed 24 GB RAM budget, all on a single Proxmox host where "in-cluster" buys no real HA anyway.

**Approach:** Run Anki on a dedicated **Proxmox LXC** on the LAN bridge (`vmbr1`), reachable from k3s pods by LAN IP. The LXC runs two systemd services: (1) Anki headless under Xvfb with the AnkiConnect add-on bound to `0.0.0.0:8765`, and (2) Anki's built-in `--syncserver` for fully self-hosted device sync (no cloud). The existing AnkiWeb collection is migrated once by re-pointing clients at the self-hosted server and uploading. This lives in the **host layer** (Ansible/runbook, outside ArgoCD), matching how the repo already provisions VMs (Terraform deferred; VM shapes documented in Git, provisioned by hand).

## Boundaries & Constraints

**Always:**
- LXC on Proxmox host `${SECRET:HOST_PROXMOX}`, bridge `vmbr1`, **static/reserved LAN IP** (matching OpenWrt DHCP leases, same pattern as the k3s nodes), `onboot: 1`. Sizing ~2 vCPU / 1.5–2 GB RAM (headroom for slow growth between restarts) / 8 GB disk — unprivileged container.
- Anki installed at a **pinned version** that matches your client devices (sync protocol is version-sensitive — see Design Notes). Record the version in `versions.yaml` SSOT style or the runbook.
- AnkiConnect add-on (ID `2055492159`) config: `webBindAddress: "0.0.0.0"`, `apiKey` set to a non-empty secret (LAN is semi-trusted — lock it), `webCorsOriginList` left default (n8n is a non-browser caller, sends no Origin).
- Anki runs headless via **Xvfb** (`QT_QPA_PLATFORM` offscreen is insufficient for AnkiConnect's webview in some builds — use a real Xvfb display), as a systemd unit with `Restart=always`. A **12-hourly restart timer at 03:00 / 15:00 KST** absorbs Anki's slow memory growth — deliberately offset from the 06:00 workflow window so Anki is freshly restarted and stable (~3h up) before the daily card add, and a restart never collides with a run. Collection is on the sync server, so a restart loses no data (seconds of downtime).
- `anki --syncserver` runs as a second systemd unit with credentials from env (`SYNC_USER1=user:pass`, `SYNC_BASE`, `SYNC_PORT=27701`). The headless Anki client on this same LXC syncs to `http://127.0.0.1:27701`.
- Secrets (AnkiConnect `apiKey`, `SYNC_USER1`) are NOT committed in clear text — store via the repo's tokenization pattern (`${SECRET:...}`) in any committed config, real values only in the git-ignored `rendered/` output.
- Backup = Proxmox snapshot/backup of the LXC (collection lives at the Anki base dir on the LXC rootfs), referenced from the existing bare-metal-recovery runbook. No k8s backup-cronjob.

**Ask First:**
- Exposing AnkiConnect (8765) or the sync server (27701) beyond the LAN (e.g. a Traefik IngressRoute + Certificate for remote phone review). MVP is **LAN-only review** — deferred.
- Bumping the Anki version after migration (must keep server and all clients within a compatible sync-protocol range).
- Switching the default from self-hosted sync to AnkiWeb (the runbook documents AnkiWeb as the simpler fallback).

**Never:**
- No k3s/ArgoCD workload for Anki — it is a host-layer pet, not a cluster cattle workload. (`workloads/anki/` must NOT be created.)
- No public exposure of 8765/27701 without TLS + auth.
- No destroying/recreating the collection during migration — the authoritative copy is uploaded, never re-initialised empty over a populated client.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| n8n reaches Anki | Pod POSTs `version` to `http://<lxc-ip>:8765` | Returns API version 6 | If unreachable, n8n workflow skips (its own concern) |
| Migration upload | Desktop has latest collection, endpoint switched to LXC | First sync prompts → choose **Upload**; server now holds full collection | If "Download" chosen by mistake, server is empty → re-do Upload from desktop |
| Phone first sync | Phone re-pointed at LXC sync server | Prompts → choose **Download**; full collection arrives | Version mismatch → bump/align Anki versions |
| Memory growth | Anki running many hours | 12-hourly timer (03:00/15:00) cycles it; AnkiConnect resumes | `Restart=always` covers crashes |
| LXC reboot | Proxmox host or LXC restarts | `onboot` + systemd units bring Anki + syncserver back | Verify with `version` curl post-boot |

</frozen-after-approval>

## Code Map

- `ansible/README.md` -- host-layer convention (Ansible owns hosts, stops at GitOps entry; VM shapes documented in Git, hand-provisioned, Terraform deferred) — the Anki LXC follows this model
- `docs/runbooks/bare-metal-recovery.md` -- backup/restore runbook style + where to reference the LXC snapshot backup
- `_bmad-output/implementation-artifacts/spec-english-quest.md` -- the consumer; its `ANKI_CONNECT_URL` points at this LXC

## Tasks & Acceptance

**Execution:**
- [ ] `docs/runbooks/anki-lxc.md` -- the full runbook: (1) Proxmox LXC creation (Ubuntu/Debian, vmbr1, reserved IP, `onboot`, unprivileged, sizing); (2) install Anki at the pinned version + AnkiConnect add-on; (3) AnkiConnect config (`webBindAddress`, `apiKey`, cors) with values tokenized; (4) two systemd units — `anki-headless` (Xvfb + Anki, `Restart=always`) and `anki-syncserver` (`anki --syncserver`, env creds) — plus a `systemd timer` restarting `anki-headless` every 12h (`OnCalendar=*-*-* 03,15:00:00`, TZ Asia/Seoul), offset from the 06:00 workflow; (5) one-time **migration** steps (desktop: final AnkiWeb sync → switch custom sync URL → Upload; phone + LXC client: Download); (6) verification commands; (7) AnkiWeb fallback note.
- [ ] `versions.yaml` -- add the pinned Anki version (and AnkiConnect add-on note) as SSOT, with a re-resolve/bump comment tying server+client compatibility.

**Acceptance Criteria:**
- Given the LXC is up, when a k3s pod runs `curl -s http://<lxc-ip>:8765 -d '{"action":"version","version":6,"key":"<apiKey>"}'`, then it returns a version number (not a connection error or auth failure).
- Given migration is complete, when `{"action":"deckNames","version":6,"key":"..."}` is called, then the response lists the user's existing decks (proves the real collection was uploaded, not an empty one).
- Given a test `addNote` to a scratch deck followed by `{"action":"sync"}`, when the phone syncs, then the test note appears on the phone (proves the self-hosted sync loop closes).
- Given the LXC reboots, when it comes back, then both systemd units are active and the `version` curl succeeds without manual intervention.

## Design Notes

- **Why Xvfb, not offscreen:** AnkiConnect serves through Anki's Qt webview; several builds need a real (virtual) X display to initialise it reliably. Xvfb + a systemd unit is the robust headless path; `QT_QPA_PLATFORM=offscreen` can leave the webview/API half-initialised.
- **Sync version sensitivity:** Anki's sync protocol changes between releases; a server far from the clients throws "sync protocol mismatch". Pin one version across LXC server, LXC client, desktop, and phone, and bump them together. This is the single most likely operational failure — call it out in the runbook.
- **One LXC, two roles:** the headless Anki *client* (AnkiConnect target for n8n) and the *sync server* both run on this LXC. n8n writes to the client; the client syncs to the local server; devices sync to the server. After each addNote batch, n8n calls AnkiConnect `sync` to push.
- **AnkiWeb fallback:** if self-hosted sync proves fiddly, the runbook's fallback is to skip `anki-syncserver` and have the LXC client + devices all sync to AnkiWeb (free, official) — only the sync endpoint config differs; everything else (LXC, AnkiConnect, n8n) is unchanged.
- **Client support:** all clients accept a custom sync endpoint — desktop (Preferences → Syncing → self-hosted URL, 2.1.57+), AnkiDroid (Settings → Sync → custom sync + media URL), AnkiMobile/iOS (recent versions). All work on the home LAN against `http://<lxc-ip>:27701/`. Off-LAN review needs the deferred remote-exposure path (Traefik+TLS or Tailscale) — the built-in server is plaintext HTTP and must not be exposed bare.

## Verification

**Commands (run from a k3s node/pod once the LXC is built):**
- `curl -s http://<lxc-ip>:8765 -d '{"action":"version","version":6,"key":"<apiKey>"}'` -- expected: `{"result":6,"error":null}`-ish
- `curl -s http://<lxc-ip>:8765 -d '{"action":"deckNames","version":6,"key":"<apiKey>"}'` -- expected: existing decks listed

**Manual checks:**
- On the LXC: `systemctl is-active anki-headless anki-syncserver` → both `active`; `systemctl list-timers | grep anki` → 12-hourly restart timer (next fire 03:00 or 15:00) present.
- Phone Anki points at the custom sync server and pulls the full collection.
