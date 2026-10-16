#!/usr/bin/env bash
#
# functest.sh — 기능 테스트
#
#   1) gadget-burn 준비 : 소스를 찾아(없으면 clone) make clean && make 로 새로 빌드한다
#                         CUDA 가 없거나 버전이 안 맞으면 안내만 하고, 기존 빌드본이 있으면 그걸로 간다
#   2) GPU 상태         : ECC 카운터, nvidia-smi topo -m, NVLink 링크 상태/에러를 저장·판정한다
#                         (번인이 끝난 뒤 ECC 를 다시 읽어 늘어난 게 있는지 비교)
#   3) HW 정보          : inspect.sh 의 하드웨어 점검(PART 1)만 돌린다
#   4) GPU 번인         : 기본 5분 (검수용 1시간 번인과 구분). CPU stress 는 걸지 않는다
#                         (run-burnin.sh --no-cpu). CPU 온도는 그대로 기록된다.
#   옵션) 메모리 부하   : --mem 을 주면 번인에 메모리 스트레스를 함께 건다
#
# 서버 설정은 건드리지 않는다 — 그건 setup.sh 담당이다.
# 검수(설정 확인 포함)는 inspect.sh, 1시간 번인은 run-burnin.sh 를 쓴다.
#
# 사용법:
#   ./functest.sh                    # GPU 상태 + HW 정보 + GPU 5분 번인
#   ./functest.sh --mem              # + 메모리 부하 (기본 전체 RAM 의 80%)
#   ./functest.sh --mem 50%          # 메모리 부하량 지정 (% 또는 4G 같은 절대값)
#   ./functest.sh --time 600         # 번인 시간(초) 변경
#   ./functest.sh --no-hw            # HW 정보 생략 (GPU 상태 + 번인)
#   ./functest.sh --no-build         # make clean && make 생략 (있는 바이너리 그대로)
#   ./functest.sh --burn-dir ~/x/gadget-burn   # gadget-burn 소스/빌드 디렉터리를 직접 지정
#
# gadget-burn 소스는 --burn-dir → <저장소>/gadget-burn → ~/gadget-burn 순으로 찾고,
# 둘 다 없으면 <저장소>/gadget-burn 에 clone 한다(setup.sh 가 빌드하는 위치와 같다).
# 빌드된 gadget_burn 은 lib/find-gadget-burn.sh 가 같은 순서로 찾는다.
#
# 결과는 실행한 디렉터리 아래 functest_<host>_<시각>/ 에 모인다.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
DUR=300
DO_HW=1
MEM_LOAD=0
MEM_SIZE="80%"
INTERVAL=5
DO_BUILD=1
GB_URL=${GB_URL:-https://github.com/DEEPGadget/gadget-burn.git}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --time) shift; DUR=${1:?--time 뒤에 초를 주세요} ;;
        --mem)
            MEM_LOAD=1
            # 다음 인자가 옵션이 아니면 부하량으로 받는다
            if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then shift; MEM_SIZE="$1"; fi ;;
        --no-hw) DO_HW=0 ;;
        --interval) shift; INTERVAL=${1:-5} ;;
        --burn-dir) shift; BURN_DIR=${1:?--burn-dir 뒤에 경로를 주세요} ;;
        --no-build) DO_BUILD=0 ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "알 수 없는 옵션: $1" >&2; exit 1 ;;
    esac
    shift
done

HOSTN=$(hostname)
STAMP=$(date +%Y%m%d_%H%M%S)
OUT="$PWD/functest_${HOSTN}_${STAMP}"
mkdir -p "$OUT" || { echo "결과 디렉터리를 만들 수 없습니다: $OUT" >&2; exit 1; }

C_C=$'\033[1;36m'; C_B=$'\033[1m'; C_RST=$'\033[0m'; C_D=$'\033[2m'; C_Y=$'\033[1;33m'; C_R=$'\033[1;31m'; C_G=$'\033[1;32m'
hr() { printf '%s\n' "────────────────────────────────────────────────────────────────────────────────"; }
note() { printf '   %s%s%s\n' "$C_Y" "$*" "$C_RST"; }       # 안내(조치는 사용자가)
bad()  { printf '   %s%s%s\n' "$C_R" "$*" "$C_RST"; }

