# Session 3 — 영상 *arr 스택 (Jellyfin VM) · repo 관리 + Semaphore 배포

> bmad-quick-dev 세션에 아래 전체를 붙여넣어라.
> 목표: Jellyfin VM의 *arr/다운로드 스택을 **수동 SSH 대신 GitOps로** — compose를 repo에 두고 **Semaphore(Ansible)**가 배포.
> Jellyfin은 이미 이 VM에서 GPU로 돌고 있다고 가정. 아래는 그 옆에 얹는 자동화 레이어.
> (음악/Lidarr는 k3s 별도 — `session-2-music-lidarr.md`.)

## 왜 이 방식

이 repo엔 이미 `ansible/`(playbook+inventory) + **Semaphore**(SSH키·age키 sealed 탑재) + **SOPS** 체계가 있다.
새 도구 없이 그 레일에 얹는다: compose를 repo에 두고, Semaphore Task Template이 Ansible playbook을 돌려
VM에 `docker compose up -d`. git에서 compose 고치면 재실행 → VM 수렴. `--check`로 드리프트 확인.

## 접근 / 타깃

- 배포 타깃 = **Jellyfin VM 직접**(미디어 디스크가 거기 있음, 하드링크 위해). Proxmox 호스트(`ssh root@10.0.0.2`)는 경유/콘솔용.
- VM IP는 기존 토큰 재사용: inventory에 `${SECRET:IP_JELLYFIN}` → 실제값은 `internal/tokens.env`(git-ignored)에 이미 있음.
- SSH: 기존 `semaphore-ssh` 시크릿엔 openwrt/oracle 키뿐 → **Jellyfin VM용 키 추가 필요**(아래 런북).

---

## 레퍼런스 (반드시 읽고 컨벤션 맞출 것)

- `ansible/playbook.yml`, `ansible/inventory.yml` — 기존 playbook/inventory 스타일(토큰 `${SECRET:...}`, `bin/render`로 렌더).
- `workloads/semaphore/seal-secrets.sh` — SSH/age 시크릿 sealing 방식. SSH키는 한 시크릿에 여러 파일(`/keys/ssh/<name>`).
- `docs/runbooks/day2-tooling.md` §1c — Semaphore 프로젝트/repo/static inventory/key/`--check` 드리프트 템플릿 구성(review-gated apply). 기존 Semaphore는 `configs/openwrt/`를 돌리는 중 → 미디어 스택은 그 확장.
- age키(`semaphore-age`, cluster DR identity)는 Semaphore에 이미 sealed → SOPS 복호에 `SOPS_AGE_KEY_FILE=/keys/age/keys.txt` 사용.

## 산출물

1. `ansible/media-stack/docker-compose.yml` — 아래 compose.
2. `ansible/media-stack/deploy.yml` — playbook: docker 보장 → 디렉터리 생성 → SOPS 시크릿 복호 → `.env` 렌더 →
   compose 배치 → `community.docker.docker_compose_v2`(state present, pull). 기존 playbook.yml 스타일(주석·idempotent·no_log) 따를 것.
3. `ansible/media-stack/secrets.sops.yaml` — SOPS+age 암호화. VPN 자격증명 등. cluster age recipient로 암호화(운영자가 `sops -e`).
4. `ansible/media-stack/inventory.yml` — 토큰 inventory(group `media`, host `jellyfin`, `ansible_host: ${SECRET:IP_JELLYFIN}`, ssh key `/keys/ssh/jellyfin`).
5. `ansible/media-stack/runbook.md` — 아래 "Semaphore 와이어링" 절차.

비밀은 절대 평문 금지. compose의 비밀값은 `.env`로 빠지고 그 `.env`는 SOPS에서만 렌더된다.
작업 끝나면 `ansible-playbook --syntax-check`로 검증만(실제 실행/apply 금지), 변경 요약 남길 것.

---

## docker-compose.yml

### 선행 결정 (compose/secrets에 박을 값)

| 항목 | 설정값 |
|------|--------|
| `HOST_DATA` | VM 미디어 디스크에서 **라이브러리 + 다운로드를 같이 담을 부모 경로** (예: `/mnt/media`). 하드링크 위해 둘이 같은 fs |
| 라이브러리 | `$HOST_DATA/media/movies`, `$HOST_DATA/media/tv` = Jellyfin이 이미 읽는 폴더로 맞출 것 |
| 다운로드 | `$HOST_DATA/torrents` |
| `PUID`/`PGID` | 미디어 파일 소유 uid/gid (`id <user>`) |
| VPN | gluetun provider + 자격증명 — **secrets.sops.yaml**에만 |

