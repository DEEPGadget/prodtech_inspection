#!/usr/bin/env bash
#
# run-burnin.sh — DEEPGadget SW 검수 번인 통합 실행 스크립트
#
#   1) gadget-burn/gadget_burn                                   (GPU 번인)
#   2) stress -c <코어수>                                         (CPU 번인)
#   3) lib/sample-sensors.sh <interval> <duration> <csv>          (온도 로깅 → CSV 직접 기록)
#   위 3개를 동시에 실행하고, 현재 GPU/CPU 온도와 GPU 쓰로틀 상태를
#   터미널에 실시간 갱신 표시한다.
#
# 사용법:  ./run-burnin.sh [지속시간(초)] [샘플간격(초)] [--no-cpu]
#          기본값: 3600 5
#          --no-cpu : CPU 번인(stress)을 빼고 GPU 번인 + 온도 로깅만 (functest.sh 가 쓴다)
#
# sample-sensors.sh 의 `nvme smart-log` 때문에 root 권한이 필요하다.
# 일반 계정으로 실행하면 sudo 로 한 번만 승격한 뒤 그대로 이어서 진행한다.

set -uo pipefail

# 버전은 sudo 재실행 전에(원래 사용자로) 계산해 PI_VERSION 으로 넘긴다 — lib/version.sh 참고
source "$(dirname "$0")/lib/version.sh"

# 위치 인자(지속시간, 샘플간격)와 옵션(--no-cpu)을 섞어 받는다. sudo 재실행 시 "$@" 그대로 넘어간다.
DO_CPU=1; POS=()
for a in "$@"; do
  case "$a" in
    --no-cpu) DO_CPU=0 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    --version) echo "prodtech_inspection $PI_VERSION"; exit 0 ;;
    --skip-version-check) export PI_SKIP_VERSION_CHECK=1 ;;
    -*) echo "알 수 없는 옵션: $a" >&2; exit 1 ;;
    *) POS+=("$a") ;;
  esac
done
DUR=${POS[0]:-3600}
INTERVAL=${POS[1]:-5}
REFRESH=${REFRESH:-2}          # 화면 갱신 주기(초)
NVSMI=${NVSMI:-nvidia-smi}     # 대시보드용 조회 명령 (다GPU 렌더링 테스트 시 교체)
pi_check_latest                # sudo 재실행 전에 원래 사용자로 확인한다 (결과는 PI_VERSION_CHECKED 로 넘어감)

# ---------------------------------------------------------------- root 승격
if [ "$(id -u)" -ne 0 ]; then
  echo "[i] NVMe 온도 수집(nvme smart-log)에 root 권한이 필요합니다. sudo 로 재실행합니다."
  # sudo 는 환경변수를 버리므로 이 스크립트가 보는 설정값만 env 로 명시해서 넘긴다
  # (sudoers 의 env_keep 설정과 무관하게 동작한다)
  PASS=()
  for v in BURN_DIR LIB_DIR OUT_ROOT REFRESH NVSMI PI_VERSION PI_VERSION_CHECKED; do
    [ -n "${!v:-}" ] && PASS+=("$v=${!v}")
  done
  exec sudo -- env ${PASS[@]+"${PASS[@]}"} "$0" "$@"
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

SAMPLER=$(find_file sample-sensors.sh \
  "${LIB_DIR:-$SCRIPT_DIR/lib}/sample-sensors.sh" \
  "$SCRIPT_DIR/sample-sensors.sh")

# gadget_burn 탐색은 lib/find-gadget-burn.sh 한 곳에서 한다 (inspect/functest 와 같은 순서):
#   BURN_DIR → <저장소>/gadget-burn → <저장소>/../gadget-burn → <사용자홈>/gadget-burn → PATH 등.
# sudo 뒤라 $HOME 은 /root 이므로 원래 사용자 홈(USER_HOME)을 넘긴다.
FINDER=$(find_file find-gadget-burn.sh \
  "${LIB_DIR:-$SCRIPT_DIR/lib}/find-gadget-burn.sh" \
  "$SCRIPT_DIR/find-gadget-burn.sh")
GADGET_BURN=""
if [ -n "$FINDER" ]; then
  GADGET_BURN=$("$FINDER" "$SCRIPT_DIR" "$USER_HOME")   # 실패 시 찾아본 목록이 stderr 로 나온다
