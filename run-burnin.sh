#!/usr/bin/env bash
#
# run-burnin.sh — DEEPGadget 출고 검수 번인 통합 실행 스크립트
#
#   1) gadget-burn/gadget_burn                                   (GPU 번인)
#   2) stress -c <코어수>                                         (CPU 번인)
#   3) lib/gpu-cpu.sh <interval> <duration>                       (온도 로깅)
#   위 3개를 동시에 실행하고, 현재 GPU/CPU 온도와 GPU 쓰로틀 상태를
#   터미널에 실시간 갱신 표시한다. 종료 후 make-csv.sh 로 CSV를 생성한다.
#
# 사용법:  ./run-burnin.sh [지속시간(초)] [샘플간격(초)]
#          기본값: 3600 5
#
# gpu-cpu.sh 내부의 `sudo nvme smart-log` 때문에 root 권한이 필요하다.
# 일반 계정으로 실행하면 sudo 로 한 번만 승격한 뒤 그대로 이어서 진행한다.

set -uo pipefail

DUR=${1:-3600}
INTERVAL=${2:-5}
REFRESH=${REFRESH:-2}          # 화면 갱신 주기(초)
NVSMI=${NVSMI:-nvidia-smi}     # 대시보드용 조회 명령 (다GPU 렌더링 테스트 시 교체)

# ---------------------------------------------------------------- root 승격
if [ "$(id -u)" -ne 0 ]; then
  echo "[i] NVMe 온도 수집(nvme smart-log)에 root 권한이 필요합니다. sudo 로 재실행합니다."
  exec sudo -- "$0" "$@"
fi

INVOKE_DIR=$PWD                # 결과는 스크립트를 실행한 디렉터리에 만든다
RUN_USER=${SUDO_USER:-root}
USER_HOME=$(getent passwd "$RUN_USER" | cut -d: -f6)
[ -d "$USER_HOME" ] || USER_HOME=$HOME

OUT_ROOT=${OUT_ROOT:-$INVOKE_DIR}

# 스크립트 자신의 위치 (sudo 로 재실행돼도 cwd 가 보존되므로 상대경로 $0 도 안전)
SCRIPT_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)

# 헬퍼 탐색: 저장소 안의 lib/ 을 먼저 보고, 없으면 기존 ~/tools 배치로 폴백
find_file() {          # find_file <파일명> <후보경로...>
  local name=$1; shift
  local c
  for c in "$@"; do [ -x "$c" ] && { printf '%s' "$c"; return 0; }; done
  return 1
}

GPUCPU_SH=$(find_file gpu-cpu.sh \
  "${LIB_DIR:-$SCRIPT_DIR/lib}/gpu-cpu.sh" \
  "$SCRIPT_DIR/gpu-cpu.sh")

MAKECSV_SH=$(find_file make-csv.sh \
  "${LIB_DIR:-$SCRIPT_DIR/lib}/make-csv.sh" \
  "$SCRIPT_DIR/make-csv.sh")

# gadget_burn 은 setup.sh 가 저장소 안(./gadget-burn)에 빌드한다.
# 다른 곳에 빌드해 뒀다면 BURN_DIR=/경로 로 지정할 수 있다.
GADGET_BURN=$(find_file gadget_burn \
  "${BURN_DIR:-$SCRIPT_DIR/gadget-burn}/gadget_burn" \
  "$SCRIPT_DIR/gadget-burn/gadget_burn" \
  "$(command -v gadget_burn 2>/dev/null)")

MISSING=0
[ -n "$GPUCPU_SH" ]   || { echo "[!] lib/gpu-cpu.sh 가 없습니다 — 저장소를 통째로 받았는지 확인하세요."; MISSING=1; }
[ -n "$MAKECSV_SH" ]  || { echo "[!] lib/make-csv.sh 가 없습니다 — 저장소를 통째로 받았는지 확인하세요."; MISSING=1; }
[ -n "$GADGET_BURN" ] || { echo "[!] gadget_burn 을 찾을 수 없습니다 → ./setup.sh 를 먼저 실행하세요."; MISSING=1; }
command -v stress >/dev/null || { echo "[!] stress 가 없습니다 → ./setup.sh 를 먼저 실행하세요."; MISSING=1; }
command -v nvidia-smi >/dev/null || { echo "[!] nvidia-smi 가 없습니다 (NVIDIA 드라이버 미설치)"; MISSING=1; }
command -v sensors >/dev/null || { echo "[!] sensors 가 없습니다 → ./setup.sh 를 먼저 실행하세요 (lm-sensors)"; MISSING=1; }
command -v nvme >/dev/null || { echo "[!] nvme 가 없습니다 → ./setup.sh 를 먼저 실행하세요 (nvme-cli)"; MISSING=1; }
[ "$MISSING" -eq 0 ] || exit 1

