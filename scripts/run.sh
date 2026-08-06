#!/usr/bin/env bash
#
# 실행. speaches 를 띄우고, 모델을 미리 끌어오고, 터널이 설정돼 있으면 같이 띄웁니다.
#
# 로그가 셋으로 갈립니다 — **파일의 부재가 단서입니다** (5차).
#   speaches.log    없으면 모델 서버가 아예 안 뜬 것
#   warmup.log      없으면 speaches 가 health 까지 못 간 것
#   tunnel.log      없으면 터널을 안 띄운 것 (설정이 없으면 정상)

set -uo pipefail

WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"
LOG_DIR="$WORKSPACE_DIR/logs"
RUN_DIR="$WORKSPACE_DIR/run"
ENV_FILE="/etc/chatos-audio.env"

mkdir -p "$LOG_DIR" "$RUN_DIR"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

SPEACHES_DIR="${SPEACHES_DIR:-$WORKSPACE_DIR/speaches}"
SPEACHES_PORT="${SPEACHES_PORT:-8000}"
AUDIO_MODEL="${AUDIO_MODEL:-Systran/faster-whisper-large-v3}"
AUDIO_GPU_TOKEN="${AUDIO_GPU_TOKEN:-}"
TUNNEL_TOKEN="${TUNNEL_TOKEN:-}"
WARM="$WORKSPACE_DIR/warmup.wav"

log() { echo "[실행 $(date -u '+%H:%M:%S')] $*"; }

# **8080 을 쓰지 마세요.** Vast 의 Jupyter 가 그 자리입니다 (5차 2-3 의 재발 자리).
if [ "$SPEACHES_PORT" = "8080" ]; then
    echo "!! SPEACHES_PORT=8080 은 Jupyter 와 충돌합니다. 8000 을 쓰세요" >&2
    exit 1
fi

find_uv() {
    for p in /usr/local/bin/uv "$HOME/.local/bin/uv" "$HOME/.cargo/bin/uv"; do
        [ -x "$p" ] && { echo "$p"; return 0; }
    done
    command -v uv 2>/dev/null
}
UV="$(find_uv || true)"
[ -n "$UV" ] || { echo "!! uv 가 없습니다. bootstrap.sh 를 먼저" >&2; exit 1; }

# ── 1. 이전 실행 정리 ─────────────────────────────────────────────
#
# **자기 프로세스 그룹은 건드리지 않습니다.** 5차 2-2 에서 정리 코드가
# 실행 직전에 자기를 죽인 적이 있습니다. 이름으로만 좁게 잡습니다.

stop_one() {
    local pidfile="$RUN_DIR/$1.pid"
    [ -f "$pidfile" ] || return 0
    local pid; pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "이전 $1 정지 (PID $pid)"
        kill "$pid" 2>/dev/null || true
    fi
    rm -f "$pidfile"
}
stop_one speaches
stop_one tunnel

# ── 2. speaches ───────────────────────────────────────────────────
#
# **작업 디렉터리를 반드시 맞춰야 합니다** (11차 10-2). main.py 가 상대 경로를
# 쓰는 자리가 있어서 다른 데서 띄우면 기동 중에 죽습니다.
#
# **127.0.0.1 로만 듣습니다.** UVICORN_HOST 기본값이 0.0.0.0 이라 명시적으로
# 꺼야 합니다 — 밖에서 닿으면 할당량이 통째로 우회됩니다 (4차 ComfyUI 8188).

cd "$SPEACHES_DIR" || { echo "!! $SPEACHES_DIR 없음" >&2; exit 1; }

export UVICORN_HOST=127.0.0.1
export UVICORN_PORT="$SPEACHES_PORT"
[ -n "$AUDIO_GPU_TOKEN" ] && export API_KEY="$AUDIO_GPU_TOKEN"
[ -n "${WHISPER__COMPUTE_TYPE:-}" ] && export WHISPER__COMPUTE_TYPE

log "speaches 시작 — 127.0.0.1:$SPEACHES_PORT · cwd $SPEACHES_DIR"
[ -n "$AUDIO_GPU_TOKEN" ] || log "  ⚠ AUDIO_GPU_TOKEN 이 비었습니다 — 인증 없이 뜹니다. 터널을 붙이기 전에 채우세요"

setsid nohup "$UV" run uvicorn --factory speaches.main:create_app \
    --host 127.0.0.1 --port "$SPEACHES_PORT" \
    >>"$LOG_DIR/speaches.log" 2>&1 &
echo $! > "$RUN_DIR/speaches.pid"
SPEACHES_PID="$(cat "$RUN_DIR/speaches.pid")"
log "speaches PID $SPEACHES_PID"

# ── 3. health 대기 ────────────────────────────────────────────────
#
# /health 는 API_KEY 를 걸어도 인증에서 빠집니다. 그래서 헤더 없이 봅니다.

