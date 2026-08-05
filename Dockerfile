# chatos.page 음성(STT) 워커 이미지
#
# speaches 공식 이미지 위에 얇게 한 겹만 올립니다. 직접 굽지 않는 이유는
# speaches 가 이미 `/v1/audio/transcriptions` 를 OpenAI 규격으로 내주기 때문입니다.
#
# 올리는 것은 셋뿐입니다.
#   1. git        — Vast 의 start_server.sh 가 `git clone` 으로 이 저장소를 받습니다
#   2. root       — 원본은 USER ubuntu 라 apt 도 /workspace 쓰기도 막힙니다
#   3. on-start   — 원본 CMD 는 uvicorn 한 프로세스뿐인데 둘을 띄워야 합니다
#
# 비밀값은 넣지 마세요. 이 이미지는 public 입니다.

FROM ghcr.io/speaches-ai/speaches:latest-cuda

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/*

COPY on-start.sh /opt/chatos/on-start.sh
RUN chmod +x /opt/chatos/on-start.sh

# speaches 는 **로컬에만** 듣습니다. 밖에서 닿으면 할당량이 통째로 우회됩니다
# (4차의 ComfyUI 8188 과 같은 자리).
ENV UVICORN_HOST=127.0.0.1 \
    UVICORN_PORT=8000 \
    SPEACHES_URL=http://127.0.0.1 \
    SPEACHES_PORT=8000 \
    WORKSPACE_DIR=/workspace \
    MODEL_LOG_FILE=/workspace/logs/speaches.log \
    PYWORKER_REPO=https://github.com/chojuy9/chatos-audio

CMD ["/opt/chatos/on-start.sh"]
