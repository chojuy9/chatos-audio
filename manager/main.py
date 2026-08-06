"""
매니저 — 밖에서 닿는 유일한 자리.

터널이 speaches 를 직접 물지 않고 **이 프로세스를 뭅니다.** 두 가지가 걸려
있습니다.

  ① speaches 는 API_KEY 를 걸어도 `/health` · `/docs` · `/openapi.json` ·
     Web UI(Gradio)를 인증에서 뺍니다 (12차 8장). 터널이 speaches 를 직접
     물면 그 넷이 인증 없이 열립니다. **여기서는 아예 도달이 안 됩니다** —
     아래 catch-all 이 전부 404 로 닫고, 우리 자신의 /docs 도 끕니다.

  ② 분할·병합을 우리가 짭니다. speaches 가 batch_size 를 노출 안 하고
     (task 1-7), 문맥 사슬을 끊는 파라미터도 없어서, **조각내는 것이 긴 파일
     환각에 우리가 쓸 수 있는 유일한 개입**입니다 (plan.md 4-3).

지금은 ②가 **꺼져 있습니다** (AUDIO_SPLIT=0). 통과 경로부터 세우는 것이
순서입니다 — 이게 서면 터널·배포(4장)를 분할 완성 전에 진행할 수 있고,
분할은 이 위에 얹힙니다.

**단계는 목록으로 둡니다.** 나중에 들어올 것이 분할만이 아닙니다 — 노래
가사용 음원 분리(보컬/반주)가 전처리 자리에 들어옵니다. 그때 이 파일을
다시 뜯지 않도록 자리를 비워둡니다.
"""

from __future__ import annotations

import asyncio
import logging
import os
import sys
import tempfile
from contextlib import asynccontextmanager

import httpx

import split
from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse

log = logging.getLogger("manager")

# ── 설정 ──────────────────────────────────────────────────────────────
#
# **환경변수가 이깁니다** — defaults.sh 와 같은 규칙입니다.

MANAGER_PORT = int(os.environ.get("MANAGER_PORT", "8100"))
SPEACHES_PORT = int(os.environ.get("SPEACHES_PORT", "8000"))
SPEACHES_BASE = f"http://127.0.0.1:{SPEACHES_PORT}"

# 로그에 한글을 씁니다. **인스턴스는 UTF-8 이지만 로컬 시험(윈도우)은 cp949 라
# 그대로 두면 로깅이 예외를 던집니다** — 더미STT서버.py 가 같은 자리를 이미
# 방어하고 있습니다. 출력 때문에 서버가 멈추면 안 됩니다.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(errors="replace", line_buffering=True)
    except (AttributeError, ValueError):
        pass
AUDIO_GPU_TOKEN = os.environ.get("AUDIO_GPU_TOKEN", "")

AUDIO_SPLIT = os.environ.get("AUDIO_SPLIT", "0") == "1"

# 섹터 길이. 3분은 초안입니다 — 확정은 2-9 대조입니다.
SECTOR_SECONDS = float(os.environ.get("AUDIO_SECTOR_SECONDS", "180"))
# 목표 지점 앞뒤로 이만큼 안에서 무음을 찾습니다. 넓힐수록 조각 길이가 들쭉
# 날쭉해지고, 좁힐수록 정각 절단이 늘어납니다.
SECTOR_TOLERANCE = float(os.environ.get("AUDIO_SECTOR_TOLERANCE", "30"))
SILENCE_NOISE_DB = int(os.environ.get("AUDIO_SILENCE_NOISE_DB", "-32"))
SILENCE_MIN_SECONDS = float(os.environ.get("AUDIO_SILENCE_MIN_SECONDS", "0.35"))

# **실측한 폭까지만 씁니다.** 30초 파일 둘을 동시에 넣어 각각 1.65 · 1.67초로
# 페널티가 없었지만(2-3), 확인한 것은 거기까지입니다.
SECTOR_CONCURRENCY = int(os.environ.get("AUDIO_SECTOR_CONCURRENCY", "2"))

# **Worker 의 upstreamTimeoutMs(91초)보다 짧아야 합니다.**
# 우리가 먼저 끊어야 Worker 가 "상류 실패" 로 받아 예약을 **반환**합니다.
# 우리가 더 오래 붙들면 Worker 쪽이 먼저 끊기고, 그 요청은 #sweep 이
# 걷어낼 때까지(최대 4분 33초) 이용자 할당량을 잡고 있습니다.
UPSTREAM_TIMEOUT = float(os.environ.get("MANAGER_UPSTREAM_TIMEOUT", "85"))

