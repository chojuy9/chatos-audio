#!/usr/bin/env bash
#
# 설치. 몇 번을 돌려도 안전합니다.
#
# 판정 원칙 둘 —
#   1. **종료 코드를 믿지 않습니다.** pip/uv 는 충돌을 경고로만 찍고 0 을
#      돌려줍니다 (5차 2-1). 실제 판정은 임포트 검사가 합니다.
#   2. **모르는 것은 가정하지 않고 탐지해서 보고합니다.** realtime-console
#      같은 것은 있는지 없는지 여기서 갈립니다.

set -uo pipefail

# shellcheck disable=SC1090
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/defaults.sh"

mkdir -p "$LOG_DIR"
log() { echo "[설치 $(date -u '+%H:%M:%S')] $*"; }
die() { echo "[설치 $(date -u '+%H:%M:%S')] !! $*" >&2; exit 1; }

# ── 1. 시스템 패키지 ──────────────────────────────────────────────
#
# ffmpeg 은 섹터 분할과 워밍업 파일 생성에 씁니다. **없는 채로 두면
# 분할이 조용히 실패합니다.**

need_apt=()
command -v git      >/dev/null || need_apt+=(git)
command -v curl     >/dev/null || need_apt+=(curl)
command -v ffmpeg   >/dev/null || need_apt+=(ffmpeg)

if [ "${#need_apt[@]}" -gt 0 ]; then
    log "apt 설치: ${need_apt[*]}"
    apt-get update -qq >>"$LOG_DIR/install.log" 2>&1
    apt-get install -y --no-install-recommends "${need_apt[@]}" \
        >>"$LOG_DIR/install.log" 2>&1 || die "apt 설치 실패"
fi

command -v ffmpeg >/dev/null || die "ffmpeg 이 없습니다"
log "ffmpeg $(ffmpeg -version 2>/dev/null | head -1 | cut -d' ' -f3)"

# ── 2. uv ─────────────────────────────────────────────────────────

find_uv() {
    for p in /usr/local/bin/uv "$HOME/.local/bin/uv" "$HOME/.cargo/bin/uv"; do
        [ -x "$p" ] && { echo "$p"; return 0; }
    done
    command -v uv 2>/dev/null && return 0
    return 1
}

UV="$(find_uv || true)"
if [ -z "$UV" ]; then
    log "uv 설치"
    curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh \
        >>"$LOG_DIR/install.log" 2>&1 || die "uv 설치 실패"
    UV="$(find_uv || true)"
fi
[ -n "$UV" ] || die "uv 를 찾을 수 없습니다"
log "uv $("$UV" --version 2>/dev/null | cut -d' ' -f2)"

# ── 3. speaches ───────────────────────────────────────────────────
#
# **PyPI 에 없습니다.** clone 후 `uv sync` 가 유일한 비-Docker 경로입니다.
# 그게 오히려 유리해요 — 저장소 안에 격리된 .venv 가 생겨서 베이스 이미지의
# torch 와 안 섞입니다. 5차 2-1 의 충돌 함정이 구조적으로 안 생깁니다.

if [ -d "$SPEACHES_DIR/.git" ]; then
    log "speaches 갱신"
    git -C "$SPEACHES_DIR" fetch --depth 1 origin >>"$LOG_DIR/install.log" 2>&1 || true
else
    log "speaches 클론 → $SPEACHES_DIR"
    git clone --depth 1 "$SPEACHES_REPO" "$SPEACHES_DIR" \
        >>"$LOG_DIR/install.log" 2>&1 || die "speaches 클론 실패"
fi

cd "$SPEACHES_DIR" || die "speaches 디렉터리로 못 들어감"

log "uv sync (몇 분 걸립니다)"
"$UV" python install >>"$LOG_DIR/install.log" 2>&1 || true
"$UV" venv           >>"$LOG_DIR/install.log" 2>&1 || true
"$UV" sync           >>"$LOG_DIR/install.log" 2>&1
log "uv sync 종료 코드 $? — **이걸로 판정하지 않습니다**"

# ── 4. 임포트 검사 — 여기가 진짜 판정입니다 ──────────────────────