else
  GADGET_BURN=$(find_file gadget_burn "${BURN_DIR:-$SCRIPT_DIR/gadget-burn}/gadget_burn" \
    "$SCRIPT_DIR/gadget-burn/gadget_burn" "$USER_HOME/gadget-burn/gadget_burn" \
    "$(command -v gadget_burn 2>/dev/null)")
fi

MISSING=0
[ -n "$SAMPLER" ]     || { echo "[!] lib/sample-sensors.sh 가 없습니다 — 저장소를 통째로 받았는지 확인하세요."; MISSING=1; }
[ -n "$GADGET_BURN" ] || { echo "[!] gadget_burn 을 찾을 수 없습니다 → 위 목록의 위치에 없습니다. BURN_DIR=/경로 로 알려주거나 ./setup.sh 로 빌드하세요."; MISSING=1; }
[ "$DO_CPU" -eq 0 ] || command -v stress >/dev/null || { echo "[!] stress 가 없습니다 → ./setup.sh 를 먼저 실행하세요."; MISSING=1; }
command -v nvidia-smi >/dev/null || { echo "[!] nvidia-smi 가 없습니다 (NVIDIA 드라이버 미설치)"; MISSING=1; }
command -v sensors >/dev/null || { echo "[!] sensors 가 없습니다 → ./setup.sh 를 먼저 실행하세요 (lm-sensors)"; MISSING=1; }
command -v nvme >/dev/null || { echo "[!] nvme 가 없습니다 → ./setup.sh 를 먼저 실행하세요 (nvme-cli)"; MISSING=1; }
[ "$MISSING" -eq 0 ] || exit 1

# ---------------------------------------------------------------- 준비
HOSTN=$(hostname)
STAMP=$(date '+%Y%m%d_%H%M%S')
RUNDIR="$OUT_ROOT/burnin_${HOSTN}_${STAMP}"
mkdir -p "$RUNDIR"
cd "$RUNDIR" || exit 1

NCPU=$(nproc)
GPUNAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
GPUCNT=$($NVSMI --query-gpu=index --format=csv,noheader | wc -l)
# 쓰로틀 사유 필드 이름은 드라이버에 따라 clocks_throttle_reasons.* / clocks_event_reasons.*
# (잘못된 필드가 하나라도 섞이면 대시보드 조회 전체가 비므로 미리 확인)
TR=clocks_throttle_reasons
$NVSMI --query-gpu=$TR.hw_power_brake_slowdown --format=csv,noheader >/dev/null 2>&1 || TR=clocks_event_reasons
# 수집기가 CSV 를 바로 쓴다 (구 GPU_CPU_log.txt → make-csv.sh 단계 없음)
CSV_FINAL="$RUNDIR/GPU_CPU_${HOSTN}_${STAMP}.csv"
LOG="$CSV_FINAL"
EVENTS="$RUNDIR/max-events.log"        # 최고온도 갱신 이력 (화면 대신 파일로)
BURN_CSV="$RUNDIR/gadget_burn.csv"     # gadget_burn -o : GPU별 TFLOPS/Peak% 1Hz 기록
BURN_LOG="$RUNDIR/gadget_burn.log"     # gadget_burn 화면 출력 : 끝에 "최종 측정 결과" 박스

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
ms2s() { printf '%d.%d' $(($1/1000)) $(($1%1000/100)); }        # 밀리초 → "12.3"
# Peak% 색: gadget-burn 의 rpeak_color 와 같다 — ≥70 초록 / 60~69 노랑 / <60 빨강
peak_col() {
  if gt 60 "$1"; then printf '%s' "$C_R"
  elif gt 70 "$1"; then printf '%s' "$C_Y"
  else printf '%s' "$C_G"; fi
}

RULE="────────────────────────────────────────────────────────────────────────────────"

echo "$RULE"
echo " ${C_C}DEEPGadget SW 검수 번인${C_RST}  —  $HOSTN"
echo "   버전     : prodtech_inspection $PI_VERSION"
echo "   지속시간 : $DUR 초 ($(hms "$DUR"))     로그 샘플간격 : ${INTERVAL}s"
if [ "$DO_CPU" -eq 1 ]; then echo "   CPU      : ${NCPU} threads   (stress -c $NCPU -t $DUR)"
else                        echo "   CPU      : 부하 없음 (--no-cpu) — 온도만 기록"; fi
echo "   GPU      : ${GPUNAME} x${GPUCNT}   (gadget_burn -t $DUR)"
echo "   결과경로 : $RUNDIR"
echo "   사용도구 : $GADGET_BURN"
echo "              $SAMPLER"
# 구버전 gadget-burn(2026-09 이전 release 1.0)은 -o 가 없어 "invalid option -- 'o'" 로 시작 즉시 죽고
# stress 와 온도 로깅만 남는다. -h 출력에 "-o [" 가 있는지로 판별해 없으면 -o 없이 돌린다.
BURN_OPTS=(-t "$DUR")
BURN_OLD=0
if "$GADGET_BURN" -h 2>&1 | grep -q -- '-o \['; then
  BURN_OPTS+=(-o "$BURN_CSV")
