---
title: 'Jellyfin host *arr media stack — GitOps via Semaphore/Ansible'
type: 'feature'
created: '2026-06-23'
status: 'done'
baseline_commit: 'ffbe04c1d0d47d313350af550c01e36e340e135d'
context:
  - '{project-root}/ansible/playbook.yml'
  - '{project-root}/ansible/inventory.yml'
  - '{project-root}/workloads/semaphore/seal-secrets.sh'
  - '{project-root}/docs/runbooks/day2-tooling.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Jellyfin host의 *arr/다운로드 스택(qbittorrent·prowlarr·radarr·sonarr·jellyseerr·maintainerr + gluetun VPN)이 수동 SSH로 관리돼 드리프트·재현성 문제가 있다. 미디어 디스크(하드링크용)가 그 호스트에 있어 k3s가 아닌 호스트 직접 배포가 맞다.

**Approach:** 새 도구 없이 기존 레일(`ansible/` + Semaphore + SOPS/age)에 얹는다. compose를 `ansible/media-stack/`에 두고, Semaphore Task Template이 playbook을 돌려 호스트에 `docker compose up -d`. 비밀은 SOPS+age로만, `.env`는 런타임에 복호·렌더. git에서 compose 고치면 재실행 → 호스트 수렴, `--check`로 드리프트 확인.

## Boundaries & Constraints

**Always:**
- 기존 `playbook.yml` 스타일 준수: 풍부한 주석, idempotent, 비밀 task엔 `no_log: true`.
- 이미지는 **digest(`@sha256`) 핀**(AR29 정신). compose `pull_policy: missing` + `docker_compose_v2 pull: missing` — 재실행/`--check`이 태그를 말없이 점프시키지 않게(드리프트 신호 보존).
- 비밀(VPN 자격증명)은 `secrets.sops.yaml`에만, **단일 클러스터 age recipient**(openwrt/oracle와 동일)로 암호화. 복호는 `/keys/age/keys.txt`. — DECISIONS.md "zero new keys".
- `.env`는 **repo 체크아웃 밖** 호스트 배포 경로에 0600·`no_log`로 렌더. git 추적 불가.
- 비-비밀 노브(PUID/PGID/HOST_DATA/HOST_CONFIG/TZ)는 inventory group_vars. 토큰 inventory는 `${SECRET:...}` 컨벤션(운영자가 `bin/render`로 Semaphore static inventory 생성).
- 디렉터리는 스택이 쓰는 하위 경로만 PUID:PGID로 생성. **기존 미디어 트리에 `chown -R` 금지**(대용량 + Jellyfin 소유 파괴 위험).
- 작업 후 `ansible-playbook --syntax-check` 검증만. **실제 apply/실행 금지.**

**Ask First:**
- Jellyseerr 외부 노출 시 CF Access 게이트(권장) vs 가족 공개.
- 기존 `$HOST_DATA` 미디어 소유 uid/gid가 PUID/PGID와 불일치 시 정렬 방법(수동 선별 chown vs PUID 조정).

**Never:**
- 새 media-stack 전용 age 키를 만들지 않는다. repo의 Semaphore/SOPS 운영 결정은 단일 cluster age identity 재사용("zero new keys")이다.
- floating tag(`:latest`) + `pull: always` 조합.
- 음악/Lidarr(별도 k3s 세션). qbt 외 나머지 앱 터널 룰. compose→k8s 변환. 미디어 데이터 백업(config만).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| 정상 배포 | sops 복호 OK, docker 존재 | 스택 하위 dir 생성 → `.env` 렌더(repo 밖, 0600) → compose 배치 → `docker_compose_v2` pull=missing+up, 컨테이너 7개 up | N/A |
| 재실행(수렴) | 변경 없음, 같은 digest | 모든 task `ok`, 이미지 재-pull/recreate 없음(`pull: missing`) | N/A |
| `--check` 드리프트 | 호스트가 git과 다름 | changed>0 보고(apply 안 함), 이미지 변동은 0(핀 고정) | N/A |
| cluster age 키 부재 | `/keys/age/keys.txt` 없음 | decrypt task fail fast, `.env` 안 써짐 | task 실패, 명확 메시지 |
| 기존 미디어 소유 불일치 | `$HOST_DATA` 기존 파일이 타 uid 소유 | preflight가 경고/실패(blind chown 안 함) | assert/warn, 운영자 정렬 |
| qbt 다운로드 클라이언트 | radarr/sonarr가 qbt 접속 | `gluetun:8080`로 연결(qbt가 gluetun netns 공유 → `localhost` 아님) | 잘못 설정 시 import 0건 |

</frozen-after-approval>

## Code Map

