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
cloudflared 터널        (AUDIO_TUNNEL_TOKEN 이 있을 때만)
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
| `AUDIO_JOB_TOKEN` | **비동기 잡 사용 시 필수** | Worker 내부 pull 인증. Worker의 같은 이름 시크릿과 같고 `AUDIO_GPU_TOKEN`과는 다른 값 |
| `AUDIO_JOB_API_BASE` | | 비동기 잡 Worker. 기본 `https://chatos.page` |
| `AUDIO_LYRICS_ENABLED` | | 보컬 분리 실측 후 `1`. 기본 `0` |
| `AUDIO_LYRICS_MODEL` | | Demucs 모델. 기본 `htdemucs` |
| `AUDIO_LYRICS_DEVICE` | | Demucs 장치. GPU 서비스 기본 `cuda` |
| `AUDIO_LYRICS_SEPARATOR_CMD` | | Demucs 대신 쓸 명령. `{input}`·`{output}`·`{output_dir}` 자리표시자 지원 |
| `AUDIO_MODEL` | | whisper 모델 id. 기본 `deepdml/faster-whisper-large-v3-turbo-ct2` |
| `AUDIO_TUNNEL_TOKEN` | | 있으면 cloudflared 를 같이 띄웁니다. 없으면 로컬 전용 |
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
| `scripts/run.sh` | speaches·매니저 기동 · 워밍업 · 비동기 잡 에이전트 · 선택적 터널 |
| `manager/job_agent.py` | Worker에서 잡·입력을 가져와 전사하고 결과를 되돌리는 pull 에이전트 |
| `scripts/chatos-audio` | 위 명령들 |

**speaches 는 PyPI 에 없습니다.** `git clone` + `uv sync` 가 유일한 비-Docker 경로이고, 그 덕에 저장소 안에 격리된 `.venv` 가 생겨 **베이스 이미지의 torch 와 안 섞입니다.**

### 노래 가사 경로 열기

`AUDIO_LYRICS_ENABLED=1`이면 매니저 전용 가상환경에 고정 버전 Demucs를 추가로 설치합니다. 기본 STT만 쓰는 인스턴스에는 Demucs와 두 번째 torch 환경을 설치하지 않습니다. 설치 중 Demucs 임포트·CUDA 확인에 이어 1초 오디오의 실제 보컬 분리까지 통과해야 기동됩니다.

먼저 대표 노래 파일로 분리 시간과 전사 결과를 확인합니다.

```bash
chatos-audio lyrics-test /workspace/sample-song.mp3 > /workspace/sample-song.lyrics.json
```

이 명령은 `보컬 분리 → vocals.wav → 매니저 STT`를 실제 서비스와 같은 순서로 실행하고, 분리·전사 시간을 stderr에 따로 표시합니다. 결과와 VRAM을 확인한 뒤에만 `chatos-auth/config/service-policy.json`의 `lyrics.enabled`를 여세요. GPU만 켜거나 Worker만 켜면 공개되지 않도록 두 단계로 분리돼 있습니다.

> **다만 격리에는 대가가 있습니다.** 파이썬 패키지 충돌은 안 생기는 대신 **네이티브 라이브러리가 로더 경로에 안 잡힙니다.** `run.sh` 가 `.venv/.../site-packages/nvidia/*/lib` 를 `LD_LIBRARY_PATH` 에 넣는 이유입니다 — 안 넣으면 whisper 적재에서 프로세스가 통째로 죽습니다(아래 진단 참고).

---

## 진단

로그는 `/workspace/logs/` 에 넷으로 갈립니다. **파일이 없다는 것 자체가 단서입니다.**

| 파일 | 없으면 |
|---|---|
| `install.log` | `go.sh` 가 시작도 못 한 것 |
| `speaches.log` | 모델 서버가 아예 안 뜬 것 |
| `warmup.log` | speaches 가 health 까지 못 간 것 |
| `tunnel.log` | 터널을 안 띄운 것 (`AUDIO_TUNNEL_TOKEN` 이 없으면 정상) |