# **/docs · /openapi.json · /redoc 를 끕니다.** speaches 의 그것들을 막으려고
# 매니저를 두는데 우리가 같은 것을 열면 아무 의미가 없습니다.
_client: httpx.AsyncClient | None = None


@asynccontextmanager
async def _lifespan(_app: FastAPI):
    global _client
    # 연결을 재사용합니다. 분할이 켜지면 한 요청에 조각 수만큼 호출합니다.
    _client = httpx.AsyncClient(base_url=SPEACHES_BASE, timeout=UPSTREAM_TIMEOUT)
    log.info(
        "매니저 시작 — 포트 %s · 상류 %s · 분할 %s · 타임아웃 %.0f초",
        MANAGER_PORT, SPEACHES_BASE, "켬" if AUDIO_SPLIT else "끔", UPSTREAM_TIMEOUT,
    )
    if not AUDIO_GPU_TOKEN:
        log.warning("AUDIO_GPU_TOKEN 이 비었습니다 — 인증 없이 받습니다. 터널을 붙이기 전에 채우세요")
    if AUDIO_SPLIT:
        # **없는 채로 두면 분할이 조용히 실패합니다** (plan.md 11장). 켜뒀는데
        # 안 도는 것이 제일 나쁘니, 경고가 아니라 기동 거부입니다.
        if not split.have_ffmpeg():
            raise RuntimeError(
                "AUDIO_SPLIT=1 인데 ffmpeg/ffprobe 가 없습니다. "
                "bootstrap.sh 의 apt 목록을 확인하세요 (task 1-8)"
            )
        log.info("분할 켬 — 섹터 %.0f초 ±%.0f · 동시 %d · 무음 %ddB/%.2fs",
                 SECTOR_SECONDS, SECTOR_TOLERANCE, SECTOR_CONCURRENCY,
                 SILENCE_NOISE_DB, SILENCE_MIN_SECONDS)
    try:
        yield
    finally:
        await _client.aclose()


# **/docs · /openapi.json · /redoc 를 끕니다.** speaches 의 그것들을 막으려고
# 매니저를 두는데 우리가 같은 것을 열면 아무 의미가 없습니다.
app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None, lifespan=_lifespan)


# ── 인증 ──────────────────────────────────────────────────────────────
#
# **밖에 닿는 것이 이 프로세스입니다.** 여기가 뚫리면 이 서비스의 할당량이
# 통째로 우회됩니다 (4차 ComfyUI 8188 과 같은 자리).
#
# speaches 에도 API_KEY 를 겁니다. 두 겹이고, **바깥 겹이 없으면 안 됩니다.**

def _authorized(request: Request) -> bool:
    if not AUDIO_GPU_TOKEN:
        # 토큰이 없는 채로 뜨는 것은 로컬 시험 단계에서만 정상입니다.
        # run.sh 가 TUNNEL_TOKEN 과 같이 있으면 기동 자체를 거부합니다.
        return True
    header = request.headers.get("authorization", "")
    if not header.startswith("Bearer "):
        return False
    # 길이가 다르면 빨리 끝나지만, 토큰은 우리가 만든 고정 길이 값이라
    # 실질적인 정보가 안 샙니다.
    return _constant_eq(header[7:], AUDIO_GPU_TOKEN)


def _constant_eq(a: str, b: str) -> bool:
    import hmac
    return hmac.compare_digest(a.encode(), b.encode())


def _unauthorized() -> JSONResponse:
    return JSONResponse({"error": {"message": "unauthorized", "type": "auth"}}, status_code=401)


# ── 상류 오류를 그대로 안 흘립니다 (task 3-27) ────────────────────────
#
# 6차에서 예외 메시지에 실린 경로가 관리 화면까지 갔습니다. speaches 의
# 오류 본문에는 인스턴스 경로(`/workspace/...`)와 모델 캐시 위치가 들어
# 있습니다. **로그에는 전부 남기고, 밖으로는 분류만 냅니다.**

