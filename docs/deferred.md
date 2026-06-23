# Deferred — 노드 팬 주기적 가동 원인 추적

상태: **재조사 (H1 오결론 정정 → H5 longhorn / H6 netdata 유력)** · 작성일: 2026-06-22 · 관련 커밋: `ae83cff` (longhorn dataLocality best-effort)

> **2026-06-23 정정 — H1(trade-monitor)은 사실상 무죄.** Netdata 대시보드(k8s.cgroup.cpu) 라이브
> 스냅샷 2장에서 **trade-monitor는 두 프레임 모두 Top CPU에 없음.** 실제 그림은 아래:
>
> | namespace | 1차(총 54%) | 2차(총 106%) | 해석 |
> |---|---|---|---|
> | **longhorn-system** | 20.70% | **66.83%** | **3배 점프 = 스파이크 주범** |
> | **netdata** | 26.04% | 25.12% | 거의 고정 = **상시 CPU 바닥** |
> | 그 외(argocd/anytype/karakeep…) | <2% | <5% | 노이즈 |
> | Disk Write | 0.17 | 0.24 MiBy/s | 두 프레임 다 **거의 0** |
>
> 핵심: longhorn이 66%까지 튀는데 **디스크 Write는 0.24 MiBy/s로 정지** → 디스크 I/O 작업이 아니라
> **CPU 해싱/체크섬류** 시그니처. → **새 가설 H5(longhorn 주기 CPU) / H6(netdata 상시 CPU)** 로 전환.
>
> **H1이 왜 오결론이었나:** 매 60초 발화·~18초 스파이크는 사실이지만, 대시보드 실측에서 trade-monitor의
> CPU 점유가 Top에 안 잡힘(부하가 작거나 측정창 밖). 60초 톱니파에 꽂혀 **상시 바닥(netdata)과
> 더 큰 스파이크(longhorn)를 못 봤음.** 교훈: 가설을 `kubectl top`/대시보드 **실측 랭킹**으로 먼저
> 검증했어야 함. (S1 trade-monitor warm Deployment 작업물은 무해하므로 별도 판단 — 팬과는 무관.)

---

## 증상

노드 팬이 **주기적으로 계속 가동**된다. `ae83cff` 에서 Longhorn `dataLocality: best-effort`
로 VM 간 디스크 I/O를 줄였지만 팬 패턴은 **변화 없음**.

이게 핵심 단서다: 디스크 I/O 튜닝이 팬에 영향을 못 줬다는 건 **병목이 디스크가 아니라
CPU(또는 디스크라 해도 dataLocality가 못 잡는 워크로드)** 라는 뜻.

---

## 추측 (Hypotheses) — 의심 순위

### H1 — `trade-monitor` 매분 콜드스타트 — ❌ **무죄 (2026-06-23 대시보드 실측)**

> 대시보드 2장 모두 Top CPU에 trade-monitor 없음. 아래는 원래 가설 기록(보존).


- 파일: [workloads/trade-monitor/cronjob.yaml](../workloads/trade-monitor/cronjob.yaml)
- `schedule: "* * * * *"` — **매 1분마다** 새 Pod 생성.
- 이미지가 무거운 **matplotlib / pandas** 스택. 매 사이클마다:
  1. 컨테이너 콜드스타트
  2. Python 인터프리터 + matplotlib/pandas import ← **CPU 폭발 지점**
  3. Binance/Yahoo OHLCV fetch
  4. 240×240 JPEG 렌더링 → LAN 디스플레이로 multipart POST
- `cronjob.yaml:47-48` — **CPU limit이 의도적으로 없음** (`no CPU limit -> no CFS throttle`).
  스파이크가 코어를 풀로 점유 가능 → 팬 즉시 램프업.
- 파일 주석이 이미 이 리스크를 명시: `🔴 Reconciliation 2 — every-minute churn: a fresh
  pod spins each cycle on a heavy matplotlib/pandas image.`
