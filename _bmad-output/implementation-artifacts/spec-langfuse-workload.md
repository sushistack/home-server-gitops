---
title: 'Langfuse self-hosted workload for LangGraph observability'
type: 'feature'
created: '2026-06-30'
status: 'in-review'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** yt.flow(LangGraph 파이프라인)은 노드별 트레이싱, 프롬프트 버전 관리, RAGAS 평가 스코어 기록, 지연 시간 분석이 필요한데, 현재 homelab에 observability 백엔드가 없어 이 기능들을 사용할 수 없다.

**Approach:** 공식 Helm 차트(langfuse/langfuse 1.5.37)를 사용해 ArgoCD multi-source Application으로 Langfuse v3를 k3s 클러스터에 배포한다. 6개 컴포넌트(web, worker, postgres, clickhouse, redis, minio)를 Helm 서브차트로 묶어 배포하고, 커스텀 Traefik IngressRoute + CF Tunnel로 `langfuse.eli.kr`에서 접근한다.

## Boundaries & Constraints

**Always:**
- 기존 homelab 패턴 준수: local-path-retain 스토리지, SealedSecrets, Traefik IngressRoute, cert-manager TLS, CF Tunnel annotation
- 차트/이미지 버전 고정 (`:latest` 금지) — versions.yaml이 SSOT
- CPU limit 없음, memory limit만 (CFS throttling 방지, AR 패턴)
- `telemetryEnabled: false` — SaaS 전송 차단
- ClickHouse 단일 레플리카 (`replicaCount: 1`, `clusterEnabled: false`) — 홈랩은 HA 불필요
- 모든 자격증명은 SealedSecret으로만 Git 커밋

**Ask First:**
- ClickHouse 20Gi + MinIO 10Gi + Postgres 10Gi + Redis 2Gi ≈ 42Gi 디스크가 부족하면 크기 재협의

**Never:**
- 평문 credentials를 Git에 저장
- 표준 Kubernetes Ingress 사용 (반드시 Traefik IngressRoute)
- Redis/Postgres/ClickHouse 클러스터링 (단일 노드 홈랩)
- `signUpDisabled: true`를 초기 배포에 적용 (첫 admin 계정 생성 불가)

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| 최초 배포 | SealedSecret 봉인 완료 후 ArgoCD sync | 모든 6개 pod Running, `langfuse.eli.kr` 접속 시 로그인 화면 | pod CrashLoop → `kubectl logs` 확인; 주로 시크릿 키 누락 |
| yt.flow 트레이싱 | `YTFLOW_LANGFUSE_*` 환경변수 설정 후 파이프라인 실행 | Langfuse UI에 트레이스 + 스팬 트리 가시화 | Langfuse 미접근 시 warn 로그 후 파이프라인 계속 (non-fatal) |
| RAGAS 평가 | RAGAS 스코어를 Langfuse SDK `score()` 호출로 기록 | Langfuse trace에 faithfulness/relevancy 스코어 표시 | SDK 연결 실패 시 평가 결과 로컬 로그만 보존 |
| 프롬프트 관리 | Prompt Hub에서 버전 변경 후 yt.flow 재기동 | 새 버전 프롬프트가 다음 파이프라인 실행에 반영 | 버전 미존재 시 Langfuse SDK fallback 동작 |

</frozen-after-approval>

## Code Map

- `argocd/apps/langfuse.yaml` — ArgoCD Application (multi-source: Helm chart + infra/langfuse kustomize)
- `argocd/projects/homelab.yaml` — sourceRepos에 langfuse Helm repo 추가 필요
- `infra/langfuse/kustomization.yaml` — SealedSecret + Certificate + IngressRoute 리소스 목록
- `infra/langfuse/sealedsecret.yaml` — PLACEHOLDER 봉인 시크릿 (8개 키 포함, 봉인 레시피 주석)
- `infra/langfuse/certificate.yaml` — cert-manager Certificate (langfuse.eli.kr)
- `infra/langfuse/ingressroute.yaml` — Traefik IngressRoute HTTPS + HTTP→HTTPS 리디렉션
- `versions.yaml` — langfuse 차트 버전 항목 추가
- `docs/deploy-prompts/langfuse-seal-recipe.md` — 봉인 절차 운영 문서

