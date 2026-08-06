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

INSTALL_ROOT="${INSTALL_ROOT:-/workspace/chatos-audio}"
WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"
LOG_DIR="$WORKSPACE_DIR/logs"
ENV_FILE="/etc/chatos-audio.env"

mkdir -p "$LOG_DIR"

log() { echo "[go $(date -u '+%H:%M:%S')] $*"; }

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

for v in AUDIO_GPU_TOKEN AUDIO_MODEL SPEACHES_PORT MANAGER_PORT \
         TUNNEL_TOKEN TUNNEL_HOSTNAME INSTALL_ROOT SPEACHES_DIR \
         WHISPER__COMPUTE_TYPE HF_TOKEN; do
    persist "$v"
done

# shellcheck disable=SC1090
source "$ENV_FILE"

log "환경 파일: $ENV_FILE"

# ── 2. 최신으로 맞춥니다 ──────────────────────────────────────────
#
# pull 이 아니라 원격 상태로 덮어씁니다. 인스턴스는 쓰고 버리는 것이라
# 로컬 변경을 지킬 이유가 없고, 덕분에 충돌이 안 납니다 (이미지 쪽과 동일).

if [ -d "$INSTALL_ROOT/.git" ]; then
    log "저장소 갱신"
    git -C "$INSTALL_ROOT" fetch --depth 1 origin main >>"$LOG_DIR/install.log" 2>&1 \
        && git -C "$INSTALL_ROOT" reset --hard origin/main >>"$LOG_DIR/install.log" 2>&1 \
        || log "갱신 실패 — 있는 것으로 계속합니다"
fi

chmod +x "$INSTALL_ROOT"/go.sh "$INSTALL_ROOT"/scripts/*.sh 2>/dev/null || true

# ── 3. 명령 설치 ──────────────────────────────────────────────────

if [ -f "$INSTALL_ROOT/scripts/chatos-audio" ]; then
    install -m 755 "$INSTALL_ROOT/scripts/chatos-audio" /usr/local/bin/chatos-audio
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

bash "$INSTALL_ROOT/scripts/bootstrap.sh" 2>&1 | tee -a "$LOG_DIR/install.log"
rc="${PIPESTATUS[0]}"

if [ "$rc" -ne 0 ]; then
    log "설치 실패 (코드 $rc). $LOG_DIR/install.log 를 보세요"
    exit "$rc"
fi

exec bash "$INSTALL_ROOT/scripts/run.sh"
