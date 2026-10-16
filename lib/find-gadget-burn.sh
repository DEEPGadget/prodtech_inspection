#!/usr/bin/env bash
#
# find-gadget-burn.sh — gadget_burn 실행파일을 찾아 절대경로를 stdout 에 찍는다.
#
#   사용법: find-gadget-burn.sh <저장소 경로> [사용자 홈]
#   종료:   0 = 찾음 (stdout 에 경로 한 줄)
#           1 = 못 찾음 (stderr 에 찾아본 위치 목록과 조치 안내)
#
# run-burnin.sh / inspect.sh / functest.sh 가 같은 순서로 찾도록 한 곳에 모았다.
# run-burnin.sh 는 sudo 로 재실행되므로 PATH 가 secure_path 로 바뀌고 $HOME 이 /root 가 된다.
# 그래서 호출자가 "원래 사용자 홈"을 2번째 인자로 넘기고, PATH 밖의 흔한 위치도 직접 본다.
#
# 찾는 순서:
#   1) BURN_DIR                — 디렉터리면 그 안의 gadget_burn, 실행파일이면 그 자체
#   2) <저장소>/gadget-burn      — setup.sh 가 clone+make 하는 위치
#   3) <저장소>/../gadget-burn   — 저장소 옆에 따로 둔 경우
#   4) <홈>/gadget-burn          — setup.sh 를 안 쓰는 서버(Rocky 등)에서 손으로 빌드해 둔 위치
#   5) PATH, <홈>/.local/bin, /usr/local/bin

set -u

REPO=${1:?사용법: $0 <저장소 경로> [사용자 홈]}
UHOME=${2:-${HOME:-/root}}

CANDS=()
if [[ -n "${BURN_DIR:-}" ]]; then
    if [[ -d "$BURN_DIR" ]]; then CANDS+=("$BURN_DIR/gadget_burn"); else CANDS+=("$BURN_DIR"); fi
fi
CANDS+=("$REPO/gadget-burn/gadget_burn"
        "$REPO/../gadget-burn/gadget_burn"
        "$UHOME/gadget-burn/gadget_burn")
p=$(command -v gadget_burn 2>/dev/null) && [[ -n "$p" ]] && CANDS+=("$p")
CANDS+=("$UHOME/.local/bin/gadget_burn" "/usr/local/bin/gadget_burn")

declare -A SEEN=()
TRIED=()
for c in "${CANDS[@]}"; do
    # ../ 같은 상대 요소를 정리한 경로로 중복을 걸러낸다 (없는 경로면 입력 그대로 둔다)
    n=$(readlink -m -- "$c" 2>/dev/null || printf '%s' "$c")
    [[ -n "${SEEN[$n]:-}" ]] && continue
    SEEN[$n]=1; TRIED+=("$n")
    if [[ -f "$n" && -x "$n" ]]; then printf '%s\n' "$n"; exit 0; fi
done

{
    echo "gadget_burn 을 찾을 수 없습니다. 찾아본 위치:"
    for c in "${TRIED[@]}"; do echo "    $c"; done
    echo "  → 이미 빌드해 둔 곳이 있으면  BURN_DIR=/그/경로  를 앞에 붙여 다시 실행하세요."
    echo "    (functest.sh 는 --burn-dir /그/경로 로도 됩니다)"
    echo "  → 없으면 저장소에서 ./setup.sh 를 돌려 <저장소>/gadget-burn 에 빌드하세요."
} >&2
exit 1
