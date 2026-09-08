#!/usr/bin/env bash
#
# setup.sh — run-burnin.sh 실행에 필요한 것만 설치한다.
#
#   1) apt 패키지 : stress, lm-sensors, nvme-cli, ipmitool, pciutils,
#                   ifupdown-extra, build-essential, git
#   2) gadget-burn : clone + make  (CUDA 필요)
#
# 검수 스크립트(inspect.sh)와 분리해 둔 이유:
#   make 출력이 수백 줄이라 같이 돌리면 HW 체크·서버 설정 결과가 묻힌다.
#   설치는 장비당 한 번만 하면 되고, 검수는 여러 번 돌린다.
#
# 사용법:
#   ./setup.sh              # 저장소 안(./gadget-burn)에 설치
#   ./setup.sh /opt/bench   # 원하는 경로에 gadget-burn 설치
#
# 로그는 실행한 디렉터리에 setup_<host>_<시각>.log 로 남는다.

set -uo pipefail

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    echo "root 로 실행하지 마세요. 현재 사용자 계정으로 실행하면 필요할 때만 sudo 를 씁니다." >&2
    exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BASE_DIR="${1:-$SCRIPT_DIR}"
LOG_FILE="$PWD/setup_$(hostname)_$(date +%Y%m%d_%H%M%S).log"

mkdir -p "$BASE_DIR" || { echo "설치 경로를 만들 수 없습니다: $BASE_DIR" >&2; exit 1; }
exec > >(tee -a "$LOG_FILE") 2>&1

# CUDA: 인스톨러가 ~/.bashrc 끝에 넣는 PATH 는 비대화형 셸에서 로드되지 않으므로 직접 넣는다.
CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"
if [[ -d "$CUDA_HOME/bin" ]]; then
    export CUDA_HOME
    export PATH="$CUDA_HOME/bin:$PATH"
    export LD_LIBRARY_PATH="$CUDA_HOME/lib64:${LD_LIBRARY_PATH:-}"
fi

RESULTS=()
log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[WARN] %s\033[0m\n' "$*"; }
err()  { printf '\033[1;31m[FAIL] %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ] %s\033[0m\n' "$*"; }
record() { RESULTS+=("$1|$2|$3"); }

log "sudo 권한 확인"
sudo -v || { err "sudo 권한이 필요합니다."; exit 1; }

# ---------------------------------------------------------------- apt 패키지
# NOTE: apt-daily 타이머가 /var/lib/dpkg/lock 을 잡고 있으면 "Could not get lock" 이
#       난다. inspect.sh 가 그 타이머를 mask 하므로, 잠기면 inspect.sh 를 먼저 돌릴 것.
PKGS=(stress lm-sensors nvme-cli ipmitool pciutils ifupdown-extra build-essential git)
log "apt 패키지 설치: ${PKGS[*]}"
sudo apt-get update
if sudo apt-get install -y "${PKGS[@]}"; then
    ok "apt 패키지 설치 완료"
    record OK "apt 패키지" "${PKGS[*]}"
else
    err "apt 패키지 설치 실패"
    record FAIL "apt 패키지" "apt-get install 실패 — 위 로그의 apt 구간 확인"
fi

# ---------------------------------------------------------------- gadget-burn
log "gadget-burn: clone/pull + make  (설치 경로: $BASE_DIR/gadget-burn)"
if [[ -d "$BASE_DIR/gadget-burn/.git" ]]; then
    git -C "$BASE_DIR/gadget-burn" pull --ff-only
else
    git clone https://github.com/DEEPGadget/gadget-burn.git "$BASE_DIR/gadget-burn"
fi

if [[ ! -d "$BASE_DIR/gadget-burn" ]]; then
    err "gadget-burn clone 실패"
    record FAIL "gadget-burn" "clone 실패 — 네트워크/접근권한 확인"
elif ! command -v nvcc >/dev/null 2>&1 && [[ ! -x "$CUDA_HOME/bin/nvcc" ]]; then
    warn "CUDA(nvcc)가 없어 gadget-burn 빌드를 건너뜁니다."
    record SKIP "gadget-burn" "clone만 완료 / CUDA(nvcc) 없음 — 드라이버·툴킷 설치 후 재실행"
elif make -C "$BASE_DIR/gadget-burn"; then
    ok "gadget-burn make 완료: $BASE_DIR/gadget-burn/gadget_burn"
    record OK "gadget-burn" "clone + make 완료"
else
    err "gadget-burn make 실패"
    record FAIL "gadget-burn" "clone은 됨 / make 실패 — 위 로그의 make 구간 확인"
fi

# ---------------------------------------------------------------- sensors 초기화
if command -v sensors >/dev/null 2>&1; then
    if sensors 2>/dev/null | grep -qE 'Tctl|Package id'; then
        ok "sensors: CPU 온도 센서 인식됨"
        record OK "lm-sensors" "$(sensors 2>/dev/null | grep -cE 'Tctl|Package id')개 CPU 온도 센서 인식"
    else
        warn "sensors 에서 CPU 온도(Tctl/Package id)를 찾지 못했습니다. 'sudo sensors-detect --auto' 후 재확인하세요."
        record FAIL "lm-sensors" "Tctl/Package id 없음 — sudo sensors-detect --auto 필요"
    fi
fi

# ---------------------------------------------------------------- 요약
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
        printf '   %-20s %s\n' "$name" "$detail"
    done
    return "$count"
}

printf '\n\033[1;34m========================================================\033[0m\n'
printf '\033[1;34m  setup 결과 요약\033[0m\n'
printf '\033[1;34m========================================================\033[0m\n'
print_group OK   "✅ 잘 된 것"    32 || OK_COUNT=$?
print_group FAIL "❌ 잘 안 된 것" 31 || FAIL_COUNT=$?
print_group SKIP "⚠️  건너뛴 것"  33 || SKIP_COUNT=$?
OK_COUNT=${OK_COUNT:-0}; FAIL_COUNT=${FAIL_COUNT:-0}; SKIP_COUNT=${SKIP_COUNT:-0}

printf '\n'; printf '%s\n' '--------------------------------------------------------'
printf '  성공 %d / 실패 %d / 생략 %d\n' "$OK_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
printf '  로그 : %s\n' "$LOG_FILE"
printf '%s\n' '--------------------------------------------------------'
printf '\n  다음 단계:\n'
printf '    ./inspect.sh        # 하드웨어 점검 + 서버 설정\n'
printf '    ./run-burnin.sh     # 1시간 번인 (결과는 실행한 디렉터리에 생성)\n\n'

[[ $FAIL_COUNT -gt 0 ]] && exit 1
exit 0
