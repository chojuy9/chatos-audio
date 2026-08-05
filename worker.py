"""
chatos.page 음성(STT) PyWorker.

Vast 서버리스 워커가 뜰 때 `start_server.sh` 가 이 저장소를 클론하고
`python3 -m worker` 로 이 파일을 실행합니다. 저장소 최상단에 있어야 합니다.

구조:

    Cloudflare Worker ──POST /route/──▶ Vast          (워커 주소 확보)
                      ──POST {워커}/v1/audio/transcriptions
                            { "auth_data": {...},
                              "payload": { "audio_url": "...", ... } }
                                      │
                                   PyWorker (이 파일)
                                      │  audio_url 을 내려받아
                                      ▼  multipart 로 넘김
                                   speaches  127.0.0.1:8000

PyWorker 는 JSON 만 주고받습니다. multipart 를 받는 자리가 없어서
오디오는 URL 로 건네받고 여기서 내려받습니다. 자세한 경위는
`litellm_memory/plan.md` 2-1-1 · 2-4-1.

이 파일에는 비밀값이 없습니다. 저장소가 public 이므로 앞으로도 넣지 마세요.
토큰은 Vast 환경변수와 Cloudflare Worker 시크릿에 둡니다.
"""

import base64
import io
import logging
import math
import os
import struct
import wave
from typing import Any, Dict, Optional

import aiohttp

from vastai.serverless.server.worker import (
    BenchmarkConfig,
    HandlerConfig,
    LogActionConfig,
    Worker,
    WorkerConfig,
)

log = logging.getLogger(__name__)


# ─────────────────────────────────────────────────────────────
# 설정
# ─────────────────────────────────────────────────────────────

SPEACHES_URL = os.environ.get("SPEACHES_URL", "http://127.0.0.1")
SPEACHES_PORT = int(os.environ.get("SPEACHES_PORT", "8000"))
SPEACHES_BASE = f"{SPEACHES_URL}:{SPEACHES_PORT}"

STT_MODEL = os.environ.get("STT_MODEL", "Systran/faster-whisper-large-v3-turbo")

# 내려받기 상한. Cloudflare Worker 쪽 maxUploadBytes 보다 넉넉해야 합니다 —
# 여기서 걸리면 이용자에게는 원인이 안 보이는 실패가 됩니다.
MAX_AUDIO_BYTES = int(os.environ.get("MAX_AUDIO_BYTES", str(64 * 1024 * 1024)))

# 오디오를 내려받는 데 걸리는 시간. 전사 시간과는 별개입니다.
FETCH_TIMEOUT_SECONDS = float(os.environ.get("AUDIO_FETCH_TIMEOUT", "60"))

# 전사 자체의 상한. Cloudflare Worker 의 upstreamTimeoutMs 보다 짧아야
# 우리 쪽에서 먼저 끊고 사유를 붙일 수 있습니다.
TRANSCRIBE_TIMEOUT_SECONDS = float(os.environ.get("TRANSCRIBE_TIMEOUT", "600"))

# 근사 기준. Cloudflare Worker 의 durationFallback 과 같은 값이어야 합니다.
BYTES_PER_SECOND = int(os.environ.get("AUDIO_BYTES_PER_SECOND", "16000"))


class UpstreamError(RuntimeError):
    """상류(내려받기 또는 speaches)에서 난 실패. 사유를 앞에 붙입니다."""


# ─────────────────────────────────────────────────────────────
# 오디오 확보
# ─────────────────────────────────────────────────────────────


