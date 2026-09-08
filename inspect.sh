#!/usr/bin/env bash
#
# inspect.sh — DEEPGadget 출고 검수 (읽기 전용)
#
#   구 Check_server_information/test.sh (HW 리스트) 와 구 setup_tools.sh
#   (서버 설정) 를 대체한다. 이 저장소 하나로 검수가 끝난다.
#
#   이 스크립트는 아무것도 바꾸지 않는다. 하드웨어를 조사하고, setup.sh 가
#   적용해 둔 서버 설정이 실제로 걸려 있는지 확인해 합격/불합격만 보고한다.
#   설정을 바꾸는 것도, 도구를 빌드하는 것도 setup.sh 담당이다.
#     - 설정이 안 걸려 있다고 나오면  → ./setup.sh 를 (다시) 실행
#     - 도구가 없다고 나오면          → ./setup.sh 를 실행
#
# 사용법:
#   ./inspect.sh                 # PCIe 측정 시 GPU 부하를 걸어 링크를 최대 속도로 올림
#   ./inspect.sh --no-load       # 부하 없이 (유휴 링크 속도가 그대로 찍힘)
#   ./inspect.sh --load-sec 120  # 부하 시간(기본 60초)
#
# 결과는 실행한 디렉터리 아래 inspect_<host>_<시각>/ 에 모인다.
#   inspect.log   전체 출력
#   serials.csv   구성품 S/N 목록 (검수확인서용)
#   raw/          lspci -vvv, dmidecode, nvidia-smi -q, ipmitool sdr 등 원본 덤프

set -uo pipefail

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    echo "root 로 실행하지 마세요. 현재 사용자 계정으로 실행하면 필요할 때만 sudo 를 씁니다." >&2
    exit 1
fi

# --check 는 예전 옵션. 이제 항상 읽기 전용이라 받아만 주고 무시한다.
PCIE_LOAD=1
PCIE_LOAD_SEC=${PCIE_LOAD_SEC:-60}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check|--check-only|--no-apply) ;;
        --no-load) PCIE_LOAD=0 ;;
        --load-sec) shift; PCIE_LOAD_SEC=${1:-60} ;;
        -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
        *) echo "알 수 없는 옵션: $1" >&2; exit 1 ;;
    esac
    shift
done

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TZ_WANT="${TZ_WANT:-Asia/Seoul}"
STAMP=$(date +%Y%m%d_%H%M%S)
OUTDIR="$PWD/inspect_$(hostname)_${STAMP}"
RAWDIR="$OUTDIR/raw"
mkdir -p "$RAWDIR" || { echo "결과 디렉터리를 만들 수 없습니다: $OUTDIR" >&2; exit 1; }
LOG_FILE="$OUTDIR/inspect.log"
SN_CSV="$OUTDIR/serials.csv"
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

# 구성품 S/N 수집: add_sn <분류> <식별자> <S/N> [비고]
SERIALS=()
add_sn() { SERIALS+=("$1|$2|$3|${4:-}"); }
# 값이 비었거나 의미 없는 자리표시자면 "-" 로 정규화
sn_clean() {
    local v="${1//$'\t'/ }"; v="$(echo "$v" | sed 's/^ *//;s/ *$//')"
    case "$v" in
        ""|Unknown|unknown|"Not Specified"|"To Be Filled By O.E.M."|"Default string"|        "System Serial Number"|"None"|0|"0000000000") echo "-" ;;
        *) echo "$v" ;;
    esac
}

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
kv "모드"   "읽기 전용 — 설정은 바꾸지 않습니다 (변경은 ./setup.sh)"
kv "결과경로" "$OUTDIR"

log "sudo 권한 확인"
sudo -v || { err "sudo 권한이 필요합니다."; exit 1; }

