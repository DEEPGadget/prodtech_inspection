# prodtech_inspection

Manycoresoft / DEEPGadget **SW 검수** 스크립트 모음.

검수 대상 장비의 서버 설정을 적용하고(`setup.sh`), 하드웨어를 점검하고(`inspect.sh`),
번인을 돌려 검수확인서에 붙일 온도 CSV를 뽑는다(`run-burnin.sh`).

```
prodtech_inspection/
├── setup.sh          # 서버 설정 + 도구 설치     ← 값을 바꾸는 건 여기뿐
├── inspect.sh        # 검수 (읽기 전용)          ← 확인만, 아무것도 안 바꿈
├── run-burnin.sh     # GPU/CPU 동시 번인 + 온도 로깅 → CSV
└── lib/
    ├── gpu-cpu.sh    # 온도 로깅
    └── make-csv.sh   # 온도 로그 → CSV
```

구 `Check_server_information` 과 `setup_tools.sh` 를 대체한다. 이 저장소 하나면 된다.

**역할 분담**

| | setup.sh | inspect.sh |
|---|---|---|
| 서버 설정 | **적용한다** | 걸려 있는지 **확인만** |
| 도구 설치·빌드 | 한다 | 안 한다 |
| 실행 횟수 | 장비당 1회 (설정 바뀔 때 재실행) | 몇 번이든 |

`inspect.sh` 에서 ❌ 가 나오면 대부분 `./setup.sh` 를 (다시) 돌리면 된다.

## 빠른 시작

```bash
git clone https://github.com/DEEPGadget/prodtech_inspection.git
cd prodtech_inspection

./setup.sh          # 1회. 서버 설정 + 도구 설치 (make 로그가 길다)
./inspect.sh        # 검수 — 읽기 전용
./run-burnin.sh     # 1시간 번인 → CSV
```

세 스크립트 모두 **일반 계정으로** 실행한다. 필요할 때만 내부에서 `sudo` 를 쓴다.
결과 파일은 전부 **실행한 디렉터리**에 생긴다.

---

## setup.sh

**설정을 바꾸는 것은 이 스크립트뿐이다.**

```bash
./setup.sh                    # 설정 + 검수/번인 기본 도구
./setup.sh --full             # + 벤치마크 도구 (nccl-tests / gpu-burn / fio)
./setup.sh --full /opt/bench  # 외부 저장소를 다른 경로에 설치
```

**PART A — 서버 설정**

| 항목 | 하는 일 |
|---|---|
| 자동 업데이트 차단 | `apt-daily.timer` `apt-daily-upgrade.timer` `unattended-upgrades.service` → stop + disable + mask |
| 전원관리 | sleep/suspend/hibernate mask + performance 프로파일 |
| Time Zone | `Asia/Seoul` (`TZ_WANT` 로 변경 가능) |
| NVIDIA Persistence Mode | `nvidia-pm.service` 생성 → `enable --now` (재부팅 후 유지) |
| OS ACS Disable | `/usr/local/sbin/disable_acs.sh` + `disable-acs.service` → `enable --now` |
| /etc/default/grub | `iommu=pt` `pcie_aspm=off` **점검·안내만** (자동 편집 안 함) |

> **자동 업데이트 차단이 맨 앞에 있는 이유**: `apt-daily.timer` 가 깨어나
> `/var/lib/dpkg/lock` 을 잡으면 아래 패키지 설치가 `Could not get lock` 으로 막힌다.

**PART B — 도구 설치**

| | 기본 | `--full` |
|---|---|---|
| apt 패키지 | ✓ `stress` `lm-sensors` `nvme-cli` `ipmitool` `pciutils` `usbutils` `dmidecode` `ifupdown-extra` `infiniband-diags` `build-essential` `git` | ✓ |
| gadget-burn | ✓ clone + make (번인 필수, CUDA 필요) | ✓ |
| deepgadget-log-grabber | ✓ clone (장애 로그 수집, 빌드 없음) | ✓ |
| nccl-tests | — | ✓ clone + make (NCCL 필요) |
| gpu-burn | — | ✓ clone + make |
| fio | — | ✓ clone + build + install |

결과: `setup_<host>_<시각>/setup.log` — make 출력이 길어도 맨 끝 요약에 항목별 성공/실패가 모인다.

---

## inspect.sh

하드웨어 점검과 서버 설정을 한 번에 한다. 빌드는 포함하지 않는다.

```bash
./inspect.sh                 # PCIe 측정 시 GPU 부하를 걸어 링크를 최대 속도로 올림
./inspect.sh --no-load       # 부하 없이
./inspect.sh --load-sec 120  # 부하 시간 (기본 60초)
```

아무것도 바꾸지 않는다. 하드웨어를 조사하고, `setup.sh` 가 적용해 둔 설정이
실제로 걸려 있는지 확인해 합격/불합격만 보고한다.
(`--check` 는 예전 옵션 — 받아만 주고 무시한다.)