# ---------------------------------------------------------------- 준비
HOSTN=$(hostname)
STAMP=$(date '+%Y%m%d_%H%M%S')
RUNDIR="$OUT_ROOT/${HOSTN}_${STAMP}"
mkdir -p "$RUNDIR"
cd "$RUNDIR" || exit 1

NCPU=$(nproc)
GPUNAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
GPUCNT=$($NVSMI --query-gpu=index --format=csv,noheader | wc -l)
LOG="$RUNDIR/GPU_CPU_log.txt"          # gpu-cpu.sh 가 CWD 에 만드는 파일명
CSV_FINAL="$RUNDIR/GPU_CPU_${HOSTN}_${STAMP}.csv"
EVENTS="$RUNDIR/max-events.log"        # 최고온도 갱신 이력 (화면 대신 파일로)

if [ -t 1 ]; then
  TTY=1
  C_RST=$'\e[0m'; C_R=$'\e[1;31m'; C_G=$'\e[1;32m'; C_Y=$'\e[1;33m'
  C_C=$'\e[1;36m'; C_D=$'\e[2m'; C_B=$'\e[1m'
else
  TTY=0
  C_RST=; C_R=; C_G=; C_Y=; C_C=; C_D=; C_B=
fi

hms() { printf '%02d:%02d:%02d' $(($1/3600)) $(($1%3600/60)) $(($1%60)); }
gt()  { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0>b+0)}'; }   # a > b 이면 true

RULE="────────────────────────────────────────────────────────────────────────────────"

echo "$RULE"
echo " ${C_C}DEEPGadget 검수 번인${C_RST}  —  $HOSTN"
echo "   지속시간 : $DUR 초 ($(hms "$DUR"))     로그 샘플간격 : ${INTERVAL}s"
echo "   CPU      : ${NCPU} threads   (stress -c $NCPU -t $DUR)"
echo "   GPU      : ${GPUNAME} x${GPUCNT}   (gadget_burn -t $DUR)"
echo "   결과경로 : $RUNDIR"
echo "   사용도구 : $GADGET_BURN"
echo "              $GPUCPU_SH"
echo "              $MAKECSV_SH"
echo "$RULE"

{
  echo "### date";       date
  echo "### hostname";   hostname
  echo "### uname";      uname -a
  echo "### lscpu";      lscpu
  echo "### nvidia-smi"; nvidia-smi
  echo "### free";       free -h
  echo "### nvme list";  nvme list
} > "$RUNDIR/system_info.txt" 2>&1

# ---------------------------------------------------------------- 종료 처리
PIDS=()
kill_tree() { pkill -TERM -P "$1" 2>/dev/null; kill -TERM "$1" 2>/dev/null; }
cleanup() { for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill_tree "$p"; done; }
show_cursor() { [ "$TTY" = 1 ] && printf '\e[?25h'; }

on_int() {
  show_cursor
  echo
  echo "${C_Y}[!] 중단 요청됨 — 실행 중인 부하/로깅을 정리합니다.${C_RST}"
  cleanup
  sleep 2
  finish "중단됨"
  exit 130
}

