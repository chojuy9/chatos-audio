#!/usr/bin/env bash
#
# chatos.page 음성(STT) — 한 줄 진입점
#
#   git clone --depth 1 https://github.com/chojuy9/chatos-audio /workspace/chatos-audio
#   bash /workspace/chatos-audio/go.sh
#
# 이미지 쪽 comfyui_workflow_maker 의 go.sh 와 같은 자리입니다.
# 몇 번을 쳐도 안전합니다 — 이미 된 것은 건너뜁니다.
#
# 설치가 끝나면 `chatos-audio` 명령이 깔립니다.

set -uo pipefail

# ── 자기 위치에서 구합니다 — 환경변수를 믿지 않습니다 ────────────
#
# **`INSTALL_ROOT` 를 쓰면 안 됩니다.** Vast 계정 환경변수는 그 계정의
# **모든 인스턴스**에 들어오는데, 이미지 생성 쪽이 이미
# `INSTALL_ROOT=/workspace/chatos-image` 를 점유하고 있습니다
# (`GPU-원터치-명령어.md` 2-1). 그대로 쓰면 음성 인스턴스가 이미지 저장소를
# 가리키고, 최악의 경우 2번의 `git reset --hard` 가 **남의 저장소를 덮어씁니다.**
#
# 그래서 위치는 이 파일이 어디 있는지로만 정합니다. 환경변수로 못 바꿉니다.

AUDIO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUDIO_ROOT

WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"
LOG_DIR="$WORKSPACE_DIR/logs"
ENV_FILE="/etc/chatos-audio.env"

mkdir -p "$LOG_DIR"

log() { echo "[go $(date -u '+%H:%M:%S')] $*"; }

log "저장소 위치: $AUDIO_ROOT"
if [ -n "${INSTALL_ROOT:-}" ]; then
    log "  (계정 환경변수 INSTALL_ROOT=$INSTALL_ROOT 은 이미지 쪽 값이라 무시합니다)"
fi

# ── 1. 계정 환경변수를 파일로 굳힙니다 ────────────────────────────
#
# Vast 계정 환경변수는 **on-start 에서만 보입니다.** Jupyter 터미널에는
# 안 넘어와요. 이미지 쪽 go.sh 가 /etc/chatos.env 로 우회한 것과 같습니다.
# 한 번 돌리고 나면 터미널에서 다시 돌려도 값이 살아 있습니다.

persist() {
    local name="$1" val="${!1:-}"
    [ -z "$val" ] && return 0
    # 이미 있으면 지우고 새로 씁니다. 값이 바뀌었을 수 있으니까요.
    if [ -f "$ENV_FILE" ]; then
        grep -v "^export ${name}=" "$ENV_FILE" > "${ENV_FILE}.tmp" 2>/dev/null || true
        mv "${ENV_FILE}.tmp" "$ENV_FILE"
    fi
    printf 'export %s=%q\n' "$name" "$val" >> "$ENV_FILE"
}

touch "$ENV_FILE"
chmod 600 "$ENV_FILE"   # 토큰이 들어갑니다

# 이전 판이 남긴 INSTALL_ROOT 줄을 걷어냅니다. 안 지우면 source 할 때마다
# 이미지 쪽 경로가 되살아납니다.
if grep -q '^export INSTALL_ROOT=' "$ENV_FILE" 2>/dev/null; then
    log "환경 파일에서 낡은 INSTALL_ROOT 줄을 지웁니다"
    grep -v '^export INSTALL_ROOT=' "$ENV_FILE" > "${ENV_FILE}.tmp" && mv "${ENV_FILE}.tmp" "$ENV_FILE"
fi

# **INSTALL_ROOT 는 여기 없습니다.** 위 주석 참고
for v in AUDIO_GPU_TOKEN AUDIO_MODEL SPEACHES_PORT MANAGER_PORT \
         TUNNEL_TOKEN TUNNEL_HOSTNAME SPEACHES_DIR \
         WHISPER__COMPUTE_TYPE HF_TOKEN; do
    persist "$v"
done
persist AUDIO_ROOT

# shellcheck disable=SC1090
source "$ENV_FILE"

# source 가 덮어썼을 수 있으니 자기 위치로 되돌립니다. 이 값이 이깁니다.
AUDIO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log "환경 파일: $ENV_FILE"

# ── 2. 최신으로 맞춥니다 ──────────────────────────────────────────
#
# pull 이 아니라 원격 상태로 덮어씁니다. 인스턴스는 쓰고 버리는 것이라
# 로컬 변경을 지킬 이유가 없고, 덕분에 충돌이 안 납니다 (이미지 쪽과 동일).

# 원격이 chatos-audio 인지 확인하고 나서만 덮어씁니다. 엉뚱한 저장소에서
# reset --hard 를 돌리면 남의 작업이 날아갑니다.
if [ -d "$AUDIO_ROOT/.git" ]; then
    origin="$(git -C "$AUDIO_ROOT" remote get-url origin 2>/dev/null || true)"
    case "$origin" in
        *chatos-audio*)
            log "저장소 갱신 ($origin)"
            git -C "$AUDIO_ROOT" fetch --depth 1 origin main >>"$LOG_DIR/install.log" 2>&1 \
                && git -C "$AUDIO_ROOT" reset --hard origin/main >>"$LOG_DIR/install.log" 2>&1 \
                || log "갱신 실패 — 있는 것으로 계속합니다"
            ;;
        *)
            log "origin 이 chatos-audio 가 아닙니다 ($origin) — 갱신을 건너뜁니다"
            ;;
    esac
fi

# **`chmod +x` 를 하지 않습니다.** git 이 실행 비트를 추적하기 때문에, 클론 뒤
# chmod 를 돌리면 그 파일들이 "로컬 변경" 이 되어 다음 `git pull` 이 거부됩니다
# (4차 5장에서 이미 한 번 겪은 것). 그리고 필요도 없습니다 —
#   scripts/bootstrap.sh · run.sh  → `bash <파일>` 로 부릅니다
#   scripts/chatos-audio           → `install -m 755` 로 복사합니다
#   go.sh 자신                     → On-start 도 `bash go.sh` 입니다
# 실행 비트가 있어야 하는 파일이 하나도 없습니다.

# ── 3. 명령 설치 ──────────────────────────────────────────────────

if [ -f "$AUDIO_ROOT/scripts/chatos-audio" ]; then
    install -m 755 "$AUDIO_ROOT/scripts/chatos-audio" /usr/local/bin/chatos-audio
    log "chatos-audio 명령 설치됨"
fi

# ── 4. 설치 → 실행 ────────────────────────────────────────────────
#
# 전경에서 돕니다. Jupyter 터미널에서 진행이 보여야 하니까요.
# 데몬은 run.sh 가 setsid 로 띄웁니다.
#
# **설치 프로세스를 죽이는 코드는 일부러 안 넣었습니다.** 5차 2-2 에서
# `kill -- -$pgid` 가 자기 프로세스 그룹을 죽여 실행 직전에 자살한 적이
# 있습니다. 여기서는 그 경로 자체를 만들지 않습니다.

bash "$AUDIO_ROOT/scripts/bootstrap.sh" 2>&1 | tee -a "$LOG_DIR/install.log"
rc="${PIPESTATUS[0]}"

if [ "$rc" -ne 0 ]; then
    log "설치 실패 (코드 $rc). $LOG_DIR/install.log 를 보세요"
    exit "$rc"
fi

exec bash "$AUDIO_ROOT/scripts/run.sh"