```yaml
services:
  gluetun:                     # VPN — qbittorrent가 이 네트워크로만 나간다 (킬스위치)
    image: qmcgaw/gluetun
    container_name: gluetun
    cap_add: [NET_ADMIN]
    environment:
      VPN_SERVICE_PROVIDER: ${VPN_SERVICE_PROVIDER}
      VPN_TYPE: ${VPN_TYPE}
      WIREGUARD_PRIVATE_KEY: ${WIREGUARD_PRIVATE_KEY}
      WIREGUARD_ADDRESSES: ${WIREGUARD_ADDRESSES}
      SERVER_CITIES: ${SERVER_CITIES}
      TZ: ${TZ}
    ports:
      - 8080:8080              # qbittorrent UI (gluetun 네트워크에 게시)
    restart: unless-stopped

  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent
    container_name: qbittorrent
    network_mode: "service:gluetun"   # VPN 끊기면 토렌트도 차단
    depends_on: [gluetun]
    environment: {PUID: ${PUID}, PGID: ${PGID}, TZ: ${TZ}, WEBUI_PORT: 8080}
    volumes:
      - ${HOST_CONFIG}/qbittorrent:/config
      - ${HOST_DATA}:/data              # /data/torrents 로 받음 (라이브러리와 같은 fs → 하드링크)
    restart: unless-stopped

  prowlarr:
    image: lscr.io/linuxserver/prowlarr
    container_name: prowlarr
    environment: {PUID: ${PUID}, PGID: ${PGID}, TZ: ${TZ}}
    volumes: [ "${HOST_CONFIG}/prowlarr:/config" ]
    ports: [ "9696:9696" ]
    restart: unless-stopped

  radarr:
    image: lscr.io/linuxserver/radarr
    container_name: radarr
    environment: {PUID: ${PUID}, PGID: ${PGID}, TZ: ${TZ}}
    volumes:
      - ${HOST_CONFIG}/radarr:/config
      - ${HOST_DATA}:/data
    ports: [ "7878:7878" ]
    restart: unless-stopped

  sonarr:
    image: lscr.io/linuxserver/sonarr
    container_name: sonarr
    environment: {PUID: ${PUID}, PGID: ${PGID}, TZ: ${TZ}}
    volumes:
      - ${HOST_CONFIG}/sonarr:/config
      - ${HOST_DATA}:/data
    ports: [ "8989:8989" ]
    restart: unless-stopped

  jellyseerr:                  # 요청 UI (가족) — Radarr/Sonarr/Jellyfin 연동
    image: fallenbagel/jellyseerr
    container_name: jellyseerr
    environment: {TZ: ${TZ}}
    volumes: [ "${HOST_CONFIG}/jellyseerr:/app/config" ]
    ports: [ "5055:5055" ]
    restart: unless-stopped

  maintainerr:                 # 안 본 콘텐츠 자동 정리
    image: ghcr.io/jorenn92/maintainerr
    container_name: maintainerr
    environment: {TZ: ${TZ}}
    volumes: [ "${HOST_CONFIG}/maintainerr:/opt/data" ]
    ports: [ "6246:6246" ]
    restart: unless-stopped
```

---

## Semaphore 와이어링 (운영자 수동, day2-tooling.md §1c 패턴)

1. **SSH키 추가**: Jellyfin VM용 키를 `semaphore-ssh` 시크릿에 추가 — `seal-secrets.sh`에
   `--from-file=jellyfin=<key>` 한 줄 더해 reseal → pod에 `/keys/ssh/jellyfin`로 마운트됨.
2. **IP 토큰**: 기존 `internal/tokens.env`의 `IP_JELLYFIN=<VM LAN IP>` 재사용(렌더 SSOT).
3. **SOPS 시크릿**: `secrets.sops.yaml`을 cluster age recipient로 `sops -e`. Task에 `SOPS_AGE_KEY_FILE=/keys/age/keys.txt`.
4. **Task Template**: Repository=이 repo, Inventory=media, Playbook=`ansible/media-stack/deploy.yml`.
   버튼 실행 or repo push 트리거. 드리프트 확인용 `--check` 템플릿도 하나(§1d처럼).

## 앱 연결 (배포 후 UI)

1. **Prowlarr** → 인덱서 추가 → Settings/Apps에 Radarr·Sonarr 등록(API키). 인덱서 자동 동기화.
2. **Radarr/Sonarr** → Download Client = qBittorrent(`gluetun:8080`; `localhost` 아님). Root folder = `/data/media/movies`(radarr), `/data/media/tv`(sonarr).
3. **Jellyseerr** → Jellyfin + Radarr + Sonarr 연동.
4. **Maintainerr** → Jellyfin + Radarr/Sonarr + Jellyseerr 연동.

## 외부 노출

- Jellyseerr만 외부 필요 → 기존 **cloudflared 터널(`761ca633-...`)에 ingress rule 추가**: `<jellyseerr-host> → http://${IP_JELLYFIN}:5055`.
  CF Access로 게이트할지(권장) 가족 공개로 둘지 선택.
- 나머지(qbt/prowlarr/radarr/sonarr/maintainerr)는 LAN/VPN only — 터널 룰 추가하지 말 것.

## 백업

- `${HOST_CONFIG}`(각 앱 config/DB)만 백업. 미디어는 재취득 가능.
- PBS/스크립트 백업 범위에 `${HOST_CONFIG}` 포함.

---

## 메모 — 음악(Lidarr)은 별도 세션 (k3s)

음악은 **무손실(FLAC)/정식 릴리스 목표 확정** → Lidarr GO. 단 Navidrome 음악이 k3s(만화 디스크 공유 node-local PV)라
**k3s**에서, Navidrome 옆에 둔다. 자작 yt-dlp/Last.fm(lossy)은 이걸로 대체.
→ 프롬프트: `session-2-music-lidarr.md` (Lidarr + slskd + soularr).
