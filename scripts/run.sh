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

# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && source "$ENV_FILE"
# shellcheck disable=SC1090
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/defaults.sh"

mkdir -p "$LOG_DIR" "$RUN_DIR" "$HF_HUB_CACHE"

log() { echo "[실행 $(date -u '+%H:%M:%S')] $*"; }

# **8080 을 쓰지 마세요.** Vast 의 Jupyter 가 그 자리입니다 (5차 2-3 의 재발 자리).
if [ "$SPEACHES_PORT" = "8080" ]; then
    echo "!! SPEACHES_PORT=8080 은 Jupyter 와 충돌합니다. 8000 을 쓰세요" >&2
    exit 1
fi

# **터널이 붙는데 토큰이 없으면 아예 안 뜹니다.**
# 이 조합이 곧 "인증 없는 GPU 를 인터넷에 내놓기" 입니다. 경고로 두면
# 언젠가 그냥 지나갑니다 — 6차 workers_dev 와 같은 자리라 못 하게 만듭니다.
if [ -n "${TUNNEL_TOKEN:-}" ] && [ -z "${AUDIO_GPU_TOKEN:-}" ]; then
    cat >&2 <<'MSG'
!! 터널이 설정돼 있는데 AUDIO_GPU_TOKEN 이 비었습니다.
!! 이대로 뜨면 주소를 아는 사람이 GPU 를 직접 부를 수 있고,
!! 그러면 할당량이 통째로 우회됩니다. 기동을 거부합니다.
!!
!!   해결: AUDIO_GPU_TOKEN 을 Vast 계정 환경변수에 넣고 go.sh 를 다시 돌리세요.
!!         Cloudflare Worker 의 AUDIO_GPU_TOKEN 시크릿과 **같은 값**이어야 합니다.
MSG
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

# **죽으라고 신호를 보내는 것과 죽은 것은 다릅니다.**
# kill 만 하고 바로 다음으로 가면, 종료 중인 옛 프로세스가 아직 포트를 쥐고
# 있어서 새 프로세스가 바인드에 실패합니다. 그런데 health 검사는 **옛
# 프로세스한테서 200 을 받아** 통과해버립니다 — 도구가 거짓말하는 자리입니다.
stop_one() {
    local name="$1" pidfile="$RUN_DIR/$1.pid" pid
    [ -f "$pidfile" ] || return 0
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    rm -f "$pidfile"
    [ -n "$pid" ] || return 0
    kill -0 "$pid" 2>/dev/null || return 0

    log "이전 $name 정지 (PID $pid)"
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 30); do
        kill -0 "$pid" 2>/dev/null || { log "  종료 확인"; return 0; }
        sleep 1
    done
    log "  30초 안에 안 죽어서 SIGKILL"
    kill -9 "$pid" 2>/dev/null || true
    sleep 1
}

# 포트가 실제로 비었는지 확인합니다. 프로세스가 죽어도 소켓이 잠깐 남습니다.
port_free() {
    python3 - "$1" <<'PY' 2>/dev/null
import socket, sys
s = socket.socket()
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
}

stop_one audio-agent
stop_one manager
stop_one speaches
stop_one tunnel

wait_port_free() {  # wait_port_free <포트> <이름>
    log "포트 $1 이(가) 비기를 기다립니다"
    for _ in $(seq 1 30); do
        if port_free "$1"; then log "포트 $1 비었음"; return 0; fi
        sleep 1
    done
    log "⚠ 포트 $1 을(를) 아직 누가 쥐고 있습니다 ($2)"
    log "   남은 프로세스: $(pgrep -af 'uvicorn|speaches|manager' | tr '\n' ' ' || true)"
    log "   그대로 띄우면 바인드에 실패하고, health 검사가 옛 프로세스한테 속습니다"
    return 1
}

wait_port_free "$SPEACHES_PORT" speaches || exit 1
wait_port_free "$MANAGER_PORT" 매니저 || exit 1

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

# HF 캐시 경로는 defaults.sh 에서 옵니다. bootstrap 과 같은 값이어야 하고,
# 어긋나면 받아둔 모델을 못 찾아 CacheNotFound 로 500 이 납니다.

# ── cuDNN 경로 ───────────────────────────────────────────────────
#
# **격리된 venv 의 대가입니다.** 파이썬 패키지 충돌은 안 생기는 대신,
# 네이티브 라이브러리가 로더 경로에 안 잡힙니다.
#
# cuDNN 9 는 ops · cnn · adv · graph 로 쪼개져 있습니다. onnxruntime 은
# 자기 벤더 사본(`libcudnn-<해시>.so.9.1.0`)을 먼저 올리는데 거기엔 `_cnn` 이
# 없고, 뒤이어 ctranslate2 가 `libcudnn_cnn.so.9` 를 열려다 실패한 뒤 이미
# 열린 핸들로 폴백해서 이렇게 죽습니다 —
#
#   Unable to load any of {libcudnn_cnn.so.9.1.0, ..., libcudnn_cnn.so.9}
#   Invalid handle. Cannot load symbol cudnnCreateConvolutionDescriptor
#
# **파이썬 예외가 아니라 프로세스가 통째로 죽습니다.** 그래서 500 이 아니라
# `curl: (52) Empty reply from server` 로 보입니다.
#
# 직접 `WhisperModel(device="cuda")` 를 돌리면 되는데 서버에서만 죽는 이유가
# 이것입니다 — 서버는 whisper 앞에 VAD(onnxruntime)를 먼저 돌립니다.