## Tasks & Acceptance

**Execution:**
- [ ] `versions.yaml` -- langfuse 차트 항목 추가 (1.5.37 / appVersion 3.201.1)
- [ ] `argocd/projects/homelab.yaml` -- `https://langfuse.github.io/langfuse-k8s` sourceRepos 추가
- [ ] `argocd/apps/langfuse.yaml` -- multi-source Application: Source1=Helm chart(inline values), Source2=infra/langfuse
- [ ] `infra/langfuse/kustomization.yaml` -- resources 목록
- [ ] `infra/langfuse/sealedsecret.yaml` -- PLACEHOLDER SealedSecret + 봉인 레시피 주석
- [ ] `infra/langfuse/certificate.yaml` -- `${SECRET:DOMAIN_LANGFUSE}` 토큰화된 Certificate
- [ ] `infra/langfuse/ingressroute.yaml` -- websecure IngressRoute (langfuse-web:3000) + HTTP 리디렉션 미들웨어
- [ ] `docs/deploy-prompts/langfuse-seal-recipe.md` -- kubeseal 명령어 포함 봉인 운영 가이드

**Acceptance Criteria:**
- Given ArgoCD sync 완료, when `kubectl get pods -n langfuse` 실행, then web/worker/postgres/clickhouse/redis/minio 모두 Running
- Given SealedSecret 봉인 완료, when https://langfuse.eli.kr 접속, then Langfuse 로그인 페이지 로드 (HTTP→HTTPS 301 리디렉션 포함)
- Given `YTFLOW_LANGFUSE_HOST=https://langfuse.eli.kr` 설정 후 yt.flow 파이프라인 실행, when Langfuse UI 트레이스 탭 확인, then 노드별 스팬이 중첩 계층으로 표시됨
- Given signUpDisabled: false, when 첫 admin 계정 생성 후 signUpDisabled: true로 변경 (PR), then 추가 회원가입 불가

## Design Notes

**Multi-source 선택 이유:** Helm 차트(6개 서브컴포넌트)와 Traefik IngressRoute/Certificate/SealedSecret을 하나의 ArgoCD Application으로 관리. 두 개의 별도 App을 만들면 Langfuse-helm, Langfuse-infra로 분리되어 sync 순서 의존성이 생김.

**단일 SealedSecret 전략:** `langfuse-secrets` 하나에 8개 키를 모두 담아 Helm values의 `secretKeyRef`/`existingSecret`에서 참조. 키 이름이 명확하면 서브차트별 별도 시크릿보다 관리가 단순하다.

**ClickHouse 설정 주의:** 기본 `replicaCount: 3`, `clusterEnabled: true` → 홈랩에서는 반드시 1/false로 덮어쓰기. 이 설정 없이 배포하면 ZooKeeper 앙상블까지 뜨면서 수십 GB 소비.

## Verification

**Commands:**
- `kubectl get pods -n langfuse` -- expected: All pods Running (web, worker, langfuse-postgresql-0, langfuse-clickhouse-0, langfuse-redis-master-0, langfuse-minio-0)
- `kubectl get certificate -n langfuse` -- expected: READY=True for langfuse-tls
- `kubectl get ingressroute -n langfuse` -- expected: langfuse (websecure) + langfuse-redirect (web)
- `curl -I https://langfuse.eli.kr` -- expected: HTTP 200 or login redirect

**Manual checks (if no CLI):**
- ArgoCD UI → langfuse Application: Synced + Healthy (6개 서브차트 리소스 모두 초록)
- Langfuse UI 로그인 후 Projects > Traces 탭: 빈 상태이지만 접근 가능

## Spec Change Log