# 증빙용 원본 덤프 (요약이 놓친 것을 나중에 되짚을 수 있도록)
# 주의: 이 스크립트는 stdout 을 tee 프로세스 치환으로 넘겨두었다. 덤프를 &로 띄우고
#       인자 없는 wait 를 쓰면 그 tee 까지 기다려 영원히 멈춘다. 순차로 돌린다.
log "원본 덤프 저장: $RAWDIR"
sudo lspci -vvv > "$RAWDIR/lspci-vvv.txt" 2>&1
sudo dmidecode  > "$RAWDIR/dmidecode.txt" 2>&1
lscpu           > "$RAWDIR/lscpu.txt"     2>&1
lsblk -O        > "$RAWDIR/lsblk.txt"     2>&1
sensors         > "$RAWDIR/sensors.txt"   2>&1
ip -d addr      > "$RAWDIR/ip-addr.txt"   2>&1
lsusb -t        > "$RAWDIR/lsusb.txt"     2>&1
have nvidia-smi && nvidia-smi -q > "$RAWDIR/nvidia-smi-q.txt" 2>&1
if have ipmitool; then
    sudo ipmitool sdr    > "$RAWDIR/ipmitool-sdr.txt"    2>&1
    sudo ipmitool sensor > "$RAWDIR/ipmitool-sensor.txt" 2>&1
    sudo ipmitool fru    > "$RAWDIR/ipmitool-fru.txt"    2>&1
fi
have nvme && sudo nvme list > "$RAWDIR/nvme-list.txt" 2>&1
dmesg 2>/dev/null | grep -iE "pcie|nvidia|mlx|error" > "$RAWDIR/dmesg-filtered.txt" 2>&1
ok "$(ls -1 "$RAWDIR" | wc -l)개 덤프 저장됨"

# ---------------------------------------------------------------- 시스템 / 보드
title "시스템 / 메인보드"
BB_VENDOR=$(sudo dmidecode -s baseboard-manufacturer 2>/dev/null)
BB_MODEL=$(sudo dmidecode -s baseboard-product-name 2>/dev/null)
BB_SN=$(sn_clean "$(sudo dmidecode -s baseboard-serial-number 2>/dev/null)")
SYS_SN=$(sn_clean "$(sudo dmidecode -s system-serial-number 2>/dev/null)")
BIOS_VER=$(sudo dmidecode -s bios-version 2>/dev/null)
kv "메인보드" "${BB_VENDOR} ${BB_MODEL}"
kv "보드 S/N"  "$BB_SN"
kv "시스템 S/N" "$SYS_SN"
kv "BIOS"      "$BIOS_VER"
add_sn "Mainboard" "${BB_VENDOR} ${BB_MODEL}" "$BB_SN" "BIOS $BIOS_VER"
[[ "$SYS_SN" != "-" ]] && add_sn "System" "chassis" "$SYS_SN"
record OK "시스템/메인보드" "${BB_MODEL} / S/N ${BB_SN}"

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
# AMD/Intel 대부분 CPU S/N 을 "Unknown" 으로 내놓는다. 그럴 땐 CPUID 를 식별자로 쓴다.
i=0
while IFS='|' read -r sock ver sn cid; do
    [[ -z "$sock" ]] && continue
    sn=$(sn_clean "$sn")
    [[ "$sn" == "-" ]] && sn="CPUID $(echo "$cid" | tr -d ' ')"
    printf '   %-22s %s\n' "S/N (${sock})" "$sn"
    add_sn "CPU" "${sock} ${ver}" "$sn"
    i=$((i+1))
