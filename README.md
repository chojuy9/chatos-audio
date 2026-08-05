# chatos-audio

[chatos.page](https://chatos.page) 의 음성 인식(STT)을 Vast.ai 서버리스에서 돌리는 워커입니다.

**이 저장소는 public 입니다. 비밀값을 넣지 마세요.** 토큰과 키는 Vast 환경변수와 Cloudflare Worker 시크릿에 있습니다. public 인 이유는 Vast 의 `start_server.sh` 가 `git clone "$PYWORKER_REPO"` 한 줄로 받아가는데 **인증을 붙이는 자리가 없어서**입니다 — private 으로 두면 PAT 를 URL 에 박아야 하고, 그 토큰이 남의 물리 머신에 평문으로 앉습니다.

## 구조

```
이용자 앱 ──multipart──▶ api.chatos.page/v1/audio/transcriptions
                             Cloudflare Worker (chatos-auth, private)
                               ├─ LiteLLM 키 검증 · 할당량 예약
                               ├─ 오디오를 R2 에 저장 → 일회용 토큰 URL
                               ├─ POST run.vast.ai/route/     → 워커 주소
                               └─ POST {워커}/v1/audio/transcriptions
                                        { "auth_data": {...},
                                          "payload": { "audio_url": "...", ... } }
                                                │
                                          PyWorker (worker.py, 이 저장소)
                                                │  audio_url 을 내려받아
                                                ▼  multipart 로 넘김
                                          speaches  127.0.0.1:8000
```

**왜 URL 로 건네받나** — Vast 의 PyWorker 는 JSON 만 주고받습니다. `await request.json()` 으로 읽고 `session.post(..., json=...)` 로 넘기는 구조라 multipart 를 받는 자리가 없습니다. base64 를 봉투에 담는 방법도 있지만 본문 크기 제약이 따라와서 R2 경유로 갔습니다.

## 파일

| 파일 | 역할 |
|---|---|
| `worker.py` | PyWorker 설정. **저장소 최상단에 있어야 합니다** — `start_server.sh` 가 `python3 -m worker` 로 찾습니다 |
| `Dockerfile` | speaches 공식 이미지 + `git` + root + 시작 스크립트. 다섯 줄짜리 한 겹 |
| `on-start.sh` | speaches 와 PyWorker 를 함께 띄웁니다 |
| `.github/workflows/build.yml` | ghcr 로 빌드·푸시. **풀린 이미지 크기를 요약에 남깁니다** |

## 환경변수

이미지에 기본값이 박혀 있고, Vast 템플릿에서 덮어쓸 수 있습니다.

| 변수 | 기본값 | 비고 |
|---|---|---|
| `STT_MODEL` | `Systran/faster-whisper-large-v3-turbo` | |
| `SPEACHES_PORT` | `8000` | **로컬에만 듣습니다.** 밖에서 닿으면 할당량이 우회됩니다 |
| `MAX_AUDIO_BYTES` | 64MB | Cloudflare 쪽 상한보다 넉넉해야 합니다 |
| `TRANSCRIBE_TIMEOUT` | 600초 | Worker 의 `upstreamTimeoutMs` 보다 **짧아야** 사유가 붙습니다 |
| `AUDIO_BYTES_PER_SECOND` | 16000 | 근사 기준. Worker 의 `durationFallback` 과 같아야 합니다 |
| `PYWORKER_REPO` | 이 저장소 | |

## 응답

`remote_function` 의 반환값은 PyWorker 가 `{"result": ...}` 로 감싸서 돌려줍니다.

```json
{ "result": { "text": "...", "duration": 83.4,
              "duration_estimated": false, "audio_bytes": 1334016 } }
```

`duration_estimated` 가 `true` 면 **speaches 가 길이를 안 줘서 파일 크기로 짐작한 것**입니다. 조용히 근사값을 정확한 값처럼 돌려주면 이용자가 자기 할당량이 왜 줄었는지 알 수 없습니다.

## 아직 안 된 것

- **벤치마크가 합성 톤입니다.** 모델을 깨우는 데는 충분하지만 실제 말소리가 아니라 성능 점수를 낮게 잡을 수 있습니다. 한국어 표본을 재고 나면 바꿔야 합니다
- **1건당 소요시간을 안 재봤습니다.** 콜드스타트·모델로드·연산 중 무엇이 지배적인지에 따라 타임아웃과 할당량이 정해집니다
- TTS 는 없습니다. STT 로 경로를 완성한 뒤에 엔드포인트를 하나 더하는 일입니다