async def _fetch_audio(session: aiohttp.ClientSession, url: str) -> bytes:
    """audio_url 을 내려받습니다. 상한을 넘으면 다 받기 전에 끊습니다."""
    timeout = aiohttp.ClientTimeout(total=FETCH_TIMEOUT_SECONDS)
    async with session.get(url, timeout=timeout) as response:
        if response.status != 200:
            raise UpstreamError(f"audio_fetch_failed: HTTP {response.status}")

        # Content-Length 가 있으면 받기 전에 거릅니다.
        declared = response.headers.get("Content-Length")
        if declared and int(declared) > MAX_AUDIO_BYTES:
            raise UpstreamError(f"audio_too_large: {declared} bytes")

        buf = bytearray()
        async for chunk in response.content.iter_chunked(64 * 1024):
            buf.extend(chunk)
            # Content-Length 를 안 주는 경우가 있어 받으면서도 봅니다.
            if len(buf) > MAX_AUDIO_BYTES:
                raise UpstreamError(f"audio_too_large: >{MAX_AUDIO_BYTES} bytes")
        return bytes(buf)


def _resolve_audio(audio_url: Optional[str], audio_b64: Optional[str]) -> Optional[bytes]:
    """base64 로 온 경우만 즉시 처리합니다. URL 은 비동기라 호출부에서."""
    if audio_b64:
        try:
            return base64.b64decode(audio_b64, validate=True)
        except Exception as exc:
            raise UpstreamError(f"audio_decode_failed: {exc}") from exc
    if not audio_url:
        raise UpstreamError("audio_missing: audio_url 또는 audio_b64 가 필요합니다")
    return None


# ─────────────────────────────────────────────────────────────
# 전사
# ─────────────────────────────────────────────────────────────


async def transcribe(
    audio_url: Optional[str] = None,
    audio_b64: Optional[str] = None,
    filename: str = "audio",
    content_type: str = "application/octet-stream",
    language: Optional[str] = None,
    prompt: Optional[str] = None,
    response_format: str = "verbose_json",
    temperature: Optional[float] = None,
    model: Optional[str] = None,
    **_ignored: Any,
) -> Dict[str, Any]:
    """
    PyWorker 의 remote_function. 반환값은 `{"result": ...}` 로 감싸여 나갑니다.

    모르는 필드는 무시합니다 — 여기서 거절하면 Cloudflare Worker 가 이미 한
    검증을 두 번 하게 되고, 필드가 하나 늘 때마다 GPU 쪽을 같이 배포해야 합니다.
    """
    payload_model = model or STT_MODEL

    async with aiohttp.ClientSession() as session:
        audio = _resolve_audio(audio_url, audio_b64)
        if audio is None:
            audio = await _fetch_audio(session, audio_url)

        if not audio:
            raise UpstreamError("audio_empty: 0 바이트")

        form = aiohttp.FormData()
        form.add_field("file", audio, filename=filename, content_type=content_type)
        form.add_field("model", payload_model)
        # 이용자가 무엇을 원했든 우리는 길이가 필요합니다. 줄이는 것은
        # Cloudflare Worker 가 합니다 (10차 5-3).
        form.add_field("response_format", "verbose_json")
        if language:
            form.add_field("language", language)
        if prompt:
            form.add_field("prompt", prompt)
        if temperature is not None:
            form.add_field("temperature", str(temperature))

        timeout = aiohttp.ClientTimeout(total=TRANSCRIBE_TIMEOUT_SECONDS)
        url = f"{SPEACHES_BASE}/v1/audio/transcriptions"
        async with session.post(url, data=form, timeout=timeout) as response:
            body = await response.text()
            if response.status != 200:
                # 본문을 그대로 흘리지 않습니다. 예외 메시지에 섞인 경로가
                # 관리 화면까지 가는 것을 6차에서 겪었습니다.
                log.error("speaches %s: %s", response.status, body[:500])
                raise UpstreamError(f"transcribe_failed: HTTP {response.status}")

            try:
                result = await response.json(content_type=None)
            except Exception as exc:
                raise UpstreamError(f"transcribe_bad_json: {exc}") from exc

    # duration 이 없으면 크기로 짐작하고 **짐작했다고 밝힙니다.**
    # 조용히 근사값을 정확한 값처럼 돌려주면 이용자는 자기 한도가 왜 줄었는지
    # 알 방법이 없습니다 (8차 "값이 없는 것과 0 은 다르다").
    duration = result.get("duration")
    estimated = False
    if not isinstance(duration, (int, float)) or duration <= 0:
        duration = round(len(audio) / BYTES_PER_SECOND, 2)
        estimated = True

    result["duration"] = duration
    result["duration_estimated"] = estimated
    result["audio_bytes"] = len(audio)
    return result


