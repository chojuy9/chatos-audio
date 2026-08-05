#!/bin/bash
#
# speaches 와 PyWorker 를 함께 띄웁니다.
#
# 순서가 있습니다 — speaches 가 먼저 떠야 PyWorker 의 healthcheck 가 붙고,
# 그래야 Vast 가 이 워커를 "준비됨"으로 봅니다.
#
# 진단할 때: 로그 파일이 **없다**는 것이 단서입니다. speaches.log 가 없으면
# 모델 서버가 아예 안 뜬 것이고, pyworker.log 가 없으면 부트스트랩에서
# 멈춘 것입니다 (5차 agent.log 와 같은 판정).

set -uo pipefail

WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"
LOG_DIR="$WORKSPACE_DIR/logs"
mkdir -p "$LOG_DIR"

log() { echo "[chatos $(date -u '+%Y-%m-%d %H:%M:%S')] $*"; }

# ── 1. speaches ──────────────────────────────────────────────
log "speaches 시작 (${UVICORN_HOST:-127.0.0.1}:${UVICORN_PORT:-8000})"

uvicorn --factory speaches.main:create_app \
    --host "${UVICORN_HOST:-127.0.0.1}" \
    --port "${UVICORN_PORT:-8000}" \
    >> "$LOG_DIR/speaches.log" 2>&1 &
SPEACHES_PID=$!

log "speaches PID $SPEACHES_PID"

# 죽으면 알아채게 둡니다. PyWorker 의 healthcheck 가 실패로 잡아 Vast 에
# 보고하지만, 로그에 사유가 남아 있어야 진단이 됩니다.
(
    wait "$SPEACHES_PID"
    log "speaches 종료 (코드 $?) — 마지막 로그:"
    tail -n 40 "$LOG_DIR/speaches.log"
) &

# ── 2. PyWorker 부트스트랩 ───────────────────────────────────
#
# start_server.sh 가 PYWORKER_REPO 를 클론하고 vastai SDK 를 설치한 뒤
# 저장소 최상단의 worker.py 를 `python3 -m worker` 로 실행합니다.
#
# 이 스크립트 자체는 이미지에 굽지 않고 매번 받아옵니다 — Vast 가 고치면
# 그대로 따라가야 하는 쪽이라, 우리가 사본을 들고 있으면 언젠가 어긋납니다.

BOOTSTRAP_URL="${PYWORKER_BOOTSTRAP_URL:-https://raw.githubusercontent.com/vast-ai/pyworker/main/start_server.sh}"
BOOTSTRAP="$WORKSPACE_DIR/start_server.sh"

log "PyWorker 부트스트랩 내려받기: $BOOTSTRAP_URL"
if ! curl -fsSL "$BOOTSTRAP_URL" -o "$BOOTSTRAP"; then
    log "부트스트랩 내려받기 실패"
    exit 1
fi
chmod +x "$BOOTSTRAP"

log "PYWORKER_REPO=${PYWORKER_REPO:-(기본값)}"
log "PyWorker 시작"

exec bash "$BOOTSTRAP"