# ---------------------------------------------------------------- 마무리
finish() {
  local why=${1:-완료}
  trap - INT TERM
  show_cursor
  echo
  echo "${C_D}  부하 프로세스 종료 대기...${C_RST}"
  wait "$BURN_PID" 2>/dev/null
  wait "$STRESS_PID" 2>/dev/null
  wait "$GPUCPU_PID" 2>/dev/null

  echo "  make-csv.sh 실행 중..."
  chown -R "$RUN_USER": "$RUNDIR" 2>/dev/null
  # NOTE: make-csv.sh 는 반드시 일반 계정으로 실행할 것.
  #       root 로 실행하면 lscpu 가 "BIOS Vendor ID:" 줄을 추가로 출력해
  #       cpu_vendor 판별이 깨지고 CPU 온도 칼럼이 전부 비어버린다.
  if [ "$RUN_USER" != "root" ]; then
    ( cd "$RUNDIR" && runuser -u "$RUN_USER" -- "$MAKECSV_SH" > "$RUNDIR/make-csv.log" 2>&1 )
  else
    ( cd "$RUNDIR" && "$MAKECSV_SH" > "$RUNDIR/make-csv.log" 2>&1 )
  fi
  [ -s "$RUNDIR/output.csv" ] && cp -f "$RUNDIR/output.csv" "$CSV_FINAL"
  chown -R "$RUN_USER": "$RUNDIR" 2>/dev/null

  if [ -s "$CSV_FINAL" ] && [ "$(awk -F',' 'NR>1 && $6!="" {c++} END{print c+0}' "$CSV_FINAL")" -eq 0 ]; then
    echo "${C_Y}[!] 경고: CSV 의 CPU 온도 칼럼이 비어 있습니다. make-csv.sh 실행 환경을 확인하세요.${C_RST}"
  fi

  local samples=0
  [ -s "$LOG" ] && samples=$(( $(wc -l < "$LOG") - 1 ))
  echo
  echo "$RULE"
  echo " ${C_C}번인 $why${C_RST}  —  $HOSTN   ($(hms $(( $(date +%s) - START_EPOCH )))  경과, ${samples} 샘플)"
  echo "   ${C_R}CPU 최고온도  : ${cmax} °C${C_RST}"
  echo "   ${C_G}GPU 최고온도  : ${gmax} °C${C_RST}"
  local gi
  for gi in $(printf '%s\n' "${!GMAX[@]}" | sort -n); do
    printf '     GPU%-3s 최고 %s°C   쓰로틀 열 %ss / 전력 %ss\n' "$gi" "${GMAX[$gi]}" "${THT[$gi]}" "${THP[$gi]}"
  done
  echo "   NVMe 최고온도 : ${nmax} °C"
  echo "$RULE"
  echo "   원본 로그  : $LOG"
  echo "   검수 CSV   : ${C_B}$CSV_FINAL${C_RST}"
  echo "   burn CSV   : $RUNDIR/gadget_burn.csv"
  echo "   최고온도 이력 : $EVENTS"
  echo "   시스템정보 : $RUNDIR/system_info.txt"
  echo "$RULE"
  echo
  echo "다운로드 (워크스테이션에서):"
  echo "  scp ${RUN_USER}@$(hostname -I | awk '{print $1}'):${CSV_FINAL} ."
}

# ---------------------------------------------------------------- 실행
START_EPOCH=$(date +%s)

"$GADGET_BURN" -t "$DUR" -o "$RUNDIR/gadget_burn.csv" > "$RUNDIR/gadget_burn.log" 2>&1 &
BURN_PID=$!

stress -c "$NCPU" -t "$DUR" > "$RUNDIR/stress.log" 2>&1 &
STRESS_PID=$!

"$GPUCPU_SH" "$INTERVAL" "$DUR" > "$RUNDIR/gpu-cpu.log" 2>&1 &
GPUCPU_PID=$!

PIDS=("$BURN_PID" "$STRESS_PID" "$GPUCPU_PID")
trap on_int INT TERM

echo "${C_D}  gadget_burn pid=$BURN_PID / stress pid=$STRESS_PID / gpu-cpu.sh pid=$GPUCPU_PID${C_RST}"
echo "  로그 준비 중..."

for _ in $(seq 1 30); do [ -s "$LOG" ] && break; sleep 1; done
[ -s "$LOG" ] || { echo "${C_R}[!] $LOG 이 생성되지 않았습니다. gpu-cpu.log 확인 필요.${C_RST}"; cleanup; exit 1; }

# ---------------------------------------------------------------- 모니터링
gmax=-1; cmax=-1; nmax=-1
th_therm=0; th_power=0
declare -A GMAX THT THP        # GPU별 최고온도 / 열·전력 쓰로틀 누적(초)
PREV_LINES=0
: > "$EVENTS"
[ "$TTY" = 1 ] && printf '\e[?25l'

# 표 서식 — 컬럼 정렬이 깨지지 않도록 데이터 칸은 ASCII 숫자만 넣는다
#            (한글/°는 폭이 2칸이라 printf 의 %Ns 패딩과 어긋난다)
GFMT_H=' %3s  %5s %5s  %6s  %13s  %8s  %5s  %s'

bar() {   # bar <percent> <width>
  local pct=$1 w=$2 f i s=""
  f=$(( pct * w / 100 )); [ "$f" -gt "$w" ] && f=$w
  for ((i=0;i<f;i++)); do s+="█"; done
  for ((i=f;i<w;i++)); do s+="░"; done
  printf '%s' "$s"
}

