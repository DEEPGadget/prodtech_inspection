#!/usr/bin/env bash
#
# inspect.sh — DEEPGadget 출고 검수: 하드웨어 점검 + 서버 설정
#
#   Check_server_information/test.sh (HW 리스트) 와
#   setup_tools.sh (서버 설정) 를 하나로 합친 것.
#   빌드(gadget-burn/nccl-tests/fio/gpu-burn)는 setup.sh 로 분리했다 —
#   make 출력 수백 줄이 점검 결과를 덮어버리기 때문.
#
# 사용법:
#   ./inspect.sh            # 하드웨어 점검 + 서버 설정 적용
#   ./inspect.sh --check    # 아무것도 바꾸지 않고 점검만 (재검수용)
#
# 로그는 실행한 디렉터리에 inspect_<host>_<시각>.log 로 남는다.

set -uo pipefail

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    echo "root 로 실행하지 마세요. 현재 사용자 계정으로 실행하면 필요할 때만 sudo 를 씁니다." >&2
    exit 1
fi

APPLY=1
for a in "$@"; do
    case "$a" in
        --check|--check-only|--no-apply) APPLY=0 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "알 수 없는 옵션: $a" >&2; exit 1 ;;
    esac
done

TZ_WANT="${TZ_WANT:-Asia/Seoul}"
LOG_FILE="$PWD/inspect_$(hostname)_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

RESULTS=()
C_B=$'\033[1m'; C_RST=$'\033[0m'
log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[WARN] %s\033[0m\n' "$*"; }
err()  { printf '\033[1;31m[FAIL] %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ] %s\033[0m\n' "$*"; }
record() { RESULTS+=("$1|$2|$3"); }
hr()   { printf '%s\n' "────────────────────────────────────────────────────────────────────────────────"; }
title(){ printf '\n\033[1;36m▌%s\033[0m\n' "$*"; }
kv()   { printf '   %-22s %s\n' "$1" "$2"; }

have() { command -v "$1" >/dev/null 2>&1; }

printf '\033[1;36m'
cat <<'BANNER'
================================================================================
   Manycoresoft / DEEPGadget  —  출고 검수 (Production Inspection)
================================================================================
BANNER
printf '\033[0m'
kv "호스트" "$(hostname)"
kv "일시"   "$(date '+%Y-%m-%d %H:%M:%S %Z')"
kv "OS"     "$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") / kernel $(uname -r)"
kv "모드"   "$([ "$APPLY" -eq 1 ] && echo '점검 + 설정 적용' || echo '점검만 (--check)')"
kv "로그"   "$LOG_FILE"

log "sudo 권한 확인"
sudo -v || { err "sudo 권한이 필요합니다."; exit 1; }

# ================================================================
#  PART 1 — 하드웨어 점검 (읽기 전용)
# ================================================================
printf '\n\033[1;35m'
hr; printf ' PART 1.  하드웨어 점검\n'; hr
printf '\033[0m'

# ---------------------------------------------------------------- CPU
title "CPU 정보"
CPU_MODEL=$(lscpu | grep -m1 "^Model name" | cut -d: -f2- | sed 's/^[ \t]*//')
CPU_SOCKETS=$(lscpu | grep -m1 "^Socket(s)" | cut -d: -f2- | tr -d ' ')
CPU_CORES_PER=$(lscpu | grep -m1 "^Core(s) per socket" | cut -d: -f2- | tr -d ' ')
CPU_THREADS=$(lscpu | grep -m1 "^CPU(s):" | cut -d: -f2- | tr -d ' ')
CPU_MAXMHZ=$(lscpu | grep -m1 "CPU max MHz" | cut -d: -f2- | tr -d ' ')
kv "Model"        "${CPU_MODEL:-?}"
kv "Socket"       "${CPU_SOCKETS:-?} socket"
kv "Core/Socket"  "${CPU_CORES_PER:-?}"
kv "Total Thread" "${CPU_THREADS:-?}"
kv "Max MHz"      "${CPU_MAXMHZ:-N/A}"
if [[ -n "$CPU_MODEL" ]]; then
    record OK "CPU" "$CPU_MODEL / ${CPU_SOCKETS}소켓 / ${CPU_THREADS}스레드"
else
    record FAIL "CPU" "lscpu 에서 Model name 을 읽지 못했습니다"
fi

