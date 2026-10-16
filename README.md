# prodtech_inspection

Manycoresoft / DEEPGadget **SW 검수** 스크립트 모음.

검수 대상 장비의 서버 설정을 적용하고(`setup.sh`), 하드웨어를 점검하고(`inspect.sh`),
번인을 돌려 검수확인서에 붙일 온도 CSV를 뽑는다(`run-burnin.sh`).

```
prodtech_inspection/
├── setup.sh              # 서버 설정 + 도구 설치     ← 값을 바꾸는 건 여기뿐
├── inspect.sh            # 검수 (읽기 전용)          ← 확인만, 아무것도 안 바꿈
├── functest.sh           # 기능 테스트 (GPU ECC/topo/NVLink + HW 정보 + GPU 5분 번인)
├── run-burnin.sh         # 1시간 번인 + 온도 CSV
└── lib/
    ├── sample-sensors.sh    # GPU/CPU/NVMe 온도를 CSV 로 직접 기록
    └── find-gadget-burn.sh  # gadget_burn 탐색 (세 스크립트가 같이 씀)
```

구 `Check_server_information` 과 `setup_tools.sh` 를 대체한다. 이 저장소 하나면 된다.

**역할 분담**

| | setup.sh | inspect.sh | functest.sh | run-burnin.sh |
|---|---|---|---|---|
| 서버 설정 | **적용** | 확인만 | 안 함 | 안 함 |
| 도구 설치·빌드 | 함 | 안 함 | 안 함 | 안 함 |
| HW 점검 | — | ✓ | ✓ (HW 부분만) | — |
| 번인 | — | — | GPU+CPU 5분 | GPU+CPU 1시간 |
| 메모리 부하 | — | — | `--mem` | — |

`inspect.sh` 에서 ❌ 가 나오면 대부분 `./setup.sh` 를 (다시) 돌리면 된다.

## 전제 조건

| | 필요한 것 |
|---|---|
| OS | Ubuntu/Debian 계열 (`apt-get`, `systemd` 를 쓴다) |
| 권한 | `sudo` 가 되는 **일반 계정** (root 로 직접 실행하면 거부한다) |
| 네트워크 | `setup.sh` 가 apt + GitHub 에서 받아온다 (오프라인이면 PART B 가 실패) |
| GPU | NVIDIA 드라이버(`nvidia-smi`) + CUDA 툴킷 — `gadget-burn` 빌드에 필요 |

CUDA 가 없으면 `setup.sh` 는 `gadget-burn` 을 clone 까지만 하고 ⚠️ 로 남긴다.
드라이버·툴킷을 깐 뒤 `./setup.sh` 를 다시 돌리면 그때 빌드된다.

## 빠른 시작

```bash
git clone https://github.com/DEEPGadget/prodtech_inspection.git
cd prodtech_inspection

./setup.sh          # 1회. 서버 설정 + 도구 설치 (make 로그가 길다)
./functest.sh       # 기능 테스트 — GPU 상태 + HW 정보 + GPU 5분 번인
./inspect.sh        # 검수 — 읽기 전용
./run-burnin.sh     # 1시간 번인 → CSV
```