hr
printf ' %sDEEPGadget 기능 테스트%s  —  %s\n' "$C_C" "$C_RST" "$HOSTN"
printf '   HW 정보    : %s\n' "$([ "$DO_HW" -eq 1 ] && echo '수집' || echo '생략 (--no-hw)')"
printf '   번인       : GPU %s초 (CPU stress 없음)\n' "$DUR"
printf '   메모리 부하: %s\n' "$([ "$MEM_LOAD" -eq 1 ] && echo "$MEM_SIZE" || echo '없음 (--mem 으로 켬)')"
printf '   빌드       : %s\n' "$([ "$DO_BUILD" -eq 1 ] && echo 'make clean && make' || echo '생략 (--no-build)')"
printf '   결과경로   : %s\n' "$OUT"
hr

# ---------------------------------------------------------------- 1) gadget-burn 준비
# 소스 디렉터리: --burn-dir → <저장소>/gadget-burn → ~/gadget-burn → (둘 다 없으면) <저장소>/gadget-burn 에 clone.
# 번인 전에 항상 make clean && make 로 다시 빌드한다(드라이버/CUDA 가 바뀐 서버에서 옛 바이너리로 도는 사고 방지).
# CUDA 가 없거나 버전이 안 맞으면 고치려 들지 않고 안내만 한다. 기존 빌드본이 있으면 그걸로 계속 간다.
printf '\n%s[1/4] gadget-burn 준비%s\n' "$C_B" "$C_RST"
GB_SRC=""
if [[ -n "${BURN_DIR:-}" ]]; then
    GB_SRC=$BURN_DIR; [[ -f "$GB_SRC" ]] && GB_SRC=$(dirname "$GB_SRC")     # 실행파일 경로를 줬으면 그 디렉터리
    GB_SRC=$(cd "$GB_SRC" 2>/dev/null && pwd) || { bad "--burn-dir 경로가 없습니다: $BURN_DIR"; exit 1; }
    printf '   소스       : %s  (--burn-dir)\n' "$GB_SRC"
elif [[ -d "$SCRIPT_DIR/gadget-burn" ]]; then
    GB_SRC="$SCRIPT_DIR/gadget-burn";  printf '   소스       : %s\n' "$GB_SRC"
elif [[ -d "$HOME/gadget-burn" ]]; then
    GB_SRC="$HOME/gadget-burn";        printf '   소스       : %s\n' "$GB_SRC"
else
    GB_SRC="$SCRIPT_DIR/gadget-burn"
    printf '   소스       : %s 에도 %s 에도 없음 → clone\n' "$SCRIPT_DIR/gadget-burn" "$HOME/gadget-burn"
    printf '                %s\n' "$GB_URL"
    if git clone "$GB_URL" "$GB_SRC" > "$OUT/gadget-burn-clone.log" 2>&1; then
        printf '   %sclone 완료%s: %s\n' "$C_G" "$C_RST" "$(git -C "$GB_SRC" log -1 --format='%h %cs' 2>/dev/null)"
    else
        bad "clone 실패 — 네트워크/GitHub 접근을 확인하세요. 로그: $OUT/gadget-burn-clone.log"
        tail -3 "$OUT/gadget-burn-clone.log" | sed 's/^/     /'
        note "다른 PC 에서 받아 서버의 $SCRIPT_DIR/gadget-burn 또는 ~/gadget-burn 에 두고 다시 실행하면 됩니다."
        exit 1
    fi
fi

