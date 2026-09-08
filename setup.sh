#!/usr/bin/env bash
#
# setup.sh — SW 검수용 서버 설정 + 도구 설치
#
#   PART A. 서버 설정 (실제로 값을 바꾸는 쪽)
#     자동 업데이트 차단 / 전원관리 / Time Zone /
#     NVIDIA Persistence Mode / OS ACS Disable / GRUB 점검·안내
#   PART B. 도구 설치
#     apt 패키지 + gadget-burn + deepgadget-log-grabber
#     --full 이면 nccl-tests / gpu-burn / fio 까지
#
# 설정을 바꾸는 것은 이 스크립트뿐이다. inspect.sh 는 확인만 한다.
#
# 사용법:
#   ./setup.sh                    # 설정 + 검수/번인 기본 도구
#   ./setup.sh --full             # + 벤치마크/진단 도구 전부
#   ./setup.sh --full /opt/bench  # 외부 저장소를 다른 경로에 설치
#
# 결과는 실행한 디렉터리 아래 setup_<host>_<시각>/setup.log 로 남는다.

set -uo pipefail

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    echo "root 로 실행하지 마세요. 현재 사용자 계정으로 실행하면 필요할 때만 sudo 를 씁니다." >&2
    exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
FULL=0
BASE_DIR=""
for a in "$@"; do
    case "$a" in
        --full) FULL=1 ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        -*) echo "알 수 없는 옵션: $a" >&2; exit 1 ;;
        *)  BASE_DIR="$a" ;;
    esac
done
BASE_DIR="${BASE_DIR:-$SCRIPT_DIR}"
TZ_WANT="${TZ_WANT:-Asia/Seoul}"

mkdir -p "$BASE_DIR" || { echo "설치 경로를 만들 수 없습니다: $BASE_DIR" >&2; exit 1; }
OUTDIR="$PWD/setup_$(hostname)_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTDIR" || { echo "결과 디렉터리를 만들 수 없습니다: $OUTDIR" >&2; exit 1; }
LOG_FILE="$OUTDIR/setup.log"
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
hr()   { printf '%s\n' "--------------------------------------------------------------------------------"; }
have() { command -v "$1" >/dev/null 2>&1; }

clone_repo() {   # clone_repo <url> <name>
    local url=$1 name=$2
    if [[ -d "$BASE_DIR/$name/.git" ]]; then
        log "$name: 이미 존재함 → git pull"
        git -C "$BASE_DIR/$name" pull --ff-only
    else
        log "$name: clone"
        git clone "$url" "$BASE_DIR/$name"
    fi
}

printf '\033[1;36m'
hr; printf '  DEEPGadget SW 검수 · 설정 + 도구 설치  —  %s\n' "$(hostname)"; hr
printf '\033[0m'
printf '   설치 경로 : %s\n' "$BASE_DIR"
printf '   모드      : %s\n' "$([ "$FULL" -eq 1 ] && echo '--full (벤치마크 도구 포함)' || echo '기본 (검수/번인 도구)')"
printf '   결과경로  : %s\n' "$OUTDIR"

log "sudo 권한 확인"
sudo -v || { err "sudo 권한이 필요합니다."; exit 1; }

# ================================================================
#  PART A.  서버 설정
# ================================================================
printf '\n\033[1;35m'; hr; printf ' PART A.  서버 설정\n'; hr; printf '\033[0m'

# ---------------------------------------------------------------- 자동 업데이트 차단
# 반드시 apt-get 보다 먼저. apt-daily.timer 가 깨어나 /var/lib/dpkg/lock 을 잡으면
# 아래 패키지 설치가 "Could not get lock" 으로 막힌다.
# 서비스 유닛은 [Install] 로 부팅 시 뜨는 게 아니라 타이머가 깨우는 구조라
# 타이머만 mask 해도 자동 실행은 막힌다.
log "자동 업데이트 차단 (apt 잠금 방지 — 패키지 설치보다 먼저)"
AUTOUPD_UNITS=(apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service)
for u in "${AUTOUPD_UNITS[@]}"; do
    if ! systemctl list-unit-files 2>/dev/null | grep -q "^${u//./\\.}[[:space:]]"; then
        record SKIP "자동업데이트: $u" "해당 unit 없음"
        continue
    fi
    sudo systemctl stop    "$u" 2>/dev/null || true
    sudo systemctl disable "$u" 2>/dev/null || true
    sudo systemctl mask    "$u"
    # NOTE: masked 유닛에서 is-enabled 는 "masked" 를 출력하면서 exit 1 을 낸다.
    #       파이프로 검사하면 pipefail 때문에 성공인데 실패로 판정되므로 문자열 비교.
    if [[ "$(systemctl is-enabled "$u" 2>/dev/null)" == masked ]]; then
        ok "$u masked"
        record OK "자동업데이트: $u" "masked"
    else
        err "$u mask 실패"
        record FAIL "자동업데이트: $u" "mask 후에도 masked 아님"
    fi
