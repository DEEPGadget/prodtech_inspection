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