전부 **일반 계정으로** 실행한다. `setup.sh` 와 `inspect.sh` 는 root 로 실행하면 아예
거부하고, 필요할 때만 내부에서 `sudo` 를 쓴다. 예외는 `run-burnin.sh` 하나로,
NVMe 온도(`nvme smart-log`)를 읽어야 해서 **스스로 `sudo` 로 재실행**한다
(→ [알아둘 것](#알아둘-것)).

결과 파일은 전부 **실행한 디렉터리**에 생긴다. 저장소를 더럽히지 않으려면
결과를 모을 폴더에서 스크립트를 절대경로로 부르면 된다.

```bash
mkdir -p ~/검수/DG-2026-001 && cd ~/검수/DG-2026-001
~/prodtech_inspection/inspect.sh
```

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
| 자동 업데이트 차단 | ① `apt-daily.timer` `apt-daily-upgrade.timer` `unattended-upgrades.service` → stop + disable + mask<br>② `/etc/apt/apt.conf.d/99-disable-auto-upgrades` 에 `APT::Periodic::*` 를 `0` 으로 고정<br>③ `snap refresh --hold` (snapd 가 있을 때) |
| 전원관리 | sleep/suspend/hibernate mask + performance 프로파일 |
| Time Zone | `Asia/Seoul` (`TZ_WANT` 로 변경 가능) |
| NVIDIA Persistence Mode | `nvidia-pm.service` 생성 → `enable --now` (재부팅 후 유지) |
| OS ACS Disable | `/usr/local/sbin/disable_acs.sh` + `disable-acs.service` → `enable --now` |
| /etc/default/grub | `iommu=pt` `pcie_aspm=off` **점검·안내만** (자동 편집 안 함) |

> **자동 업데이트 차단이 맨 앞에 있는 이유**: `apt-daily.timer` 가 깨어나
> `/var/lib/dpkg/lock` 을 잡으면 아래 패키지 설치가 `Could not get lock` 으로 막힌다.

> **왜 세 겹인가**: mask 는 타이머가 깨어나는 것을 막고, `APT::Periodic::Enable "0"` 은
> 어떤 경로로든 `/usr/lib/apt/apt.systemd.daily` 가 실행됐을 때 맨 앞에서 즉시 exit 시킨다.
> snap 은 `snapd` 자체 타이머(기본 하루 4회)로 돌아 APT 설정과 완전히 무관하므로 따로 막는다.
>
> 설정 파일을 `99-` 로 두는 이유는 apt 가 `apt.conf.d` 를 파일명 오름차순으로 읽어 뒤쪽이
> 이기기 때문이다. 배포판이 관리하는 `20auto-upgrades` / `10periodic` 을 고치면 패키지
> 업데이트 때 되돌아갈 수 있다.
>
> **키 이름 주의**: 실제 키는 `APT::Periodic::` 이다. 사내 문서에 돌던 `APTPeriodic::` 처럼
> 쓰면 apt 가 조용히 무시해서 파일은 멀쩡한데 자동 업데이트는 계속 돈다. 그래서 setup.sh 도
> inspect.sh 도 파일 내용이 아니라 `apt-config dump` 출력으로 판정한다.

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

## functest.sh

출하 전 **기능 확인**용. 검수(`inspect.sh`)보다 가볍게, HW 가 다 보이는지,
GPU 의 ECC/NVLink 가 깨끗한지, GPU 가 부하를 받는지만 짧게 본다.

```bash
./functest.sh              # GPU 상태 + HW 정보 + GPU 5분 번인
./functest.sh --mem        # + 메모리 부하 (전체 RAM 의 80%)
./functest.sh --mem 30%    # 부하량 지정 (% 또는 4G / 512M)
./functest.sh --time 600   # 번인 시간(초)
./functest.sh --interval 2 # 온도 샘플 간격(초, 기본 5)
./functest.sh --no-hw      # HW 정보 생략 (GPU 상태 + 번인)
./functest.sh --no-build   # make clean && make 생략 (있는 바이너리 그대로)
./functest.sh --burn-dir ~/x/gadget-burn   # gadget-burn 소스/빌드 디렉터리를 직접 지정
```

**1단계: gadget-burn 준비.** 소스 디렉터리를 `--burn-dir` → `<저장소>/gadget-burn` →
`~/gadget-burn` 순으로 찾고, **둘 다 없으면 `<저장소>/gadget-burn` 에 clone** 한다
(`setup.sh` 가 빌드하는 위치와 같다). 그 다음 번인 전에 **항상 `make clean && make`**
로 다시 빌드한다 — 드라이버나 CUDA 가 바뀐 서버에서 옛 바이너리로 도는 일을 막기 위해서다.
nvcc 는 `PATH` → `$CUDA_HOME/bin` → `/usr/local/cuda/bin` 에서 찾는다.

CUDA 쪽 문제는 **안내만 하고 고치지 않는다**(설치·변경 없음):

| 상황 | 동작 |
|---|---|
| nvcc 없음 | 빌드 건너뜀 + 드라이버가 지원하는 CUDA 버전 안내. 빌드본이 있으면 그걸로 진행 |
| nvcc 가 드라이버 지원 CUDA 보다 높음 | 경고 후 빌드 시도 (실행 시 `driver version is insufficient` 가능성 안내) |
| 빌드 실패 (`Unsupported gpu architecture`, `-lnvidia-ml`, cuBLAS 등) | 원인별 안내. `make clean` 전에 보관해 둔 **기존 바이너리를 되돌려** 진행 |
| 빌드본도 없음 | 번인 불가 → 종료(exit 1). HW 수집은 들어가지 않는다 |

빌드 로그는 `functest_<host>_<시각>/gadget-burn-build.log`, clone 로그는 `gadget-burn-clone.log`.
빌드된 `gadget_burn` 은 세 스크립트(`functest.sh` `inspect.sh` `run-burnin.sh`)가
`lib/find-gadget-burn.sh` 로 같은 순서(`BURN_DIR` → `<저장소>/gadget-burn` →
`<저장소>/../gadget-burn` → `~/gadget-burn` → `PATH`)로 찾는다.

1. **gadget-burn 준비** — 위 참고 (찾기 → 없으면 clone → make clean && make)
2. **GPU 상태 (ECC / topo / NVLink)** — 번인 전에 아래를 `gpu/` 에 저장하고 화면에 표로 찍는다.
   설정은 바꾸지 않는다.
   - **GPU 목록**: `nvidia-smi --query-gpu` 한 번으로 GPU 별 이름·S/N·UUID·BDF·VBIOS·온도·
     PCIe gen/폭(current/max)·ECC uncorrected aggregate 를 한 줄씩 (`gpu/gpu_list.csv`).
     PCIe gen current 는 idle 이면 낮게 나오므로 판정하지 않지만, 폭(width)은 idle 에도 유지되므로
     **current < max 면 확인 필요**(슬롯/라이저 의심). 부하 중 속도 판정은 HW 정보 단계가 한다.
   - **ECC**: GPU 별 ECC 모드, corrected/uncorrected (volatile·aggregate), row remapping
     (Ampere 이후; 없으면 retired pages). **uncorrected > 0 이거나 remap uncorrectable /
     pending / failure > 0 이면 확인 필요**. ECC 미지원·Disabled(`[N/A]`) 카드는 표시만 한다.
     번인이 끝나면 한 번 더 읽어 **번인 전후 늘어난 카운터**를 GPU 별로 보여준다.
   - **topo**: `nvidia-smi topo -m` 매트릭스를 그대로 출력하고(범례는 `gpu/topo.txt`)
     NVLink(`NV#`)로 묶인 GPU 쌍 수를 요약한다.
   - **NVLink**: `nvidia-smi nvlink -s` 로 GPU 별 active/inactive 링크 수, `nvlink -e` 로
     에러 카운터(Replay/Recovery/CRC)를 본다. Link 줄이 하나도 없으면(5090 처럼 NVLink 가
     없거나 브리지 미장착) 건너뛴다. **한 GPU 에 active/inactive 가 섞이거나, GPU 마다 active
     수가 다르거나, 에러 카운터가 0 이 아니면 확인 필요** (브리지 장착/접촉 의심).
3. **HW 정보** — `inspect.sh --hw-only` 를 그대로 쓴다(PART 1만, 서버 설정은 안 봄).
   gadget_burn 을 먼저 띄워 20초 뒤 수집하므로 GPU PCIe 링크가 최대 속도로 찍힌다.
   끝에 **하드웨어 구성 요약**(CPU 모델/수량/S/N, 메인보드 모델/S/N, RAM 제조사·단품
   용량·속도·수량·총 용량, 스토리지·PCIe 디바이스의 구분/모델/S/N)을 `hw/hw_summary.txt`
   로 남기고, functest 가 끝날 때 다시 출력한다
4. **GPU 번인** — `run-burnin.sh --no-cpu` 를 5분으로 호출. CPU stress 는 걸지 않고
   GPU 만 돌리며, CPU 온도는 CSV 에 그대로 기록된다 (1시간 검수 번인은 CPU 도 같이 돈다)
5. **메모리 부하**(옵션) — `stress --vm` 을 번인과 겹쳐서 건다

GPU 상태 판정에 걸린 항목이 있으면 요약의 `GPU 판정` 에 표시되고 종료 코드가 1 이 된다.

```
functest_<host>_<시각>/
├── gadget-burn-build.log  make clean && make 출력 (clone 했으면 gadget-burn-clone.log 도)
├── gpu/                   gpu_list.csv / ecc_before.csv / ecc_after.csv / topo.txt / nvlink_status.txt / nvlink_errors.txt
├── hw/                    inspect.log / serials.csv / hw_summary.txt / raw/
├── burnin_<host>_<시각>/  온도 CSV, gadget_burn 로그 등
└── stress-mem.log         --mem 을 준 경우
```

서버 설정은 건드리지 않는다. 설정은 `setup.sh`, 설정 확인까지 포함한 검수는
`inspect.sh` 다.

---

## inspect.sh

하드웨어 점검과 서버 설정을 한 번에 한다. 빌드는 포함하지 않는다.

```bash
./inspect.sh                 # GPU 부하를 먼저 걸고 20초 뒤 HW 수집 (링크가 최대 속도로 올라온 상태)
./inspect.sh --no-load       # 부하 없이
./inspect.sh --load-sec 30   # 부하를 건 뒤 수집 시작까지 기다리는 시간 (기본 20초)
./inspect.sh --hw-only       # PART 1(하드웨어)만 — functest.sh 가 쓰는 모드
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

### HW 수집 전에 GPU 부하를 먼저 거는 이유

NVIDIA GPU 는 유휴일 때 링크를 Gen1 으로 내린다. 그 상태로 읽으면 멀쩡한 카드가
`Speed 2.5GT/s (downgraded)` 로 보인다. 부하가 걸려 있으면 각 장치가 낼 수 있는
최대 속도(Gen5 카드·슬롯이면 32GT/s, Gen4 면 16GT/s)로 올라온 값이 찍힌다.

```
유휴      LnkSta: Speed 2.5GT/s (downgraded), Width x16
부하 +3s  LnkSta: Speed 32GT/s, Width x16          ← LnkCap 과 일치
```

그래서 `inspect.sh` 는 sudo 확인 직후, 원본 덤프와 PART 1 하드웨어 수집에 들어가기
**전에** `gadget_burn` 을 백그라운드로 띄우고 20초(`--load-sec`) 기다린다. 그 상태로
`lspci -vvv` 덤프와 PCIe 항목을 읽고, PCIe 항목이 끝나면 바로 부하를 내린다
(`functest.sh` 의 HW 단계도 같다). 부하를 걸었을 때만 속도까지 합격 판정하고,
못 걸었으면 "속도 판정 불가" 로 남긴다.

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

`serials.csv` 는 `category,location,item,serial,note` 다. `location` 에는
PCI address(`0000:c1:00.0`), DIMM 슬롯(`P0 CHANNEL A`), 블록 장치(`/dev/nvme0n1`),
CPU 소켓(`SP6`)이 들어가 어느 자리의 부품인지 바로 짚을 수 있다.

**PART 1 — 하드웨어 점검 (읽기 전용)**

| 항목 | 확인 내용 |
|---|---|
| 시스템 / 메인보드 | 제조사 / 모델 / 보드 S/N / BIOS 버전 |
| CPU 정보 | 모델 / 소켓 / 코어 / 스레드 / 최대 클럭 / S/N |
| Memory 정보 | 총 용량 + DIMM 슬롯별 용량·속도·Part Number·S/N |
| Storage 정보 | 디스크 목록·S/N + NVMe 온도·`critical_warning` |
| GPU 정보 | `nvidia-smi` 기본 표 + 검수용 표(PCI address / VBIOS / S/N / ECC) |
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
| 자동 업데이트 중지 | 타이머 3종이 masked 인지 + `apt-config dump` 의 `APT::Periodic::Enable` 이 `0` 인지 + snap 이 `hold: forever` 인지 |
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
`--no-cpu` 를 주면 CPU 번인(stress)을 빼고 GPU 번인 + 온도 로깅만 한다(`functest.sh` 가 쓴다).

```bash
./run-burnin.sh          # 3600초 / 5초 샘플 (기본값)
./run-burnin.sh 1800 5   # 30분
```

- `gadget_burn -t <초>` — GPU 번인
- `stress -c $(nproc) -t <초>` — CPU 번인
- `lib/sample-sensors.sh <간격> <초> <출력.csv>` — 온도를 **CSV 로 바로** 기록

중간 txt 를 만들지 않는다. 예전에는 `GPU_CPU_log.txt` 를 만든 뒤 `make-csv.sh` 로
변환했는데, 그 파싱 단계에서 헤더와 데이터의 칼럼 수가 어긋나는 문제가 있었다.

화면은 2초마다 **제자리에서 갱신**된다. 최고온도가 바뀔 때마다 줄이 쌓이지
않으므로 GPU 가 10장이어도 화면이 흐르지 않는다.

```
 DEEPGadget SW 검수 번인 · deepgadget   경과 00:12:35 / 01:00:00   남은시간 00:47:25
 █████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ 21%   합계 172.803 TFLOPS
────────────────────────────────────────────────────────────────────────────────
 GPU  PCI ADDRESS     TEMP   MAX   SLOWDN        POWER W   UTIL    TFLOPS    PEAK  THROTTLE  열 / 전력 누적
   0  0000:c1:00.0      90    90        5  598.00/600.00   100%    86.412   82.4%  THERM 열 41.2s / 전력 0.0s
   1  0000:c9:00.0      73    90       22  598.00/600.00    99%    86.391   82.3%  -     열 0.0s / 전력 0.0s
 CPU   85.4°C (max 86.1°C)   소켓별 [ 85.4 83.2 ]   128 threads @ stress
 NVMe  43°C (max 43°C)   로그 샘플 151개 · 5s 간격 · Ctrl-C 중단
────────────────────────────────────────────────────────────────────────────────
```

- `PCI ADDRESS` — GPU 를 index 가 아니라 슬롯 주소로 식별한다
- `SLOWDN` — 하드웨어 슬로우다운까지 남은 여유(°C, `temperature.gpu.tlimit`)
- `THROTTLE` — gadget-burn 과 같은 기준이다. 열 쓰로틀(SW/HW Thermal Slowdown)이면
  `THERM`, HW Power Brake 면 `PWR`, 없으면 `-`. 뒤의 누적은 **GPU 별** 열 / 전력
  쓰로틀 시간. SW Power Cap(설정된 TDP 를 다 쓰는 정상 상태)은 쓰로틀로 치지 않는다
- 누적은 화면 갱신(약 2초)마다 순간값을 보고 그 사이 경과시간을 더하므로,
  100ms 마다 세는 gadget-burn 요약과 소수점·초 단위로는 조금 다를 수 있다
- `TFLOPS` / `PEAK` — gadget-burn 이 매초 `gadget_burn.csv` 에 쓰는 값을 그대로 옮긴다
  (gadget-burn 화면과 같은 최근 10초 슬라이딩 윈도우, PEAK = TFLOPS / 현재 클럭 기준 이론 피크).
  색도 gadget-burn 과 같다: 70% 이상 초록 / 60~69% 노랑 / 60% 미만 빨강.
  시작 직후 gadget-burn 이 초기화·autotune 하는 동안은 `-` 로 나온다
- 종료 요약의 GPU별 `TFLOPS` / `Peak` 는 gadget-burn 의 "최종 측정 결과"(전체 측정 구간 평균).
  Ctrl-C 로 중단하면 gadget-burn 이 그 결과를 내지 않으므로 CSV 1Hz 값의 평균으로 대신하고 그렇게 표시한다
- 표가 터미널 폭보다 넓으면 줄이 접히지 않고 오른쪽이 잘린다(제자리 갱신이 깨지지 않게)
- Ctrl-C 로 중단해도 그 시점까지의 CSV 가 남는다

결과는 실행한 디렉터리 아래 `burnin_<host>_<시각>/` 에 모인다.

```
burnin_deepgadget_20260908_143000/
├── GPU_CPU_deepgadget_20260908_143000.csv   ← 검수확인서에 붙일 파일
├── gadget_burn.csv/.log   TFLOPS·전력·쓰로틀 상세
├── stress.log / sample-sensors.log
├── max-events.log         최고온도 갱신 이력
└── system_info.txt        lscpu / nvidia-smi / nvme list 스냅샷
```

CSV 컬럼은 이런 모양이다. GPU 는 PCI address 로 구분한다.

```
Timestamp,Elapsed(s),Memory_Used(MB),nvme0_Temp(C),CPU0_Tctl(C),
GPU0_0000:c1:00.0_Temp(C),GPU0_0000:c1:00.0_Power(W),
GPU0_0000:c1:00.0_Util(%),GPU0_0000:c1:00.0_Throttle
```

`_Throttle` 칼럼은 gadget-burn 과 같은 기준의 쓰로틀 상태다:
`0` 없음 / `THERM` 열 쓰로틀 / `PWR` HW Power Brake.

### 알아둘 것

- `sample-sensors.sh` 는 매 샘플마다 `nvme smart-log` 를 부른다. root 가 필요해서
  `run-burnin.sh` 가 스크립트 전체를 root 로 한 번 승격시켜 돌린다.
  (tty 없이 미리 `sudo -v` 해두는 방식은 ppid 티켓 때문에 안 먹힌다)
- NVMe 는 `/dev/nvme0`, `/dev/nvme1` … 전부 컬럼으로 들어간다.

---

## 검수 순서

```bash
./setup.sh          # 1) 서버 설정 + 도구 설치 (장비당 1회)
                    #    GRUB 안내가 나오면 편집 + update-grub + reboot
./functest.sh       # 2) 기능 테스트 — HW 다 보이는지 + 5분 부하
./inspect.sh        # 3) 검수 → inspect_<host>_<시각>/
                    #    ❌ 가 있으면 조치 후 다시 ./inspect.sh
./run-burnin.sh     # 4) 1시간 번인 → CSV 를 검수확인서에 첨부
```

`run-burnin.sh` 는 `functest.sh` 가 5분짜리로 부르는 것과 같은 스크립트다.
1시간 번인은 검수확인서에 붙일 CSV 를 뽑는 단계이므로 따로 한 번 더 돌린다.

---

## 환경변수

옵션으로 노출하지 않은 값들. 평소에는 건드릴 일이 없다.

| 변수 | 쓰는 곳 | 기본값 | 용도 |
|---|---|---|---|
| `TZ_WANT` | setup / inspect | `Asia/Seoul` | 적용·판정할 타임존 |
| `CUDA_HOME` | setup | `/usr/local/cuda` | CUDA 를 다른 곳에 깐 경우 |
| `PCIE_LOAD_SEC` | inspect | `20` | `--load-sec` 와 같음 — 부하를 건 뒤 HW 수집 시작까지 대기(초) |
| `OUTDIR` | inspect | `inspect_<host>_<시각>` | 결과 폴더 지정 (`functest.sh` 가 쓴다) |
| `OUT_ROOT` | run-burnin | 실행한 디렉터리 | `burnin_*` 를 만들 상위 경로 |
| `BURN_DIR` | functest / inspect / run-burnin | (탐색) | `gadget_burn` 이 있는 디렉터리(또는 실행파일 경로). 없으면 `<저장소>/gadget-burn` → `<저장소>/../gadget-burn` → `~/gadget-burn` → `PATH` 순으로 찾는다 |
| `LIB_DIR` | run-burnin | `<저장소>/lib` | `sample-sensors.sh` / `find-gadget-burn.sh` 위치 |
| `REFRESH` | run-burnin | `2` | 대시보드 갱신 주기(초) |

`run-burnin.sh` 는 `exec sudo` 로 자기를 재실행한다. sudo 는 환경변수를 버리지만
위 표의 `BURN_DIR` `LIB_DIR` `OUT_ROOT` `REFRESH` 는 스크립트가 `env` 로 직접 넘기므로
`BURN_DIR=~/gadget-burn ./run-burnin.sh` 처럼 앞에 붙이면 된다. 그 밖의 변수는
넘어가지 않는다.

## 종료 코드

| | 0 | 1 |
|---|---|---|
| setup.sh | 실패 항목 없음 | 실패(❌) 항목이 있거나, 실행 자체가 막힘(root 실행 / sudo 실패) |
| inspect.sh | ❌ 없음 | **확인 필요(❌) 항목이 하나라도 있음** |
| functest.sh | HW·번인 모두 정상 | HW 판정 ❌ 또는 번인 실패 |
| run-burnin.sh | CSV 생성 완료 | 필수 도구 없음 / CSV 미생성 |

⚠️(건너뜀)은 실패로 세지 않는다 — 해당 하드웨어가 없거나 도구가 없어 판정을
못 한 경우다. 여러 대를 자동으로 돌릴 때는 exit code 로 걸러 쓸 수 있다.

```bash
./inspect.sh || echo "$(hostname) 확인 필요"
```

GRUB 안내는 exit code 에 반영되지 않는다. `setup.sh` 요약 뒤에 노란 박스가 뜨면
편집 → `update-grub` → 재부팅이 남아 있다는 뜻이므로 눈으로 확인해야 한다.

## 문제 해결

| 증상 | 원인 / 조치 |
|---|---|
| `root 로 실행하지 마세요` | `setup.sh` `inspect.sh` 는 일반 계정 전용. `sudo` 를 빼고 다시 |
| `gadget_burn 을 찾을 수 없습니다` | 메시지 아래에 찾아본 경로 목록이 나온다. 이미 빌드해 둔 곳이 있으면 `--burn-dir /경로`(functest) 또는 `BURN_DIR=/경로`(inspect / run-burnin). `functest.sh` 는 둘 다 없으면 clone 해서 빌드하므로 CUDA 만 있으면 된다. inspect / run-burnin 단독이면 `./setup.sh` 로 빌드 |
| functest 가 `[안내] CUDA 툴킷(nvcc)이 없어…` | 빌드 못 함. 드라이버가 지원하는 CUDA 버전 이하의 툴킷을 설치한 뒤 재실행. 빌드본이 있으면 `--no-build` 로 그대로 진행 가능 |
| 번인 시작 직후 `gadget_burn.log` 가 `invalid option -- 'o'` | 2026-09 이전 gadget-burn(release 1.0). 스크립트가 `-h` 로 미리 판별해 `-o` 없이 돌리므로 번인은 되지만 TFLOPS/Peak 는 안 나온다. `git -C <gadget-burn> pull --ff-only && make -C <gadget-burn>` 으로 갱신 |
| `Could not get lock /var/lib/dpkg/lock` | 자동 업데이트 타이머가 먼저 깨어난 것. `./setup.sh` 를 다시 돌리면 맨 앞에서 차단하고 진행한다 |
| GPU 가 `Speed 2.5GT/s (downgraded)` | 유휴 상태로 읽힌 것. `--no-load` 를 뺐는지 확인 (기본은 부하를 건다) |
| 온보드 NIC 이 `Width x4` 로 ❌ | 설계상 x4 인 보드가 많다(예: MS73-HB2 의 BCM57416). 슬롯 카드가 아니면 상위 브리지의 `LnkSta` 를 보고 판단한다 |
| GRUB 항목만 계속 ❌ | `setup.sh` 는 grub 을 자동 편집하지 않는다. 안내대로 편집 → `sudo update-grub` → **재부팅** |
| `ipmitool` 없음 → PSU ⚠️ | `./setup.sh` 로 설치. 건너뜀이라 검수는 계속된다 |
| PSU 센서 값이 `na` → ❌ | 해당 PSU 의 **AC 케이블이 빠진 것**을 의심한다. `sudo ipmitool sensor \| grep -i psu` 로 어느 쪽인지 확인 |
| 번인 화면이 깨져 보임 | tty 가 아니거나 폭이 좁은 터미널. CSV·로그는 정상으로 남으니 결과 파일로 확인 |
