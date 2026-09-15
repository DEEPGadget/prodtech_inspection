#!/usr/bin/env bash
#
# sample-sensors.sh — GPU/CPU/NVMe 온도를 CSV 로 바로 기록한다.
#
#   사용법: sample-sensors.sh <간격(초)> <지속(초)> <출력.csv>
#
# 구 gpu-cpu.sh + make-csv.sh 를 대체한다. 중간 txt 를 만들지 않으므로
# 파싱 단계가 없어지고, 컬럼 수가 헤더와 어긋날 일도 없다.
# GPU 는 index 가 아니라 PCI address 로 식별한다 (슬롯을 바로 알 수 있게).
#
# NVMe 온도 수집에 root 가 필요하다 (nvme smart-log).

set -uo pipefail

INTERVAL=${1:?사용법: $0 <간격> <지속> <출력.csv>}
DURATION=${2:?사용법: $0 <간격> <지속> <출력.csv>}
OUT=${3:?사용법: $0 <간격> <지속> <출력.csv>}

# ---------------------------------------------------------------- 구성 파악 (1회)
# GPU: index + PCI address
GPU_IDX=(); GPU_BDF=()
if command -v nvidia-smi >/dev/null 2>&1; then
    while IFS=',' read -r i bdf; do
        [[ -z "$i" ]] && continue
        GPU_IDX+=("${i// /}")
        # nvidia-smi 는 "00000000:C1:00.0" 로 주므로 lspci 표기 "0000:c1:00.0" 로 맞춘다
        bdf=$(echo "$bdf" | tr -d ' ' | tr 'A-F' 'a-f')
        GPU_BDF+=("${bdf: -12}")
    done < <(nvidia-smi --query-gpu=index,pci.bus_id --format=csv,noheader 2>/dev/null)
fi

# 쓰로틀 사유 필드 이름은 드라이버에 따라 clocks_throttle_reasons.* / clocks_event_reasons.*
# (잘못된 필드가 하나라도 섞이면 nvidia-smi 조회 전체가 실패하므로 미리 확인)
TR=clocks_throttle_reasons
if [[ ${#GPU_IDX[@]} -gt 0 ]] && ! nvidia-smi --query-gpu=$TR.hw_power_brake_slowdown --format=csv,noheader >/dev/null 2>&1; then
    TR=clocks_event_reasons
fi

# CPU: 소켓별 온도 센서 라벨 (AMD=Tctl, Intel=Package id N)
mapfile -t CPU_LABEL < <(sensors 2>/dev/null | grep -oE '^(Tctl|Package id [0-9]+):' | sed 's/:$//')
[[ ${#CPU_LABEL[@]} -eq 0 ]] && CPU_LABEL=("CPU")

# NVMe 컨트롤러 목록
NVME_DEV=()
for d in /dev/nvme[0-9]*; do
    [[ "$d" =~ ^/dev/nvme[0-9]+$ ]] && NVME_DEV+=("$d")
done

# ---------------------------------------------------------------- 헤더
{
    printf 'Timestamp,Elapsed(s),Memory_Used(MB)'
    for d in "${NVME_DEV[@]}"; do printf ',%s_Temp(C)' "$(basename "$d")"; done
    for ((c=0; c<${#CPU_LABEL[@]}; c++)); do
        printf ',CPU%d_%s(C)' "$c" "$(echo "${CPU_LABEL[$c]}" | tr ' ' '_')"
    done
    # _Throttle 값: 0 없음 / THERM 열 쓰로틀 / PWR HW Power Brake
    for ((g=0; g<${#GPU_IDX[@]}; g++)); do
        printf ',GPU%s_%s_Temp(C),GPU%s_%s_Power(W),GPU%s_%s_Util(%%),GPU%s_%s_Throttle' \
            "${GPU_IDX[$g]}" "${GPU_BDF[$g]}" \
            "${GPU_IDX[$g]}" "${GPU_BDF[$g]}" \
            "${GPU_IDX[$g]}" "${GPU_BDF[$g]}" \
            "${GPU_IDX[$g]}" "${GPU_BDF[$g]}"
    done
    printf '\n'
} > "$OUT"

# ---------------------------------------------------------------- 수집 루프
START=$SECONDS
END=$((SECONDS + DURATION))

while [ $SECONDS -lt $END ]; do
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    el=$((SECONDS - START))
    mem=$(free -m | awk '/^Mem:/ {print $3}')

    row="$ts,$el,$mem"

    for d in "${NVME_DEV[@]}"; do
        t=$(nvme smart-log "$d" 2>/dev/null | awk '/^temperature/{print $3; exit}')
        row+=",${t:-}"
    done

    # sensors 1회 호출로 전 소켓 온도
    mapfile -t ctemps < <(sensors 2>/dev/null | grep -oE '^(Tctl|Package id [0-9]+): +\+[0-9.]+' | grep -oE '\+[0-9.]+' | tr -d '+')
    for ((c=0; c<${#CPU_LABEL[@]}; c++)); do row+=",${ctemps[$c]:-}"; done

    # nvidia-smi 1회 호출로 전 GPU
    if [[ ${#GPU_IDX[@]} -gt 0 ]]; then
        mapfile -t gq < <(nvidia-smi \
            --query-gpu=temperature.gpu,power.draw,utilization.gpu,$TR.sw_thermal_slowdown,$TR.hw_thermal_slowdown,$TR.hw_power_brake_slowdown \
            --format=csv,noheader,nounits 2>/dev/null)
        for ((g=0; g<${#GPU_IDX[@]}; g++)); do
            IFS=',' read -r gt gp gu swt hwt pwb <<< "${gq[$g]:-,,,,,}"
            # gadget-burn 과 같은 기준: 열(SW/HW Thermal Slowdown) > HW Power Brake.
            # SW Power Cap 은 TDP 를 다 쓰는 정상 상태라 보지 않는다.
            # "Not Active" 가 " Active" 를 포함하므로 공백 제거 후 정확히 비교할 것
            swt=${swt// /}; hwt=${hwt// /}; pwb=${pwb// /}
            if [[ "$swt" == "Active" || "$hwt" == "Active" ]]; then gc=THERM
            elif [[ "$pwb" == "Active" ]]; then gc=PWR
            else gc=0; fi
            row+=",$(echo "$gt" | tr -d ' '),$(echo "$gp" | tr -d ' '),$(echo "$gu" | tr -d ' '),$gc"
        done
    fi

    echo "$row" >> "$OUT"
    sleep "$INTERVAL"
done