- **예상 팬 패턴: ~60초 주기의 톱니파** (매분 올랐다 내렸다).
- 왜 dataLocality 무효였나: 이 워크로드는 PVC 없는 **stateless·CPU 바운드** 배치.
  디스크를 거의 안 건드린다.

### H2 — Navidrome 15분 라이브러리 스캔 (디스크 read 스파이크) — ❌ **기각 (2026-06-22 검증)**

- 파일: [workloads/navidrome/configmap.yaml](../workloads/navidrome/configmap.yaml)
- 가설: `ND_AUTOIMPORTSCANINTERVAL: "900"` — 15분마다 음악 폴더 전체 스캔.
- **실측 반증:** navidrome **v0.62.0** Insights 실효 config 덤프 = `scannerEnabled:true`,
  **`scanWatcherWait:5`(inotify 와처 기반)**, interval/schedule 값 **부재**. 즉 이 버전은 주기 폴링이
  아니라 **파일 변경 시에만** 스캔. 라이브러리 정적(306 트랙)이라 변경 이벤트 0.
  파드 2d18h 무재시작·스캔 로그 0건·CPU 1m. → `ND_AUTOIMPORTSCANINTERVAL`는 **이 버전에서
  주기 스캔을 안 일으키는 죽은 키** = 가설 자체가 성립 안 함. **configmap에서 제거함.**
- S2(스캔 간격 상향)는 죽은 키를 고치는 헛수고 → **드롭.**

### H3 — `ops-alerts` CronJob 15분 주기 — ⚠️ **저듀티, 비주범 (2026-06-22 검증)**