done
sudo systemctl daemon-reload
printf '   해제하려면: sudo systemctl unmask %s\n' "${AUTOUPD_UNITS[*]}"

# ---------------------------------------------------------------- 전원관리
log "전원관리: sleep/suspend/hibernate 차단 + performance 프로파일"
SLEEP_TARGETS=(sleep.target suspend.target hibernate.target hybrid-sleep.target)
# sleep.target 계열은 static unit 이라 disable 시 "no install section" 경고가 정상.
# 실제 차단은 mask 가 담당한다.
sudo systemctl disable "${SLEEP_TARGETS[@]}" 2>/dev/null || true
sudo systemctl mask "${SLEEP_TARGETS[@]}"
for t in "${SLEEP_TARGETS[@]}"; do
    en=$(systemctl is-enabled "$t" 2>/dev/null); en=${en:-unknown}
    printf '    %-22s enabled=%s\n' "$t" "$en"
done
if [[ "$(systemctl is-enabled sleep.target 2>/dev/null)" == masked ]]; then
    ok "sleep/suspend/hibernate 차단됨 (masked)"
    record OK "전원관리(sleep/suspend)" "masked — 절전 진입 차단됨"
else
    err "sleep.target mask 실패"
    record FAIL "전원관리(sleep/suspend)" "masked 아님"
fi

if have powerprofilesctl; then
    if sudo powerprofilesctl set performance 2>/dev/null; then
        ok "power profile: $(powerprofilesctl get 2>/dev/null)"
        record OK "전원 프로파일" "performance"
    else
        warn "performance 프로파일 설정 실패 (지원하지 않는 하드웨어일 수 있음)"
        record FAIL "전원 프로파일" "설정 실패 — powerprofilesctl list 확인"
    fi
else
    record SKIP "전원 프로파일" "powerprofilesctl 없음 (apt install power-profiles-daemon)"
fi

# ---------------------------------------------------------------- Time Zone
log "Time Zone: $TZ_WANT"
TZ_NOW=$(timedatectl show -p Timezone --value 2>/dev/null)
if [[ "$TZ_NOW" == "$TZ_WANT" ]]; then
    ok "Time Zone: $TZ_NOW"
    record OK "Time Zone" "$TZ_NOW"
elif sudo timedatectl set-timezone "$TZ_WANT"; then
    ok "Time Zone: $TZ_NOW → $TZ_WANT"
    record OK "Time Zone" "$TZ_NOW → $TZ_WANT 로 변경함"
else
    err "Time Zone 변경 실패"
    record FAIL "Time Zone" "$TZ_NOW — $TZ_WANT 로 변경 실패"
fi

# ---------------------------------------------------------------- Persistence Mode
log "NVIDIA Persistence Mode (nvidia-pm.service)"
if have nvidia-smi; then
    sudo tee /etc/systemd/system/nvidia-pm.service > /dev/null <<'EOF'
[Unit]
Description=Enable NVIDIA Persistence Mode
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/bin/nvidia-smi -pm 1
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now nvidia-pm.service >/dev/null 2>&1
    PM_STATE=$(nvidia-smi -q 2>/dev/null | grep -i "Persistence Mode" | head -1 | awk -F': ' '{print $2}')
    if [[ "$PM_STATE" == *Enabled* ]]; then
        ok "Persistence Mode: Enabled (재부팅 후에도 유지)"
        record OK "NVIDIA Persistence Mode" "Enabled — 서비스 등록됨"
    else
        err "서비스는 등록됐으나 현재 상태: ${PM_STATE:-unknown}"
        record FAIL "NVIDIA Persistence Mode" "state=${PM_STATE:-unknown} — journalctl -u nvidia-pm 확인"
    fi
else
    warn "nvidia-smi 없음 → NVIDIA 드라이버 미설치"
    record SKIP "NVIDIA Persistence Mode" "nvidia-smi 없음"
fi

# ---------------------------------------------------------------- ACS
# ACS 가 켜져 있으면 PCIe P2P 트래픽이 루트 컴플렉스로 우회돼 GPUDirect/NCCL
# 성능이 크게 떨어진다. setpci 는 재부팅하면 초기화되므로 systemd 로 등록한다.
# BIOS 설정이 우선이므로 VT-d(AMD-V)/ACS Control 은 BIOS 에서 Disabled 해야 한다.
log "PCIe ACS 비활성화 (disable-acs.service)"
if ! have setpci || ! have lspci; then
    warn "pciutils 없음 → 아래 apt 설치 후 이 스크립트를 다시 실행하세요."
    record SKIP "OS ACS Disable" "pciutils 없음 — apt 설치 후 재실행 필요"