def _upstream_error(status: int, body: bytes) -> JSONResponse:
    log.error("상류 %s — %s", status, body[:2000].decode("utf-8", "replace"))
    if status == 400:
        message, kind = "요청을 상류가 거절했습니다", "bad_request"
    elif status in (401, 403):
        # 매니저는 통과했는데 speaches 가 거절한 것 = 우리 설정이 어긋난 것입니다.
        # 이용자 잘못이 아니므로 5xx 로 냅니다.
        message, kind = "상류 인증 설정이 어긋났습니다", "upstream_auth"
        status = 502
    elif status == 500:
        # 거의 항상 CacheNotFound(모델 미다운로드)입니다 — 12차 4-3.
        message, kind = "상류가 요청을 처리하지 못했습니다", "upstream_error"
        status = 502
    else:
        message, kind = "상류 오류", "upstream_error"
        status = 502
    return JSONResponse({"error": {"message": message, "type": kind}}, status_code=status)


# ── 파이프라인 ────────────────────────────────────────────────────────
#
# 단계를 목록으로 둡니다. 지금 켜져 있는 것은 transcribe 하나입니다.
#
#   preprocess   (미착수) 음원 분리 — 노래 가사용. 보컬만 남깁니다
#   split        (미착수) 섹터 분할 — VAD/무음 기준, **정각 금지**
#   transcribe   ← 지금은 이것만. 원본을 통째로 speaches 에 넘깁니다
#   merge        (미착수) 병합 — **타임스탬프에 섹터 시작 오프셋을 더할 것**
#
# 넣을 때 지켜야 할 것은 plan.md 4-3 의 표에 있습니다. 특히:
#   · duration 은 **원본 길이**로 (겹침을 더하면 이용자가 더 냅니다)
#   · 부분 실패는 **조각 재시도 1회 → 그래도 실패면 전체 실패** (task 3-26)
#   · 프롬프트·프리셋은 **조각마다 재주입** (task 3-25)


async def _transcribe_split(raw: bytes, filename: str, data: dict) -> Response:
    """분할 경로. 무음에서 잘라 조각마다 돌리고 다시 붙입니다.

    **조각마다 프롬프트를 다시 넣습니다.** 이게 되살린 근거 둘째입니다 —
    통짜로 넣으면 앞부분만 듣고 중반부터 효과가 옅어집니다 (2-8-a).

    **부분 실패는 조각 재시도 1회 → 그래도 실패면 전체 실패입니다** (3-26,
    소유자 결정). 구멍 난 전사를 조용히 주지 않습니다.
    """
    with tempfile.TemporaryDirectory(prefix="chatos-audio-") as tmp:
        src = os.path.join(tmp, filename or "input")
        with open(src, "wb") as fh:
            fh.write(raw)

        duration = await split.probe_duration(src)
        if duration is None:
            # 길이를 못 재면 자를 지점을 정할 수 없습니다. **통짜로 넘깁니다** —
            # 여기서 실패시키면 ffprobe 가 못 읽는 형식이 전부 막힙니다.
            log.warning("길이를 못 쟀습니다 — 통짜로 넘깁니다")
            return await _transcribe_whole(_file_part(filename, raw), data)

        if duration <= SECTOR_SECONDS:
            log.info("%.1f초 — 섹터 하나라 그대로 넘깁니다", duration)
            return await _transcribe_whole(_file_part(filename, raw), data)

        silences = await split.detect_silences(src, SILENCE_NOISE_DB, SILENCE_MIN_SECONDS)
        boundaries, hard_cuts = split.pick_boundaries(
            silences, duration, SECTOR_SECONDS, SECTOR_TOLERANCE
        )
        sectors = split.sectors_from_boundaries(boundaries, duration)
        if hard_cuts:
            # **조용히 넘어가지 않습니다.** 무음이 없는 오디오(노래가 정확히
            # 그렇습니다)에서는 정각 절단이 나고, 그 조각의 경계가 깨집니다.
            log.warning("정각으로 자른 경계 %d개 — 무음을 못 찾았습니다", hard_cuts)
        log.info("%.1f초 → 섹터 %d개 (무음 %d구간, 정각 %d)",
                 duration, len(sectors), len(silences), hard_cuts)

        # 조각을 뽑습니다. 하나라도 실패하면 전체 실패입니다 — 여기서 실패하는
        # 것은 오디오 자체의 문제라 재시도해도 같습니다.
        paths: list[str] = []
        for index, (start, end) in enumerate(sectors):
            dst = os.path.join(tmp, f"sector-{index:03d}.wav")
            if not await split.cut_sector(src, dst, start, end):
                return JSONResponse(
                    {"error": {"message": "오디오를 나누지 못했습니다", "type": "split_failed"}},
                    status_code=502,
                )
            paths.append(dst)

        gate = asyncio.Semaphore(SECTOR_CONCURRENCY)

        async def one(index: int, path: str) -> dict | None:
            async with gate:
                # **조각마다 프롬프트·프리셋을 다시 넣습니다.** data 를 그대로
                # 물려주므로 prompt · hotwords · language 가 전부 따라갑니다.
                for attempt in (1, 2):
                    with open(path, "rb") as fh:
                        part = _file_part(f"sector-{index:03d}.wav", fh.read(), "audio/wav")
                    result = await _post_upstream(part, data)
                    if result is not None:
                        return result
                    if attempt == 1:
                        log.warning("섹터 %d 실패 — 1회 재시도합니다", index)
                return None

        results = await asyncio.gather(*(one(i, p) for i, p in enumerate(paths)))

        if any(r is None for r in results):
            # **구멍 난 전사를 주지 않습니다** (3-26). 전체 실패로 내야 Worker 가
            # 예약을 **반환**합니다 — 차감이 아니라요.
            failed = [i for i, r in enumerate(results) if r is None]
            log.error("섹터 %s 가 재시도 뒤에도 실패 — 전체 실패로 냅니다", failed)
            return JSONResponse(
                {"error": {"message": "일부 구간을 전사하지 못했습니다", "type": "sector_failed"}},
                status_code=502,
            )

        merged = split.merge_payloads(
            [r for r in results if r is not None],
            [start for start, _ in sectors],
            duration,
        )
        return JSONResponse(merged, status_code=200)


