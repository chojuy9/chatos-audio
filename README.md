# chatos-audio

[chatos.page](https://chatos.page) 의 음성 인식(STT) GPU 쪽 패키지입니다. **온디맨드로 빌린 GPU 인스턴스에서 돕니다.**

이미지를 굽지 않습니다. Vast 기본 파이토치 템플릿 위에 이 저장소를 클론하면 스크립트가 설치·실행을 다 합니다 — 이미지 생성 쪽 `comfyui_workflow_maker` 와 같은 구조입니다.

> **2026-08-06 — Vast 서버리스(PyWorker) 방식은 접었습니다.** `Dockerfile` · `worker.py` · `on-start.sh` · ghcr 빌드는 그때 쓰던 것이라 지웠습니다. PyWorker 가 JSON 전용이라 multipart 를 못 받는 것이 발단이었고, 온디맨드에서는 클라이언트가 speaches 에 직접 닿아 그 제약이 통째로 사라집니다.

**이 저장소는 public 입니다. 비밀값을 넣지 마세요.** 토큰은 전부 Vast 계정 환경변수와 Cloudflare Worker 시크릿에 있습니다. `.gitignore` 가 `.env` 를 막고 있지만, 막는 것과 안 넣는 것은 다릅니다.

---

## 쓰는 법

새 인스턴스의 **On-start Script** 칸에 두 줄:

```bash
git clone --depth 1 https://github.com/chojuy9/chatos-audio /workspace/chatos-audio
bash /workspace/chatos-audio/go.sh
```

그다음부터는 인스턴스에서 한 마디입니다.

```
chatos-audio                     최신으로 받고 설치·실행 (몇 번을 쳐도 안전)
chatos-audio status              응답 · 프로세스 · 로그 · HF 캐시 · GPU
chatos-audio registry [검색어]   **내려받을 수 있는** 모델 (정확한 id 확인용)
chatos-audio models              **받아둔** 로컬 모델
chatos-audio pull [모델id]       모델 내려받기
chatos-audio test <오디오파일>   전사 한 건 + 걸린 시간
chatos-audio logs                로그 따라가기
chatos-audio stop                정지
```

---

## 구조

```
Cloudflare Worker (chatos-auth, private)
   │  multipart + Authorization: Bearer <AUDIO_GPU_TOKEN>
   ▼
cloudflared 터널        (TUNNEL_TOKEN 이 있을 때만)
   ▼
speaches  127.0.0.1:8000   ← 밖에서 직접 못 닿습니다
```

**speaches 는 `127.0.0.1` 로만 듣습니다.** `UVICORN_HOST` 기본값이 `0.0.0.0` 이라 `run.sh` 가 명시적으로 끕니다 — 밖에서 닿으면 할당량이 통째로 우회됩니다 (4차 ComfyUI 8188 과 같은 자리).

**터널이 설정됐는데 `AUDIO_GPU_TOKEN` 이 비면 기동을 거부합니다.** 그 조합이 곧 "인증 없는 GPU 를 인터넷에 내놓기" 라서, 경고가 아니라 거부입니다.

---

## 환경변수

**Vast 계정 환경변수**(Account → Settings)에 넣어두면 인스턴스를 새로 잡아도 따라옵니다. `go.sh` 가 `/etc/chatos-audio.env` 에 굳혀서 Jupyter 터미널에서도 보이게 합니다.

| 이름 | 필수 | 내용 |
|---|---|---|
| `AUDIO_GPU_TOKEN` | **터널을 붙이면 필수** | GPU 앞단 인증. Worker 의 같은 이름 시크릿과 **같은 값** |
| `AUDIO_MODEL` | | whisper 모델 id. 기본 `deepdml/faster-whisper-large-v3-turbo-ct2` |
| `TUNNEL_TOKEN` | | 있으면 cloudflared 를 같이 띄웁니다. 없으면 로컬 전용 |
| `SPEACHES_PORT` | | 기본 8000. **8080 은 Jupyter 와 충돌해서 거부됩니다** |
| `WHISPER__COMPUTE_TYPE` | | speaches 설정. 중첩 설정은 이중 밑줄입니다 |

> **`INSTALL_ROOT` 를 쓰지 않습니다.** 이미지 생성 쪽이 계정 환경변수로 그 이름을 이미 점유하고 있어서(`/workspace/chatos-image`), 쓰면 엉뚱한 저장소를 가리킵니다. 실제로 한 번 걸렸습니다. 위치는 스크립트가 자기 경로에서 구하고, `origin` 이 `chatos-audio` 일 때만 갱신합니다.
>
> **계정 환경변수는 그 계정의 모든 인스턴스에 들어옵니다.** 새 변수는 `AUDIO_` 접두사로 만드세요.

---

## 파일

| | |
|---|---|
| `go.sh` | 진입점. 환경변수를 굳히고 설치 → 실행 → `chatos-audio` 명령 설치 |
| `scripts/bootstrap.sh` | apt(ffmpeg) · uv · speaches clone · `uv sync` · **임포트 검사** · 워밍업 파일 |
| `scripts/run.sh` | speaches 기동 · health 대기 · 모델 목록 · 워밍업 · 터널 · 감시 |
| `scripts/chatos-audio` | 위 명령들 |

**speaches 는 PyPI 에 없습니다.** `git clone` + `uv sync` 가 유일한 비-Docker 경로이고, 그 덕에 저장소 안에 격리된 `.venv` 가 생겨 **베이스 이미지의 torch 와 안 섞입니다.**

---

## 진단

로그는 `/workspace/logs/` 에 넷으로 갈립니다. **파일이 없다는 것 자체가 단서입니다.**

| 파일 | 없으면 |
|---|---|
| `install.log` | `go.sh` 가 시작도 못 한 것 |
| `speaches.log` | 모델 서버가 아예 안 뜬 것 |
| `warmup.log` | speaches 가 health 까지 못 간 것 |
| `tunnel.log` | 터널을 안 띄운 것 (`TUNNEL_TOKEN` 이 없으면 정상) |

**설치의 성공 종료 코드를 믿지 마세요.** `uv sync` 는 의존성 충돌을 경고로만 찍고 0 을 돌려줍니다. 판정은 `bootstrap.sh` 의 임포트 검사(`ctranslate2` · `faster_whisper` · `speaches.main`)가 합니다.

**speaches 는 모델을 자동으로 안 받습니다 — 이게 함정입니다.** 로컬 HF 캐시를 찾고 없으면 `CacheNotFound` 로 **500** 을 냅니다. 캐시 디렉터리 자체가 없으면 `/v1/models` 도 같이 500 이고요. 그래서 `bootstrap.sh` 가 캐시를 만들고 모델을 명시적으로 받습니다.

```
huggingface_hub.errors.CacheNotFound: Cache directory not found: /workspace/.hf_home/hub
```

이게 보이면 모델이 안 받아진 것입니다 — `chatos-audio pull`.

**`bootstrap.sh` 와 `run.sh` 의 HF 캐시 경로가 같아야 합니다.** 어긋나면 받아둔 모델을 speaches 가 못 찾고 같은 500 이 납니다.

**워밍업이 첫 추론까지 밀어봅니다.** 여기가 통과하면 STT 는 실제로 되는 것이고, **CUDA/cuDNN 궁합도 여기서 갈립니다** — 모델을 적재해야 나오는 종류라 내려받기만으로는 안 드러납니다.

---

## 아직 안 된 것

- **매니저(분할·병렬·병합)가 없습니다.** 지금은 speaches 를 그대로 부릅니다. 긴 오디오를 섹터로 나눠 배치로 돌리는 층이 들어올 자리이고, speaches 가 배치/VAD 를 노출하는지에 따라 두께가 갈립니다
- **1건당 소요시간을 안 재봤습니다.** 타임아웃·할당량·입력 상한이 전부 여기 달려 있습니다
- **모델 id 를 확정 안 했습니다.** 기본값은 후보일 뿐이라 `chatos-audio models` 로 확인하세요
- TTS 는 없습니다. STT 로 경로를 완성한 뒤에 엔드포인트를 하나 더하는 일입니다