BUILD_LOG="$OUT/gadget-burn-build.log"
if [[ "$DO_BUILD" -eq 1 ]]; then
    if [[ ! -f "$GB_SRC/Makefile" ]]; then
        note "Makefile 이 없어 빌드를 건너뜁니다 (바이너리만 복사해 둔 폴더): $GB_SRC"
    else
        # nvcc: PATH → $CUDA_HOME/bin → /usr/local/cuda/bin (Rocky 등은 PATH 에 없는 경우가 많다)
        NVCC_BIN=$(command -v nvcc 2>/dev/null)
        for c in "${CUDA_HOME:-}/bin/nvcc" /usr/local/cuda/bin/nvcc; do
            [[ -z "$NVCC_BIN" && -x "$c" ]] && NVCC_BIN=$c
        done
        DRV_CUDA=$(nvidia-smi 2>/dev/null | grep -oP 'CUDA (UMD )?Version: \K[0-9.]+' | head -1)
        if [[ -z "$NVCC_BIN" ]]; then
            note "[안내] CUDA 툴킷(nvcc)이 없어 빌드할 수 없습니다. 찾아본 곳: PATH, \${CUDA_HOME}/bin, /usr/local/cuda/bin"
            [[ -n "$DRV_CUDA" ]] && note "       드라이버가 지원하는 CUDA 는 ${DRV_CUDA} 입니다 → 그 이하 버전의 CUDA 툴킷을 설치하면 됩니다."
            note "       이 스크립트는 설치하지 않습니다. 설치 후 다시 실행하거나, 빌드본이 있으면 --no-build 로 그대로 씁니다."
        else
            NVCC_VER=$("$NVCC_BIN" --version 2>/dev/null | grep -oP 'release \K[0-9]+\.[0-9]+' | head -1)
            printf '   nvcc       : %s (CUDA %s)   드라이버 지원 CUDA: %s\n' "$NVCC_BIN" "${NVCC_VER:-?}" "${DRV_CUDA:-?}"
            if [[ -n "$NVCC_VER" && -n "$DRV_CUDA" ]] && [[ "$(printf '%s\n%s\n' "$NVCC_VER" "$DRV_CUDA" | sort -V | tail -1)" != "$DRV_CUDA" ]]; then
                note "[안내] nvcc(CUDA ${NVCC_VER})가 드라이버가 지원하는 CUDA(${DRV_CUDA})보다 높습니다."
                note "       빌드는 되더라도 실행 시 'CUDA driver version is insufficient' 로 죽을 수 있습니다."
                note "       → 드라이버를 올리거나 CUDA ${DRV_CUDA} 이하 툴킷으로 빌드하세요. (이 스크립트는 바꾸지 않습니다)"
            fi
            # make clean 이 기존 바이너리를 지우므로, 빌드가 실패하면 되돌릴 수 있게 잠시 보관한다
            [[ -x "$GB_SRC/gadget_burn" ]] && cp -p "$GB_SRC/gadget_burn" "$GB_SRC/.gadget_burn.prev"
            printf '   빌드       : make -C %s clean && make  (로그: %s)\n' "$GB_SRC" "$BUILD_LOG"
            if make -C "$GB_SRC" clean > "$BUILD_LOG" 2>&1 && make -C "$GB_SRC" NVCC="$NVCC_BIN" >> "$BUILD_LOG" 2>&1 \
               && [[ -x "$GB_SRC/gadget_burn" ]]; then
                printf '   %s빌드 완료%s  : %s\n' "$C_G" "$C_RST" "$GB_SRC/gadget_burn"
                rm -f "$GB_SRC/.gadget_burn.prev"
            else
                bad "빌드 실패 — 로그 마지막 줄:"
                grep -vE '^\s*$' "$BUILD_LOG" | tail -6 | cut -c1-110 | sed 's/^/     /'
                if grep -qi "Unsupported gpu architecture" "$BUILD_LOG"; then
                    note "[안내] nvcc ${NVCC_VER:-?} 가 이 GPU 의 아키텍처를 모릅니다 → 더 높은 CUDA 툴킷이 필요합니다 (예: Blackwell 은 12.8+)."
                elif grep -qiE "cannot find -lnvidia-ml|nvidia-ml" "$BUILD_LOG"; then
                    note "[안내] libnvidia-ml 을 못 찾습니다 → NVIDIA 드라이버(또는 CUDA 툴킷의 stubs) 경로 확인."
                elif grep -qiE "cublas" "$BUILD_LOG"; then
                    note "[안내] cuBLAS 를 못 찾습니다 → CUDA 툴킷이 불완전하게 설치됐습니다."
                else
                    note "[안내] CUDA/드라이버 구성을 확인하세요. 이 스크립트는 설치·변경하지 않습니다."
                fi
                if [[ -f "$GB_SRC/.gadget_burn.prev" ]]; then
                    mv -f "$GB_SRC/.gadget_burn.prev" "$GB_SRC/gadget_burn"
                    note "       기존 빌드본을 되돌려 그걸로 계속 진행합니다: $GB_SRC/gadget_burn"
                fi
            fi
        fi
    fi