def _file_part(filename: str, raw: bytes, content_type: str | None = None) -> dict:
    return {"file": (filename or "audio", raw, content_type or "application/octet-stream")}


async def _post_upstream(files: dict, data: dict) -> dict | None:
    """조각 하나를 상류에 넘깁니다. 실패는 None 으로만 알립니다 (재시도용)."""
    assert _client is not None
    try:
        r = await _client.post("/v1/audio/transcriptions", files=files, data=data,
                               headers=_upstream_headers())
    except httpx.HTTPError as exc:
        log.error("섹터 상류 오류: %s", exc)
        return None
    if r.status_code != 200:
        log.error("섹터 상류 %s — %s", r.status_code,
                  r.content[:500].decode("utf-8", "replace"))
        return None
    try:
        payload = r.json()
    except ValueError:
        log.error("섹터 응답이 JSON 이 아닙니다")
        return None
    return payload if isinstance(payload, dict) else None


async def _transcribe_whole(files, data) -> Response:
    """분할 없이 그대로 넘깁니다. 지금의 유일한 경로입니다."""
    assert _client is not None
    try:
        r = await _client.post("/v1/audio/transcriptions", files=files, data=data,
                               headers=_upstream_headers())
    except httpx.TimeoutException:
        log.error("상류 타임아웃 (%.0f초)", UPSTREAM_TIMEOUT)
        return JSONResponse(
            {"error": {"message": "상류가 시간 안에 응답하지 않았습니다", "type": "upstream_timeout"}},
            status_code=504,
        )
    except httpx.HTTPError as exc:
        # **빈 응답은 500 과 다른 사건입니다** — speaches 프로세스가 그 자리에서
        # 죽은 것이고, 대개 네이티브(cuDNN) 쪽입니다 (12차 4-5).
        log.error("상류에 못 닿았습니다: %s", exc)
        return JSONResponse(
            {"error": {"message": "상류에 닿지 못했습니다", "type": "upstream_unreachable"}},
            status_code=502,
        )

    if r.status_code != 200:
        return _upstream_error(r.status_code, r.content)

    # **본문을 그대로 돌려줍니다.** Worker 가 최상위 `duration` 을 읽습니다
    # (external-audio-api.js:290). 이 필드를 건드리면 정확 차감이 파일 크기
    # 근사로 떨어집니다 — task 1-5-b.
    media_type = r.headers.get("content-type", "application/json")
    return Response(content=r.content, status_code=200, media_type=media_type)


