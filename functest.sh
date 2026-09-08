#!/usr/bin/env bash
#
# functest.sh — 기능 테스트
#
#   1) HW 정보          : inspect.sh 의 하드웨어 점검(PART 1)만 돌린다
#   2) GPU + CPU 번인   : 기본 5분 (검수용 1시간 번인과 구분)
#   옵션) 메모리 부하   : --mem 을 주면 번인에 메모리 스트레스를 함께 건다
#
# 서버 설정은 건드리지 않는다 — 그건 setup.sh 담당이다.
# 검수(설정 확인 포함)는 inspect.sh, 1시간 번인은 run-burnin.sh 를 쓴다.
#
# 사용법:
#   ./functest.sh                    # HW 정보 + GPU/CPU 5분 번인
#   ./functest.sh --mem              # + 메모리 부하 (기본 전체 RAM 의 80%)
#   ./functest.sh --mem 50%          # 메모리 부하량 지정 (% 또는 4G 같은 절대값)
#   ./functest.sh --time 600         # 번인 시간(초) 변경
#   ./functest.sh --no-hw            # 번인만
#
# 결과는 실행한 디렉터리 아래 functest_<host>_<시각>/ 에 모인다.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
DUR=300
DO_HW=1
MEM_LOAD=0
MEM_SIZE="80%"
INTERVAL=5

while [[ $# -gt 0 ]]; do
    case "$1" in
        --time) shift; DUR=${1:?--time 뒤에 초를 주세요} ;;
        --mem)
            MEM_LOAD=1
            # 다음 인자가 옵션이 아니면 부하량으로 받는다
            if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then shift; MEM_SIZE="$1"; fi ;;
        --no-hw) DO_HW=0 ;;
        --interval) shift; INTERVAL=${1:-5} ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "알 수 없는 옵션: $1" >&2; exit 1 ;;
    esac
    shift
done

HOSTN=$(hostname)
STAMP=$(date +%Y%m%d_%H%M%S)
OUT="$PWD/functest_${HOSTN}_${STAMP}"
mkdir -p "$OUT" || { echo "결과 디렉터리를 만들 수 없습니다: $OUT" >&2; exit 1; }

C_C=$'\033[1;36m'; C_B=$'\033[1m'; C_RST=$'\033[0m'; C_D=$'\033[2m'
hr() { printf '%s\n' "────────────────────────────────────────────────────────────────────────────────"; }

hr
printf ' %sDEEPGadget 기능 테스트%s  —  %s\n' "$C_C" "$C_RST" "$HOSTN"
printf '   HW 정보    : %s\n' "$([ "$DO_HW" -eq 1 ] && echo '수집' || echo '생략 (--no-hw)')"
printf '   번인       : GPU + CPU %s초\n' "$DUR"
printf '   메모리 부하: %s\n' "$([ "$MEM_LOAD" -eq 1 ] && echo "$MEM_SIZE" || echo '없음 (--mem 으로 켬)')"
printf '   결과경로   : %s\n' "$OUT"
hr

# ---------------------------------------------------------------- 1) HW 정보
if [[ "$DO_HW" -eq 1 ]]; then
    printf '\n%s[1/2] HW 정보 수집%s\n' "$C_B" "$C_RST"
    [[ -x "$SCRIPT_DIR/inspect.sh" ]] || { echo "inspect.sh 를 찾을 수 없습니다: $SCRIPT_DIR" >&2; exit 1; }
    OUTDIR="$OUT/hw" "$SCRIPT_DIR/inspect.sh" --hw-only
    HW_RC=$?
    printf '   → %s\n' "$OUT/hw"
else
    HW_RC=0
fi

# ---------------------------------------------------------------- 2) 번인
printf '\n%s[2/2] GPU + CPU 번인 %s초%s\n' "$C_B" "$DUR" "$C_RST"

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
# NOTE: run-burnin.sh 는 exec sudo 로 자기를 재실행한다. sudo 는 기본적으로 환경변수를
#       버리므로 OUT_ROOT 를 넘겨도 소용없다. cwd 는 보존되므로 결과 폴더에서 실행한다.
( cd "$OUT" && "$SCRIPT_DIR/run-burnin.sh" "$DUR" "$INTERVAL" )
BURN_RC=$?

cleanup_mem

# ---------------------------------------------------------------- 요약
BURN_DIR=$(ls -dt "$OUT"/burnin_* 2>/dev/null | head -1)
CSV=$(ls -t "$BURN_DIR"/GPU_CPU_*.csv 2>/dev/null | head -1)

printf '\n'; hr
printf ' %s기능 테스트 완료%s  —  %s\n' "$C_C" "$C_RST" "$HOSTN"
hr
if [[ "$DO_HW" -eq 1 ]]; then
    printf '   HW 정보    : %s\n' "$OUT/hw/inspect.log"
    printf '                %s\n' "$OUT/hw/serials.csv"
    printf '   HW 판정    : %s\n' "$([ "$HW_RC" -eq 0 ] && echo '이상 없음' || echo '확인 필요 항목 있음 — 위 요약 참고')"
fi
[[ -n "$CSV" ]]      && printf '   온도 CSV   : %s%s%s\n' "$C_B" "$CSV" "$C_RST"
[[ -n "$BURN_DIR" ]] && printf '   번인 결과  : %s\n' "$BURN_DIR"
[[ "$MEM_LOAD" -eq 1 ]] && printf '   메모리 부하: %s\n' "$OUT/stress-mem.log"
printf '   전체       : %s\n' "$OUT"
hr
printf '\n'

[[ "$HW_RC" -ne 0 || "$BURN_RC" -ne 0 ]] && exit 1
exit 0