fi

# 빌드된 실행파일 확인 (탐색 순서는 lib/find-gadget-burn.sh 와 같다). inspect/run-burnin 에도 같은 경로가 가게 BURN_DIR 로 넘긴다.
export BURN_DIR="$GB_SRC"
if [[ -x "$SCRIPT_DIR/lib/find-gadget-burn.sh" ]]; then
    GB=$("$SCRIPT_DIR/lib/find-gadget-burn.sh" "$SCRIPT_DIR" "$HOME") || { bad "gadget_burn 실행파일이 없어 번인을 할 수 없습니다 — 위 안내대로 CUDA 를 갖춘 뒤 다시 실행하세요."; exit 1; }
else
    GB="$GB_SRC/gadget_burn"; [[ -x "$GB" ]] || { bad "gadget_burn 실행파일이 없습니다: $GB"; exit 1; }
fi
printf '   사용할 바이너리: %s\n' "$GB"

# ---------------------------------------------------------------- 2) GPU 상태 (ECC / topo / NVLink)
# 번인 전에 ECC 카운터·PCIe/NVLink 토폴로지·NVLink 링크 상태를 저장하고, 번인이 끝난 뒤
# ECC 를 한 번 더 읽어 늘어난 게 있는지 본다. 설정은 바꾸지 않는다.
#   ECC    : uncorrected(volatile/aggregate) > 0, row remap uncorrectable/pending/failure > 0 → 확인 필요
#            ECC 미지원·비활성([N/A]/Disabled) 카드는 카운터가 없으니 표시만 한다
#   topo   : nvidia-smi topo -m 를 그대로 저장·출력하고 GPU 쌍 중 NVLink(NV#) 로 묶인 수를 요약
#   NVLink : nvlink -s 에 Link 줄이 하나도 없으면 미지원/미장착 → 건너뜀
#            한 GPU 에 active 와 inactive 링크가 섞이거나 GPU 마다 active 수가 다르면 브리지 접촉 불량 의심
#            nvlink -e 의 에러 카운터(Replay/Recovery/CRC) > 0 → 확인 필요
GPU_RC=0
GPUDIR="$OUT/gpu"
ECC_FIELDS=index,name,ecc.mode.current,ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.volatile.total,ecc.errors.corrected.aggregate.total,ecc.errors.uncorrected.aggregate.total

# $1 = 저장 파일. 한 줄 = idx,name,mode,corr_vol,unc_vol,corr_agg,unc_agg,remap_corr,remap_unc,remap_pending,remap_fail
ecc_snapshot() {
    local f=$1
    nvidia-smi --query-gpu=$ECC_FIELDS --format=csv,noheader 2>/dev/null | sed 's/, /,/g' > "$f.ecc" || : > "$f.ecc"
    # row remapping(Ampere 이후) → 없으면 retired pages(Volta/Turing, failure 칸은 0) → 둘 다 없으면 빈칸
    if ! nvidia-smi --query-gpu=index,remapped_rows.correctable,remapped_rows.uncorrectable,remapped_rows.pending,remapped_rows.failure \
            --format=csv,noheader 2>/dev/null | sed 's/, /,/g' > "$f.remap"; then
        nvidia-smi --query-gpu=index,retired_pages.sbe,retired_pages.dbe,retired_pages.pending --format=csv,noheader 2>/dev/null \
            | sed 's/, /,/g' | awk -F, '{print $1","$2","$3","$4",0"}' > "$f.remap" || : > "$f.remap"
    fi
    # (remap 파일이 비어 있을 수 있어 NR==FNR 대신 FILENAME 으로 구분)
    awk -F, 'FILENAME == ARGV[1] { sub(/^[^,]*/, "", $0); r[FNR]=$0; next } { print $0 r[FNR] }' "$f.remap" "$f.ecc" > "$f"
    rm -f "$f.ecc" "$f.remap"
}
gt0() { [[ "$1" =~ ^[0-9]+$ && "$1" -gt 0 ]]; }

