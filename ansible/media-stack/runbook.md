# Media stack — Semaphore wiring runbook

Deploys `ansible/media-stack/` to the Jellyfin host via Semaphore (Ansible). Extends the day2-tooling
§1c/§1d pattern (the OpenWrt stack already runs this way). All steps are **operator-live** — the
playbook itself only `--syntax-check`s in CI; nothing here is auto-applied.

## 1. SSH key → `semaphore-ssh` (reseal)

`seal-secrets.sh` now takes the jellyfin host key as its **4th argument** (already wired). Use whatever
key already opens `root@<jellyfin-host>` — confirm which, then reseal:

```sh
ssh -v root@<jellyfin-host> 'echo ok' 2>&1 | grep -iE 'Server accepts|Offering'   # the accepted key file
cd workloads/semaphore
./seal-secrets.sh ~/.ssh/id_ed25519 ~/.ssh/oracle_proxy ~/.config/sops/age/keys.txt <jellyfin-key>
kubectl kustomize workloads/semaphore && git add -A workloads/semaphore && git commit && git push
```

Mounts at `/keys/ssh/jellyfin` (`ansible_user: root`).
> ⚠️ On reseal, reuse the existing `SEMAPHORE_ACCESS_KEY_ENCRYPTION` (don't regenerate — see script note),
> or every stored Semaphore access key is orphaned.

## 2. age key — REUSE the single cluster identity (NO new key)

"Zero new keys" is a recorded decision (DECISIONS.md, operational-gotchas.md): the cluster age recipient
already decrypts openwrt/oracle secrets in Semaphore and is mounted at `/keys/age/keys.txt`. media-stack
uses the same — nothing to generate or seal.

- Put the **full public recipient** into `.sops.yaml` (replace the placeholder):
  ```sh
  age-keygen -y ~/.config/sops/age/keys.txt    # prints age1chmmudv… — paste into .sops.yaml
  ```
- `deploy.yml` already points `SOPS_AGE_KEY_FILE` at `/keys/age/keys.txt`.

## 3. Encrypt the VPN secrets

Fill the real values in `ansible/media-stack/secrets.sops.yaml`, then encrypt in place and commit
ONLY the ciphertext:

```sh
sops -e -i ansible/media-stack/secrets.sops.yaml
git add ansible/media-stack/secrets.sops.yaml && git commit   # encrypted
```

> gitleaks CI is red on master as a baseline — confirm **your diff** introduces no plaintext secret
> (`git grep -nE 'WIREGUARD_PRIVATE_KEY|SERVER_CITIES' ansible/media-stack/` returns ciphertext only).

## 4. Semaphore project

- **Static inventory** (the pod can't `bin/render` — no `tokens.env` there). On a workstation:
  ```sh
  bin/render ansible/media-stack/inventory.yml      # -> rendered/ansible/media-stack/inventory.yml
  ```
  Paste the rendered file into a Semaphore Static Inventory. Confirm PUID/PGID/HOST_DATA/HOST_CONFIG
  against the live host first.
- **Runner needs binaries/collections**: `sops` + `age` CLIs (for `community.sops`), and
  `ansible-galaxy collection install community.docker community.sops` as a first-run setup step.
  If the stock Semaphore image lacks `sops`/`age`, use a custom runner image or a bootstrap task
  (same caveat as day2 §1b).
- **Image digests**: already pinned to `@sha256` index digests in `docker-compose.yml`. To bump a
  version, swap tag + digest together (`docker buildx imagetools inspect <image>:<tag>`). `:latest` is forbidden.

## 5. Task Templates (two-stance, day2 §1c/§1d)

- **Drift check (default/scheduled):**
  `ansible-playbook -i <inventory> ansible/media-stack/deploy.yml --check --diff --limit jellyfin`
  Acceptance = **0 changed / 0 failed**. `pull: missing` + digest pins mean a clean host stays at 0.
- **Live apply (review-required, not one-click):**
  `ansible-playbook -i <inventory> ansible/media-stack/deploy.yml --diff --limit jellyfin`

## 6. App connection (post-deploy UI)

1. **qBittorrent** → Options → Default Save Path = **`/data/torrents`** (🔴 MUST be under `/data` so it
   shares the library fs → hardlinks. The image default `/downloads` forces slow cross-fs copies).
2. **Prowlarr** → 인덱서 추가 → Settings/Apps에 Radarr·Sonarr 등록(API키).
3. **Radarr/Sonarr** → Download Client = qBittorrent host **`gluetun`**, port **8080**
   (🔴 NOT `localhost` — qbt shares gluetun's netns; radarr/sonarr are separate containers).
   Root folders: `/data/media/movies` (radarr), `/data/media/tv` (sonarr).
4. **Jellyseerr** → Jellyfin + Radarr + Sonarr 연동.
5. **Maintainerr** → Jellyfin + Radarr/Sonarr + Jellyseerr 연동.

## 7. External exposure & backup

- **Jellyseerr만** 외부: cloudflared 터널(`761ca633-…`)에 ingress rule 추가 →
  `<jellyseerr-host> → http://${IP_JELLYFIN}:5055`. CF Access 게이트 권장(Ask First). 나머지는 LAN/VPN only.
- **Backup**: `${HOST_CONFIG}`(앱 config/DB)만. 미디어는 재취득 가능. PBS 범위에 포함.

## 8. Docker-in-LXC caveat

The Jellyfin host is LXC #200 (iGPU passthrough). Docker needs **`nesting=1`** on the container, and
gluetun's `/dev/net/tun` needs the device allowed into the LXC
(`lxc.cgroup2.devices.allow: c 10:200 rwm` + `lxc.mount.entry: /dev/net/tun …`). Confirm before apply.