# ---------------------------------------------------------------- Memory
title "Memory 정보"
MEM_TOTAL=$(free -h | awk '/^Mem:/ {print $2}')
kv "Total" "${MEM_TOTAL:-?}"
DIMM_N=0
if have dmidecode; then
    # Size 가 "No Module Installed" 인 슬롯은 제외
    DIMM_N=$(sudo dmidecode -t memory 2>/dev/null | grep -c "^\s*Size: [0-9]")
    if [[ "$DIMM_N" -gt 0 ]]; then
        # NOTE: 이 보드는 Locator 가 전 슬롯 "DIMM 0" 으로 같으므로 Bank Locator 로 구분한다.
        #       Configured Memory Speed 는 Part Number 보다 뒤에 나오므로 블록이 끝날 때 출력.
        printf '   %-18s %-10s %-12s %-12s %s\n' "SLOT" "SIZE" "SPEED" "VENDOR" "PART NUMBER"
        sudo dmidecode -t memory 2>/dev/null | awk '
          function flush(){ if (size ~ /^[0-9]/) printf "   %-18s %-10s %-12s %-12s %s\n", loc, size, spd, mf, pn;
                            size="";loc="";spd="";pn="";mf="" }
          /^Memory Device$/ { flush() }
          /^\tSize:/ {sub(/^\tSize: /,"");size=$0}
          /^\tBank Locator:/ {sub(/^\tBank Locator: /,"");loc=$0}
          /^\tManufacturer:/ {sub(/^\tManufacturer: /,"");mf=$0}
          /^\tPart Number:/ {sub(/^\tPart Number: /,"");sub(/ +$/,"");pn=$0}
          /^\tConfigured Memory Speed:/ {sub(/^\tConfigured Memory Speed: /,"");spd=$0}
          END { flush() }'
        record OK "Memory" "$MEM_TOTAL / DIMM ${DIMM_N}개"
    else
        warn "dmidecode 에서 DIMM 정보를 읽지 못했습니다."
        record FAIL "Memory" "$MEM_TOTAL / DIMM 정보 없음 — dmidecode 확인"
    fi
else
    warn "dmidecode 없음 → DIMM 상세를 건너뜁니다 (apt install dmidecode)"
    record SKIP "Memory" "$MEM_TOTAL / dmidecode 없음"
fi

# ---------------------------------------------------------------- Storage
title "Storage 정보"
printf '   %-12s %-9s %-8s %s\n' "NAME" "SIZE" "TYPE" "MODEL"
lsblk -dno NAME,SIZE,TYPE,MODEL | awk '$3=="disk"{m="";for(i=4;i<=NF;i++)m=m" "$i; printf "   %-12s %-9s %-8s%s\n",$1,$2,$3,m}'
DISK_N=$(lsblk -dno TYPE | grep -c '^disk$')
if have nvme; then
    printf '\n   NVMe:\n'
    sudo nvme list 2>/dev/null | sed 's/^/   /'
    for d in /dev/nvme[0-9]; do
        [ -e "$d" ] || continue
        t=$(sudo nvme smart-log "$d" 2>/dev/null | awk '/^temperature/{print $3}')
        w=$(sudo nvme smart-log "$d" 2>/dev/null | awk '/^critical_warning/{print $3}')
        printf '   %-12s temp %s°C   critical_warning %s\n' "$(basename "$d")" "${t:-?}" "${w:-?}"
        [[ "${w:-0}" != "0" ]] && record FAIL "Storage: $(basename "$d")" "critical_warning=$w — SMART 경고"
    done
fi
record OK "Storage" "disk ${DISK_N}개"

# ---------------------------------------------------------------- GPU
title "GPU 정보"
GPU_N=0
if have nvidia-smi; then
    GPU_N=$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l)
    kv "Driver"  "$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)"
    kv "CUDA"    "$(nvidia-smi 2>/dev/null | grep -oP 'CUDA Version: \K[0-9.]+' | head -1)"
    kv "GPU 수"  "${GPU_N} EA"
    printf '\n   %-4s %-46s %-10s %-12s %s\n' "IDX" "NAME" "VBIOS" "SERIAL" "MEMORY"
    nvidia-smi --query-gpu=index,name,vbios_version,serial,memory.total \
               --format=csv,noheader | while IFS=',' read -r i n v s m; do
        printf '   %-4s %-46s %-10s %-12s %s\n' "${i// /}" "${n# }" "${v// /}" "${s// /}" "${m# }"
    done
    ECC=$(nvidia-smi --query-gpu=ecc.errors.uncorrected.volatile.total --format=csv,noheader 2>/dev/null | tr -d ' ' | grep -v '^\[N/A\]$' | awk '{s+=$1} END{print s+0}')
    kv "ECC uncorrected" "${ECC:-N/A}"
    if [[ "$GPU_N" -gt 0 ]]; then
        record OK "GPU" "$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1) × ${GPU_N}"
    else
        record FAIL "GPU" "nvidia-smi 는 있으나 GPU 가 0개"
    fi