# $1 = 스냅샷 파일. 표를 찍고 이상이 있으면 GPU_RC=1
ecc_report() {
    local f=$1 idx name mode cv uv ca ua rc ru rp rf why
    printf '   %-3s %-26s %-9s %9s %9s %9s %9s %8s %8s %8s\n' GPU NAME ECC corr_vol unc_vol corr_agg unc_agg remap_u remap_p remap_f
    while IFS=, read -r idx name mode cv uv ca ua rc ru rp rf; do
        why=""
        gt0 "$uv" && why="uncorrected(volatile) $uv"
        gt0 "$ua" && why="${why:+$why, }uncorrected(aggregate) $ua"
        gt0 "$ru" && why="${why:+$why, }remap uncorrectable $ru"
        gt0 "$rp" && why="${why:+$why, }remap pending $rp"
        gt0 "$rf" && why="${why:+$why, }remap FAILURE $rf"
        printf '   %-3s %-26.26s %-9s %9s %9s %9s %9s %8s %8s %8s' "$idx" "$name" "${mode:--}" "${cv:--}" "${uv:--}" "${ca:--}" "${ua:--}" "${ru:--}" "${rp:--}" "${rf:--}"
        if [[ -n "$why" ]]; then printf '  %s← %s%s\n' "$C_R" "$why" "$C_RST"; GPU_RC=1; else printf '\n'; fi
    done < "$f"
}

if ! command -v nvidia-smi >/dev/null 2>&1; then
    printf '\n%s[2/4] GPU 상태 (ECC / topo / NVLink)%s\n' "$C_B" "$C_RST"
    note "nvidia-smi 없음 → 건너뜀"
