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

# whisper 모델. `chatos-audio registry whisper` 로 고를 수 있는 것을 봅니다.
AUDIO_MODEL="${AUDIO_MODEL:-deepdml/faster-whisper-large-v3-turbo-ct2}"

AUDIO_GPU_TOKEN="${AUDIO_GPU_TOKEN:-}"
TUNNEL_TOKEN="${TUNNEL_TOKEN:-}"
AUDIO_VAD_CPU="${AUDIO_VAD_CPU:-0}"

# **speaches 는 모델을 자동으로 안 받습니다.** 이 경로가 bootstrap 과 run 에서
# 어긋나면 받아둔 모델을 못 찾고 CacheNotFound 로 500 이 납니다.
HF_HOME="${HF_HOME:-$WORKSPACE_DIR/.hf_home}"
HF_HUB_CACHE="${HF_HUB_CACHE:-$HF_HOME/hub}"

WARM="$WORKSPACE_DIR/warmup.wav"

export WORKSPACE_DIR LOG_DIR RUN_DIR \
       SPEACHES_DIR SPEACHES_PORT SPEACHES_REPO \
       AUDIO_MODEL AUDIO_GPU_TOKEN TUNNEL_TOKEN AUDIO_VAD_CPU \
       HF_HOME HF_HUB_CACHE WARM