else
    err "nvidia-smi 없음 → NVIDIA 드라이버 미설치"
    lspci | grep -i nvidia | sed 's/^/   /'
    record FAIL "GPU" "nvidia-smi 없음 — NVIDIA 드라이버 설치 필요"
fi

# ---------------------------------------------------------------- PCIe
title "PCIe 연결 상태"
# GPU 는 LnkSta(현재) 와 LnkCap(카드 능력)을 같이 본다.
# NOTE: 온보드 NIC 등이 x4 로 뜨는 것은 설계상 정상인 경우가 많다.
#       폭 판정은 해당 슬롯의 상위 브리지 LnkSta 로 확인할 것.
PCIE_BAD=0
if have lspci; then
    printf '   %-12s %-40s %-22s %s\n' "BDF" "DEVICE" "LnkSta" "LnkCap"
    while read -r bdf rest; do
        [ -z "$bdf" ] && continue
        sta=$(sudo lspci -s "$bdf" -vvv 2>/dev/null | grep -m1 "LnkSta:" | sed 's/.*LnkSta:\s*//;s/,.*Margin.*//' | cut -c1-40)
        cap=$(sudo lspci -s "$bdf" -vvv 2>/dev/null | grep -m1 "LnkCap:" | grep -oP 'Speed \S+, Width \S+')
        sta_s=$(echo "$sta" | grep -oP 'Speed \S+' | head -1)
        sta_w=$(echo "$sta" | grep -oP 'Width \S+' | head -1)
        cap_w=$(echo "$cap" | grep -oP 'Width \K\S+')
        cur_w=$(echo "$sta_w" | grep -oP 'x\K[0-9]+')
        max_w=$(echo "$cap_w" | grep -oP 'x\K[0-9]+')
        mark=""
        if [[ -n "$cur_w" && -n "$max_w" && "$cur_w" -lt "$max_w" ]]; then mark="  ← 축소"; PCIE_BAD=$((PCIE_BAD+1)); fi
        printf '   %-12s %-40s %-22s %s%s\n' "$bdf" "$(echo "$rest" | cut -c1-40)" "${sta_s} ${sta_w}" "${cap}" "$mark"
    done < <(lspci -D 2>/dev/null | grep -iE 'nvidia|mellanox|infiniband|ethernet|raid' | sed 's/ /|/;s/|/ /' | awk '{bdf=$1; $1=""; sub(/^ /,""); print bdf, $0}')

    printf '   ※ 링크 속도(GT/s)는 유휴 시 낮아지는 것이 정상이므로 폭(Width)으로 판정한다.\n'
    printf '   ※ 온보드 NIC 의 x4 는 설계상 정상인 경우가 많다. 의심되면 상위 브리지의 LnkSta 를 볼 것.\n'
    if [[ "$PCIE_BAD" -eq 0 ]]; then
        ok "링크 폭 축소된 장치 없음"
        record OK "PCIe 연결 상태" "모든 대상 장치가 LnkCap 폭으로 링크됨"
    else
        warn "링크 폭이 LnkCap 보다 낮은 장치 ${PCIE_BAD}개 (온보드 NIC 등 설계상 정상인 경우 있음)"
        record FAIL "PCIe 연결 상태" "축소 ${PCIE_BAD}개 — 상위 브리지 LnkSta 로 재확인 필요"
    fi

    # AER 에러 카운트 (SLIM 케이블/라이저 불량 조기 발견)
    AER=$(dmesg 2>/dev/null | grep -ci "pcie bus error\|no pci_dev" || true)
    kv "dmesg PCIe 에러" "${AER}건"
    [[ "${AER:-0}" -gt 0 ]] && record FAIL "PCIe 에러(dmesg)" "${AER}건 — 케이블/라이저 경로 점검 필요"
fi

# ---------------------------------------------------------------- Infiniband
title "Infiniband"
IB_N=$(lspci 2>/dev/null | grep -ciE 'infiniband|mellanox' || true)
if [[ "${IB_N:-0}" -eq 0 ]]; then
    kv "장치" "없음"
    record SKIP "Infiniband" "장착된 IB/Mellanox 장치 없음"