done < <(sudo dmidecode -t processor 2>/dev/null | awk '
    /^Processor Information/ {sock="";ver="";sn="";cid=""}
    /^\tSocket Designation:/ {sub(/^\tSocket Designation: /,"");sock=$0}
    /^\tVersion:/ {sub(/^\tVersion: /,"");sub(/ +$/,"");ver=$0}
    /^\tID:/ {sub(/^\tID: /,"");cid=$0}
    /^\tSerial Number:/ {sub(/^\tSerial Number: /,"");sn=$0; if(sock!="") print sock"|"ver"|"sn"|"cid}')
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
        printf '   %-18s %-9s %-11s %-10s %-18s %s\n' "SLOT" "SIZE" "SPEED" "VENDOR" "PART NUMBER" "S/N"
        while IFS='|' read -r loc size spd mf pn dsn; do
            [[ -z "$loc" ]] && continue
            dsn=$(sn_clean "$dsn")
            printf '   %-18s %-9s %-11s %-10s %-18s %s\n' "$loc" "$size" "$spd" "$mf" "$pn" "$dsn"
            add_sn "DIMM" "$loc ${size} ${pn}" "$dsn"
        done < <(sudo dmidecode -t memory 2>/dev/null | awk '
          function flush(){ if (size ~ /^[0-9]/) print loc"|"size"|"spd"|"mf"|"pn"|"sn;
                            size="";loc="";spd="";pn="";mf="";sn="" }
          /^Memory Device$/ { flush() }
          /^\tSize:/ {sub(/^\tSize: /,"");size=$0}
          /^\tBank Locator:/ {sub(/^\tBank Locator: /,"");loc=$0}
          /^\tManufacturer:/ {sub(/^\tManufacturer: /,"");mf=$0}
          /^\tPart Number:/ {sub(/^\tPart Number: /,"");sub(/ +$/,"");pn=$0}
          /^\tSerial Number:/ {sub(/^\tSerial Number: /,"");sn=$0}
          /^\tConfigured Memory Speed:/ {sub(/^\tConfigured Memory Speed: /,"");spd=$0}
          END { flush() }')
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
printf '   %-12s %-9s %-24s %-22s %s\n' "NAME" "SIZE" "MODEL" "S/N" "ROTA"
while read -r n sz tp sn rota model; do
    [[ "$tp" == "disk" ]] || continue
    sn=$(sn_clean "$sn")
    [[ "$rota" == "1" ]] && rota="HDD" || rota="SSD"
    printf '   %-12s %-9s %-24s %-22s %s\n' "$n" "$sz" "${model:-?}" "$sn" "$rota"
    add_sn "Storage" "$n ${sz} ${model}" "$sn"
done < <(lsblk -dno NAME,SIZE,TYPE,SERIAL,ROTA,MODEL)
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
    printf '\n   %-4s %-46s %-16s %-16s %s\n' "IDX" "NAME" "VBIOS" "S/N" "MEMORY"
    while IFS=',' read -r i n v sn m; do
        [[ -z "$i" ]] && continue
        i=${i// /}; sn=$(sn_clean "$sn")
        printf '   %-4s %-46s %-16s %-16s %s\n' "$i" "${n# }" "${v// /}" "$sn" "${m# }"
        add_sn "GPU" "GPU${i} ${n# }" "$sn" "VBIOS ${v// /}"
    done < <(nvidia-smi --query-gpu=index,name,vbios_version,serial,memory.total --format=csv,noheader)
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
# NVIDIA GPU 는 유휴일 때 링크를 Gen1(2.5GT/s)로 내린다. 그 상태로 읽으면
# "downgraded" 로 보이므로, 측정 직전에 GPU 부하를 걸어 최대 속도로 올린 뒤 읽는다.
# (실측: 유휴 2.5GT/s → 부하 3초 만에 32GT/s)
GPULOAD_PID=""; PCIE_LOADED=0
gpu_load_start() {
    [[ "$PCIE_LOAD" -eq 1 ]] || { warn "--no-load: 유휴 상태로 측정합니다 (GPU 링크가 낮게 보일 수 있음)"; return 0; }
    local gb=""
    for c in "$SCRIPT_DIR/gadget-burn/gadget_burn" "$(command -v gadget_burn 2>/dev/null)"; do
        [[ -n "$c" && -x "$c" ]] && { gb="$c"; break; }
    done
    if [[ -z "$gb" ]]; then
        warn "gadget_burn 이 없어 부하 없이 측정합니다 → ./setup.sh 실행 후 다시 검수하세요."
        return 0
    fi
    printf '   GPU 부하 %s초 인가 중 (링크를 최대 속도로 올리기 위함): %s\n' "$PCIE_LOAD_SEC" "$gb"
    "$gb" -t "$PCIE_LOAD_SEC" > "$RAWDIR/pcie-load-burn.log" 2>&1 &
    GPULOAD_PID=$!
    # 링크 재협상 대기 (3초면 충분하지만 여유를 둔다)
    sleep 6
    PCIE_LOADED=1
    printf '   GPU util %s%%  power %sW  → 부하 인가됨\n' \
        "$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1)" \
        "$(nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits 2>/dev/null | head -1)"
}
gpu_load_stop() {
    # 주의: pkill -f gadget_burn 은 이 스크립트 자신의 명령줄까지 잡아 죽인다. PID 로만 끝낼 것.
    [[ -n "$GPULOAD_PID" ]] || return 0
    kill "$GPULOAD_PID" 2>/dev/null
    wait "$GPULOAD_PID" 2>/dev/null
    GPULOAD_PID=""
}
trap 'gpu_load_stop' EXIT INT TERM
gpu_load_start
# GPU 는 LnkSta(현재) 와 LnkCap(카드 능력)을 같이 본다.
# NOTE: 온보드 NIC 등이 x4 로 뜨는 것은 설계상 정상인 경우가 많다.
#       폭 판정은 해당 슬롯의 상위 브리지 LnkSta 로 확인할 것.
PCIE_BAD=0; PCIE_SLOW=0
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
        cur_s=$(echo "$sta_s" | grep -oP '[0-9.]+(?=GT)')
        max_s=$(echo "$cap"   | grep -oP 'Speed \K[0-9.]+(?=GT)')
        mark=""
        if [[ -n "$cur_w" && -n "$max_w" && "$cur_w" -lt "$max_w" ]]; then
            mark="  ← 폭 축소"; PCIE_BAD=$((PCIE_BAD+1))
        elif [[ -n "$cur_s" && -n "$max_s" ]] && awk -v a="$cur_s" -v b="$max_s" 'BEGIN{exit !(a<b)}'; then
            mark="  ← 속도 낮음"; PCIE_SLOW=$((PCIE_SLOW+1))
        fi
        printf '   %-12s %-40s %-22s %s%s\n' "$bdf" "$(echo "$rest" | cut -c1-40)" "${sta_s} ${sta_w}" "${cap}" "$mark"
    done < <(lspci -D 2>/dev/null | grep -iE 'nvidia|mellanox|infiniband|ethernet|raid' | sed 's/ /|/;s/|/ /' | awk '{bdf=$1; $1=""; sub(/^ /,""); print bdf, $0}')

    printf '   ※ 온보드 NIC 의 x4 는 설계상 정상인 경우가 많다. 의심되면 상위 브리지의 LnkSta 를 볼 것.\n'
    if [[ "$PCIE_BAD" -eq 0 && "$PCIE_SLOW" -eq 0 ]]; then
        ok "모든 대상 장치가 LnkCap 의 속도·폭으로 링크됨"
        record OK "PCIe 연결 상태" "폭·속도 모두 LnkCap 과 일치 (GPU 부하 인가 상태에서 측정)"
    elif [[ "$PCIE_BAD" -gt 0 ]]; then
        warn "링크 폭이 LnkCap 보다 낮은 장치 ${PCIE_BAD}개"
        record FAIL "PCIe 연결 상태" "폭 축소 ${PCIE_BAD}개 / 속도 낮음 ${PCIE_SLOW}개 — 슬롯·라이저·상위 브리지 확인"
    elif [[ "$PCIE_LOADED" -eq 0 ]]; then
        # 부하를 못 걸었으면 GPU 는 유휴 Gen1(2.5GT/s)로 내려가 있는 게 정상이다.
        # 하드웨어 불량이 아니라 측정 조건이 안 갖춰진 것이므로 그렇게 적는다.
        warn "부하를 걸지 못해 유휴 상태로 측정했습니다 → 속도 판정 불가 (장치 ${PCIE_SLOW}개)"
        record FAIL "PCIe 연결 상태" "부하 미인가 상태 측정이라 속도 판정 불가(${PCIE_SLOW}개) — ./setup.sh 로 gadget-burn 설치 후 재검수"
    else
        warn "부하 중인데도 링크 속도가 LnkCap 보다 낮은 장치 ${PCIE_SLOW}개"
        record FAIL "PCIe 연결 상태" "부하 상태에서도 속도 낮음 ${PCIE_SLOW}개 — 슬롯·라이저·BIOS Gen 설정 확인"
    fi

    # AER 에러 카운트 (SLIM 케이블/라이저 불량 조기 발견)
    AER=$(dmesg 2>/dev/null | grep -ci "pcie bus error\|no pci_dev" || true)
    kv "dmesg PCIe 에러" "${AER}건"
    [[ "${AER:-0}" -gt 0 ]] && record FAIL "PCIe 에러(dmesg)" "${AER}건 — 케이블/라이저 경로 점검 필요"
fi
gpu_load_stop

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
        sudo "$RAID_TOOL" /c0 show all > "$RAWDIR/raid-controller.txt" 2>&1
        sudo "$RAID_TOOL" /c0 show 2>/dev/null | head -30 | sed 's/^/   /'
        RAID_SN=$(sn_clean "$(grep -iE "Serial Number" "$RAWDIR/raid-controller.txt" 2>/dev/null | head -1 | awk -F'= *|: *' '{print $NF}')")
        kv "RAID S/N" "$RAID_SN"
        add_sn "RAID" "$(echo "$RAID_LIST" | head -1 | cut -d: -f3- | sed 's/^ *//' | cut -c1-48)" "$RAID_SN"
        record OK "RAID Card" "$(echo "$RAID_LIST" | head -1 | cut -c1-60) / $RAID_TOOL / S/N $RAID_SN"
    else
        warn "RAID 관리도구(storcli/perccli/MegaCli 등)가 없어 어레이 상태·S/N 을 읽지 못했습니다."
        while read -r bdf; do
            dsn=$(sudo lspci -vv -s "$bdf" 2>/dev/null | grep -i "Device Serial Number" | awk '{print $NF}' | head -1)
            add_sn "RAID" "$(lspci -s "$bdf" | cut -d: -f3- | sed 's/^ *//' | cut -c1-48)" "$(sn_clean "$dsn")" "관리도구 없음"
        done < <(echo "$RAID_LIST" | awk '{print $1}')
        record FAIL "RAID Card" "카드는 인식됨 / 관리도구 없음 — storcli 설치 후 어레이 상태·S/N 확인 필요"
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
printf '   %-16s %-7s %-10s %-18s %-18s %s\n' "IFACE" "STATE" "SPEED" "IPv4" "MAC" "BDF / DRIVER"
NET_UP=0
for i in /sys/class/net/*; do
    n=$(basename "$i")
    [[ "$n" == "lo" ]] && continue
    st=$(cat "$i/operstate" 2>/dev/null)
    sp=$(cat "$i/speed" 2>/dev/null); [[ -n "$sp" && "$sp" != "-1" ]] && sp="${sp}Mb/s" || sp="-"
    ip4=$(ip -4 -o addr show "$n" 2>/dev/null | awk '{print $4}' | head -1)
    mac=$(cat "$i/address" 2>/dev/null)
    bdf=$(basename "$(readlink -f "$i/device" 2>/dev/null)" 2>/dev/null)
    drv=$(basename "$(readlink -f "$i/device/driver" 2>/dev/null)" 2>/dev/null)
    printf '   %-16s %-7s %-10s %-18s %-18s %s\n' "$n" "${st:-?}" "$sp" "${ip4:--}" "$mac" "${bdf:-?} / ${drv:-?}"
    [[ "$st" == "up" ]] && NET_UP=$((NET_UP+1))

    # NIC 는 S/N 을 노출하지 않는 경우가 대부분이다.
    #   1순위 PCIe Device Serial Number(DSN) — Mellanox 등 일부만 제공
    #   2순위 고정 MAC(ethtool -P) — 실무상 NIC 고유 식별자로 쓴다
    # USB NIC(BMC 가상 이더넷, gadget 등)은 BDF 가 "7-6.3:2.0" 처럼 생겨서
    # 느슨한 패턴에 걸린다. 장착 부품만 세도록 PCI BDF 형식을 정확히 본다.
    if [[ "$bdf" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9]$ ]]; then
            dsn=$(sudo lspci -vv -s "$bdf" 2>/dev/null | grep -i "Device Serial Number" | awk '{print $NF}' | head -1)
            pmac=$(ethtool -P "$n" 2>/dev/null | awk '{print $NF}')
            fw=$(ethtool -i "$n" 2>/dev/null | awk -F': ' '/^firmware-version/{print $2}')
            model=$(lspci -s "$bdf" 2>/dev/null | cut -d: -f3- | sed 's/^ *//' | cut -c1-48)
            sn=$(sn_clean "${dsn:-$pmac}")
            # DSN 은 카드 단위라 듀얼포트 카드의 두 포트가 같은 값을 갖는다(정상).
            if [[ -n "$dsn" ]]; then src="PCIe DSN(카드 공통)"; else src="고정MAC"; fi
            note="$src"; [[ -n "$fw" ]] && note="$note / fw $fw"
            add_sn "NIC" "${n} (${sp}) ${model}" "$sn" "$note"
    fi
done

# Mellanox/IB 카드는 node_guid·board_id 가 사실상의 고유 식별자다.
for d in /sys/class/infiniband/*; do
    [[ -d "$d" ]] || continue
    ca=$(basename "$d")
    add_sn "IB/HCA" "$ca $(cat "$d/board_id" 2>/dev/null)" \
           "$(cat "$d/node_guid" 2>/dev/null)" "fw $(cat "$d/fw_ver" 2>/dev/null) (node_guid)"
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

# ---------------------------------------------------------------- 구성품 S/N
title "구성품 S/N  (검수확인서용)"
if [[ ${#SERIALS[@]} -eq 0 ]]; then
    warn "수집된 S/N 이 없습니다."
    record FAIL "구성품 S/N" "수집 실패"
else
    printf '   %-10s %-50s %-24s %s\n' "분류" "식별자" "S/N" "비고"
    printf '   %-10s %-50s %-24s %s\n' "----------" "--------------------------------------------------" "------------------------" "--------"
    printf 'category,item,serial,note\n' > "$SN_CSV"
    SN_MISS=0
    for line in "${SERIALS[@]}"; do
        IFS='|' read -r cat item sn note <<< "$line"
        [[ "$sn" == "-" ]] && SN_MISS=$((SN_MISS+1))
        printf '   %-10s %-50s %-24s %s\n' "$cat" "$(echo "$item" | cut -c1-50)" "$sn" "$note"
        # CSV: 쉼표가 든 값은 큰따옴표로 감싼다
        printf '"%s","%s","%s","%s"\n' "${cat//\"/\"\"}" "${item//\"/\"\"}" "${sn//\"/\"\"}" "${note//\"/\"\"}" >> "$SN_CSV"
    done
    printf '\n   총 %d개 항목 / S/N 미제공 %d개  →  %s\n' "${#SERIALS[@]}" "$SN_MISS" "$SN_CSV"
    if [[ "$SN_MISS" -eq 0 ]]; then
        record OK "구성품 S/N" "${#SERIALS[@]}개 전부 수집 — serials.csv"
    else
        # CPU S/N 처럼 하드웨어가 아예 안 내놓는 값도 있어 실패로 보지 않는다.
        record OK "구성품 S/N" "${#SERIALS[@]}개 중 ${SN_MISS}개는 S/N 미제공(하드웨어가 노출 안 함) — serials.csv"
    fi
fi

# ================================================================
#  PART 2 — 서버 설정
# ================================================================
printf '\n\033[1;35m'
hr; printf ' PART 2.  서버 설정 확인   (변경은 ./setup.sh 가 한다)\n'; hr
printf '\033[0m'

# ---------------------------------------------------------------- Time Zone
title "Time Zone"
TZ_NOW=$(timedatectl show -p Timezone --value 2>/dev/null)
kv "현재" "$TZ_NOW"
kv "NTP 동기화" "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
if [[ "$TZ_NOW" == "$TZ_WANT" ]]; then
    ok "Time Zone: $TZ_NOW"
    record OK "Time Zone" "$TZ_NOW"
else
    err "Time Zone 이 $TZ_WANT 가 아닙니다 (현재 $TZ_NOW) → ./setup.sh"
    record FAIL "Time Zone" "$TZ_NOW — $TZ_WANT 아님, ./setup.sh 실행 필요"
fi

# ---------------------------------------------------------------- 전원관리
title "전원관리 서비스 비활성화"
SLEEP_TARGETS=(sleep.target suspend.target hibernate.target hybrid-sleep.target)
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
    err "sleep.target 이 masked 가 아닙니다 → ./setup.sh"
    record FAIL "전원관리(sleep/suspend)" "masked 아님 — ./setup.sh 실행 필요"
fi

if have powerprofilesctl; then
    PP=$(powerprofilesctl get 2>/dev/null)
    kv "power profile" "${PP:-?}"
    if [[ "$PP" == performance ]]; then
        record OK "전원 프로파일" "performance"
    else
        record FAIL "전원 프로파일" "현재=${PP:-unknown} — performance 아님, ./setup.sh 실행 필요"
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
    en=$(systemctl is-enabled "$u" 2>/dev/null); en=${en:-not-found}
    ac=$(systemctl is-active  "$u" 2>/dev/null); ac=${ac:-inactive}
    printf '   %-30s enabled=%-10s active=%s\n' "$u" "$en" "$ac"
    if [[ "$en" == masked ]]; then
        record OK "자동업데이트: $u" "masked"
    else
        record FAIL "자동업데이트: $u" "enabled=$en — masked 아님, ./setup.sh 실행 필요"
    fi
done
printf '   해제하려면: sudo systemctl unmask %s\n' "${AUTOUPD_UNITS[*]}"

# ---------------------------------------------------------------- Persistence Mode
title "NVIDIA Persistence Mode"
if have nvidia-smi; then
    PM_STATE=$(nvidia-smi -q 2>/dev/null | grep -i "Persistence Mode" | head -1 | awk -F': ' '{print $2}')
    SVC=$(systemctl is-enabled nvidia-pm.service 2>/dev/null); SVC=${SVC:-not-found}
    kv "Persistence Mode" "${PM_STATE:-unknown}"
    kv "nvidia-pm.service" "$SVC"
    if [[ "$PM_STATE" == *Enabled* && "$SVC" == enabled ]]; then
        record OK "NVIDIA Persistence Mode" "Enabled / 서비스 등록됨 (재부팅 후 유지)"
    else
        err "Persistence Mode 미설정 → ./setup.sh"
        record FAIL "NVIDIA Persistence Mode" "state=${PM_STATE:-unknown} service=$SVC — ./setup.sh 실행 필요"
    fi
else
    record SKIP "NVIDIA Persistence Mode" "nvidia-smi 없음"
fi

# ---------------------------------------------------------------- ACS
title "OS ACS Disable"
# ACS 가 켜져 있으면 PCIe P2P 트래픽이 루트 컴플렉스로 우회돼 GPUDirect/NCCL
# 성능이 크게 떨어진다. 비활성화는 setup.sh 가 disable-acs.service 로 등록한다.
if ! have setpci || ! have lspci; then
    record SKIP "OS ACS Disable" "pciutils 없음 — ./setup.sh 실행 필요"
else
    ACS_ON=$(sudo lspci -vvv 2>/dev/null | grep ACSCtl | grep -c 'SrcValid+' || true)
    SVC=$(systemctl is-enabled disable-acs.service 2>/dev/null); SVC=${SVC:-not-found}
    kv "ACSCtl SrcValid+" "${ACS_ON:-0}개  (0이어야 정상)"
    kv "disable-acs.service" "$SVC"
    if [[ "${ACS_ON:-1}" -eq 0 && "$SVC" == enabled ]]; then
        record OK "OS ACS Disable" "SrcValid+ 0개 / 서비스 등록됨"
    elif [[ "${ACS_ON:-1}" -ne 0 ]]; then
        err "ACS 가 켜진 장치 ${ACS_ON}개 — ./setup.sh 실행, 그래도 남으면 BIOS 에서 VT-d(AMD-V)/ACS Control Disabled"
        record FAIL "OS ACS Disable" "SrcValid+ ${ACS_ON}개 남음 — ./setup.sh 또는 BIOS 설정 필요"
    else
        err "SrcValid+ 는 0개이나 disable-acs.service 가 $SVC — 재부팅하면 되살아납니다"
        record FAIL "OS ACS Disable" "서비스=$SVC — ./setup.sh 실행 필요"
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
printf '  결과 : %s\n' "$OUTDIR"
printf '           inspect.log  /  serials.csv  /  raw/\n'
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