nvidia_libs=""
for d in "$SPEACHES_DIR"/.venv/lib/python*/site-packages/nvidia/*/lib; do
    [ -d "$d" ] && nvidia_libs="${nvidia_libs:+$nvidia_libs:}$d"
done
if [ -n "$nvidia_libs" ]; then
    export LD_LIBRARY_PATH="${nvidia_libs}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    log "cuDNN 경로 $(printf '%s' "$nvidia_libs" | tr ':' '\n' | wc -l)개를 LD_LIBRARY_PATH 에 넣었습니다"
else
    log "⚠ venv 에서 nvidia 라이브러리 디렉터리를 못 찾았습니다"
fi

# 위로 안 되면 이쪽입니다 — VAD 를 CPU 로 돌려 onnxruntime 의 CUDA 스택을
# 아예 안 올립니다. silero VAD 는 아주 작은 모델이라 CPU 로 충분합니다
# (GPU 에서도 1초 오디오에 0.32초 걸렸습니다 — 전송이 연산보다 큰 크기).
if [ "${AUDIO_VAD_CPU:-0}" = "1" ]; then
    export UNSTABLE_ORT_OPTS__EXCLUDE_PROVIDERS='["TensorrtExecutionProvider","CUDAExecutionProvider"]'
    log "VAD 를 CPU 로 돌립니다 (AUDIO_VAD_CPU=1)"
fi

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

# **`curl -f` 를 쓰지 않습니다.** -f 는 오류 본문을 버려서 "실패했다" 만 남기고
# 왜 실패했는지를 지웁니다. 상태 코드와 본문을 같이 봅니다.
show() {  # show <설명> <URL>
    local body code
    body="$(curl -sS -w '\n%{http_code}' "${auth[@]}" "$2" 2>&1)"
    code="$(printf '%s' "$body" | tail -n1)"
    body="$(printf '%s' "$body" | sed '$d')"
    if [ "$code" = "200" ]; then
        printf '%s' "$body"
        return 0
    fi
    log "$1 실패 — HTTP $code"
    printf '%s\n' "$body" | head -n 5 | sed 's/^/      /'
    return 1
}

log "쓸 수 있는 모델 (로컬 캐시):"
if models_json="$(show '모델 목록' "http://127.0.0.1:$SPEACHES_PORT/v1/models")"; then
    printf '%s' "$models_json" | python3 -c 'import json,sys
d=json.load(sys.stdin)
items=d.get("data", d if isinstance(d,list) else [])
if not items:
    print("    (비어 있음 — 내려받은 모델이 없습니다)")
for m in items:
    print("   ", m.get("id", m) if isinstance(m, dict) else m)' 2>/dev/null \
        || log "    (JSON 을 읽지 못했습니다)"
fi

# ── 5. 워밍업 ─────────────────────────────────────────────────────
#
# 첫 이용자가 모델 내려받기를 기다리지 않게 합니다. 덤으로 경로 전체가
# 도는지 확인됩니다 — 여기가 통과하면 STT 는 실제로 됩니다.

if [ -f "$WARM" ]; then
    log "워밍업 — 모델 $AUDIO_MODEL (첫 적재라 좀 걸립니다)"

    # **본문과 stderr 를 같은 파일에 쓰면 안 됩니다.** 연결 자체가 실패하면
    # 본문이 안 써져서 지난 실행의 내용이 그대로 남고, 그게 이번 오류처럼
    # 보입니다. 파일을 나누고 매번 비웁니다.
    : > "$LOG_DIR/warmup.log"
    : > "$LOG_DIR/warmup.err"

    code="$(curl -sS --max-time 900 -o "$LOG_DIR/warmup.log" -w '%{http_code}' \
        "${auth[@]}" \
        -F "file=@$WARM" -F "model=$AUDIO_MODEL" \
        "http://127.0.0.1:$SPEACHES_PORT/v1/audio/transcriptions" 2>"$LOG_DIR/warmup.err")"

    if [ "$code" = "200" ]; then
        log "워밍업 통과 (HTTP 200) → $LOG_DIR/warmup.log"
        head -c 300 "$LOG_DIR/warmup.log" | sed 's/^/      /'
        echo
    else
        log "⚠ 워밍업 실패 — HTTP $code"
        [ -s "$LOG_DIR/warmup.err" ] && sed 's/^/      curl: /' "$LOG_DIR/warmup.err"
        [ -s "$LOG_DIR/warmup.log" ] && head -c 600 "$LOG_DIR/warmup.log" | sed 's/^/      /'
        echo
        case "$code" in
            000) log "  응답 자체가 없습니다 — speaches 가 죽었을 가능성이 큽니다"
                 log "  tail -n 40 $LOG_DIR/speaches.log" ;;
            500) log "  CacheNotFound 면 모델이 안 받아진 것입니다 — chatos-audio pull" ;;
            401|403) log "  AUDIO_GPU_TOKEN 이 speaches 의 API_KEY 와 다릅니다" ;;
            *)   log "  tail -n 40 $LOG_DIR/speaches.log" ;;
        esac
    fi
else
    log "워밍업 파일이 없어 건너뜁니다"
fi

# ── 5-1. 매니저 ───────────────────────────────────────────────────
#
# **밖에서 닿는 것은 speaches 가 아니라 이쪽입니다.** 터널 ingress 를 반드시
# 이 포트로 잡으세요 — speaches 를 직접 물면 `/docs` · `/openapi.json` ·
# Web UI 가 인증 없이 열립니다 (12차 8장).
#
# **speaches 가 health 를 통과한 뒤에 띄웁니다.** 매니저만 살아 있고 상류가
# 없는 상태를 만들면, 그 사이 요청이 502 로 나가고 이용자 할당량이 왔다
# 갔다 합니다.

if [ -d "$MANAGER_DIR" ]; then
    log "매니저 시작 — 127.0.0.1:$MANAGER_PORT (분할 $([ "$AUDIO_SPLIT" = "1" ] && echo 켬 || echo 끔))"
    cd "$MANAGER_DIR" || { echo "!! $MANAGER_DIR 없음" >&2; exit 1; }
    setsid nohup "$UV" run python main.py >>"$LOG_DIR/manager.log" 2>&1 &
    echo $! > "$RUN_DIR/manager.pid"
    MANAGER_PID="$(cat "$RUN_DIR/manager.pid")"
    log "매니저 PID $MANAGER_PID"

    mready=0
    for _ in $(seq 1 30); do
        # **200 이 아니라 응답 자체를 봅니다.** 매니저의 /health 는 상류가
        # 죽어 있으면 503 을 냅니다 — 그것도 "매니저는 떴다" 는 뜻입니다.
        if curl -sS -o /dev/null "http://127.0.0.1:$MANAGER_PORT/health" 2>/dev/null; then
            mready=1; break
        fi
        if ! kill -0 "$MANAGER_PID" 2>/dev/null; then
            log "매니저가 죽었습니다 — 마지막 40줄:"
            tail -n 40 "$LOG_DIR/manager.log"
            exit 1
        fi
        sleep 1
    done
    if [ "$mready" -ne 1 ]; then
        log "⚠ 매니저 health 가 30초 안에 안 떴습니다 — 마지막 40줄:"
        tail -n 40 "$LOG_DIR/manager.log"
        exit 1
    fi
    log "매니저 health 응답: $(curl -sS "http://127.0.0.1:$MANAGER_PORT/health" 2>/dev/null)"
else
    log "⚠ $MANAGER_DIR 없음 — 매니저 없이 뜹니다"
    log "   이 상태로 터널을 speaches 에 물면 /docs 와 Web UI 가 인증 없이 열립니다"
fi

# ── 5-2. 비동기 잡 pull 에이전트 ───────────────────────────────────
#
# GPU로 들어오는 공개 포트는 없습니다. 에이전트가 Worker에서 잡과 입력을 가져가고
# 결과만 되돌립니다. AUDIO_JOB_TOKEN이 없으면 기존 동기 STT만 그대로 동작합니다.

if [ -n "${AUDIO_JOB_TOKEN:-}" ] && [ -n "${AUDIO_JOB_API_BASE:-}" ]; then
    log "비동기 잡 에이전트 시작 — ${AUDIO_JOB_API_BASE}"
    cd "$MANAGER_DIR" || { echo "!! $MANAGER_DIR 없음" >&2; exit 1; }
    setsid nohup "$UV" run python job_agent.py >>"$LOG_DIR/audio-agent.log" 2>&1 &
    echo $! > "$RUN_DIR/audio-agent.pid"
    AUDIO_AGENT_PID="$(cat "$RUN_DIR/audio-agent.pid")"
    log "잡 에이전트 PID $AUDIO_AGENT_PID"
else
    log "AUDIO_JOB_TOKEN 없음 — 비동기 잡 에이전트 건너뜀"
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
        log "  ⚠ 대시보드의 Public Hostname 이 **127.0.0.1:$MANAGER_PORT (매니저)** 를"
        log "    가리키는지 확인하세요. $SPEACHES_PORT 로 두면 /docs · Web UI 가 인증 없이 열립니다"
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

log '준비 완료. chatos-audio status 로 확인하세요'

(
    while kill -0 "$SPEACHES_PID" 2>/dev/null; do sleep 10; done
    echo "[감시 $(date -u '+%H:%M:%S')] speaches 가 사라졌습니다 — 마지막 40줄:" \
        >>"$LOG_DIR/speaches.log"
    tail -n 40 "$LOG_DIR/speaches.log" >>"$LOG_DIR/run.log"
) >/dev/null 2>&1 &

exit 0