else
    ACS_BEFORE=$(sudo lspci -vvv 2>/dev/null | grep ACSCtl | grep -c 'SrcValid+' || true)
    sudo tee /usr/local/sbin/disable_acs.sh > /dev/null <<'EOF'
#!/bin/bash
# This script must be run with root privileges.
if [ "$EUID" -ne 0 ]; then
  echo "Error: run as root (e.g. sudo ./disable_acs.sh)"; exit 1
fi
echo "Disabling ACS on all PCIe devices..."
for BDF in $(lspci | awk '{print $1}'); do
    setpci -s ${BDF} ECAP_ACS+0x6.w > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "Disabling ACS on device [${BDF}]..."
        setpci -s ${BDF} ECAP_ACS+0x6.w=0000
    fi
done
echo "Done. Verify with: sudo lspci -vvv | grep ACSCtl"
EOF
    sudo chmod +x /usr/local/sbin/disable_acs.sh
    sudo tee /etc/systemd/system/disable-acs.service > /dev/null <<'EOF'
[Unit]
Description=Disable PCIe ACS at boot
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/disable_acs.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now disable-acs.service >/dev/null 2>&1
    ACS_AFTER=$(sudo lspci -vvv 2>/dev/null | grep ACSCtl | grep -c 'SrcValid+' || true)
    printf '    ACSCtl SrcValid+ : %s개 → %s개\n' "${ACS_BEFORE:-0}" "${ACS_AFTER:-0}"
    if [[ "${ACS_AFTER:-1}" -eq 0 ]]; then
        ok "ACS 비활성화 완료 (부팅 시 자동 적용)"
        record OK "OS ACS Disable" "SrcValid+ ${ACS_BEFORE}개 → 0개 / 서비스 등록됨"
    else
        warn "아직 ACS 가 켜진 장치 ${ACS_AFTER}개 — BIOS 에서 VT-d(AMD-V)/ACS Control 을 Disabled 하세요."
        record FAIL "OS ACS Disable" "SrcValid+ ${ACS_AFTER}개 남음 — BIOS 설정 필요"
    fi
fi

# ---------------------------------------------------------------- GRUB
# iommu=pt      : IOMMU passthrough — DMA 주소변환 오버헤드 제거
# pcie_aspm=off : PCIe 링크 절전 비활성화 — 링크 복귀 지연 제거
# 부팅 파라미터라 즉시 반영이 불가능하고 자동 편집은 부팅을 깨뜨릴 위험이 있어
# 점검 + 안내만 한다.
log "GRUB 커널 파라미터 점검 (iommu=pt, pcie_aspm=off)"
GRUB_FILE=/etc/default/grub
GRUB_PARAMS=(iommu=pt pcie_aspm=off)
GRUB_MISS_CMDLINE=(); GRUB_MISS_FILE=()
CMDLINE=$(tr '\n' ' ' < /proc/cmdline 2>/dev/null)
GRUB_CONF=$(sudo grep -E '^GRUB_CMDLINE_LINUX(_DEFAULT)?=' "$GRUB_FILE" 2>/dev/null)
for p in "${GRUB_PARAMS[@]}"; do
    [[ " $CMDLINE " == *" $p "* ]] || GRUB_MISS_CMDLINE+=("$p")
    [[ "$GRUB_CONF" == *"$p"* ]]   || GRUB_MISS_FILE+=("$p")