def _upstream_headers() -> dict[str, str]:
    if AUDIO_GPU_TOKEN:
        return {"Authorization": f"Bearer {AUDIO_GPU_TOKEN}"}
    return {}


# ── 라우트 ────────────────────────────────────────────────────────────

@app.post("/v1/audio/transcriptions")
async def transcriptions(request: Request):
    if not _authorized(request):
        return _unauthorized()

    form = await request.form()
    upload = form.get("file")
    if upload is None or not hasattr(upload, "filename"):
        return JSONResponse(
            {"error": {"message": "file 이 없습니다", "type": "bad_request"}}, status_code=400
        )

    # **알 수 없는 필드를 지어내지 않습니다.** Worker 가 보내는 것만 넘깁니다.
    # 목록은 speaches 의 실제 파라미터입니다 (task 1-7). `hotwords` 는 Worker
    # 쪽이 아직 안 보내지만(task 3-8) 여기서는 미리 받아둡니다.
    passthrough = (
        "model", "language", "prompt", "response_format", "temperature",
        "hotwords", "without_timestamps", "timestamp_granularities[]",
    )
    # **dict 여야 합니다.** 튜플 목록으로 주면 httpx 가 폼 필드가 아니라 raw
    # 본문으로 읽고 동기 경로로 빠져서, AsyncClient 에서 이렇게 죽습니다 —
    #   RuntimeError: Attempted to send an sync request with an AsyncClient
    # 반복 키(`timestamp_granularities[]`)는 **값을 리스트로** 주면 됩니다.
    data: dict[str, object] = {}
    for key in passthrough:
        values = [v for v in form.getlist(key) if isinstance(v, str)]
        if not values:
            continue
        data[key] = values if len(values) > 1 else values[0]

    raw = await upload.read()
    files = _file_part(upload.filename, raw, upload.content_type)

    if AUDIO_SPLIT:
        # **분할하면 세그먼트가 있어야 붙일 수 있습니다.** Worker 는 항상
        # verbose_json 으로 받지만(duration 을 얻으려고), 여기서 그 전제에
        # 기대지 않고 상류에는 명시적으로 요구합니다.
        sector_data = dict(data)
        sector_data["response_format"] = "verbose_json"
        return await _transcribe_split(raw, upload.filename, sector_data)

    return await _transcribe_whole(files, data)


@app.get("/health")
async def health():
    """**우리 것입니다.** speaches 의 /health 를 프록시하지 않습니다.

    상류가 죽었는지도 같이 봅니다 — 매니저만 살아 있고 speaches 가 죽은 상태를
    "정상" 으로 답하면, 4차 health 사건(죽어가는 프로세스가 200 을 답한 것)을
    한 겹 위에서 되풀이하는 셈입니다.
    """
    upstream = "unknown"
    if _client is not None:
        try:
            r = await _client.get("/health", timeout=3)
            upstream = "ok" if r.status_code == 200 else f"http_{r.status_code}"
        except httpx.HTTPError:
            upstream = "unreachable"
    body = {"status": "ok" if upstream == "ok" else "degraded",
            "upstream": upstream, "split": AUDIO_SPLIT}
    return JSONResponse(body, status_code=200 if upstream == "ok" else 503)


# ── 나머지는 전부 닫습니다 ────────────────────────────────────────────
#
# **매니저를 두는 이유의 절반이 이것입니다.** 터널 뒤에 speaches 의 `/docs` ·
# `/openapi.json` · Web UI 가 놓이지 않게 하는 것. 새 경로를 늘리고 싶으면
# 여기 위에 명시적으로 추가하세요 — 열려 있는 것이 기본값이면 언젠가 샙니다.

@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"])
async def _closed(path: str):
    return JSONResponse({"error": {"message": "not found", "type": "not_found"}}, status_code=404)


def main() -> None:
    import uvicorn

    logging.basicConfig(
        level=logging.INFO,
        format="[매니저 %(asctime)s] %(levelname)s %(message)s",
        datefmt="%H:%M:%S",
        stream=sys.stdout,
    )
    # **127.0.0.1 로만 듣습니다.** 밖으로는 터널만 통합니다.
    uvicorn.run(app, host="127.0.0.1", port=MANAGER_PORT, log_config=None)


if __name__ == "__main__":
    main()