else
    mkdir -p "$GPUDIR"
    printf '\n%s[2/4] GPU 상태 (ECC / topo / NVLink)%s  → %s\n' "$C_B" "$C_RST" "$GPUDIR"

    # ---- GPU 목록 (한 번의 --query-gpu 로 S/N·UUID·BDF·VBIOS·온도·PCIe·ECC 집계)
    # pcie.link.gen.gpucurrent 는 최근 드라이버 필드 — 없는 드라이버면 pcie.link.gen.current 로 대체.
    # (필드 하나라도 모르면 조회 전체가 실패하므로 두 세트를 차례로 시도)
    printf '   %sGPU 목록%s\n' "$C_B" "$C_RST"
    GPU_LIST_OK=0
    for gen_cur in pcie.link.gen.gpucurrent pcie.link.gen.current; do
        GPU_FIELDS=index,name,serial,uuid,pci.bus_id,vbios_version,temperature.gpu,$gen_cur,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max,ecc.errors.uncorrected.aggregate.total
        if nvidia-smi --query-gpu=$GPU_FIELDS --format=csv,noheader 2>/dev/null | sed 's/, /,/g' > "$GPUDIR/gpu_list.csv" \
           && [[ -s "$GPUDIR/gpu_list.csv" ]]; then GPU_LIST_OK=1; break; fi
    done
    if [[ "$GPU_LIST_OK" -eq 1 ]]; then
        printf '   %-3s %-26s %-14s %-40s %-16s %-16s %5s %7s %7s %s\n' GPU NAME SERIAL UUID BUS_ID VBIOS TEMP PCIeGen Width ECC_unc_agg
        while IFS=, read -r idx name serial uuid bus vbios temp gcur gmax wcur wmax ua; do
            printf '   %-3s %-26.26s %-14s %-40s %-16s %-16s %4s℃ %3s/%-3s %3s/%-3s %s' \
                "$idx" "$name" "$serial" "$uuid" "$bus" "$vbios" "$temp" "$gcur" "$gmax" "$wcur" "$wmax" "$ua"
            if gt0 "$ua"; then printf '  %s← uncorrected(aggregate) %s%s\n' "$C_R" "$ua" "$C_RST"; else printf '\n'; fi
        done < "$GPUDIR/gpu_list.csv"
        printf '   ※ PCIe current 는 idle 이면 gen/폭이 낮게 나올 수 있다 — 부하 중 판정은 HW 정보 단계의 "PCIe 연결 상태" 표를 볼 것\n'
    else
        note "GPU 목록 조회 실패 (nvidia-smi --query-gpu)"
    fi

    # ---- ECC (번인 전)
    printf '   %sECC (번인 전)%s\n' "$C_B" "$C_RST"
    ecc_snapshot "$GPUDIR/ecc_before.csv"
    if [[ -s "$GPUDIR/ecc_before.csv" ]]; then
        ecc_report "$GPUDIR/ecc_before.csv"
        if ! grep -q ',Enabled,' "$GPUDIR/ecc_before.csv"; then
            note "ECC 가 켜진 GPU 가 없습니다(미지원 또는 Disabled) — 카운터 판정 없이 표시만 합니다"
        fi
    else
        note "ECC 조회 실패 (nvidia-smi --query-gpu 가 값을 주지 않음)"
    fi

    # ---- topo
    printf '   %snvidia-smi topo -m%s\n' "$C_B" "$C_RST"
    if nvidia-smi topo -m > "$GPUDIR/topo.txt" 2>&1; then
        # 매트릭스만 보여준다(범례는 파일에). GPU 쌍 중 NV# 로 묶인 수 = NV 셀 수 / 2
        awk 'NF==0 {exit} {print}' "$GPUDIR/topo.txt" | sed 's/^/     /'
        NV_PAIRS=$(awk '/^GPU[0-9]+/ { for (i=2; i<=NF; i++) if ($i ~ /^NV[0-9]+$/) c++ } END { print int(c/2) }' "$GPUDIR/topo.txt")
        printf '   NVLink 로 묶인 GPU 쌍: %s개  (범례는 %s)\n' "${NV_PAIRS:-0}" "$GPUDIR/topo.txt"
    else
        note "topo -m 실패: $(head -1 "$GPUDIR/topo.txt")"
    fi

    # ---- NVLink 링크 상태 / 에러
    printf '   %sNVLink 상태 (nvlink -s / -e)%s\n' "$C_B" "$C_RST"
    nvidia-smi nvlink -s > "$GPUDIR/nvlink_status.txt" 2>&1 || true
    nvidia-smi nvlink -e > "$GPUDIR/nvlink_errors.txt" 2>&1 || true
    # GPU 별 "idx active inactive"
    NVL=$(awk '/^GPU [0-9]+:/ { if (g != "") print g, a, n; g=$2; sub(":", "", g); a=0; n=0; next }
               /Link [0-9]+:/ { if ($0 ~ /<inactive>/) n++; else a++ }
               END { if (g != "") print g, a, n }' "$GPUDIR/nvlink_status.txt")
    NVL_TOTAL=$(printf '%s\n' "$NVL" | awk '{ s += $2 + $3 } END { print s + 0 }')
    if [[ "$NVL_TOTAL" -eq 0 ]]; then
        printf '   NVLink 링크 없음 — 미지원 카드이거나 브리지 미장착 (건너뜀)\n'
    else
        printf '   %-3s %7s %9s\n' GPU active inactive
        NVL_BAD=0; NVL_ACTIVE_SET=$(printf '%s\n' "$NVL" | awk '$2 > 0 { print $2 }' | sort -u | wc -l)
        while read -r g a n; do
            [[ -z "$g" ]] && continue
            printf '   %-3s %7s %9s' "$g" "$a" "$n"
            if [[ "$a" -gt 0 && "$n" -gt 0 ]]; then
                printf '  %s← active/inactive 혼재 — 브리지 접촉 확인%s\n' "$C_R" "$C_RST"; NVL_BAD=1
            elif [[ "$a" -eq 0 ]]; then
                printf '  (브리지 없음)\n'
            else
                printf '\n'
            fi
        done <<< "$NVL"
        if [[ "$NVL_ACTIVE_SET" -gt 1 ]]; then
            bad "GPU 마다 active 링크 수가 다릅니다 — 브리지 장착/접촉 확인"; NVL_BAD=1
        fi
        # 에러 카운터: "... Errors: N" 줄 중 N > 0
        NVL_ERR=$(grep -oE 'Errors?: *[0-9]+' "$GPUDIR/nvlink_errors.txt" 2>/dev/null | awk -F': *' '$2 > 0 { c++ } END { print c + 0 }')
        if [[ "$NVL_ERR" -gt 0 ]]; then
            bad "NVLink 에러 카운터가 0 이 아닌 항목 ${NVL_ERR}개 — $GPUDIR/nvlink_errors.txt"
            grep -E 'Errors?: *[1-9]' "$GPUDIR/nvlink_errors.txt" | head -8 | sed 's/^/     /'
            NVL_BAD=1
        else
            printf '   NVLink 에러 카운터: 모두 0\n'
        fi
        [[ "$NVL_BAD" -eq 1 ]] && GPU_RC=1
    fi
fi

# ---------------------------------------------------------------- 3) HW 정보
if [[ "$DO_HW" -eq 1 ]]; then
    printf '\n%s[3/4] HW 정보 수집%s\n' "$C_B" "$C_RST"
    [[ -x "$SCRIPT_DIR/inspect.sh" ]] || { echo "inspect.sh 를 찾을 수 없습니다: $SCRIPT_DIR" >&2; exit 1; }
    OUTDIR="$OUT/hw" "$SCRIPT_DIR/inspect.sh" --hw-only
    HW_RC=$?
    printf '   → %s\n' "$OUT/hw"
else
    HW_RC=0
fi

# ---------------------------------------------------------------- 4) 번인
printf '\n%s[4/4] GPU 번인 %s초%s  (CPU stress 없음)\n' "$C_B" "$DUR" "$C_RST"

MEM_PID=""
if [[ "$MEM_LOAD" -eq 1 ]]; then
    # stress 의 --vm 은 워커당 --vm-bytes 를 잡는다. 워커 수로 나눠 총량을 맞춘다.
    TOTAL_MB=$(free -m | awk '/^Mem:/ {print $2}')
    case "$MEM_SIZE" in
        *%) WANT_MB=$(( TOTAL_MB * ${MEM_SIZE%\%} / 100 )) ;;
        *G|*g) WANT_MB=$(( ${MEM_SIZE%[Gg]} * 1024 )) ;;
        *M|*m) WANT_MB=${MEM_SIZE%[Mm]} ;;
        *) WANT_MB=$MEM_SIZE ;;
    esac
    VM_WORKERS=4
    PER_MB=$(( WANT_MB / VM_WORKERS ))
    printf '   메모리 부하: 총 %s MB (전체 %s MB 중) — stress --vm %s --vm-bytes %sM\n' \
        "$WANT_MB" "$TOTAL_MB" "$VM_WORKERS" "$PER_MB"
    # NOTE: OOM 을 피하려고 --vm-keep 없이 계속 할당/해제한다(메모리 대역폭도 함께 때린다).
    stress --vm "$VM_WORKERS" --vm-bytes "${PER_MB}M" --timeout "$((DUR + 15))" \
        > "$OUT/stress-mem.log" 2>&1 &
    MEM_PID=$!
    printf '   stress(mem) pid=%s\n' "$MEM_PID"