- `ansible/playbook.yml` -- 따라야 할 스타일 레퍼런스(주석·idempotent·no_log·`creates:` 가드).
- `ansible/inventory.yml` -- `${SECRET:...}` 토큰 inventory 컨벤션.
- `workloads/semaphore/seal-secrets.sh` -- SSH/age sealing(`--from-file=<name>=<key>` → `/keys/ssh|age/<name>`); jellyfin SSH 키 추가 대상. age key는 기존 `keys.txt` 재사용.
- `docs/runbooks/day2-tooling.md` §1c/§1d -- Semaphore static inventory/`--check` 드리프트 패턴 + 이미지 placeholder→digest 절차.
- `bin/render`, `internal/tokens.env` -- inventory 렌더 SSOT(워크스테이션에서 실행).
- `.sops.yaml` -- media-stack secrets creation_rule; existing cluster age recipient 재사용.

## Tasks & Acceptance

**Execution:**
- [x] `ansible/media-stack/docker-compose.yml` -- 프롬프트 7개 서비스(gluetun·qbittorrent·prowlarr·radarr·sonarr·jellyseerr·maintainerr). **이미지 digest 핀** + 각 줄에 `docker buildx imagetools inspect` 갱신 커맨드 주석. `${HOST_CONFIG}` 변수 추가. `pull_policy: missing`. gluetun netns 공유/qbt 접근은 `gluetun:8080`임을 주석. LXC `nesting=1`/`/dev/net/tun` 주석. gluetun 재생성 시 qbt 동반 recreate 주석.
- [x] `ansible/media-stack/inventory.yml` -- group `media`, host `jellyfin`, `ansible_host: ${SECRET:IP_JELLYFIN}`(기존 토큰 재사용), `ansible_ssh_private_key_file: /keys/ssh/jellyfin`. group_vars: PUID/PGID/HOST_DATA(`/mnt/media`)/HOST_CONFIG(`/opt/media-stack/config`)/TZ 기본값. **렌더 소스**(operator `bin/render` → Semaphore static inventory).
- [x] `ansible/media-stack/secrets.sops.yaml` -- VPN 자격증명 placeholder YAML. **기존 cluster age recipient로** `sops -e -i`(DECISIONS.md "zero new keys"). 평문 커밋 금지.
- [x] `.sops.yaml` -- `ansible/media-stack/secrets\.sops\.yaml` creation_rule → existing cluster age public recipient(`age1chmmudv…`) 재사용.
- [x] `ansible/media-stack/env.j2` -- (구현 중 추가) `.env` 렌더용 Jinja 템플릿. secrets(sops 복호) + group_vars 병합.
- [x] `ansible/media-stack/.gitignore` -- `*.env`, 렌더 산출물 무시(평문 누출 가드).
- [x] `ansible/media-stack/deploy.yml` -- playbook: ① docker engine + compose plugin 보장 ② **preflight**: 기존 `$HOST_DATA` 소유가 PUID:PGID와 호환인지 assert/warn(blind chown 안 함) ③ 스택 하위 dir만 생성(`torrents`, `media/movies`, `media/tv`, 각 앱 config) owner PUID:PGID ④ `community.sops`로 `secrets.sops.yaml` 복호(`SOPS_AGE_KEY_FILE=/keys/age/keys.txt`, `no_log`) ⑤ `.env`를 **호스트 배포 경로(repo 밖)**에 렌더(secrets+group_vars, 0600, `no_log`) ⑥ compose 복사 ⑦ `community.docker.docker_compose_v2`(state=present, **pull=missing**).
- [x] `ansible/media-stack/runbook.md` -- Semaphore 와이어링: (1) `seal-secrets.sh`에 `--from-file=jellyfin=<ssh-key>` 추가+reseal (2) `.sops.yaml`은 existing cluster age recipient 재사용 (3) `secrets.sops.yaml` `sops -e -i` (4) `bin/render ansible/media-stack/inventory.yml` → 결과를 Semaphore static inventory에 붙여넣기 + `community.docker`/`community.sops` collection 설치 step (5) Task Template: apply + `--check` 드리프트 (6) 🔴 **앱 연결: radarr/sonarr Download Client = `gluetun:8080`(`localhost` 아님)** (7) jellyseerr만 cloudflared 터널(`761ca633`) ingress → `http://${IP_JELLYFIN}:5055` (8) 백업=`${HOST_CONFIG}`만 (9) gitleaks CI는 master 베이스라인 red — 본인 diff만 clean 확인 (10) 🔴 LXC면 `nesting=1`.