결과는 실행한 디렉터리 아래 한 폴더에 모인다.

```
inspect_<host>_<시각>/
├── inspect.log     전체 출력
├── serials.csv     구성품 S/N 목록  ← 검수확인서에 그대로 붙일 수 있다
└── raw/            lspci -vvv, dmidecode, nvidia-smi -q, ipmitool sdr/sensor/fru,
                    lsblk -O, sensors, ip -d addr, lsusb -t, nvme list, dmesg 발췌
```

부하에 쓰는 것은 **`gadget-burn`** 이다(`setup.sh` 가 `./gadget-burn/` 에 빌드해 둔 것).
구 `test.sh` 가 쓰던 `gpu-burn` 이 아니다.

### PCIe 측정 전에 GPU 부하를 거는 이유

NVIDIA GPU 는 유휴일 때 링크를 Gen1 으로 내린다. 그 상태로 읽으면 멀쩡한 카드가
`Speed 2.5GT/s (downgraded)` 로 보인다.

```
유휴      LnkSta: Speed 2.5GT/s (downgraded), Width x16
부하 +3s  LnkSta: Speed 32GT/s, Width x16          ← LnkCap 과 일치
```

그래서 PCIe 항목에 들어가기 직전 `gadget_burn` 을 백그라운드로 띄우고, 링크가
재협상될 시간을 준 뒤 읽고, 측정이 끝나면 바로 끝낸다. 부하를 걸었을 때만
속도까지 합격 판정하고, 못 걸었으면 "속도 판정 불가" 로 남긴다.

### 구성품 S/N

| 분류 | 출처 | 비고 |
|---|---|---|
| Mainboard | `dmidecode` baseboard-serial-number | BIOS 버전 함께 기록 |
| CPU | `dmidecode -t processor` Serial Number | 대부분 `Unknown` → CPUID 로 대체 |
| DIMM | `dmidecode -t memory` Serial Number | Bank Locator(슬롯)별 |
| Storage | `lsblk SERIAL` | SATA/NVMe 공통 |
| GPU | `nvidia-smi --query-gpu=serial`, 없으면 GPU UUID | GeForce(3090/4090/5090 등)는 보드 S/N 이 없어 `N/A` → UUID 로 대체. VBIOS·BDF 함께 기록 |
| NIC | PCIe Device Serial Number, 없으면 고정 MAC(`ethtool -P`) | DSN 은 카드 단위라 듀얼포트면 두 포트가 같은 값 |
| IB/HCA | `/sys/class/infiniband/*/node_guid` | board_id·fw 함께 기록 |
| RAID | storcli/perccli `show all`, 없으면 PCIe DSN | 관리도구 없으면 불합격 처리 |

USB 이더넷(BMC 가상 NIC, gadget 등)은 장착 부품이 아니므로 S/N 목록에서 제외한다.

**PART 1 — 하드웨어 점검 (읽기 전용)**

| 항목 | 확인 내용 |
|---|---|
| 시스템 / 메인보드 | 제조사 / 모델 / 보드 S/N / BIOS 버전 |
| CPU 정보 | 모델 / 소켓 / 코어 / 스레드 / 최대 클럭 / S/N |
| Memory 정보 | 총 용량 + DIMM 슬롯별 용량·속도·Part Number·S/N |
| Storage 정보 | 디스크 목록·S/N + NVMe 온도·`critical_warning` |
| GPU 정보 | 드라이버 / CUDA / 모델 / VBIOS / S/N / ECC |
| PCIe 연결 상태 | **GPU 부하 인가 후** `LnkSta` vs `LnkCap` 속도·폭 비교 + dmesg PCIe 에러 |
| Infiniband | 장치 인식 + `ibstat` 포트 State |
| RAID Card | 컨트롤러 인식 + storcli/perccli 어레이 상태 |
| 기타 추가 부품 | GPU·NIC·RAID·IB 로 분류되지 않은 PCIe 장치 |
| Network 상태 | 인터페이스 up/down / speed / IPv4 / MAC / BDF / 드라이버 |
| USB 포트 상태 | Bus 별 장치 수 |
| PSU 상태 | PSU 인식 수 / Power In·Out / 온도 / Fan RPM |
| 구성품 S/N | 위 항목에서 모은 S/N 을 표 + `serials.csv` 로 |

**PART 2 — 서버 설정 확인 (읽기 전용)**

`setup.sh` 가 적용한 것이 걸려 있는지만 본다. ❌ 가 나오면 `./setup.sh` 를 다시 돌린다.