else
    lspci 2>/dev/null | grep -iE 'infiniband|mellanox' | sed 's/^/   /'
    if have ibstat; then
        ibstat 2>/dev/null | grep -E "CA '|State:|Physical state:|Rate:|Link layer:" | sed 's/^/   /'
        IB_ACTIVE=$(ibstat 2>/dev/null | grep -c "State: Active" || true)
        if [[ "${IB_ACTIVE:-0}" -gt 0 ]]; then
            record OK "Infiniband" "장치 ${IB_N}개 / Active 포트 ${IB_ACTIVE}개"
        else
            record FAIL "Infiniband" "장치 ${IB_N}개 / Active 포트 없음 — 케이블·스위치 확인"
        fi
    else
        warn "ibstat 없음 → 포트 상태 확인 불가 (apt install infiniband-diags)"
        record SKIP "Infiniband" "장치 ${IB_N}개 / ibstat 없음 — infiniband-diags 설치 후 재확인"
    fi
fi

# ---------------------------------------------------------------- RAID Card
title "RAID Card"
RAID_LIST=$(lspci 2>/dev/null | grep -iE 'raid|megaraid|smartraid|storage controller' | grep -viE 'nvme|non-volatile' || true)
if [[ -z "$RAID_LIST" ]]; then
    kv "장치" "없음"
    record SKIP "RAID Card" "RAID 컨트롤러 없음"
else
    echo "$RAID_LIST" | sed 's/^/   /'
    RAID_TOOL=""
    for t in storcli64 storcli perccli64 perccli MegaCli64 megacli ssacli arcconf; do
        have "$t" && { RAID_TOOL=$t; break; }
    done
    if [[ -n "$RAID_TOOL" ]]; then
        kv "관리도구" "$RAID_TOOL"
        sudo "$RAID_TOOL" /c0 show 2>/dev/null | head -30 | sed 's/^/   /'
        record OK "RAID Card" "$(echo "$RAID_LIST" | head -1 | cut -c1-60) / $RAID_TOOL"
    else
        warn "RAID 관리도구(storcli/perccli/MegaCli 등)가 없어 어레이 상태를 읽지 못했습니다."
        record FAIL "RAID Card" "카드는 인식됨 / 관리도구 없음 — storcli 설치 후 어레이 상태 확인 필요"
    fi
fi

# ---------------------------------------------------------------- 기타 추가 부품
title "기타 추가 부품 (GPU·NIC·RAID·IB 제외 PCIe 장치)"
lspci 2>/dev/null \
  | grep -viE 'nvidia|mellanox|infiniband|ethernet|raid|non-volatile|bridge|host|isa|smbus|usb|audio|encryption|system peripheral|sata|iommu|non-essential instrumentation|signal processing' \
  | sed 's/^/   /' | head -20
ETC_N=$(lspci 2>/dev/null | grep -viE 'nvidia|mellanox|infiniband|ethernet|raid|non-volatile|bridge|host|isa|smbus|usb|audio|encryption|system peripheral|sata|iommu|non-essential instrumentation|signal processing' | wc -l)
record OK "기타 추가 부품" "분류되지 않은 PCIe 장치 ${ETC_N}개 (위 목록 확인)"