done
printf '    /proc/cmdline : %s\n' "${CMDLINE:-(읽기 실패)}"
if [[ ${#GRUB_MISS_CMDLINE[@]} -eq 0 ]]; then
    GRUB_ACTION=none
    ok "iommu=pt, pcie_aspm=off 모두 현재 부팅에 반영됨"
    record OK "/etc/default/grub" "iommu=pt, pcie_aspm=off 적용됨"
elif [[ ${#GRUB_MISS_FILE[@]} -eq 0 ]]; then
    GRUB_ACTION=reboot
    warn "grub 파일엔 있으나 현재 부팅 미반영: ${GRUB_MISS_CMDLINE[*]}"
    record FAIL "/etc/default/grub" "미반영(${GRUB_MISS_CMDLINE[*]}) — update-grub + 재부팅 필요"
else
    GRUB_ACTION=edit
    warn "grub 파일에 누락: ${GRUB_MISS_FILE[*]}"
    record FAIL "/etc/default/grub" "누락(${GRUB_MISS_FILE[*]}) — 편집 + update-grub + 재부팅 필요"
fi

# ================================================================
#  PART B.  도구 설치
# ================================================================
printf '\n\033[1;35m'; hr; printf ' PART B.  도구 설치\n'; hr; printf '\033[0m'

PKGS=(stress lm-sensors nvme-cli ipmitool pciutils usbutils dmidecode
      ifupdown-extra infiniband-diags build-essential git)
log "apt 패키지 설치: ${PKGS[*]}"
sudo apt-get update
if sudo apt-get install -y "${PKGS[@]}"; then
    ok "apt 패키지 설치 완료"
    record OK "apt 패키지" "${#PKGS[@]}개 설치/확인 완료"
else
    err "apt 패키지 설치 실패"
    record FAIL "apt 패키지" "apt-get install 실패 — 위 로그의 apt 구간 확인"
fi

if have sensors; then
    if sensors 2>/dev/null | grep -qE 'Tctl|Package id'; then
        record OK "lm-sensors" "$(sensors 2>/dev/null | grep -cE 'Tctl|Package id')개 CPU 온도 센서 인식"
    else
        warn "sensors 에서 CPU 온도(Tctl/Package id)를 찾지 못했습니다 → sudo sensors-detect --auto"
        record FAIL "lm-sensors" "Tctl/Package id 없음 — sudo sensors-detect --auto 필요"
    fi
fi

# ---------------------------------------------------------------- gadget-burn (필수)
log "gadget-burn: clone/pull + make"
clone_repo https://github.com/DEEPGadget/gadget-burn.git gadget-burn
if [[ ! -d "$BASE_DIR/gadget-burn" ]]; then
    err "gadget-burn clone 실패"
    record FAIL "gadget-burn" "clone 실패 — 네트워크/접근권한 확인"
elif ! have nvcc && [[ ! -x "$CUDA_HOME/bin/nvcc" ]]; then
    warn "CUDA(nvcc) 없음 → 빌드를 건너뜁니다."
    record SKIP "gadget-burn" "clone만 완료 / CUDA 없음 — 드라이버·툴킷 설치 후 재실행"
elif make -C "$BASE_DIR/gadget-burn"; then
    ok "gadget-burn make 완료: $BASE_DIR/gadget-burn/gadget_burn"
    record OK "gadget-burn" "clone + make 완료"
else
    err "gadget-burn make 실패"
    record FAIL "gadget-burn" "make 실패 — 위 로그의 make 구간 확인"
fi

# ---------------------------------------------------------------- deepgadget-log-grabber (필수)
# 장애 로그 수집은 출고 후에도 쓰이므로 기본 설치에 포함한다. 빌드가 없어 로그도 짧다.
log "deepgadget-log-grabber: clone/pull (빌드 없음)"
if clone_repo https://github.com/DEEPGadget/deepgadget-log-grabber.git deepgadget-log-grabber; then
    ok "deepgadget-log-grabber 준비 완료: $BASE_DIR/deepgadget-log-grabber"
    record OK "deepgadget-log-grabber" "clone 완료 (빌드 없음)"
else
    err "deepgadget-log-grabber clone 실패"
    record FAIL "deepgadget-log-grabber" "clone 실패 — 네트워크/접근권한 확인"
fi

# ---------------------------------------------------------------- --full 추가 도구
if [[ "$FULL" -eq 1 ]]; then
    log "nccl-tests: clone + make"
    if clone_repo https://github.com/NVIDIA/nccl-tests.git nccl-tests; then
        NCCL_HEADER=""
        for h in /usr/include/nccl.h "$CUDA_HOME/include/nccl.h" /usr/local/nccl/include/nccl.h; do
            [[ -f "$h" ]] && { NCCL_HEADER="$h"; break; }
        done
        if [[ ! -d "$CUDA_HOME" ]] && ! have nvcc; then
            warn "CUDA 없음 → nccl-tests 빌드를 건너뜁니다."
            record SKIP "nccl-tests" "clone만 완료 / CUDA 없음"
        elif [[ -z "$NCCL_HEADER" ]]; then
            warn "nccl.h 없음 → sudo apt-get install -y libnccl2 libnccl-dev 후 재실행"
            record SKIP "nccl-tests" "clone만 완료 / NCCL 없음 — libnccl2 libnccl-dev 설치 필요"
        elif make -C "$BASE_DIR/nccl-tests" CUDA_HOME="$CUDA_HOME"; then
            ok "nccl-tests make 완료"
            record OK "nccl-tests" "clone + make 완료"
        else
            err "nccl-tests make 실패"
            record FAIL "nccl-tests" "make 실패 — 위 로그 확인"
        fi
    else
        record FAIL "nccl-tests" "clone 실패"
    fi

    log "gpu-burn: clone + make"
    if clone_repo https://github.com/wilicc/gpu-burn.git gpu-burn; then
        if have nvcc || [[ -x "$CUDA_HOME/bin/nvcc" ]]; then
            if make -C "$BASE_DIR/gpu-burn"; then
                ok "gpu-burn make 완료"; record OK "gpu-burn" "clone + make 완료"
            else
                err "gpu-burn make 실패"; record FAIL "gpu-burn" "make 실패 — 위 로그 확인"
            fi
        else
            record SKIP "gpu-burn" "clone만 완료 / CUDA(nvcc) 없음"
        fi
    else
        record FAIL "gpu-burn" "clone 실패"
    fi

    log "fio: clone + configure + make + install"
    if clone_repo https://github.com/axboe/fio.git fio; then
        if (cd "$BASE_DIR/fio" && ./configure && make && sudo make install); then
            ok "fio 설치 완료: $(command -v fio || echo /usr/local/bin/fio)"
            record OK "fio" "clone + build + install ($(command -v fio || echo /usr/local/bin/fio))"
        else
            err "fio 빌드/설치 실패"
            record FAIL "fio" "configure·make·install 중 실패 — 위 로그 확인"
        fi
    else
        record FAIL "fio" "clone 실패"
    fi
else
    record SKIP "벤치마크 도구" "nccl-tests / gpu-burn / fio — 필요하면 ./setup.sh --full"
fi

# ================================================================
#  요약
# ================================================================
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
        printf '   %-30s %s\n' "$name" "$detail"
    done
    return "$count"
}

printf '\n\033[1;34m'; hr; printf '  setup 결과 요약  —  %s\n' "$(hostname)"; hr; printf '\033[0m'
print_group OK   "✅ 잘 된 것"    32 || OK_COUNT=$?
print_group FAIL "❌ 잘 안 된 것" 31 || FAIL_COUNT=$?
print_group SKIP "⚠️  건너뛴 것"  33 || SKIP_COUNT=$?
OK_COUNT=${OK_COUNT:-0}; FAIL_COUNT=${FAIL_COUNT:-0}; SKIP_COUNT=${SKIP_COUNT:-0}

printf '\n'; hr
printf '  성공 %d / 실패 %d / 생략 %d\n' "$OK_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
printf '  설치 경로 : %s\n' "$BASE_DIR"
printf '  결과      : %s\n' "$OUTDIR"
hr

if [[ "${GRUB_ACTION:-none}" != none ]]; then
    printf '\n\033[1;33m'; hr
    printf '  ⚠  남은 수동 작업 — GRUB 커널 파라미터 설정 후 재부팅\n'
    hr; printf '\033[0m'
    if [[ "${GRUB_ACTION}" == edit ]]; then
        printf '\n  1) sudo vi /etc/default/grub\n'
        printf '     GRUB_CMDLINE_LINUX_DEFAULT 줄 끝에 아래를 추가 (기존 값은 유지)\n\n'
        printf '       \033[1miommu=pt pcie_aspm=off\033[0m\n\n'
        printf '     현재 값:\n'
        printf '%s\n' "${GRUB_CONF:-(읽지 못함)}" | sed 's/^/       /'
        printf '     누락된 값: \033[1;31m%s\033[0m\n' "${GRUB_MISS_FILE[*]}"
    else
        printf '\n  grub 파일엔 있으나 현재 부팅 미반영: \033[1;31m%s\033[0m\n' "${GRUB_MISS_CMDLINE[*]}"
    fi
    printf '\n  2) sudo update-grub\n  3) sudo reboot\n'
    printf '\n  ※ 재부팅 전 BIOS 도 확인 (스크립트로는 설정 불가)\n'
    printf '       - Virtualization Technology (VT-d / AMD-V) : Disabled\n'
    printf '       - ACS Control                              : Disabled\n'
    printf '       - IOMMU                                    : 문제 없으면 그대로\n'
    printf '\033[1;33m'; hr; printf '\033[0m'
fi

printf '\n  다음 단계:\n'
printf '    ./inspect.sh        # 검수 (읽기 전용 — 설정은 바꾸지 않음)\n'
printf '    ./run-burnin.sh     # 1시간 번인 (결과는 실행한 디렉터리에 생성)\n\n'

[[ $FAIL_COUNT -gt 0 ]] && exit 1
exit 0