| 항목 | 확인 내용 |
|---|---|
| Time Zone | `Asia/Seoul` 인지 + NTP 동기화 |
| 전원관리 | sleep/suspend/hibernate 가 masked 인지 + 프로파일이 performance 인지 |
| 자동 업데이트 중지 | 타이머 3종이 masked 인지 |
| NVIDIA Persistence Mode | Enabled 인지 + `nvidia-pm.service` 가 enabled 인지 |
| OS ACS Disable | `ACSCtl SrcValid+` 가 0개인지 + `disable-acs.service` 가 enabled 인지 |
| /etc/default/grub | `iommu=pt` `pcie_aspm=off` 가 현재 부팅에 반영됐는지 |

마지막에 정상 / 확인 필요 / 건너뜀 으로 요약이 나오고,
확인 필요 항목이 하나라도 있으면 exit code 1 로 끝난다.

> BIOS 설정과 Gadgetini 그래프 확인은 범위 밖이다.
> GRUB 항목에서 BIOS 에서 확인할 값(VT-d / ACS Control)을 안내만 한다.

---

## run-burnin.sh

GPU 번인, CPU 번인, 온도 로깅 **3개를 동시에** 돌리고 CSV까지 만든다.

```bash
./run-burnin.sh          # 3600초 / 5초 샘플 (기본값)
./run-burnin.sh 1800 5   # 30분
```

- `gadget_burn -t <초>` — GPU 번인
- `stress -c $(nproc) -t <초>` — CPU 번인
- `lib/gpu-cpu.sh <간격> <초>` — 온도 로깅
- 끝나면 `lib/make-csv.sh` 로 CSV 생성

화면은 2초마다 **제자리에서 갱신**된다. 최고온도가 바뀔 때마다 줄이 쌓이지
않으므로 GPU 가 10장이어도 화면이 흐르지 않는다.

```
 DEEPGadget SW 검수 번인 · deepgadget   경과 00:12:35 / 01:00:00   남은시간 00:47:25
 █████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ 21%
────────────────────────────────────────────────────────────────────────────────
 GPU   TEMP   MAX  SLOWDN        POWER W   CLK MHz   UTIL  THROTTLE
   0     90    90       5  598.00/600.00      2175    97%  HWTHERM HWSLOW PWRCAP   [T 8s / P 20s]
   1     73    90      22  598.00/600.00      2175    99%  PWRCAP                  [T 6s / P 22s]
 CPU   85.4°C (max 86.1°C)   소켓별 [ 85.4 83.2 ]   128 threads @ stress
 NVMe  43°C (max 43°C)   로그 샘플 151개 · 5s 간격 · Ctrl-C 중단
────────────────────────────────────────────────────────────────────────────────
```

- `SLOWDN` — 하드웨어 슬로우다운까지 남은 여유(°C, `temperature.gpu.tlimit`)
- `THROTTLE` — `SWTHERM` / `HWTHERM` / `BRAKE` / `HWSLOW` / `PWRCAP`,
  뒤의 `[T ..s / P ..s]` 는 **GPU 별** 열·전력 쓰로틀 누적 시간
- Ctrl-C 로 중단해도 그 시점까지의 CSV를 만들고 끝낸다

결과는 실행한 디렉터리 아래 `<host>_<시각>/` 에 모인다.

```
deepgadget_20260908_143000/
├── GPU_CPU_deepgadget_20260908_143000.csv   ← 검수확인서에 붙일 파일
├── GPU_CPU_log.txt        원본 로그
├── output.csv             make-csv.sh 기본 산출물
├── gadget_burn.csv/.log   TFLOPS·전력·쓰로틀 상세
├── stress.log / gpu-cpu.log / make-csv.log
├── max-events.log         최고온도 갱신 이력
└── system_info.txt        lscpu / nvidia-smi / nvme list 스냅샷
```

### 알아둘 것

- **`make-csv.sh` 는 root 로 실행하면 안 된다.** root 에서 `lscpu` 가
  `BIOS Vendor ID:` 줄을 하나 더 출력해 벤더 판별이 깨지고, **에러 없이 조용히**
  CPU 온도 칼럼이 전부 빈다. `run-burnin.sh` 는 일반 계정으로 실행하도록 처리해 둔다.
- `gpu-cpu.sh` 는 매 샘플마다 `sudo nvme smart-log` 를 부른다. tty 없이 미리
  `sudo -v` 해둬도 ppid 티켓 때문에 안 먹히므로, `run-burnin.sh` 는 스크립트
  전체를 root 로 한 번 승격시켜 돌린다.
- NVMe 온도는 `/dev/nvme0` 만 수집한다 (`gpu-cpu.sh` 의 기존 동작).

---

## 검수 순서

```bash
./setup.sh          # 1) 서버 설정 + 도구 설치 (장비당 1회)
                    #    GRUB 안내가 나오면 편집 + update-grub + reboot
./inspect.sh        # 2) 검수 → inspect_*.log
                    #    ❌ 가 있으면 조치 후 다시 ./inspect.sh
./run-burnin.sh     # 3) 1시간 번인 → CSV 를 검수확인서에 첨부
```