fi

cleanup_mem() {
    [[ -n "$MEM_PID" ]] || return 0
    pkill -TERM -P "$MEM_PID" 2>/dev/null
    kill -TERM "$MEM_PID" 2>/dev/null
    wait "$MEM_PID" 2>/dev/null
    MEM_PID=""
}
trap 'cleanup_mem' EXIT INT TERM

[[ -x "$SCRIPT_DIR/run-burnin.sh" ]] || { echo "run-burnin.sh 를 찾을 수 없습니다: $SCRIPT_DIR" >&2; cleanup_mem; exit 1; }
# NOTE: run-burnin.sh 는 exec sudo 로 자기를 재실행한다. BURN_DIR/OUT_ROOT 같은 자기 설정값은
#       env 로 직접 넘기지만, 결과 위치는 cwd 가 보존되는 성질을 그대로 써서 결과 폴더에서 실행한다.
( cd "$OUT" && "$SCRIPT_DIR/run-burnin.sh" "$DUR" "$INTERVAL" --no-cpu )
BURN_RC=$?

cleanup_mem

# ---------------------------------------------------------------- ECC (번인 후)
# 번인 전 스냅샷과 비교해 uncorrected / remap 쪽이 늘어난 GPU 를 찾는다.
if [[ -s "$GPUDIR/ecc_before.csv" ]]; then
    printf '\n%sECC (번인 후)%s\n' "$C_B" "$C_RST"
    ecc_snapshot "$GPUDIR/ecc_after.csv"
    ecc_report "$GPUDIR/ecc_after.csv"
    ECC_GREW=$(awk -F, 'NR==FNR { b[$1]=$0; next }
        { split(b[$1], o, ",")
          d=""
          if ($5+0 > o[5]+0)   d = d " unc_vol " o[5] "→" $5
          if ($7+0 > o[7]+0)   d = d " unc_agg " o[7] "→" $7
          if ($4+0 > o[4]+0)   d = d " corr_vol " o[4] "→" $4
          if ($9+0 > o[9]+0)   d = d " remap_u " o[9] "→" $9
          if ($10+0 > o[10]+0) d = d " remap_p " o[10] "→" $10
          if ($11+0 > o[11]+0) d = d " remap_f " o[11] "→" $11
          if (d != "") print "GPU" $1 ":" d }' "$GPUDIR/ecc_before.csv" "$GPUDIR/ecc_after.csv")
    if [[ -n "$ECC_GREW" ]]; then
        bad "번인 중 ECC 카운터가 늘어난 GPU:"
        printf '%s\n' "$ECC_GREW" | sed 's/^/     /'
        GPU_RC=1
    else
        printf '   번인 전후 ECC 카운터 변화 없음\n'
    fi
fi

# ---------------------------------------------------------------- 요약
BURN_DIR=$(ls -dt "$OUT"/burnin_* 2>/dev/null | head -1)
CSV=$(ls -t "$BURN_DIR"/GPU_CPU_*.csv 2>/dev/null | head -1)

printf '\n'; hr
printf ' %s기능 테스트 완료%s  —  %s\n' "$C_C" "$C_RST" "$HOSTN"
hr
if [[ "$DO_HW" -eq 1 ]]; then
    printf '   HW 정보    : %s\n' "$OUT/hw/inspect.log"
    printf '                %s\n' "$OUT/hw/serials.csv"
    printf '   HW 요약    : %s\n' "$OUT/hw/hw_summary.txt"
    printf '   HW 판정    : %s\n' "$([ "$HW_RC" -eq 0 ] && echo '이상 없음' || echo '확인 필요 항목 있음 — 위 요약 참고')"
fi
if [[ -d "$GPUDIR" ]]; then
    printf '   GPU 상태   : %s  (gpu_list.csv, ecc_before/after.csv, topo.txt, nvlink_status/errors.txt)\n' "$GPUDIR"
    printf '   GPU 판정   : %s\n' "$([ "$GPU_RC" -eq 0 ] && echo 'ECC/NVLink 이상 없음' || echo '확인 필요 — 위 ECC/NVLink 표시 참고')"
fi
[[ -n "$CSV" ]]      && printf '   온도 CSV   : %s%s%s\n' "$C_B" "$CSV" "$C_RST"
[[ -n "$BURN_DIR" ]] && printf '   번인 결과  : %s\n' "$BURN_DIR"
[[ "$MEM_LOAD" -eq 1 ]] && printf '   메모리 부하: %s\n' "$OUT/stress-mem.log"
[[ -s "$BUILD_LOG" ]] && printf '   빌드 로그  : %s\n' "$BUILD_LOG"
printf '   gadget_burn: %s\n' "$GB"
printf '   전체       : %s\n' "$OUT"
hr
# 하드웨어 구성 요약(CPU / 메인보드 / RAM / 스토리지 / PCIe) — inspect.sh 가 만든 파일을 그대로 보여준다.
# 번인 화면이 길어 HW 단계 출력이 위로 밀려나므로 맨 끝에 한 번 더 찍는다.
if [[ "$DO_HW" -eq 1 && -s "$OUT/hw/hw_summary.txt" ]]; then
    cat "$OUT/hw/hw_summary.txt"
    hr
fi
printf '\n'

[[ "$HW_RC" -ne 0 || "$GPU_RC" -ne 0 || "$BURN_RC" -ne 0 ]] && exit 1
exit 0