render() {
  local -a FRAME=()
  local el=$(( $(date +%s) - START_EPOCH ))
  local rem=$(( DUR - el )); [ "$rem" -lt 0 ] && rem=0
  local pct=$(( el * 100 / (DUR>0?DUR:1) )); [ "$pct" -gt 100 ] && pct=100

  # 터미널 높이보다 프레임이 길어지면 제자리 갱신이 깨지므로 장식 줄을 뺀다
  # sudo 로 승격하면 stdin 이 tty 가 아닐 수 있어 tput 이 실제 높이 대신 24 를 준다 → /dev/tty 우선
  local tl_rows
  tl_rows=$(stty size < /dev/tty 2>/dev/null | awk '{print $1}')
  [ -z "$tl_rows" ] && tl_rows=$(tput lines 2>/dev/null)
  [ -z "$tl_rows" ] && tl_rows=24
  local need=$(( 8 + GPUCNT ))          # 고정 8줄 + GPU 행
  local slim=0; [ "$need" -ge "$tl_rows" ] && slim=1

  if [ "$slim" = 0 ]; then
    FRAME+=("$RULE")
    FRAME+=(" ${C_C}DEEPGadget 검수 번인${C_RST} · ${C_B}${HOSTN}${C_RST}   경과 $(hms "$el") / $(hms "$DUR")   남은시간 $(hms "$rem")")
    FRAME+=(" $(bar "$pct" 46) ${pct}%")
    FRAME+=("$RULE")
  else
    FRAME+=(" ${C_C}번인${C_RST} ${C_B}${HOSTN}${C_RST}  $(hms "$el")/$(hms "$DUR")  남은 $(hms "$rem")  ${pct}%")
  fi

  # ---- GPU : nvidia-smi 1회 호출로 전 GPU 조회, 1장이든 10장이든 한 행씩
  local q
  q=$($NVSMI --query-gpu=index,temperature.gpu,temperature.gpu.tlimit,power.draw,enforced.power.limit,utilization.gpu,clocks.sm,clocks_throttle_reasons.sw_power_cap,clocks_throttle_reasons.hw_slowdown,clocks_throttle_reasons.hw_thermal_slowdown,clocks_throttle_reasons.hw_power_brake_slowdown,clocks_throttle_reasons.sw_thermal_slowdown \
        --format=csv,noheader,nounits 2>/dev/null)

  local hdr; printf -v hdr "$GFMT_H" "GPU" "TEMP" "MAX" "SLOWDN" "POWER W" "CLK MHz" "UTIL" "THROTTLE"
  FRAME+=("${C_D}${hdr}${C_RST}")

  local gi gt_ tl pd pl ut sm r_swpwr r_hw r_hwth r_brake r_swth
  local any_hot=0 any_pwr=0
  while IFS=',' read -r gi gt_ tl pd pl ut sm r_swpwr r_hw r_hwth r_brake r_swth; do
    [ -z "${gi:-}" ] && continue
    gi=${gi// /}; gt_=${gt_// /}; tl=${tl// /}; pd=${pd// /}; pl=${pl// /}
    ut=${ut// /}; sm=${sm// /}
    # "Not Active" 가 *" Active"* 패턴에 걸리므로 공백 제거 후 정확히 비교할 것
    r_swpwr=${r_swpwr// /}; r_hw=${r_hw// /}; r_hwth=${r_hwth// /}
    r_brake=${r_brake// /}; r_swth=${r_swth// /}

    : "${GMAX[$gi]:=-1}"; : "${THT[$gi]:=0}"; : "${THP[$gi]:=0}"
    if gt "$gt_" "${GMAX[$gi]}"; then
      [ "${GMAX[$gi]}" != "-1" ] && echo "$(date '+%H:%M:%S') GPU${gi} MAX ${GMAX[$gi]} -> ${gt_} C" >> "$EVENTS"
      GMAX[$gi]=$gt_
    fi
    gt "$gt_" "$gmax" && gmax=$gt_

    local thr="" thcol="$C_D" hot=0 pwr=0
    [ "$r_swth"  = "Active" ] && { thr+="SWTHERM "; hot=1; }
    [ "$r_hwth"  = "Active" ] && { thr+="HWTHERM "; hot=1; }
    [ "$r_brake" = "Active" ] && { thr+="BRAKE ";   pwr=1; }
    [ "$r_hw"    = "Active" ] && { thr+="HWSLOW ";  hot=1; }
    [ "$r_swpwr" = "Active" ] && { thr+="PWRCAP ";  pwr=1; }
    # 주의: 산술식 안의 THT[gi] 는 첨자를 문자열 "gi" 로 해석해 전 GPU 가 키를 공유한다.
    #       연관배열은 반드시 ${THT[$gi]} 로 값을 꺼내 쓸 것.
    [ "$hot" = 1 ] && { THT[$gi]=$(( ${THT[$gi]} + REFRESH )); thcol="$C_R"; any_hot=1; }
    [ "$pwr" = 1 ] && { THP[$gi]=$(( ${THP[$gi]} + REFRESH )); [ "$hot" = 0 ] && thcol="$C_Y"; any_pwr=1; }
    [ -z "$thr" ] && thr="-"

    local tcol="$C_G"
    gt "$gt_" 80 && tcol="$C_Y"
    gt "$gt_" 88 && tcol="$C_R"
    [ -z "$tl" ] || [ "$tl" = "N/A" ] && tl="-"

    local r f
    printf -v r  ' %3s  ' "$gi"
    printf -v f  '%5s'    "$gt_";                r+="${tcol}${f}${C_RST}"
    printf -v f  ' %5s  ' "${GMAX[$gi]}";        r+="$f"
    printf -v f  '%6s  '  "$tl";                 r+="$f"
    printf -v f  '%13s  ' "${pd}/${pl}";         r+="$f"
    printf -v f  '%8s  '  "$sm";                 r+="$f"
    printf -v f  '%4s%%  ' "$ut";                r+="$f"
    printf -v f  '%-24s'  "$thr";                r+="${thcol}${f}${C_RST}"
    r+="${C_D}[T ${THT[$gi]}s / P ${THP[$gi]}s]${C_RST}"
    FRAME+=("$r")
  done <<< "$q"
  [ "$any_hot" = 1 ] && th_therm=$(( th_therm + REFRESH ))
  [ "$any_pwr" = 1 ] && th_power=$(( th_power + REFRESH ))

  # ---- CPU : 소켓 수만큼 Tctl(AMD) / Package id(Intel) 을 모두 수집해 최대값 사용
  local ctemps cnow call ccol
  ctemps=$(sensors 2>/dev/null | grep -oE '(Tctl|Package id [0-9]+): +\+[0-9.]+' | grep -oE '\+[0-9.]+' | tr -d '+')
  cnow=$(echo "$ctemps" | sort -g | tail -1); [ -z "$cnow" ] && cnow="-1"
  if gt "$cnow" "$cmax"; then
    [ "$cmax" != "-1" ] && echo "$(date '+%H:%M:%S') CPU MAX ${cmax} -> ${cnow} C" >> "$EVENTS"
    cmax=$cnow
  fi
  ccol="$C_G"; gt "$cnow" 80 && ccol="$C_Y"; gt "$cnow" 90 && ccol="$C_R"
  call=$(echo "$ctemps" | tr '\n' ' ' | sed 's/ $//')
  FRAME+=(" ${C_B}CPU ${C_RST}  ${ccol}${cnow}°C${C_RST} (max ${cmax}°C)   소켓별 [ ${call} ]   ${NCPU} threads @ stress")

  # ---- NVMe / 샘플수 (gpu-cpu.sh 로그 마지막 줄에서 — /dev/nvme0 만 수집됨)
  local last nnow samples
  last=$(tail -n 1 "$LOG" 2>/dev/null)
  nnow=$(awk -F',' '{print $2}' <<<"$last" | tr -dc '0-9'); [ -z "$nnow" ] && nnow="-1"
  gt "$nnow" "$nmax" && nmax=$nnow
  samples=$(( $(wc -l < "$LOG") - 1 ))
  FRAME+=(" ${C_B}NVMe${C_RST}  ${nnow}°C (max ${nmax}°C)   ${C_D}로그 샘플 ${samples}개 · ${INTERVAL}s 간격 · Ctrl-C 중단${C_RST}")
  [ "$slim" = 0 ] && FRAME+=("$RULE")

  if [ "$TTY" = 1 ]; then
    [ "$PREV_LINES" -gt 0 ] && printf '\e[%dA' "$PREV_LINES"
    for l in "${FRAME[@]}"; do printf '%s\e[K\n' "$l"; done
    PREV_LINES=${#FRAME[@]}
  else
    if [ $(( ( $(date +%s) - START_EPOCH ) % 30 )) -lt "$REFRESH" ]; then
      printf '[%s] GPU max %s°C  CPU %s°C(max %s)  NVMe %s°C  throttle 열%ss/전력%ss\n' \
        "$(hms "$el")" "$gmax" "$cnow" "$cmax" "$nnow" "$th_therm" "$th_power"
    fi
  fi
}

while kill -0 "$GPUCPU_PID" 2>/dev/null; do
  render
  sleep "$REFRESH"
done

finish "완료"