# ---------------------------------------------------------------- Network
title "Network 상태"
printf '   %-14s %-8s %-12s %-18s %s\n' "IFACE" "STATE" "SPEED" "IPv4" "MAC"
NET_UP=0
for i in /sys/class/net/*; do
    n=$(basename "$i")
    [[ "$n" == "lo" ]] && continue
    st=$(cat "$i/operstate" 2>/dev/null)
    sp=$(cat "$i/speed" 2>/dev/null); [[ -n "$sp" && "$sp" != "-1" ]] && sp="${sp}Mb/s" || sp="-"
    ip4=$(ip -4 -o addr show "$n" 2>/dev/null | awk '{print $4}' | head -1)
    mac=$(cat "$i/address" 2>/dev/null)
    printf '   %-14s %-8s %-12s %-18s %s\n' "$n" "${st:-?}" "$sp" "${ip4:--}" "$mac"
    [[ "$st" == "up" ]] && NET_UP=$((NET_UP+1))
done
if have network-test; then
    printf '\n'
    network-test 2>/dev/null | grep -E "interface.*(up|down)|can access web server" | sed 's/^/   /'
fi
if [[ "$NET_UP" -gt 0 ]]; then
    record OK "Network 상태" "up 인터페이스 ${NET_UP}개"
else
    record FAIL "Network 상태" "up 상태 인터페이스가 없습니다"
fi

# ---------------------------------------------------------------- USB
title "USB 포트 상태"
if have lsusb; then
    for bus in $(lsusb | awk '{print $2}' | sort -u); do
        cnt=$(lsusb | awk -v b="$bus" '$2==b' | wc -l)
        printf '   Bus %-4s  device %s개  (ok)\n' "$bus" "$cnt"
    done
    USB_BUS=$(lsusb | awk '{print $2}' | sort -u | wc -l)
    record OK "USB 포트 상태" "Bus ${USB_BUS}개 인식"
else
    record SKIP "USB 포트 상태" "lsusb 없음 (apt install usbutils)"
fi

# ---------------------------------------------------------------- PSU
title "PSU 상태 (인식 / 온도 / Fan RPM)"
if have ipmitool; then
    # NOTE: AC 미연결 PSU 는 센서 읽기가 실패하며 ipmitool 이 exit 1 을 낸다.
    #       "|| true" 로 감싸지 않으면 여기서 스크립트가 죽는다.
    PSU_RAW=$(sudo ipmitool sensor 2>/dev/null | grep -iE '^\s*PSU' || true)
    if [[ -z "$PSU_RAW" ]]; then
        warn "ipmitool 센서 목록에서 PSU 항목을 찾지 못했습니다."
        record FAIL "PSU 상태" "PSU 센서 없음 — BMC SDR 확인 필요"
    else
        echo "$PSU_RAW" | awk -F'|' '{gsub(/^ +| +$/,"",$1);gsub(/^ +| +$/,"",$2);gsub(/^ +| +$/,"",$3);gsub(/^ +| +$/,"",$4);
             printf "   %-26s %-12s %-6s %s\n", $1, $2, $3, $4}'
        # 주의: ipmitool sensor 는 임계값 칼럼을 전부 "na" 로 채운다.
        #       줄 전체를 grep 하면 정상 센서도 전부 걸리므로 판독값($2)만 본다.
        PSU_NA=$(echo "$PSU_RAW" | awk -F'|' '{gsub(/ /,"",$2); if($2=="na") c++} END{print c+0}')
        PSU_CNT=$(echo "$PSU_RAW" | grep -oiE 'PSU[0-9]+' | sort -u | wc -l)
        printf '\n   PSU 인식: %s개\n' "$PSU_CNT"
        if [[ "${PSU_NA:-0}" -gt 0 ]]; then
            warn "값이 'na' 인 PSU 센서가 ${PSU_NA}개 있습니다 → 해당 PSU 의 AC 입력이 빠졌을 수 있습니다."
            record FAIL "PSU 상태" "PSU ${PSU_CNT}개 인식 / na 센서 ${PSU_NA}개 — AC 케이블 확인"
        else
            record OK "PSU 상태" "PSU ${PSU_CNT}개 인식 / 모든 센서 정상"
        fi
    fi
    printf '\n   [Temperature]\n'
    sudo ipmitool sdr type Temperature 2>/dev/null | sed 's/^/   /' | head -15
    printf '\n   [Fan]\n'
    sudo ipmitool sdr type Fan 2>/dev/null | sed 's/^/   /' | head -20
    FAN_ZERO_LIST=$(sudo ipmitool sdr type Fan 2>/dev/null | awk -F'|' '$NF ~ /^ *0 RPM/ {gsub(/^ +| +$/,"",$1); printf "%s ", $1}')
    FAN_ZERO=$(echo "$FAN_ZERO_LIST" | wc -w)
    if [[ "${FAN_ZERO:-0}" -gt 0 ]]; then
        warn "0 RPM 인 팬: ${FAN_ZERO_LIST}(미장착 헤더면 정상, 장착돼 있으면 고착)"
        record FAIL "Fan RPM" "0 RPM ${FAN_ZERO}개: ${FAN_ZERO_LIST}— 장착 여부 확인"
    else
        record OK "Fan RPM" "0 RPM 팬 없음"
    fi
else
    warn "ipmitool 없음 → PSU/온도/팬 확인 불가 (./setup.sh 로 설치)"
    record SKIP "PSU 상태" "ipmitool 없음 — ./setup.sh 실행 필요"
fi

# ================================================================
#  PART 2 — 서버 설정
# ================================================================
printf '\n\033[1;35m'
hr; printf ' PART 2.  서버 설정  %s\n' "$([ "$APPLY" -eq 1 ] && echo '(적용)' || echo '(점검만)')"; hr
printf '\033[0m'

# ---------------------------------------------------------------- Time Zone
title "Time Zone"
TZ_NOW=$(timedatectl show -p Timezone --value 2>/dev/null)
kv "현재" "$TZ_NOW"
kv "NTP 동기화" "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
if [[ "$TZ_NOW" == "$TZ_WANT" ]]; then
    ok "Time Zone: $TZ_NOW"
    record OK "Time Zone" "$TZ_NOW"
elif [[ "$APPLY" -eq 1 ]]; then
    if sudo timedatectl set-timezone "$TZ_WANT"; then
        ok "Time Zone: $TZ_NOW → $TZ_WANT 로 변경"
        record OK "Time Zone" "$TZ_NOW → $TZ_WANT 로 변경함"
    else
        err "Time Zone 변경 실패"
        record FAIL "Time Zone" "$TZ_NOW — $TZ_WANT 로 변경 실패"
    fi
else
    warn "Time Zone 이 $TZ_WANT 가 아닙니다 (현재 $TZ_NOW)"
    record FAIL "Time Zone" "$TZ_NOW — $TZ_WANT 아님 (--check 라 변경 안 함)"
fi

# ---------------------------------------------------------------- 전원관리
title "전원관리 서비스 비활성화"
SLEEP_TARGETS=(sleep.target suspend.target hibernate.target hybrid-sleep.target)
if [[ "$APPLY" -eq 1 ]]; then
    # sleep.target 계열은 static unit 이라 disable 시 "no install section" 경고가 정상.
    # 실제 차단은 mask 가 담당한다.
    sudo systemctl disable "${SLEEP_TARGETS[@]}" 2>/dev/null || true
    sudo systemctl mask "${SLEEP_TARGETS[@]}"
fi
# NOTE: masked 유닛에서 is-enabled 는 "masked" 를 출력하면서 exit 1 을 낸다.
#       파이프로 검사하면 pipefail 때문에 성공인데 실패로 판정되므로 문자열 비교 사용.
for t in "${SLEEP_TARGETS[@]}"; do
    en=$(systemctl is-enabled "$t" 2>/dev/null); en=${en:-unknown}
    ac=$(systemctl is-active  "$t" 2>/dev/null); ac=${ac:-inactive}
    printf '   %-22s enabled=%-10s active=%s\n' "$t" "$en" "$ac"
done
if [[ "$(systemctl is-enabled sleep.target 2>/dev/null)" == masked ]]; then
    ok "sleep/suspend/hibernate 차단됨 (masked)"
    record OK "전원관리(sleep/suspend)" "masked — 절전 진입 차단됨"
else
    err "sleep.target 이 masked 가 아닙니다"
    record FAIL "전원관리(sleep/suspend)" "masked 아님 — sudo systemctl mask sleep.target 필요"
fi

if have powerprofilesctl; then
    [[ "$APPLY" -eq 1 ]] && sudo powerprofilesctl set performance 2>/dev/null
    PP=$(powerprofilesctl get 2>/dev/null)
    kv "power profile" "${PP:-?}"
    if [[ "$PP" == performance ]]; then
        record OK "전원 프로파일" "performance"
    else
        record FAIL "전원 프로파일" "현재=${PP:-unknown} — performance 아님"
    fi
else
    record SKIP "전원 프로파일" "powerprofilesctl 없음 (apt install power-profiles-daemon)"
fi

# ---------------------------------------------------------------- 자동 업데이트
title "자동 업데이트 중지"
# apt-daily.timer / apt-daily-upgrade.timer 가 실제 트리거다. 서비스만 mask 하면
# 타이머가 계속 깨어나 /var/lib/dpkg/lock 을 잡아 수동 apt 작업이 막힌다.
AUTOUPD_UNITS=(apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service)
for u in "${AUTOUPD_UNITS[@]}"; do
    if ! systemctl list-unit-files 2>/dev/null | grep -q "^${u//./\\.}[[:space:]]"; then
        record SKIP "자동업데이트: $u" "해당 unit 없음"
        continue
    fi
    if [[ "$APPLY" -eq 1 ]]; then
        sudo systemctl stop    "$u" 2>/dev/null || true
        sudo systemctl disable "$u" 2>/dev/null || true
        sudo systemctl mask    "$u"
    fi
    en=$(systemctl is-enabled "$u" 2>/dev/null); en=${en:-not-found}
    ac=$(systemctl is-active  "$u" 2>/dev/null); ac=${ac:-inactive}
    printf '   %-30s enabled=%-10s active=%s\n' "$u" "$en" "$ac"
    if [[ "$en" == masked ]]; then
        record OK "자동업데이트: $u" "masked"
    else
        record FAIL "자동업데이트: $u" "enabled=$en — masked 아님"
    fi
done
[[ "$APPLY" -eq 1 ]] && sudo systemctl daemon-reload
printf '   해제하려면: sudo systemctl unmask %s\n' "${AUTOUPD_UNITS[*]}"

# ---------------------------------------------------------------- Persistence Mode
title "NVIDIA Persistence Mode"
if have nvidia-smi; then
    if [[ "$APPLY" -eq 1 ]]; then
        sudo tee /etc/systemd/system/nvidia-pm.service > /dev/null <<'EOF'
[Unit]
Description=Enable NVIDIA Persistence Mode
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/bin/nvidia-smi -pm 1
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        sudo systemctl daemon-reload
        sudo systemctl enable --now nvidia-pm.service >/dev/null 2>&1
    fi
    PM_STATE=$(nvidia-smi -q 2>/dev/null | grep -i "Persistence Mode" | head -1 | awk -F': ' '{print $2}')
    SVC=$(systemctl is-enabled nvidia-pm.service 2>/dev/null); SVC=${SVC:-not-found}
    kv "Persistence Mode" "${PM_STATE:-unknown}"
    kv "nvidia-pm.service" "$SVC"
    if [[ "$PM_STATE" == *Enabled* && "$SVC" == enabled ]]; then
        record OK "NVIDIA Persistence Mode" "Enabled / 서비스 등록됨 (재부팅 후 유지)"
    else
        record FAIL "NVIDIA Persistence Mode" "state=${PM_STATE:-unknown} service=$SVC"
    fi
else
    record SKIP "NVIDIA Persistence Mode" "nvidia-smi 없음"
fi

# ---------------------------------------------------------------- ACS
title "OS ACS Disable"
# ACS 가 켜져 있으면 PCIe P2P 트래픽이 루트 컴플렉스로 우회돼 GPUDirect/NCCL 성능이
# 크게 떨어진다. setpci 는 재부팅하면 초기화되므로 systemd 서비스로 등록한다.
if ! have setpci || ! have lspci; then
    record SKIP "OS ACS Disable" "pciutils 없음 (apt install pciutils)"
else
    ACS_BEFORE=$(sudo lspci -vvv 2>/dev/null | grep ACSCtl | grep -c 'SrcValid+' || true)
    if [[ "$APPLY" -eq 1 ]]; then
        sudo tee /usr/local/sbin/disable_acs.sh > /dev/null <<'EOF'
#!/bin/bash
# This script must be run with root privileges.
if [ "$EUID" -ne 0 ]; then
  echo "Error: run as root (e.g. sudo ./disable_acs.sh)"; exit 1
fi
echo "Disabling ACS on all PCIe devices..."
for BDF in $(lspci | awk '{print $1}'); do
    setpci -s ${BDF} ECAP_ACS+0x6.w > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "Disabling ACS on device [${BDF}]..."
        setpci -s ${BDF} ECAP_ACS+0x6.w=0000
    fi
done
echo "Done. Verify with: sudo lspci -vvv | grep ACSCtl"
EOF
        sudo chmod +x /usr/local/sbin/disable_acs.sh
        sudo tee /etc/systemd/system/disable-acs.service > /dev/null <<'EOF'
[Unit]
Description=Disable PCIe ACS at boot
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/disable_acs.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        sudo systemctl daemon-reload
        sudo systemctl enable --now disable-acs.service >/dev/null 2>&1
    fi
    ACS_AFTER=$(sudo lspci -vvv 2>/dev/null | grep ACSCtl | grep -c 'SrcValid+' || true)
    SVC=$(systemctl is-enabled disable-acs.service 2>/dev/null); SVC=${SVC:-not-found}
    kv "ACSCtl SrcValid+" "${ACS_BEFORE:-0}개 → ${ACS_AFTER:-0}개"
    kv "disable-acs.service" "$SVC"
    if [[ "${ACS_AFTER:-1}" -eq 0 ]]; then
        record OK "OS ACS Disable" "SrcValid+ 0개 / 서비스=$SVC"
    else
        record FAIL "OS ACS Disable" "SrcValid+ ${ACS_AFTER}개 남음 — BIOS 에서 VT-d(AMD-V)/ACS Control Disabled 필요"
    fi
fi

# ---------------------------------------------------------------- GRUB
title "/etc/default/grub"
# iommu=pt      : IOMMU passthrough — DMA 주소변환 오버헤드 제거
# pcie_aspm=off : PCIe 링크 절전 비활성화 — 링크 복귀 지연 제거
# 부팅 파라미터라 즉시 반영이 불가능하고, 자동 편집은 부팅을 깨뜨릴 위험이 있어
# 여기서는 점검 + 안내만 한다.
GRUB_FILE=/etc/default/grub
GRUB_PARAMS=(iommu=pt pcie_aspm=off)
GRUB_MISS_CMDLINE=(); GRUB_MISS_FILE=()
CMDLINE=$(tr '\n' ' ' < /proc/cmdline 2>/dev/null)
GRUB_CONF=$(sudo grep -E '^GRUB_CMDLINE_LINUX(_DEFAULT)?=' "$GRUB_FILE" 2>/dev/null)
for p in "${GRUB_PARAMS[@]}"; do
    [[ " $CMDLINE " == *" $p "* ]] || GRUB_MISS_CMDLINE+=("$p")
    [[ "$GRUB_CONF" == *"$p"* ]]   || GRUB_MISS_FILE+=("$p")
done
kv "/proc/cmdline" "${CMDLINE:-(읽기 실패)}"
printf '   %-22s\n' "grub 설정"
printf '%s\n' "${GRUB_CONF:-(읽지 못함)}" | sed 's/^/       /' 
if [[ ${#GRUB_MISS_CMDLINE[@]} -eq 0 ]]; then
    GRUB_ACTION=none
    ok "iommu=pt, pcie_aspm=off 모두 현재 부팅에 반영됨"
    record OK "/etc/default/grub" "iommu=pt, pcie_aspm=off 적용됨"
elif [[ ${#GRUB_MISS_FILE[@]} -eq 0 ]]; then
    GRUB_ACTION=reboot
    warn "grub 파일엔 있으나 현재 부팅에 미반영: ${GRUB_MISS_CMDLINE[*]} → sudo update-grub && reboot"
    record FAIL "/etc/default/grub" "미반영(${GRUB_MISS_CMDLINE[*]}) — update-grub + 재부팅 필요"
else
    GRUB_ACTION=edit
    warn "grub 파일에 누락: ${GRUB_MISS_FILE[*]}"
    record FAIL "/etc/default/grub" "누락(${GRUB_MISS_FILE[*]}) — 파일 편집 + update-grub + 재부팅 필요"
fi

# ================================================================
#  요약
# ================================================================
print_group() {
    local want=$1 title=$2 color=$3 count=0 line status name detail
    for line in "${RESULTS[@]}"; do
        IFS='|' read -r status name detail <<< "$line"
        [[ "$status" == "$want" ]] && count=$((count + 1))
    done
    [[ $count -eq 0 ]] && return 0
    printf '\n\033[1;%sm%s (%d개)\033[0m\n' "$color" "$title" "$count"
    for line in "${RESULTS[@]}"; do
        IFS='|' read -r status name detail <<< "$line"
        [[ "$status" == "$want" ]] || continue
        printf '   %-26s %s\n' "$name" "$detail"
    done
    return "$count"
}

printf '\n\033[1;34m'; hr; printf '  검수 결과 요약  —  %s\n' "$(hostname)"; hr; printf '\033[0m'
print_group OK   "✅ 정상"      32 || OK_COUNT=$?
print_group FAIL "❌ 확인 필요" 31 || FAIL_COUNT=$?
print_group SKIP "⚠️  건너뜀"   33 || SKIP_COUNT=$?
OK_COUNT=${OK_COUNT:-0}; FAIL_COUNT=${FAIL_COUNT:-0}; SKIP_COUNT=${SKIP_COUNT:-0}

printf '\n'; hr
printf '  정상 %d / 확인 필요 %d / 건너뜀 %d\n' "$OK_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
printf '  로그 : %s\n' "$LOG_FILE"
hr

if [[ "${GRUB_ACTION:-none}" != none ]]; then
    printf '\n\033[1;33m'; hr
    printf '  ⚠  남은 수동 작업 — GRUB 커널 파라미터 설정 후 재부팅\n'
    hr; printf '\033[0m'
    if [[ "${GRUB_ACTION}" == edit ]]; then
        printf '\n  1) sudo vi /etc/default/grub\n'
        printf '     GRUB_CMDLINE_LINUX_DEFAULT 줄 끝에 아래를 추가 (기존 값은 유지)\n\n'
        printf '       %siommu=pt pcie_aspm=off%s\n\n' "$C_B" "$C_RST"
        printf '     누락된 값: \033[1;31m%s\033[0m\n' "${GRUB_MISS_FILE[*]}"
    else
        printf '\n  grub 파일엔 있으나 현재 부팅 미반영: \033[1;31m%s\033[0m\n' "${GRUB_MISS_CMDLINE[*]}"
    fi
    printf '\n  2) sudo update-grub\n  3) sudo reboot\n'
    printf '\n  ※ BIOS 도 함께 확인 (이 스크립트로는 설정 불가)\n'
    printf '       - Virtualization Technology (VT-d / AMD-V) : Disabled\n'
    printf '       - ACS Control                              : Disabled\n'
    printf '       - IOMMU                                    : 문제 없으면 그대로\n'
    printf '\n  ※ 재부팅 후 확인: cat /proc/cmdline / sudo lspci -vvv | grep ACSCtl\n'
    printf '\033[1;33m'; hr; printf '\033[0m'
fi

printf '\n  다음 단계: ./run-burnin.sh   (1시간 번인, 결과는 실행한 디렉터리에 생성)\n\n'

[[ $FAIL_COUNT -gt 0 ]] && exit 1
exit 0