log "임포트 검사"
if ! "$UV" run python - <<'PY' >>"$LOG_DIR/install.log" 2>&1
import ctranslate2, faster_whisper, speaches.main
print("ctranslate2", ctranslate2.__version__)
print("faster_whisper", faster_whisper.__version__)
PY
then
    echo "--- 마지막 40줄 ---"
    tail -n 40 "$LOG_DIR/install.log"
    die "임포트 실패. 설치가 '성공'했어도 쓸 수 없는 상태입니다"
fi
log "임포트 통과"

# ── 5. realtime-console/dist ─────────────────────────────────────
#
# 11차 10-2 가 재발할 자리입니다. speaches 의 main.py 가
# `StaticFiles(directory="realtime-console/dist", html=True)` 로 **상대 경로**를
# 씁니다. 공식 이미지에는 빌드 결과물이 들어 있지만, git clone 에는 JS 산출물이
# 안 들어올 수 있습니다. 그러면 cwd 를 맞춰도 기동 중에 RuntimeError 로 죽습니다
# — 이번엔 디렉터리가 진짜로 없어서요.
#
# 빈 디렉터리로 충분합니다. StaticFiles 는 존재만 확인하고, 우리는 그 UI 를
# 밖으로 안 냅니다. **다만 무엇을 했는지 로그에 남깁니다** — 나중에 "왜 콘솔이
# 404 지" 를 쫓지 않도록.

RC_DIR="$SPEACHES_DIR/realtime-console/dist"
if [ -d "$RC_DIR" ]; then
    log "realtime-console/dist 있음 (파일 $(find "$RC_DIR" -type f | wc -l)개)"
else
    log "realtime-console/dist **없음** → 빈 디렉터리를 만듭니다"
    log "  (기동 실패를 막기 위한 것입니다. 실시간 콘솔 UI 는 안 뜹니다 — 의도된 상태)"
    mkdir -p "$RC_DIR"
fi

# ── 6. 모델 내려받기 — **선택이 아니라 필수입니다** ─────────────
#
# speaches 는 요청이 오면 모델을 자동으로 받지 않습니다. 로컬 HF 캐시를
# 찾고 없으면 500 을 냅니다 —
#
#   speaches/routers/utils.py  get_model_card_data_or_raise()
#     → hf_utils.get_model_repo_path()
#       → huggingface_hub.CacheNotFound: Cache directory not found: .../hub
#
# 캐시 디렉터리 자체가 없으면 `/v1/models`(로컬 목록)도 같이 500 입니다.
# 그래서 **디렉터리를 만들고 모델을 미리 받는 것**이 설치의 일부입니다.

mkdir -p "$HF_HUB_CACHE"
log "HF 캐시: $HF_HUB_CACHE"

# 이미 받았으면 건너뜁니다. 캐시 디렉터리 이름은 huggingface_hub 규칙을 따릅니다.
model_dir="$HF_HUB_CACHE/models--${AUDIO_MODEL//\//--}"
if [ -d "$model_dir" ]; then
    log "모델 이미 있음: $AUDIO_MODEL"
else
    log "모델 내려받기: $AUDIO_MODEL (수 분 걸립니다)"
    if ! "$UV" run python - "$AUDIO_MODEL" <<'PY' >>"$LOG_DIR/install.log" 2>&1
import sys
from huggingface_hub import snapshot_download
p = snapshot_download(sys.argv[1])
print("받은 위치:", p)
PY
    then
        echo "--- 마지막 20줄 ---"
        tail -n 20 "$LOG_DIR/install.log"
        die "모델 내려받기 실패: $AUDIO_MODEL — id 가 맞는지 확인하세요 (chatos-audio registry)"
    fi
    log "모델 내려받기 완료"
fi

# ── 7. 워밍업 파일 ────────────────────────────────────────────────
#
# 1초짜리 무음. run.sh 가 이걸로 첫 추론까지 밀어봅니다 — 여기가 통과하면
# STT 는 실제로 되는 것입니다. **CUDA/cuDNN 문제는 여기서 드러납니다**
# (모델을 적재해야 나오는 종류라 내려받기만으로는 안 갈립니다).

WARM="$WORKSPACE_DIR/warmup.wav"
if [ ! -f "$WARM" ]; then
    log "워밍업 파일 생성"
    ffmpeg -f lavfi -i anullsrc=r=16000:cl=mono -t 1 -y "$WARM" \
        >>"$LOG_DIR/install.log" 2>&1 || log "워밍업 파일 생성 실패 (치명적이지 않음)"
fi

log "설치 완료"
