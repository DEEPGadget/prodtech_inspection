#!/usr/bin/env bash
#
# version.sh — prodtech_inspection 버전 문자열을 PI_VERSION 에 넣는다 (각 스크립트가 source 한다)
#
#   기준은 저장소 루트의 VERSION 파일. git clone 이면 git describe 로 태그 이후 커밋 수와
#   로컬 수정 여부까지 붙여, 서버의 클론이 최신인지 화면에서 바로 보이게 한다.
#     v1.0                 태그 v1.0 그대로
#     v1.0-3-g81d8702      v1.0 이후 커밋 3개가 더 있는 상태
#     v1.0-dirty           서버에서 파일을 손댄 상태
#   scp 로 복사해 .git 이 없으면 VERSION 값만 쓴다.
#   PI_VERSION 이 이미 있으면 그대로 둔다 — run-burnin.sh 는 sudo 재실행 전에 계산한 값을
#   넘긴다(root 로는 git 이 다른 사용자의 저장소를 거부해 describe 가 실패한다).
#
# pi_check_latest — GitHub 의 최신 태그보다 낮은 버전이면 실행을 막는다 (각 스크립트가 옵션 처리 뒤 부른다)
#   - 비교 기준은 main 이 아니라 태그(v*). 태그를 달아야 배포된다
#   - 최신 태그를 못 받아오면(오프라인 등) 경고만 하고 그대로 실행한다
#   - --skip-version-check 또는 PI_SKIP_VERSION_CHECK=1 이면 건너뛴다 (긴급 우회 / 현장 수정 클론)
#   - 한 번 확인하면 PI_VERSION_CHECKED=1 을 export 해, functest 가 부르는 inspect / run-burnin 은 다시 안 본다

if [[ -z "${PI_VERSION:-}" ]]; then
    _pi_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
    PI_VERSION="v$(tr -d '[:space:]' < "$_pi_root/VERSION" 2>/dev/null)"
    [[ "$PI_VERSION" == v ]] && PI_VERSION="v?"
    if [[ -e "$_pi_root/.git" ]] && _pi_desc=$(git -C "$_pi_root" describe --tags --dirty --match 'v*' 2>/dev/null); then
        # VERSION 을 올렸는데 아직 태그를 안 달았으면 둘 다 보여준다
        if [[ "$_pi_desc" == "$PI_VERSION" || "$_pi_desc" == "$PI_VERSION"-* ]]; then
            PI_VERSION=$_pi_desc
        else
            PI_VERSION="$PI_VERSION ($_pi_desc)"
        fi
    fi
    unset _pi_root _pi_desc
fi

pi_check_latest() {
    [[ -n "${PI_VERSION_CHECKED:-}" ]] && return 0
    export PI_VERSION_CHECKED=1
    local root cur latest
    root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
    if [[ "${PI_SKIP_VERSION_CHECK:-0}" == 1 ]]; then
        printf '\033[1;33m[버전] 최신 버전 확인을 건너뜁니다 (--skip-version-check)\033[0m\n' >&2
        return 0
    fi
    if [[ ! -e "$root/.git" ]]; then
        printf '\033[1;33m[버전] git clone 한 폴더가 아니라 최신 여부를 확인할 수 없습니다 → 그대로 실행\033[0m\n' >&2
        return 0
    fi
    # 원격 태그 목록만 받는다(수 KB). 프롬프트가 뜨거나 오래 걸리면 포기한다.
    latest=$(GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=5" \
             timeout 5 git -C "$root" ls-remote --tags --refs origin 'v*' 2>/dev/null \
             | awk '{sub("refs/tags/", "", $2); print $2}' | sort -V | tail -1)
    if [[ -z "$latest" ]]; then
        printf '\033[1;33m[버전] GitHub 에서 최신 버전을 확인하지 못했습니다(네트워크?) → 현재 %s 로 실행\033[0m\n' "$PI_VERSION" >&2
        return 0
    fi
    # 현재 커밋이 기반으로 하는 가장 가까운 태그. 태그 이후 개발 커밋이 있어도 그 태그 기준으로 본다.
    cur=$(git -C "$root" describe --tags --abbrev=0 --match 'v*' 2>/dev/null)
    if [[ -n "$cur" && "$(printf '%s\n%s\n' "$cur" "$latest" | sort -V | tail -1)" == "$cur" ]]; then
        return 0
    fi
    printf '\033[1;31m[버전] 현재 %s — 최신은 %s 입니다. 구버전으로는 실행하지 않습니다.\033[0m\n' "$PI_VERSION" "$latest" >&2
    printf '       %s/update.sh 로 업데이트한 뒤 다시 실행하세요.\n' "$root" >&2
    printf '       (급하게 지금 버전으로 돌려야 하면 --skip-version-check)\n' >&2
    exit 1
}
