# Deferred — 노드 팬 주기적 가동 원인 추적

상태: **해결 (H1 확정 → S1 차선책 적용)** · 작성일: 2026-06-22 · 관련 커밋: `ae83cff` (longhorn dataLocality best-effort)

> **2026-06-22 검증 완료 — H1 확정.** 라이브 클러스터 측정 결과:
> `trade-monitor` CronJob이 `schedule: "* * * * *"`로 **매 60초** 발화(ACTIVE=1, 연속 Job 확인).
> 한 사이클 로그 `cycle_start 09:37:02 → cycle_complete 09:37:14`, **`duration_ms=11894`(~12초)**,
> Job 총 소요 18초 → coldstart/import ~6초. 즉 **60초마다 ~18초의 풀코어급 스파이크 = 톱니파** (예측 적중).
> dataLocality 무효 이유 확인: 이 Pod는 PVC 없는 stateless라 디스크를 거의 안 건드림.
> (부수 발견: AWTRIX 10.0.0.201 push가 `No route to host` — 팬과 무관한 별개 이슈.)
>
> **S1 본안(warm Deployment)은 기각.** 현재 이미지 엔트리포인트는 1회 실행 후 종료 →
> 진짜 warm 루프는 trade.monitor 레포(업스트림) 변경이 필요하고, GitOps 레포 안의 shell `while/sleep`
> 래핑은 매 루프 재import라 무의미. 게다가 warm은 **coldstart ~6초만** 제거할 뿐 매 사이클 ~12초 렌더는 잔존 →
> 톱니파가 "사라진다"는 원문 주장은 과장.
>
> **적용: S1 본안 — CronJob → warm Deployment** ([deployment.yaml](../workloads/trade-monitor/deployment.yaml)).
> 추가 단서로 확정: 같은 워크로드가 옛 LXC `python-crontab` cron에선 조용, 매분 CronJob에선 시끄러움 →
> 범인은 matplotlib가 아니라 **매분 파드/sandbox churn**(containerd/runc/CNI 세팅+teardown, 노드 레벨 비용).
> 상주 파드 1개 + 내부 `while true; do timeout 55 python -m trade_monitor; sleep 180; done` 루프로
> LXC 모델 재현(상주 컨테이너, 매 사이클 python 재fork). 이미지 엔트리포인트가 싱글샷이라 루프는
> command 오버라이드에 둠 — **업스트림 이미지 변경 0**. churn 제거 + 3분 캐던스. server dry-run 통과.

---

## 증상

노드 팬이 **주기적으로 계속 가동**된다. `ae83cff` 에서 Longhorn `dataLocality: best-effort`
로 VM 간 디스크 I/O를 줄였지만 팬 패턴은 **변화 없음**.

이게 핵심 단서다: 디스크 I/O 튜닝이 팬에 영향을 못 줬다는 건 **병목이 디스크가 아니라
CPU(또는 디스크라 해도 dataLocality가 못 잡는 워크로드)** 라는 뜻.

---

## 추측 (Hypotheses) — 의심 순위

### H1 (최유력) — `trade-monitor` CronJob의 매분 콜드스타트 CPU 스파이크

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

### S3 — 노드 레벨 팬 곡선 (근본이 아닌 완화책)

- 워크로드 부하가 정상 범위인데 팬이 과민하면 BMC/IPMI 또는 노드 OS의 **팬 커브가
  너무 공격적**일 수 있음. fan curve를 완만하게(낮은 온도 임계에서 저 RPM) 조정.
- 단, 이건 GitOps 레포 밖(하드웨어/BIOS) 영역이라 git 히스토리에 안 남음.
- **원인(S1/S2)을 먼저 잡고**, 그래도 과민하면 마지막에 적용.

---

## 결정 로그

- 2026-06-22: 증상 접수, H1~H4 도출. **검증 우선** — 팬 주기 측정 전엔 코드 변경 보류.
- 2026-06-22: 라이브 클러스터 검증 완료.
  - **H1 확정**(매 60초, ~18초/사이클 CPU 스파이크) → S1 차선책 적용: trade-monitor `* * * * *`→`*/3`.
  - **H2 기각**(navidrome v0.62.0 와처 기반, `ND_AUTOIMPORTSCANINTERVAL` 죽은 키) → 키 제거, S2 드롭.
  - **H3 저듀티**(ops-alerts 17s/15min) / **H4 비주범**(longhorn poll 5m) → 변경 없음.
  - **6h 백업 클러스터링**(:20~:50 슬롯 10개) 확인 — 연속 팬과 무관, **별개 이슈로 분리**.
  - **S3(팬 커브)**: H1 수정 후 `*/3`으로도 과민할 때만, 그것도 GitOps 밖(BIOS/IPMI) → 조건부 보류.
- **이슈 종결.** 잔여는 별개 이슈(6h 백업 분산, S3 팬커브, AWTRIX 10.0.0.201 No-route-to-host).