**갱신은 `git pull` 말고 `chatos-audio` 를 쓰세요.** `go.sh` 가 `fetch` + `reset --hard origin/main` 으로 원격 상태를 통째로 덮어씁니다. 인스턴스는 쓰고 버리는 것이라 로컬 변경을 지킬 이유가 없고, 덕분에 충돌이 안 납니다. `git pull` 로 막혔다면:

```bash
cd /workspace/chatos-audio && git fetch origin main && git reset --hard origin/main
```

> **`chmod +x` 를 스크립트에서 돌리지 마세요.** git 이 실행 비트를 추적해서, chmod 한 파일이 "로컬 변경" 이 되어 다음 pull 을 막습니다 (4차 5장). 이 저장소는 실행 비트가 필요한 파일이 없습니다 — 전부 `bash <파일>` 이나 `install -m 755` 로 처리합니다.

**설치의 성공 종료 코드를 믿지 마세요.** `uv sync` 는 의존성 충돌을 경고로만 찍고 0 을 돌려줍니다. 판정은 `bootstrap.sh` 의 임포트 검사(`ctranslate2` · `faster_whisper` · `speaches.main`)가 합니다.

**speaches 는 모델을 자동으로 안 받습니다 — 이게 함정입니다.** 로컬 HF 캐시를 찾고 없으면 `CacheNotFound` 로 **500** 을 냅니다. 캐시 디렉터리 자체가 없으면 `/v1/models` 도 같이 500 이고요. 그래서 `bootstrap.sh` 가 캐시를 만들고 모델을 명시적으로 받습니다.

```
huggingface_hub.errors.CacheNotFound: Cache directory not found: /workspace/.hf_home/hub
```

이게 보이면 모델이 안 받아진 것입니다 — `chatos-audio pull`.

**`bootstrap.sh` 와 `run.sh` 의 HF 캐시 경로가 같아야 합니다.** 어긋나면 받아둔 모델을 speaches 가 못 찾고 같은 500 이 납니다.

**워밍업이 첫 추론까지 밀어봅니다.** 여기가 통과하면 STT 는 실제로 되는 것이고, **CUDA/cuDNN 궁합도 여기서 갈립니다** — 모델을 적재해야 나오는 종류라 내려받기만으로는 안 드러납니다.

### `curl: (52) Empty reply from server` — cuDNN

```
Unable to load any of {libcudnn_cnn.so.9.1.0, ..., libcudnn_cnn.so.9}
Invalid handle. Cannot load symbol cudnnCreateConvolutionDescriptor
```

**파이썬 예외가 아니라 프로세스가 통째로 죽는 것**이라 500 이 아니라 빈 응답으로 보입니다. cuDNN 9 가 `ops` · `cnn` · `adv` · `graph` 로 쪼개져 있는데, 서버는 whisper 앞에 **VAD(onnxruntime)** 를 먼저 돌리고 onnxruntime 은 `_cnn` 이 없는 자기 벤더 사본을 올립니다. 그다음 ctranslate2 가 `libcudnn_cnn.so.9` 를 못 찾습니다.

`run.sh` 가 `LD_LIBRARY_PATH` 로 해결합니다. 그래도 죽으면 **VAD 를 CPU 로** 돌리세요 — silero 는 아주 작은 모델이라 CPU 로 충분합니다.

```
AUDIO_VAD_CPU=1
```

> **직접 `WhisperModel(device="cuda")` 를 돌리면 성공하는데 서버에서만 죽습니다.** 그 차이가 VAD 였습니다 — 재현이 안 될 때 이 점을 기억하세요.

---

## 아직 안 된 것

- **매니저(분할·병렬·병합)가 없습니다.** 지금은 speaches 를 그대로 부릅니다. 긴 오디오를 섹터로 나눠 배치로 돌리는 층이 들어올 자리이고, speaches 가 배치/VAD 를 노출하는지에 따라 두께가 갈립니다
- **1건당 소요시간을 안 재봤습니다.** 타임아웃·할당량·입력 상한이 전부 여기 달려 있습니다
- **모델 id 를 확정 안 했습니다.** 기본값은 후보일 뿐이라 `chatos-audio models` 로 확인하세요
- TTS 는 없습니다. STT 로 경로를 완성한 뒤에 엔드포인트를 하나 더하는 일입니다