- 파일: [infra/ops-alerts/cronjob.yaml:9](../infra/ops-alerts/cronjob.yaml#L9)
- `schedule: "*/15 * * * *"`. 실측: Job 1회 ~17초, duty cycle ~1.9% (15분 중 17초).
- "계속 도는" 연속 팬과 패턴 불일치. 단독 영향 미미 → **변경 보류** (필요시 17초 소요 원인 별도 점검).

### H4 — Longhorn BackupTarget 폴링 — ❌ **비주범 (2026-06-22 검증)**

- 파일: [infra/longhorn-backup/backuptarget.yaml:17](../infra/longhorn-backup/backuptarget.yaml#L17)
- 실측 `pollInterval: 5m0s`(기본·경량). doc 예측대로 단독 영향 낮음 → **변경 없음.**

### 비유력 — 6h~12h 주기 백업 CronJob들

- karakeep/anytype/ntfy/miniflux/navidrome/komga/vaultwarden/n8n 백업, longhorn RecurringJob(12h).
- 주기가 길어 "계속 도는" 체감과는 안 맞음. 다만 :30~:50 슬롯에 몰려 있어 6시간마다
  한 번씩은 동시다발 부하가 날 수 있음(별개 이슈).

### H5 (최유력·스파이크) — `longhorn-system` 주기 CPU (체크섬/백업/재빌드)

- 근거: 대시보드 2차에서 **20.70% → 66.83%로 3배 점프**, 동시에 Disk Write 0.24 MiBy/s로 **정지**.
  CPU↑·디스크≈0 조합 = **블록 해싱/체크섬** 시그니처.
- 어느 작업인지 미확정. 후보(확인 명령은 검증 절):
  1. **snapshot-data-integrity 체크섬** ← 1순위. 스냅샷 블록 해시 주기 검증, 디스크 I/O 거의 없음.
  2. **RecurringJob 백업 압축** — 12h 백업([recurringjob.yaml:26](../infra/longhorn-backup/recurringjob.yaml#L26)) 시 압축 CPU.
  3. **replica rebuild** — ❌ **종료 확정 (2026-06-23).** `replicas.longhorn.io` rebuild 0건, attached
     볼륨 전부 healthy. `ae83cff` 재배치는 이미 끝남 → S5에서 드롭.
- **실측 (2026-06-23):** `snapshot-data-integrity = fast-check` (v1/v2 둘 다 ON) → **후보1(체크섬) 유효·1순위 확정.**
  단 측정 시점이 저점 phase라(instance-manager 39~51m 안정) 66% 스파이크는 못 잡음 — 주기적이라 측정창 밖.

### H6 (상시 바닥) — `netdata` 상시 CPU — ✅ **확정 (2026-06-23 실측), 단 주범·처방 정정**

- 확정: 팬 연속 성분의 주범 맞음. **단 parent가 아니라 children DaemonSet.**
  - `kubectl top -n netdata`: children ×3 = **74m+70m+54m ≈ 198m**, parent 49m. 노드마다 도는 DaemonSet이 4배.
- **추정 원인이 틀렸음 (child 내부 `ps` 실측):**
  - **ML** — `[ml] enabled = no` **이미 적용됨** (child/parent 둘 다). S4 1순위 레버는 이미 done.
  - **ebpf** — `ebpf.plugin` **프로세스 자체가 안 돎** (이 이미지에 없음/비활성). `[plugins] ebpf=no`는 **no-op**.
  - 실제 주범 = **`apps.plugin`** (매초 `/proc` 전 프로세스 순회) + main 수집. → **유일한 실효 레버는 `update every = 5`**.

---

## 검증 (Verification)

먼저 **팬 주기를 측정**해서 가설을 좁힌다:
- ~60초 주기  → **H1 (trade-monitor) 확정**
- ~15분 주기  → **H2/H3 (navidrome / ops-alerts)**
- ~5분 주기   → H4

### 명령어

```bash
# 1) CPU 상위 소비자 — 스파이크 순간에 실행
kubectl top pods -A --sort-by=cpu | head -20
kubectl top nodes

# 2) trade-monitor가 정말 매분 새 pod을 띄우는지 (H1)
kubectl get pods -n trade-monitor --watch
#   → 60초마다 Pending→Running→Completed 사이클이면 H1.

# 3) trade-monitor 한 사이클의 실제 CPU/소요시간
kubectl get jobs -n trade-monitor --sort-by=.metadata.creationTimestamp | tail -5
kubectl logs -n trade-monitor <job-pod> --timestamps   # import~렌더 구간 길이 확인

# 4) navidrome 스캔 타이밍 (H2)
kubectl logs -n navidrome deploy/navidrome | grep -i scan
#   → 15분 간격 scan 로그 ↔ 팬 램프 시각 대조

# 5) 노드에서 직접(가능하면) — 어떤 프로세스가 코어를 먹는지
#   ssh <node> 후:  pidstat 1 / top -b -n1 / turbostat

# 6) H5 — longhorn 스파이크가 어느 작업인지 (스파이크 순간에)
kubectl top pods -n longhorn-system --sort-by=cpu | head     # engine/replica/manager 중 누구
kubectl -n longhorn-system get settings.longhorn.io snapshot-data-integrity -o yaml  # fast-check/enabled면 체크섬 범인
kubectl -n longhorn-system get replicas.longhorn.io | grep -i rebuild               # ae83cff 재빌드 진행중?
kubectl -n longhorn-system get engines.longhorn.io -o wide

# 7) H6 — netdata 설정 형태와 무거운 collector 확인
kubectl -n netdata get cm -o name
#   netdata.conf에서 [ml] enabled / [plugins] ebpf / [global] update every 확인
```

### 판정 기준

| 측정된 팬 주기 | 결론 | 다음 액션 |
|---|---|---|
| ~60초 | H1 확정 | 아래 S1 적용 |
| ~15분 | H2/H3 | S2 적용, 필요시 ops-alerts 경량화 |
| ~5분 | H4 | pollInterval 상향 검토 |
| 불규칙·6h마다 | 백업 클러스터링 | 백업 스케줄 분산(별도 이슈) |

---

## 해결 방안 (Remediation)

### S1 — trade-monitor: 매분 CronJob → 따뜻한 Deployment + 내부 sleep 루프  *(H1 대응)*

cronjob.yaml 주석에 이미 적힌 공식 fallback. 핵심 효과: **매분 반복되는 인터프리터/라이브러리
import 콜드스타트 비용을 제거** → CPU 스파이크의 톱니파가 사라짐.

- CronJob → `Deployment` (replicas: 1)로 전환.
- 컨테이너가 내부에서 `while true; do <한 사이클>; sleep 60; done` (이미지가 1회용 진입점이면
  엔트리포인트/커맨드 조정 필요 — trade.monitor 레포 측 변경 동반 가능).
- import는 프로세스 기동 시 **단 1회** → 이후엔 메모리에 상주, 매분은 fetch+렌더만.
- 트레이드오프: 상시 RSS 점유(현재 limit 512Mi 유지 가능), 단일 프로세스라
  `concurrencyPolicy: Forbid`로 막던 중첩 보호는 `sleep`이 대체.
- 적용 시 cronjob.yaml 주석대로 **deviation 기록**.

차선책(코드 변경 없이 완화만):
- 주기를 `*/2` 또는 `*/5`로 낮춰 스파이크 빈도↓ (디스플레이 갱신 주기 허용 범위 확인 필요).
- CPU limit을 **추가**하면 CFS throttle로 스파이크 피크는 깎이나 런타임이 늘어
  `activeDeadlineSeconds: 55`를 넘길 수 있음 — 권장 안 함.

### S2 — navidrome 스캔 간격 완화  *(H2 대응 — 제안, 미적용)*

- `ND_AUTOIMPORTSCANINTERVAL`를 `900`(15분) → **`43200`(12시간)** 으로 상향 (초 단위). [configmap.yaml:14](../workloads/navidrome/configmap.yaml#L14)
- 트레이드오프: 새 트랙이 최대 12시간 뒤에 인식됨. 라이브러리 변경 빈도가 낮으면 수용 가능.
- 즉시 인식이 필요하면 navidrome UI/`navidrome scan` 수동 트리거 가능.
- 적용 시 주의: `envFrom: configMapRef`는 Pod 시작 시 1회 주입 → 머지 후 deployment rollout(재시작) 필요.
- (선택) watcher 기반 자동 스캔으로 전환하면 폴링 자체를 제거 가능.

### S4 — netdata 튜닝  *(H6 대응 — ✅ 2026-06-23 적용)*

children DaemonSet ~198m 회수가 목표. **실측 결과 실효 레버는 하나뿐:**

| 설정 (netdata-child.conf) | 상태 | 효과 | 잃는 것 |
|---|---|---|---|
| `[ml] enabled = no` | **이미 적용돼 있었음** | — | (자동 이상탐지, 이미 포기) |
| `[plugins] ebpf = no` | **불필요 (no-op)** | ebpf.plugin 안 돎 | 없음 |
| `[global] update every = 5` (기본 1) | **✅ child.conf에 적용** | apps.plugin 수집 CPU ≈1/5 | 1초→5초 해상도(홈랩 OK) |

- 적용: `workloads/netdata/netdata-child.conf`에 `[global] update every = 5` 추가.
- parent는 미적용(49m로 가벼움 + 대시보드 자체 해상도 1초 유지). 더 깎고 싶으면 parent에도 동일 적용 가능.
- **실측 효과 (재시작 후):** children 합 **198m → 53m (−73%)**, parent 49m→26m(스트림 수신↓ 부수효과),
  메모리 ~190Mi→~96Mi. netdata 전체 **247m → 79m.** 팬 연속 성분 거의 소멸.
- ⚠️ **rollout 함정 (해소함):** `netdata-config`가 `disableNameSuffixHash:true`였어서 ArgoCD가
  ConfigMap 내용만 갱신하고 파드 재시작을 안 함(subPath는 live-reload 안 됨 + netdata는 부팅 시 1회만
  conf 읽음) → "Synced인데 미발효". 최초 적용은 수동 `rollout restart`로 발효시켰고, 재발 방지로
  **해시를 다시 켜서**(kustomization에서 `disableNameSuffixHash` 제거) 앞으론 conf 변경 시 자동 rollout.

### S5 — longhorn 튜닝  *(H5 대응 — 작업 확정 후, 트레이드오프 있음)*

스파이크 완화는 가능하나 **데이터 보호 기능을 깎는 트레이드오프**. 검증(#6)으로 작업 확정이 선결.

| 확정된 원인 | 튜닝 | 잃는 것 |
|---|---|---|
| data-integrity 체크섬 | `snapshot-data-integrity: disabled` 또는 주기 ↓ | 무음 손상(bit-rot) 감지 |
| 백업 압축 | 압축 `gzip → lz4` 또는 off | 오프사이트 저장/대역폭 ↑ |
| ~~dataLocality 재빌드~~ | ~~튜닝 불필요~~ | **드롭 — 2026-06-23 종료 확정(rebuild 0건)** |
| 백업 빈도 | 12h → 24h | RPO 늘어남 |

- dataLocality 재빌드설은 실측으로 종료 확정 → 더 볼 것 없음. 남은 스파이크원은 fast-check 체크섬.

### S3 — 노드 레벨 팬 곡선 (근본이 아닌 완화책)

- 워크로드 부하가 정상 범위인데 팬이 과민하면 BMC/IPMI 또는 노드 OS의 **팬 커브가
  너무 공격적**일 수 있음. fan curve를 완만하게(낮은 온도 임계에서 저 RPM) 조정.
- 단, 이건 GitOps 레포 밖(하드웨어/BIOS) 영역이라 git 히스토리에 안 남음.
- **원인(S1/S2)을 먼저 잡고**, 그래도 과민하면 마지막에 적용.

---

## 결정 로그

- 2026-06-22: 증상 접수, H1~H4 도출. **검증 우선** — 팬 주기 측정 전엔 코드 변경 보류.
- 2026-06-22: 1차 검증. H1을 trade-monitor로 확정했으나 **(아래 정정됨)**. H2 기각(navidrome 와처 기반,
  죽은 키 제거), H3 저듀티/H4 비주범, 6h 백업 클러스터링은 별개 이슈로 분리.
- 2026-06-23: **Netdata 대시보드 실측으로 H1 정정 → 무죄.** 실제 Top CPU는
  **longhorn-system(20→66% 스파이크) + netdata(상시 ~25%)**, 둘 다 디스크 I/O 없는 CPU 부하.
  - **H5 신설**(longhorn 주기 CPU, 최유력 스파이크) — 체크섬/백업압축/재빌드 중 미확정. 검증 #6 대기.
  - **H6 신설**(netdata 상시 ~25%) → **S4 튜닝이 ROI 최고**(ml/ebpf off + update every 5), 손해 거의 0.
  - 교훈: 가설을 `kubectl top`/대시보드 실측 랭킹으로 먼저 검증할 것(H1 60초 톱니파에 꽂혀 오판).
- 2026-06-23(2차 실측): **H5/H6 확정 + 처방 정정.**
  - H6: 주범 = **netdata-children DaemonSet ~198m**(parent 아님). `ml`은 **이미 off**, `ebpf.plugin`은 **안 돎(no-op)**.
    유일 실효 레버 `update every = 5`를 `netdata-child.conf`에 **적용** → ArgoCD sync 대기.
  - H5: `snapshot-data-integrity=fast-check` ON → 체크섬이 스파이크원 1순위 확정. **재빌드설은 rebuild 0건으로 종료/드롭.**
  - 교훈(추가): 문서 가설의 "원인 추정"(ebpf 등)도 `ps`/`top` 실측으로 검증할 것 — ebpf off는 헛수고였을 뻔.
- 2026-06-23(적용 완료): child.conf `update every=5` 발효(수동 rollout), **children 198m→53m 확인**.
  `disableNameSuffixHash` 제거로 향후 conf 변경 자동 rollout화 — netdata 설정 변경의 고질적 미발효 함정 해소.
- **남은 액션:** H5 longhorn — 스파이크 순간 `kubectl top -n longhorn-system`으로 instance-manager 점프
  재확인(netdata 대시보드 history가 적격) → 필요시 S5(fast-check 체크섬 주기↓). 그 외 잔여 이슈는 아래.
- 잔여 별개 이슈: 6h 백업 분산, S3 팬커브, AWTRIX 10.0.0.201 No-route-to-host.
