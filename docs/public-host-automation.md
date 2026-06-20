# 공개 호스트 추가 자동화 — 현재 / 정석 / 마이그레이션

> 배경: 공개 호스트(`*.<public-zone>`) 하나를 추가/이동하면 **세 시스템**을 손봐야 한다.
> ntfy 웹 컷오버(2026-06-21)에서 이 toil 이 드러나 정리한 설계 노트.

## 현재 — 3개 시스템, 일부만 자동화

| 시스템 | 무엇 | 상태 |
|---|---|---|
| **homelab-gitops** (k8s manifest + IngressRoute + `DOMAIN_*` 토큰) | 앱 정의 | ✅ GitOps(ArgoCD) 자동 싱크 |
| **OpenWrt DNS** (homelab-network `ansible/host_vars/gateway.yml` `local_dns_overrides`) | LAN split-horizon (`*.<public-zone> → <node>`) | ✅ ansible 코드화 (한 줄 + apply) |
| **Cloudflare** (터널 ingress 규칙 + 공개 DNS CNAME) | 공개 엣지 | ❌ 대시보드/수기 API = **ad-hoc** |

빠진 건 둘뿐: **Cloudflare 가 코드가 아님** + **세 개를 묶는 단일 진입점이 없음**.

> 보충: 토큰은 git-ignored `internal/tokens.env` SSOT + 라이브 `argocd-render-tokens` Secret 양쪽에
> 있어야 함. CF 토큰 권한 주의 — `cloudflare_ddns_api_token`(sops)은 **DNS:Edit 전용**이라
> 터널 ingress 수정엔 별도 **Tunnel:Edit** 토큰이 필요 (`internal/cf-tunnel.env` 의 그 토큰).

## 정석 (canonical) — 단일 선언 → 컨트롤러가 reconcile

원칙: **서비스는 한 곳에서 선언적으로 정의하고, DNS·터널·LAN 은 컨트롤러가 그걸 보고 자동 생성한다.**
명령형 스크립트도, 손으로 치는 API 도, Ansible 로 클라우드 DNS 미는 것도 정석이 아님.

| 계층 | 정석 도구 |
|---|---|
| k8s 서비스/라우트 | GitOps (이미 정석) — IngressRoute 가 단일 선언 |
| 공개 DNS 레코드 | **external-dns** + Cloudflare provider. IngressRoute 를 watch → CF DNS 자동 생성/삭제 (`--source=traefik-proxy`) |
| 터널 ingress 규칙 | (i) **locally-managed 터널 + config-as-code**: 토큰 모드 대신 `credentials-file` 로 바꿔 ingress 를 in-cluster ConfigMap(git)에 둠 — 컨트롤러 0개, 제일 단순 / (ii) **cloudflare-tunnel-ingress-controller**: Ingress watch → 터널+DNS 자동, 더 자동이나 무빙파츠 ↑ |
| LAN split-horizon | external-dns 가 OpenWrt dnsmasq 를 1급으로 못 씀. 정석은 **external-dns 가 쓸 수 있는 내부 DNS**(CoreDNS / Bind RFC2136 / Technitium / AdGuard webhook)를 두고, external-dns 2번째 인스턴스로 내부존(`*.<public-zone> → <node>`) 자동 기록. OpenWrt 는 그 내부 DNS 로 conditional-forward 만 → dnsmasq 수기 목록 소멸 |

**정석이면서 단순한 조합 = external-dns(DNS) + (i) 터널 config-as-code.**

최종 그림:

> IngressRoute 하나 선언 → external-dns 가 공개 DNS(CF) + 내부 DNS 동시 기록 →
> 터널 ingress 는 git ConfigMap 으로 reconcile → ArgoCD 싱크.
> **호스트 추가가 k8s manifest 단 한 곳으로 수렴. CF·LAN·터널 수기 전부 소멸.**

## 두 학파 / 도구 위치

- **컨트롤러/오퍼레이터 학파** (external-dns + 터널 컨트롤러): k8s-네이티브 GitOps 정석. **이 환경에 가장 맞음.**
- **Terraform 학파**: "Cloudflare/인프라를 IaC 로" 의 정석. 맞지만 별도 컨트롤 플레인이 생기고, k8s-앞단 서비스의 "단일 선언" 목표엔 컨트롤러보다 덜 우아.
- **Ansible/Semaphore**: **OpenWrt 라우터 장비 자체**(방화벽/PBR/wg/패키지) 관리엔 정석. 클라우드 DNS·터널·k8s 서비스를 Semaphore 로 모는 건 external-dns 가 하는 일을 손으로 재구현하는 셈 — 정석 아님. → **Semaphore 는 라우터 장비 관리에만** 남기는 게 역할 분담상 맞음.

## 현실 판단 / 마이그레이션 순서 (가고 싶을 때)

호밤 규모(공개 호스트 ~15개, 변경 드묾)에선 풀 스택이 **오버킬**일 수 있음. 점진 도입:

1. **external-dns (CF)** 먼저 — 공개 DNS 수기 제거. 제일 효과 큼.
2. **터널 config-as-code** — 토큰 모드 → credentials-file + ConfigMap ingress. 터널 수기 제거.
3. **내부 DNS + external-dns 2번째 인스턴스** — OpenWrt dnsmasq 수기 목록 흡수 (제일 손 많이 감, 마지막).

각 단계가 독립적으로 가치 있고 되돌릴 수 있음. 1번만 해도 toil 의 절반이 사라짐.

## 중간 단계 (정석 전, lazy 대안)

정석으로 가기 전 toil 만 줄이려면: `internal/cf-tunnel.env`+`cloudflare_ddns_api_token` 을 재사용하는
래퍼 한 개(`add-public-host <host> [ip]`)가 CF DNS + CF 터널 ingress + OpenWrt override 를 한 번에 처리.
50줄, 새 의존성 0. 단 SSOT 정합성(드리프트 게이트)을 위해 repo 선언 → reconcile 형태로 둘 것.
