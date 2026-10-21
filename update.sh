#!/usr/bin/env bash
#
# update.sh — prodtech_inspection 을 GitHub 의 최신 태그(v*)로 업데이트한다
#
#   다른 스크립트(setup / inspect / functest / run-burnin)는 최신 태그보다 낮은 버전이면
#   실행하지 않고 이 스크립트를 안내한다. 업데이트는 여기서만 한다.
#
#   - 기준은 main 이 아니라 태그. 태그를 단 버전만 배포된다
#   - 서버에서 손댄 파일이 있으면(-dirty) 덮어쓰지 않고 멈춘다
#   - 번인/기능 테스트가 돌고 있으면 멈춘다 (실행 중인 스크립트의 파일을 바꾸지 않도록)
#   - git merge --ff-only 로만 옮긴다. 로컬 커밋이 섞여 있으면 멈춘다
#
# 사용법:
#   ./update.sh            # 최신 태그로 업데이트
#   ./update.sh --check    # 최신 여부만 확인 (바꾸지 않음)

set -uo pipefail

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    echo "root 로 실행하지 마세요. 저장소를 clone 한 계정으로 실행하세요." >&2
    exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/lib/version.sh"
CHECK_ONLY=0
for a in "$@"; do
    case "$a" in
        --check) CHECK_ONLY=1 ;;
        -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
        --version) echo "prodtech_inspection $PI_VERSION"; exit 0 ;;
        *) echo "알 수 없는 옵션: $a" >&2; exit 1 ;;
    esac
done

C_R=$'\033[1;31m'; C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'; C_RST=$'\033[0m'
bad() { printf '%s%s%s\n' "$C_R" "$*" "$C_RST" >&2; }

[[ -e "$SCRIPT_DIR/.git" ]] || { bad "git clone 한 폴더가 아닙니다: $SCRIPT_DIR — 새로 clone 하세요."; exit 1; }
G() { git -C "$SCRIPT_DIR" "$@"; }

printf '현재 버전 : prodtech_inspection %s\n' "$PI_VERSION"

# 최신 태그 받아오기
if ! GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10" \
     timeout 60 git -C "$SCRIPT_DIR" fetch --quiet --tags origin; then
    bad "GitHub 에서 받아오지 못했습니다 — 네트워크 / $(G remote get-url origin 2>/dev/null) 접근을 확인하세요."
    exit 1
fi
LATEST=$(G tag -l 'v*' | sort -V | tail -1)
[[ -n "$LATEST" ]] || { bad "원격에 v* 태그가 없습니다."; exit 1; }
CUR=$(G describe --tags --abbrev=0 --match 'v*' 2>/dev/null)
printf '최신 버전 : %s\n' "$LATEST"

if [[ -n "$CUR" && "$(printf '%s\n%s\n' "$CUR" "$LATEST" | sort -V | tail -1)" == "$CUR" ]]; then
    printf '%s이미 최신입니다.%s\n' "$C_G" "$C_RST"
    exit 0
fi

printf '\n%s → %s 변경 내역:\n' "${CUR:-?}" "$LATEST"
G log --no-merges --format='  - %s' "${CUR:+$CUR..}$LATEST" | head -30
printf '\n'
[[ "$CHECK_ONLY" -eq 1 ]] && { printf '%s업데이트가 필요합니다 → %s/update.sh%s\n' "$C_Y" "$SCRIPT_DIR" "$C_RST"; exit 1; }

# 서버에서 손댄 파일이 있으면 덮어쓰지 않는다
if [[ -n "$(G status --porcelain --untracked-files=no)" ]]; then
    bad "이 폴더에 수정된 파일이 있어 업데이트하지 않습니다 (덮어쓰면 수정분이 사라짐):"
    G status --short --untracked-files=no | sed 's/^/     /' >&2
    printf '   필요 없으면 git -C %s checkout -- . 로 되돌린 뒤 다시 실행하세요.\n' "$SCRIPT_DIR" >&2
    exit 1
fi

# 번인 / 기능 테스트 / 검수가 돌고 있으면 멈춘다.
# 명령줄 어딘가에 이름만 있는 경우(편집기, 다른 셸의 -c 문자열 등)는 빼고, bash 가 그 스크립트를
# 실행 중인 프로세스("bash ./run-burnin.sh ...")만 잡는다. 다른 클론에서 돌고 있어도 보수적으로 멈춘다.
RUNNING=$(pgrep -af '^([^ ]*/)?bash ([^ ]*/)?(run-burnin|functest|inspect|setup)\.sh( |$)' 2>/dev/null)
if [[ -n "$RUNNING" ]]; then
    bad "검수 스크립트가 실행 중이라 업데이트하지 않습니다. 끝난 뒤 다시 실행하세요:"
    printf '%s\n' "$RUNNING" | cut -c1-120 | sed 's/^/     /' >&2
    exit 1
fi

if ! G merge --quiet --ff-only "$LATEST"; then
    bad "$LATEST 로 fast-forward 할 수 없습니다 (이 폴더에 따로 만든 커밋이 있음)."
    printf '   현장 수정 클론이면 그대로 쓰면서 --skip-version-check 로 실행하거나, 새로 clone 하세요.\n' >&2
    exit 1
fi

unset PI_VERSION; source "$SCRIPT_DIR/lib/version.sh"
printf '%s완료: prodtech_inspection %s%s\n' "$C_G" "$PI_VERSION" "$C_RST"