log "health 대기"
ready=0
for _ in $(seq 1 90); do
    if curl -fsS "http://127.0.0.1:$SPEACHES_PORT/health" >/dev/null 2>&1; then
        ready=1; break
    fi
    if ! kill -0 "$SPEACHES_PID" 2>/dev/null; then
        log "speaches 가 죽었습니다 — 마지막 40줄:"
        tail -n 40 "$LOG_DIR/speaches.log"
        exit 1
    fi
    sleep 2
done

if [ "$ready" -ne 1 ]; then
    log "90초 안에 health 가 안 떴습니다 — 마지막 40줄:"
    tail -n 40 "$LOG_DIR/speaches.log"
    exit 1
fi
log "health 200"

# ── 4. 쓸 수 있는 모델을 로그에 남깁니다 ─────────────────────────
#
# turbo 의 정확한 모델 id 를 여기서 눈으로 확인하세요. AUDIO_MODEL 기본값은
# 확정값이 아닙니다.

auth=()
[ -n "$AUDIO_GPU_TOKEN" ] && auth=(-H "Authorization: Bearer $AUDIO_GPU_TOKEN")

log "쓸 수 있는 모델:"
curl -fsS "${auth[@]}" "http://127.0.0.1:$SPEACHES_PORT/v1/models" 2>/dev/null \
    | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    for m in d.get("data", d if isinstance(d,list) else []):
        print("   ", m.get("id", m))
except Exception as e:
    print("    (읽지 못했습니다:", e, ")")' 2>/dev/null \
    || log "    (모델 목록 조회 실패)"

# ── 5. 워밍업 ─────────────────────────────────────────────────────
#
# 첫 이용자가 모델 내려받기를 기다리지 않게 합니다. 덤으로 경로 전체가
# 도는지 확인됩니다 — 여기가 통과하면 STT 는 실제로 됩니다.

if [ -f "$WARM" ]; then
    log "워밍업 — 모델 $AUDIO_MODEL (첫 실행은 내려받기 때문에 오래 걸립니다)"
    if curl -fsS --max-time 900 "${auth[@]}" \
        -F "file=@$WARM" -F "model=$AUDIO_MODEL" \
        "http://127.0.0.1:$SPEACHES_PORT/v1/audio/transcriptions" \
        >"$LOG_DIR/warmup.log" 2>&1
    then
        log "워밍업 통과 → $LOG_DIR/warmup.log"
    else
        log "⚠ 워밍업 실패 — 모델 id 가 틀렸을 수 있습니다. 4번 목록과 대조하세요"
        tail -n 20 "$LOG_DIR/warmup.log" 2>/dev/null || true
    fi
else
    log "워밍업 파일이 없어 건너뜁니다"
fi

# ── 6. 터널 (설정돼 있을 때만) ───────────────────────────────────
#
# 자격증명 전달 방식은 아직 미결정입니다 (task 4-2). TUNNEL_TOKEN 이 있으면
# 그것으로 띄우고, 없으면 조용히 건너뜁니다 — 로컬에서 시험하는 단계에서는
# 터널이 없는 것이 정상입니다.

if [ -n "$TUNNEL_TOKEN" ]; then
    if ! command -v cloudflared >/dev/null; then
        log "cloudflared 설치"
        curl -fsSL -o /tmp/cf.deb \
            https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb \
            >>"$LOG_DIR/install.log" 2>&1 \
            && dpkg -i /tmp/cf.deb >>"$LOG_DIR/install.log" 2>&1 \
            || log "⚠ cloudflared 설치 실패"
    fi
    if command -v cloudflared >/dev/null; then
        log "터널 시작"
        setsid nohup cloudflared tunnel --no-autoupdate run --token "$TUNNEL_TOKEN" \
            >>"$LOG_DIR/tunnel.log" 2>&1 &
        echo $! > "$RUN_DIR/tunnel.pid"
    fi
else
    log "TUNNEL_TOKEN 없음 — 터널 건너뜀 (로컬 시험 단계에서는 정상)"
fi

# ── 7. 생존 감시 ──────────────────────────────────────────────────
#
# **`wait` 를 쓰지 않습니다.** setsid 로 띄운 것은 자식이 아니라 형제라,
# `wait` 가 즉시 127 로 실패하면서 **살아 있는데 죽었다고** 찍습니다
# (11차 10-3). 대신 종료 코드는 못 얻습니다.

log "준비 완료. `chatos-audio status` 로 확인하세요"

(
    while kill -0 "$SPEACHES_PID" 2>/dev/null; do sleep 10; done
    echo "[감시 $(date -u '+%H:%M:%S')] speaches 가 사라졌습니다 — 마지막 40줄:" \
        >>"$LOG_DIR/speaches.log"
    tail -n 40 "$LOG_DIR/speaches.log" >>"$LOG_DIR/run.log"
) >/dev/null 2>&1 &

exit 0
