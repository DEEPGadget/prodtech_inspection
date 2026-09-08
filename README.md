# prodtech_inspection

Manycoresoft / DEEPGadget **출고 검수** 스크립트 모음.

하드웨어 점검과 서버 설정을 한 번에 하고(`inspect.sh`), 번인을 돌려
검수확인서에 붙일 온도 CSV를 뽑는다(`run-burnin.sh`).

```
prodtech_inspection/
├── setup.sh          # 번인에 필요한 것만 설치 (apt 패키지 + gadget-burn 빌드)
├── inspect.sh        # 하드웨어 점검 + 서버 설정          ← 검수 본체
├── run-burnin.sh     # GPU/CPU 동시 번인 + 온도 로깅 → CSV
└── lib/
    ├── gpu-cpu.sh    # 온도 로깅 (Check_server_information 유래)
    └── make-csv.sh   # 온도 로그 → CSV
```

## 빠른 시작

```bash
git clone https://github.com/DEEPGadget/prodtech_inspection.git
cd prodtech_inspection

./setup.sh          # 1회만. 번인 도구 설치 (make 로그가 길다)
./inspect.sh        # 하드웨어 점검 + 서버 설정
./run-burnin.sh     # 1시간 번인 → CSV
```

세 스크립트 모두 **일반 계정으로** 실행한다. 필요할 때만 내부에서 `sudo` 를 쓴다.
결과 파일은 전부 **실행한 디렉터리**에 생긴다.

---

## setup.sh

번인 실행에 꼭 필요한 것만 설치한다.

| 항목 | 내용 |
|---|---|
| apt 패키지 | `stress` `lm-sensors` `nvme-cli` `ipmitool` `pciutils` `ifupdown-extra` `build-essential` `git` |
| gadget-burn | `DEEPGadget/gadget-burn` clone + make (CUDA 필요) |

```bash
./setup.sh              # 저장소 안(./gadget-burn)에 설치
./setup.sh /opt/bench   # 다른 경로에 gadget-burn 설치
```

> **검수와 분리한 이유**: `make` 출력이 수백 줄이라 검수와 같이 돌리면
> 하드웨어 점검·서버 설정 결과가 로그에서 묻힌다. 설치는 장비당 한 번,
> 검수는 여러 번 돌린다.

로그: `setup_<host>_<시각>.log`

---

## inspect.sh

`Check_server_information/test.sh` 의 하드웨어 리스트와 `setup_tools.sh` 의
서버 설정을 하나로 합친 것. 빌드는 포함하지 않는다.

```bash
./inspect.sh            # 점검 + 설정 적용
./inspect.sh --check    # 아무것도 바꾸지 않고 점검만 (재검수용)
```

**PART 1 — 하드웨어 점검 (읽기 전용)**

| 항목 | 확인 내용 |
|---|---|
| CPU 정보 | 모델 / 소켓 / 코어 / 스레드 / 최대 클럭 |
| Memory 정보 | 총 용량 + DIMM 슬롯별 용량·속도·Part Number |
| Storage 정보 | 디스크 목록 + NVMe 온도·`critical_warning` |
| GPU 정보 | 드라이버 / CUDA / 모델 / VBIOS / S/N / ECC |
| PCIe 연결 상태 | `LnkSta` vs `LnkCap` 폭 비교 + dmesg PCIe 에러 |
| Infiniband | 장치 인식 + `ibstat` 포트 State |
| RAID Card | 컨트롤러 인식 + storcli/perccli 어레이 상태 |
| 기타 추가 부품 | GPU·NIC·RAID·IB 로 분류되지 않은 PCIe 장치 |
| Network 상태 | 인터페이스 up/down / speed / IPv4 / MAC |
| USB 포트 상태 | Bus 별 장치 수 |
| PSU 상태 | PSU 인식 수 / Power In·Out / 온도 / Fan RPM |

**PART 2 — 서버 설정 (`--check` 면 확인만)**

| 항목 | 조치 |
|---|---|
| Time Zone | `Asia/Seoul` 로 설정 (`TZ_WANT` 로 변경 가능) |
| 전원관리 서비스 비활성화 | sleep/suspend/hibernate mask + performance 프로파일 |
| 자동 업데이트 중지 | `apt-daily.timer` `apt-daily-upgrade.timer` `unattended-upgrades` mask |
| NVIDIA Persistence Mode | `nvidia-pm.service` 등록 (재부팅 후 유지) |
| OS ACS Disable | `disable-acs.service` 등록 + `ACSCtl SrcValid+` 0개 확인 |
| /etc/default/grub | `iommu=pt` `pcie_aspm=off` **점검·안내만** (자동 편집 안 함) |

마지막에 정상 / 확인 필요 / 건너뜀 으로 요약이 나오고,
확인 필요 항목이 하나라도 있으면 exit code 1 로 끝난다.

로그: `inspect_<host>_<시각>.log`

> BIOS 설정과 Gadgetini 그래프 확인은 이 스크립트 범위 밖이라 빠져 있다.
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
 DEEPGadget 검수 번인 · deepgadget   경과 00:12:35 / 01:00:00   남은시간 00:47:25
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
./setup.sh          # 1) 번인 도구 설치 (장비당 1회)
./inspect.sh        # 2) 하드웨어 점검 + 서버 설정  → inspect_*.log
                    #    GRUB 안내가 나오면 편집 + update-grub + reboot 후 재실행
./inspect.sh --check   #    재부팅 후 재확인
./run-burnin.sh     # 3) 1시간 번인 → CSV 를 검수확인서에 첨부
```