else
  BURN_OLD=1
  echo "   ${C_Y}[!] 구버전 gadget-burn 입니다(-o 미지원). TFLOPS/Peak 표시 없이 번인만 진행합니다.${C_RST}"
  echo "   ${C_Y}    갱신: git -C $(dirname "$GADGET_BURN") pull --ff-only && make -C $(dirname "$GADGET_BURN")${C_RST}"
fi
echo "$RULE"

{
  echo "### version";    echo "prodtech_inspection $PI_VERSION"
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
show_cursor() { [ "$TTY" = 1 ] && printf '\e[?25h\e[?7h'; }   # 커서 표시 + 자동 줄바꿈 복구

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
  [ -n "$STRESS_PID" ] && wait "$STRESS_PID" 2>/dev/null
  wait "$GPUCPU_PID" 2>/dev/null

  chown -R "$RUN_USER": "$RUNDIR" 2>/dev/null

  # CSV 무결성 확인: 헤더와 데이터의 칼럼 수가 같아야 한다
  if [ -s "$CSV_FINAL" ]; then
    bad=$(awk -F',' 'NR==1{h=NF} NR>1 && NF!=h {c++} END{print c+0}' "$CSV_FINAL")
    [ "$bad" -gt 0 ] && echo "${C_Y}[!] 경고: 칼럼 수가 헤더와 다른 행이 ${bad}개 있습니다.${C_RST}"
  fi

  local samples=0
  [ -s "$LOG" ] && samples=$(( $(wc -l < "$LOG") - 1 ))
  echo
  echo "$RULE"
  echo " ${C_C}번인 $why${C_RST}  —  $HOSTN   ($(hms $(( $(date +%s) - START_EPOCH )))  경과, ${samples} 샘플)"
  echo "   ${C_R}CPU 최고온도  : ${cmax} °C${C_RST}"
  echo "   ${C_G}GPU 최고온도  : ${gmax} °C${C_RST}"
  # GPU 성능: gadget-burn 이 끝에 찍는 "최종 측정 결과" 박스(전체 측정 구간 누적 평균)를 그대로 옮긴다.
  # Ctrl-C 로 중단되면 gadget-burn 은 전력 캡만 복원하고 박스 없이 끝나므로 CSV 1Hz 값의 평균으로 대신한다.
  local -A FTF=() FPK=()
  local perf_src="" id tf pk
  if [ -s "$BURN_LOG" ]; then
    # "  GPU  0  <이름>" 다음의 "    ├ 성능         : 86.4321 TFLOPS   82.4%  (...)"
    while read -r id tf pk; do FTF[$id]=$tf; FPK[$id]=$pk; done < <(
      sed 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\r//g' "$BURN_LOG" | awk '
        /최종 측정 결과/ { box = 1 }
        box && $1 == "GPU" && $2 ~ /^[0-9]+$/ { id = $2 }
        box && $2 == "성능" && $5 == "TFLOPS" {
          p = $6; sub(/%$/, "", p); if (p !~ /^[0-9.]+$/) p = "-"
          print id, $4, p }')
    [ ${#FTF[@]} -gt 0 ] && perf_src="gadget-burn 최종 결과 (전체 측정 구간 평균)"
  fi
  if [ ${#FTF[@]} -eq 0 ] && [ -s "$BURN_CSV" ]; then
    while read -r id tf pk; do FTF[$id]=$tf; FPK[$id]=$pk; done < <(
      awk -F',' '/^#/ || $1 == "timestamp" || NF < 18 { next }
        { n[$6]++; t[$6] += $(NF-10); if ($(NF-9) != "") { pn[$6]++; p[$6] += $(NF-9) } }
        END { for (i in n) printf "%s %.4f %s\n", i, t[i]/n[i], (pn[i] ? sprintf("%.1f", p[i]/pn[i]) : "-") }' "$BURN_CSV")
    [ ${#FTF[@]} -gt 0 ] && perf_src="gadget_burn.csv 1Hz 값 평균 (최종 결과 박스 없음 — 중단됨)"
  fi

  local gi pcol
  for gi in $(printf '%s\n' "${!GMAX[@]}" | sort -n); do
    tf=${FTF[$gi]:--}; pk=${FPK[$gi]:--}; pcol=""
    if [ "$pk" != "-" ]; then pcol=$(peak_col "$pk"); pk="${pk}%"; fi
    printf '     GPU%-3s 최고 %s°C   TFLOPS %s  Peak %s%s%s   Throttle 열 %ss / 전력 %ss\n' "$gi" "${GMAX[$gi]}" \
      "$tf" "$pcol" "$pk" "$C_RST" "$(ms2s "${THT[$gi]}")" "$(ms2s "${THW[$gi]}")"
  done
  if [ -n "$perf_src" ]; then
    [ ${#FTF[@]} -gt 1 ] && echo "   GPU TFLOPS 합계 : ${C_G}$(printf '%s\n' "${FTF[@]}" | awk '{s+=$1} END{printf "%.4f", s}')${C_RST}"
    echo "   ${C_D}TFLOPS/Peak 기준 : ${perf_src}${C_RST}"
  else
    local gerr
    gerr=$(sed 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\r//g' "$BURN_LOG" 2>/dev/null | grep -m1 -iE 'ERR|error|실패')
    if [ "$BURN_OLD" = 1 ] && [ -z "$gerr" ]; then
      echo "   ${C_Y}[!] GPU 성능값 없음 — 구버전 gadget-burn(-o 미지원)이라 TFLOPS 기록이 없습니다${C_RST}"
    else
      echo "   ${C_R}[!] GPU 성능값 없음 — gadget_burn 이 측정 전에 끝났습니다${gerr:+ ($gerr)}${C_RST}"
    fi
    echo "       확인: $BURN_LOG"
  fi
  echo "   NVMe 최고온도 : ${nmax} °C"
  echo "$RULE"
  echo "   검수 CSV   : ${C_B}$CSV_FINAL${C_RST}"
  [ -s "$RUNDIR/gadget_burn.csv" ] && echo "   burn CSV   : $RUNDIR/gadget_burn.csv"
  echo "   최고온도 이력 : $EVENTS"
  echo "   시스템정보 : $RUNDIR/system_info.txt"
  echo "$RULE"
  echo
  echo "다운로드 (워크스테이션에서):"
  # 서버에 IP 가 여러 개일 수 있어(BMC·gadget 가상 NIC 포함) 하나를 고르지 않고 전부 보여준다
  echo "  scp ${RUN_USER}@<서버IP>:${CSV_FINAL} ."
  echo "  이 서버 IPv4: $(hostname -I | tr ' ' '\n' | grep -E '^[0-9]+\.' | tr '\n' ' ')"
}

# ---------------------------------------------------------------- 실행
START_EPOCH=$(date +%s)

"$GADGET_BURN" "${BURN_OPTS[@]}" > "$BURN_LOG" 2>&1 &
BURN_PID=$!

STRESS_PID=""
if [ "$DO_CPU" -eq 1 ]; then
  stress -c "$NCPU" -t "$DUR" > "$RUNDIR/stress.log" 2>&1 &
  STRESS_PID=$!
fi

"$SAMPLER" "$INTERVAL" "$DUR" "$CSV_FINAL" > "$RUNDIR/sample-sensors.log" 2>&1 &
GPUCPU_PID=$!

PIDS=("$BURN_PID" ${STRESS_PID:+"$STRESS_PID"} "$GPUCPU_PID")
trap on_int INT TERM

echo "${C_D}  gadget_burn pid=$BURN_PID / stress pid=${STRESS_PID:-없음(--no-cpu)} / sample-sensors pid=$GPUCPU_PID${C_RST}"
echo "  로그 준비 중..."

for _ in $(seq 1 30); do [ -s "$LOG" ] && break; sleep 1; done
[ -s "$LOG" ] || { echo "${C_R}[!] $LOG 이 생성되지 않았습니다. sample-sensors.log 확인 필요.${C_RST}"; cleanup; exit 1; }

# CSV 헤더에서 첫 NVMe 온도 칼럼 위치를 찾아 둔다 (칼럼 수는 장비마다 다르다)
NVME_COL=$(head -1 "$LOG" | awk -F',' '{for(i=1;i<=NF;i++) if($i ~ /^nvme[0-9]+_Temp/) {print i; exit}}')
NVME_COL=${NVME_COL:-0}

# ---------------------------------------------------------------- 모니터링
gmax=-1; cmax=-1; nmax=-1
th_therm=0; th_brake=0        # 어느 GPU 든 열 / HW Power Brake 쓰로틀이던 누적(ms)
declare -A GMAX THT THW       # GPU별 최고온도 / 열 쓰로틀 누적(ms) / HW Power Brake 누적(ms)
LAST_MS=0                     # 직전 render 시각(ms) — 누적은 실제 경과시간으로 더한다
PREV_LINES=0
: > "$EVENTS"
# 커서 숨김 + 자동 줄바꿈(DECAWM) 끔: 표가 터미널 폭보다 넓어도 줄이 접히지 않고 오른쪽만
# 잘린다. 접히면 줄 수가 늘어 \e[NA 제자리 갱신이 어긋나 화면이 흘러내린다.
[ "$TTY" = 1 ] && printf '\e[?25l\e[?7l'

# 표 서식 — 컬럼 정렬이 깨지지 않도록 데이터 칸은 ASCII 숫자만 넣는다
#            (한글/°는 폭이 2칸이라 printf 의 %Ns 패딩과 어긋난다)
GFMT_H=' %3s  %-14s %5s %5s  %7s  %13s  %5s  %8s  %6s  %s'

bar() {   # bar <percent> <width>
  local pct=$1 w=$2 f i s=""
  f=$(( pct * w / 100 )); [ "$f" -gt "$w" ] && f=$w
  for ((i=0;i<f;i++)); do s+="█"; done
  for ((i=f;i<w;i++)); do s+="░"; done
  printf '%s' "$s"
}

# gadget_burn.csv 에서 GPU별 최신 1Hz 행의 TFLOPS / Peak% 를 읽는다.
# gadget-burn 이 자기 화면과 같은 값(최근 10초 슬라이딩 윈도우, Peak% = TFLOPS / 현재 클럭 기준 Rpeak)을
# 매초 기록하고 flush 하므로 다시 계산하지 않고 그대로 옮긴다. 측정 루프 전(init/autotune)엔 행이 없다.
# 칼럼: ...,gpu_id($6),gpu_name,tflops,peak_pct,rpeak_tflops,power_w,tdp_pct,util_pct,clock_mhz,
#       temp_edge_c,temp_junction_c,throttle,vram_mib — gpu_name 에 쉼표가 있어도 되게 뒤쪽은 NF 기준.
# gpu_id 는 gadget-burn 이 CUDA_DEVICE_ORDER=PCI_BUS_ID 로 매긴 BDF 순 번호라 nvidia-smi index 와 같다.
declare -A BTF BPK
BTOT=""
burn_latest() {
  BTF=(); BPK=(); BTOT=""
  [ -s "$BURN_CSV" ] || return 0
  local id tf pk
  while read -r id tf pk; do
    if [ "$id" = "T" ]; then BTOT=$tf; continue; fi
    BTF[$id]=$tf; BPK[$id]=$pk
  done < <(tail -n $(( GPUCNT * 3 + 40 )) "$BURN_CSV" | awk -F',' '
      /^#/ || $1 == "timestamp" || NF < 18 { next }
      { tf[$6] = $(NF-10); pk[$6] = $(NF-9) }
      END { s = 0; n = 0
            for (i in tf) { print i, tf[i], (pk[i] == "" ? "-" : pk[i]); s += tf[i]; n++ }
            if (n) printf "T %.3f -\n", s }')
}

render() {
  local -a FRAME=()
  local el=$(( $(date +%s) - START_EPOCH ))
  local rem=$(( DUR - el )); [ "$rem" -lt 0 ] && rem=0
  local pct=$(( el * 100 / (DUR>0?DUR:1) )); [ "$pct" -gt 100 ] && pct=100

  # 한 바퀴는 REFRESH + nvidia-smi/sensors 호출 시간이라 고정 +REFRESH 로 더하면 어긋난다
  local now_ms dt_ms=0
  now_ms=$(date +%s%3N)
  [ "$LAST_MS" -gt 0 ] && dt_ms=$(( now_ms - LAST_MS ))
  LAST_MS=$now_ms

  # 터미널 높이보다 프레임이 길어지면 제자리 갱신이 깨지므로 장식 줄을 뺀다
  # sudo 로 승격하면 stdin 이 tty 가 아닐 수 있어 tput 이 실제 높이 대신 24 를 준다 → /dev/tty 우선
  local tl_rows
  tl_rows=$({ stty size < /dev/tty; } 2>/dev/null | awk '{print $1}')
  [ -z "$tl_rows" ] && tl_rows=$(tput lines 2>/dev/null)
  [ -z "$tl_rows" ] && tl_rows=24
  local need=$(( 8 + GPUCNT ))          # 고정 8줄 + GPU 행
  local slim=0; [ "$need" -ge "$tl_rows" ] && slim=1

  burn_latest
  local tfl_txt
  if [ -n "$BTOT" ]; then tfl_txt="합계 ${C_G}${BTOT}${C_RST} TFLOPS"
  elif [ "$BURN_OLD" = 1 ]; then
    if kill -0 "$BURN_PID" 2>/dev/null; then tfl_txt="${C_Y}TFLOPS: 구버전 gadget-burn (-o 미지원) — 표시 없음${C_RST}"
    else tfl_txt="${C_R}TFLOPS: gadget_burn 종료됨 → gadget_burn.log 확인${C_RST}"; fi
  elif ! kill -0 "$BURN_PID" 2>/dev/null; then
    # 측정 루프 전에 죽으면(예: 다른 프로세스가 VRAM 을 잡아 init 중 out of memory) CSV 행이 영영 없다
    tfl_txt="${C_R}TFLOPS: gadget_burn 이 측정 전에 종료됨 → gadget_burn.log 확인${C_RST}"
  else tfl_txt="${C_D}TFLOPS: gadget_burn 초기화 중${C_RST}"; fi

  if [ "$slim" = 0 ]; then
    FRAME+=("$RULE")
    FRAME+=(" ${C_C}DEEPGadget SW 검수 번인${C_RST} · ${C_B}${HOSTN}${C_RST}   경과 $(hms "$el") / $(hms "$DUR")   남은시간 $(hms "$rem")")
    FRAME+=(" $(bar "$pct" 46) ${pct}%   ${tfl_txt}")
    FRAME+=("$RULE")
  else
    FRAME+=(" ${C_C}번인${C_RST} ${C_B}${HOSTN}${C_RST}  $(hms "$el")/$(hms "$DUR")  남은 $(hms "$rem")  ${pct}%  ${tfl_txt}")
  fi

  # ---- GPU : nvidia-smi 1회 호출로 전 GPU 조회, 1장이든 10장이든 한 행씩
  local q
  q=$($NVSMI --query-gpu=index,temperature.gpu,temperature.gpu.tlimit,power.draw,enforced.power.limit,utilization.gpu,pci.bus_id,$TR.sw_thermal_slowdown,$TR.hw_thermal_slowdown,$TR.hw_power_brake_slowdown \
        --format=csv,noheader,nounits 2>/dev/null)

  local hdr; printf -v hdr "$GFMT_H" "GPU" "PCI ADDRESS" "TEMP" "MAX" "SLOWDN" "POWER W" "UTIL" "TFLOPS" "PEAK" "THROTTLE  열 / 전력 누적"
  FRAME+=("${C_D}${hdr}${C_RST}")

  local gi gt_ tl pd pl ut bdf r_swt r_hwt r_pwb
  local any_th=0 any_pb=0
  while IFS=',' read -r gi gt_ tl pd pl ut bdf r_swt r_hwt r_pwb; do
    [ -z "${gi:-}" ] && continue
    gi=${gi// /}; gt_=${gt_// /}; tl=${tl// /}; pd=${pd// /}; pl=${pl// /}; ut=${ut// /}
    # nvidia-smi 는 "00000000:C1:00.0" 로 준다 → lspci 표기 "0000:c1:00.0" 로 맞춘다
    bdf=$(echo "$bdf" | tr -d ' ' | tr 'A-F' 'a-f'); bdf=${bdf: -12}
    # "Not Active" 가 *" Active"* 패턴에 걸리므로 공백 제거 후 정확히 비교할 것
    r_swt=${r_swt// /}; r_hwt=${r_hwt// /}; r_pwb=${r_pwb// /}

    : "${GMAX[$gi]:=-1}"; : "${THT[$gi]:=0}"; : "${THW[$gi]:=0}"
    if gt "$gt_" "${GMAX[$gi]}"; then
      [ "${GMAX[$gi]}" != "-1" ] && echo "$(date '+%H:%M:%S') GPU${gi} ${bdf} MAX ${GMAX[$gi]} -> ${gt_} C" >> "$EVENTS"
      GMAX[$gi]=$gt_
    fi
    gt "$gt_" "$gmax" && gmax=$gt_

    # 쓰로틀 기준은 gadget-burn 과 같다: 열(SW/HW Thermal Slowdown) > HW Power Brake.
    # SW Power Cap 은 TDP 를 다 쓰는 정상 상태라 보지 않는다.
    # 주의: 산술식 안의 THT[gi] 는 첨자를 문자열 "gi" 로 해석해 전 GPU 가 키를 공유한다.
    local capmark="-" thcol="$C_D"
    if [ "$r_swt" = "Active" ] || [ "$r_hwt" = "Active" ]; then
      THT[$gi]=$(( ${THT[$gi]} + dt_ms )); any_th=1
      capmark="THERM"; thcol="$C_R"
    fi
    if [ "$r_pwb" = "Active" ]; then
      THW[$gi]=$(( ${THW[$gi]} + dt_ms )); any_pb=1
      [ "$capmark" = "-" ] && { capmark="PWR"; thcol="$C_Y"; }
    fi

    local tcol="$C_G"
    gt "$gt_" 80 && tcol="$C_Y"
    gt "$gt_" 88 && tcol="$C_R"
    [ -z "$tl" ] || [ "$tl" = "N/A" ] && tl="-"

    local r f
    printf -v r  ' %3s  ' "$gi"
    printf -v f  '%-14s ' "$bdf";                r+="$f"
    printf -v f  '%5s'    "$gt_";                r+="${tcol}${f}${C_RST}"
    printf -v f  ' %5s  ' "${GMAX[$gi]}";        r+="$f"
    printf -v f  '%7s  '  "$tl";                 r+="$f"
    printf -v f  '%13s  ' "${pd}/${pl}";         r+="$f"
    printf -v f  '%4s%%  ' "$ut";                r+="$f"
    local tf=${BTF[$gi]:--} pk=${BPK[$gi]:--} pcol="$C_D"
    if [ "$pk" != "-" ]; then pcol=$(peak_col "$pk"); pk="${pk}%"; fi
    printf -v f  '%8s  '  "$tf";                 r+="$f"
    printf -v f  '%6s'    "$pk";                 r+="${pcol}${f}${C_RST}  "
    printf -v f  '%-5s '  "$capmark";            r+="${thcol}${f}${C_RST}"
    r+="${C_D}열 $(ms2s "${THT[$gi]}")s / 전력 $(ms2s "${THW[$gi]}")s${C_RST}"
    FRAME+=("$r")
  done <<< "$q"
  [ "$any_th" = 1 ] && th_therm=$(( th_therm + dt_ms ))
  [ "$any_pb" = 1 ] && th_brake=$(( th_brake + dt_ms ))

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
  FRAME+=(" ${C_B}CPU ${C_RST}  ${ccol}${cnow}°C${C_RST} (max ${cmax}°C)   소켓별 [ ${call} ]   $([ "$DO_CPU" -eq 1 ] && echo "${NCPU} threads @ stress" || echo "부하 없음 (--no-cpu)")")

  # ---- NVMe / 샘플수 (수집기 CSV 의 마지막 줄에서)
  local last nnow samples
  last=$(tail -n 1 "$LOG" 2>/dev/null)
  nnow=$(awk -F',' -v c="$NVME_COL" 'c>0{print $c}' <<<"$last" | tr -dc '0-9'); [ -z "$nnow" ] && nnow="-1"
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
      printf '[%s] GPU max %s°C  CPU %s°C(max %s)  NVMe %s°C  TFLOPS 합계 %s  Throttle 열 %ss / 전력 %ss\n' \
        "$(hms "$el")" "$gmax" "$cnow" "$cmax" "$nnow" "${BTOT:--}" "$(ms2s "$th_therm")" "$(ms2s "$th_brake")"
    fi
  fi
}

while kill -0 "$GPUCPU_PID" 2>/dev/null; do
  render
  sleep "$REFRESH"
done

finish "완료"