# ─────────────────────────────────────────────────────────────
# 작업량 — 오토스케일러가 이 값으로 워커를 늘립니다
# ─────────────────────────────────────────────────────────────


def workload(payload: Dict[str, Any]) -> float:
    """
    초 단위 추정치. 정확할 필요는 없고 **연산량에 비례**하기만 하면 됩니다.

    전사 전에는 길이를 모르므로 Cloudflare Worker 가 보내는 크기 힌트를 씁니다.
    없으면 상한을 가정합니다 — 과소평가하면 워커 하나에 일이 몰립니다.
    """
    hint = payload.get("duration_hint")
    if isinstance(hint, (int, float)) and hint > 0:
        return float(hint)

    size = payload.get("size_bytes")
    if isinstance(size, (int, float)) and size > 0:
        return float(size) / BYTES_PER_SECOND

    return 300.0


# ─────────────────────────────────────────────────────────────
# 벤치마크
# ─────────────────────────────────────────────────────────────
#
# SDK 가 **정확히 한 handler 에 BenchmarkConfig 를 요구**합니다. 없으면
# "Missing EndpointHandler with BenchmarkConfig" 로 기동이 실패합니다.
#
# 지금은 합성 톤을 씁니다. 네트워크에 안 기대고 모델을 깨우는 데는 충분하지만,
# **실제 말소리가 아니라 성능 점수를 낮게 잡을 수 있습니다.** 한국어 표본을
# 재고 나면(`task.md` 2-1) 그걸로 바꾸세요.


def _synthetic_wav(seconds: float = 8.0, sample_rate: int = 16000) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        frames = bytearray()
        for i in range(int(seconds * sample_rate)):
            value = int(3000 * math.sin(2 * math.pi * 220 * i / sample_rate))
            frames += struct.pack("<h", value)
        wav.writeframes(bytes(frames))
    return buf.getvalue()


def _benchmark_payload() -> Dict[str, Any]:
    return {
        "audio_b64": base64.b64encode(_synthetic_wav()).decode("ascii"),
        "filename": "benchmark.wav",
        "content_type": "audio/wav",
        "language": "ko",
        "duration_hint": 8.0,
    }


# ─────────────────────────────────────────────────────────────
# 구성
# ─────────────────────────────────────────────────────────────

config = WorkerConfig(
    model_server_url=SPEACHES_URL,
    model_server_port=SPEACHES_PORT,
    model_log_file=os.environ.get(
        "MODEL_LOG_FILE", "/workspace/logs/speaches.log"
    ),
    model_healthcheck_url=f"{SPEACHES_BASE}/health",
    log_action_config=LogActionConfig(
        on_load=["Application startup complete"],
        on_error=["Traceback (most recent call last)"],
    ),
    handlers=[
        HandlerConfig(
            route="/v1/audio/transcriptions",
            # 3070 한 장에 whisper 하나입니다. 동시에 받으면 서로 느려지기만
            # 하고, 큐는 Vast 쪽에서 잡힙니다.
            allow_parallel_requests=False,
            max_queue_time=120.0,
            remote_function=transcribe,
            workload_calculator=workload,
            benchmark_config=BenchmarkConfig(
                generator=_benchmark_payload,
                runs=3,
                concurrency=1,
                do_warmup=True,
            ),
        )
    ],
)


if __name__ == "__main__":
    Worker(config).run()