**Acceptance Criteria:**
- Given `community.sops`/`community.docker` 설치 후, when `ansible-playbook --syntax-check ansible/media-stack/deploy.yml`, then 0 error(미설치 시 모듈 해석 에러 — runbook §4가 설치 커버).
- Given 모든 산출물, when `git grep -nE 'WIREGUARD_PRIVATE_KEY|WIREGUARD_ADDRESSES|SERVER_CITIES' ansible/media-stack/` (평문값), then 매치 없음(placeholder/암호문만).
- Given `.sops.yaml` recipient, when 확인, then existing cluster age recipient(`age1chmmudv…`)를 사용한다.
- Given compose, when 이미지 참조 확인, then 전부 `@sha256` index digest 핀, `:latest`/floating 없음.
- Given 운영자가 Semaphore에서 `--check`, when 호스트가 git과 일치, then 0 changed(이미지 변동 0).

## Verification

**Commands:**
- `ansible-galaxy collection install community.sops community.docker && ansible-playbook --syntax-check ansible/media-stack/deploy.yml` -- expected: syntax OK, 0 error.
- `docker compose -f ansible/media-stack/docker-compose.yml config -q` -- expected: 스키마 valid(변수 미정의 경고 무시 — 런타임 `.env`).
- `git grep -nE 'WIREGUARD_PRIVATE_KEY|SERVER_CITIES' ansible/media-stack/secrets.sops.yaml` -- expected: 평문 매치 없음.
- `grep -q 'age1chmmudv' .sops.yaml` -- expected: existing cluster recipient present(DECISIONS.md "zero new keys").

## Design Notes

- **Age key reuse:** `docs/DECISIONS.md` and `docs/operational-gotchas.md` establish a single SOPS recipient for Semaphore/openwrt/oracle/cluster secrets. media-stack follows that rail: no new age key, decrypt via `/keys/age/keys.txt`. The only new sealed material is the Jellyfin SSH private key file in `semaphore-ssh`.
- **이미지 핀 + pull 정책:** `:latest`+`pull: always`는 재실행마다 무단 메이저 점프 → 3am 페이지. digest 핀 + `pull: missing`이면 핀 바꾸기 전엔 안 움직이고, `--check` 드리프트도 노이즈 없이 의미를 가짐(Grumbal/Yui).
- **qbt 도달 경로:** qbt는 `network_mode: service:gluetun` → gluetun netns에 산다. radarr/sonarr는 별도 컨테이너라 `localhost:8080`은 자기 자신. qbt UI 포트(8080)는 gluetun이 게시하므로 `gluetun:8080`로 연결(Boundary).
- **권한:** 스택 하위 dir만 생성/소유. 기존 미디어 트리 `chown -R`은 대용량 + Jellyfin 소유 파괴라 금지 — 불일치 시 preflight가 멈추고 운영자가 선별 정렬(Dana/Boundary).
- **`.env` 렌더(golden):**
  ```yaml
  - community.sops.load_vars: { file: "{{ playbook_dir }}/secrets.sops.yaml" }
    no_log: true   # SOPS_AGE_KEY_FILE=/keys/age/keys.txt
  - ansible.builtin.template:
      src: env.j2
      dest: "{{ deploy_dir }}/.env"   # deploy_dir = repo 밖 호스트 경로 (예: /opt/media-stack)
      mode: '0600'
    no_log: true
  ```

## Suggested Review Order

**Deploy flow & secret handling (the spine)**

- 진입점 — 배포 작업 순서 전체를 한눈에: docker 보장 → preflight → 복호 → 렌더 → up
  [`deploy.yml:19`](../../ansible/media-stack/deploy.yml#L19)
- SOPS+age 복호: existing cluster key(`/keys/age/keys.txt`)로, no_log
  [`deploy.yml:77`](../../ansible/media-stack/deploy.yml#L77)
- 리뷰 반영 — 미암호화 템플릿(REPLACE_ME) 상태 배포를 fail-fast로 차단
  [`deploy.yml:85`](../../ansible/media-stack/deploy.yml#L85)
- 리뷰 반영 — 마운트 루트가 아닌 라이브러리 하위 dir만 소유권 검사(오탐 방지)
  [`deploy.yml:31`](../../ansible/media-stack/deploy.yml#L31)

**VPN killswitch & 컨테이너 결합**

- qbt가 gluetun netns 공유 → killswitch
  [`docker-compose.yml:37`](../../ansible/media-stack/docker-compose.yml#L37)
- 리뷰 반영 — 터널 healthy 전 qbt 기동 방지(`condition: service_healthy`)
  [`docker-compose.yml:39`](../../ansible/media-stack/docker-compose.yml#L39)

**Key separation & 토큰**

- existing cluster age recipient — "zero new keys" 결정 준수
  [`.sops.yaml:8`](../../.sops.yaml#L8)
- 기존 `IP_JELLYFIN` 토큰 재사용 + ssh 키 마운트 경로
  [`inventory.yml:13`](../../ansible/media-stack/inventory.yml#L13)

**운영 절차 (peripherals)**

- Semaphore 와이어링 / 앱 연결 / 외부 노출 / LXC 주의
  [`runbook.md:1`](../../ansible/media-stack/runbook.md#L1)
