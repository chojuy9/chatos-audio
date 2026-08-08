#!/usr/bin/env bash
#
# 기본값 한 곳.
#
# 8차 교훈 — 같은 값을 여러 파일에 두면 **언젠가 한 곳만 고칩니다.**
# 그리고 이 값들은 `/etc/chatos-audio.env` 에도 굳혀져야 합니다. 안 그러면
# 터미널에서 `source` 해도 비어 있어서, 손으로 치는 curl 이 조용히 깨집니다.
#
# 규칙: **환경변수가 있으면 그것이 이깁니다.** 여기 값은 없을 때의 기본값입니다.

WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"
LOG_DIR="$WORKSPACE_DIR/logs"
RUN_DIR="$WORKSPACE_DIR/run"

SPEACHES_DIR="${SPEACHES_DIR:-$WORKSPACE_DIR/speaches}"
SPEACHES_PORT="${SPEACHES_PORT:-8000}"
SPEACHES_REPO="${SPEACHES_REPO:-https://github.com/speaches-ai/speaches.git}"

# 매니저 — **밖에서 닿는 유일한 자리이고, 터널 ingress 가 이 포트로 갑니다.**
# speaches 포트를 터널에 직접 물면 /docs · /openapi.json · Web UI 가 인증
# 없이 열립니다 (12차 8장).
MANAGER_DIR="${MANAGER_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/manager}"
MANAGER_PORT="${MANAGER_PORT:-8100}"

# 분할. 지금은 꺼져 있습니다 — 통과 경로부터 세우는 것이 순서입니다.
AUDIO_SPLIT="${AUDIO_SPLIT:-0}"

# **Worker 의 upstreamTimeoutMs(91초)보다 짧아야 합니다.** 우리가 먼저 끊어야
# Worker 가 상류 실패로 받아 예약을 반환합니다. 우리가 더 오래 붙들면 그
# 요청은 #sweep 이 걷을 때까지(최대 4분 33초) 이용자 할당량을 잡습니다.
MANAGER_UPSTREAM_TIMEOUT="${MANAGER_UPSTREAM_TIMEOUT:-85}"

# whisper 모델. `chatos-audio registry whisper` 로 고를 수 있는 것을 봅니다.
#
# **`chatos-auth` 의 `config/service-policy.json` 에 있는 `model` 과 같아야
# 합니다.** Worker 가 정책 파일의 값을 요청에 실어 보내는데, 그 모델이 로컬
# 캐시에 없으면 speaches 가 CacheNotFound 로 500 을 냅니다 (12차 4-3).
# 어긋나 있으면 **워밍업은 통과하는데 실이용자 첫 요청이 500** 입니다 —
# 제일 늦게 드러나는 자리라 기본값을 정책값에 맞춰둡니다 (2-14 확정).
AUDIO_MODEL="${AUDIO_MODEL:-Systran/faster-whisper-large-v3}"

AUDIO_GPU_TOKEN="${AUDIO_GPU_TOKEN:-}"
TUNNEL_TOKEN="${TUNNEL_TOKEN:-}"
AUDIO_VAD_CPU="${AUDIO_VAD_CPU:-0}"

# 비동기 잡 pull. 토큰이 있을 때만 run.sh가 에이전트를 띄웁니다. 이 토큰은
# 로컬 STT용 AUDIO_GPU_TOKEN과 다른 값이어야 합니다.
AUDIO_JOB_API_BASE="${AUDIO_JOB_API_BASE:-https://chatos.page}"
AUDIO_JOB_TOKEN="${AUDIO_JOB_TOKEN:-}"
AUDIO_JOB_POLL_SECONDS="${AUDIO_JOB_POLL_SECONDS:-2}"
AUDIO_JOB_HEARTBEAT_SECONDS="${AUDIO_JOB_HEARTBEAT_SECONDS:-30}"
AUDIO_JOB_LOG_LEVEL="${AUDIO_JOB_LOG_LEVEL:-INFO}"

# 가사 분리는 코드만 준비하고 기본은 닫습니다. Demucs 또는 사용자 지정 명령을
# 설치·실측한 다음 AUDIO_LYRICS_ENABLED=1로 열어야 에이전트가 lyrics를 광고합니다.
AUDIO_LYRICS_ENABLED="${AUDIO_LYRICS_ENABLED:-0}"
AUDIO_LYRICS_MODEL="${AUDIO_LYRICS_MODEL:-htdemucs}"
AUDIO_LYRICS_DEVICE="${AUDIO_LYRICS_DEVICE:-cuda}"
AUDIO_LYRICS_TIMEOUT_SECONDS="${AUDIO_LYRICS_TIMEOUT_SECONDS:-900}"
AUDIO_LYRICS_SEPARATOR_CMD="${AUDIO_LYRICS_SEPARATOR_CMD:-}"

# **speaches 는 모델을 자동으로 안 받습니다.** 이 경로가 bootstrap 과 run 에서
# 어긋나면 받아둔 모델을 못 찾고 CacheNotFound 로 500 이 납니다.
HF_HOME="${HF_HOME:-$WORKSPACE_DIR/.hf_home}"
HF_HUB_CACHE="${HF_HUB_CACHE:-$HF_HOME/hub}"

WARM="$WORKSPACE_DIR/warmup.wav"

export WORKSPACE_DIR LOG_DIR RUN_DIR \
       SPEACHES_DIR SPEACHES_PORT SPEACHES_REPO \
       MANAGER_DIR MANAGER_PORT AUDIO_SPLIT MANAGER_UPSTREAM_TIMEOUT \
       AUDIO_MODEL AUDIO_GPU_TOKEN TUNNEL_TOKEN AUDIO_VAD_CPU \
       AUDIO_JOB_API_BASE AUDIO_JOB_TOKEN AUDIO_JOB_POLL_SECONDS \
       AUDIO_JOB_HEARTBEAT_SECONDS AUDIO_JOB_LOG_LEVEL \
       AUDIO_LYRICS_ENABLED AUDIO_LYRICS_MODEL AUDIO_LYRICS_DEVICE \
       AUDIO_LYRICS_TIMEOUT_SECONDS \
       AUDIO_LYRICS_SEPARATOR_CMD \
       HF_HOME HF_HUB_CACHE WARM
