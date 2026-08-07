"""Cloudflare의 비동기 음성 잡을 가져와 로컬 매니저에서 처리하는 pull 에이전트."""

from __future__ import annotations

import asyncio
import json
import logging
import os
import shlex
import shutil
import signal
import tempfile
from pathlib import Path

import httpx

log = logging.getLogger("audio-job-agent")

WORKER_BASE = os.environ.get("AUDIO_JOB_API_BASE", "https://chatos.page").rstrip("/")
WORKER_TOKEN = os.environ.get("AUDIO_JOB_TOKEN", "")
MANAGER_PORT = int(os.environ.get("MANAGER_PORT", "8100"))
MANAGER_BASE = f"http://127.0.0.1:{MANAGER_PORT}"
AUDIO_MODEL = os.environ.get("AUDIO_MODEL", "Systran/faster-whisper-large-v3")
GPU_TOKEN = os.environ.get("AUDIO_GPU_TOKEN", "")
POLL_SECONDS = max(1.0, float(os.environ.get("AUDIO_JOB_POLL_SECONDS", "2")))
HEARTBEAT_SECONDS = max(5.0, float(os.environ.get("AUDIO_JOB_HEARTBEAT_SECONDS", "30")))
LYRICS_ENABLED = os.environ.get("AUDIO_LYRICS_ENABLED", "0") == "1"
LYRICS_MODEL = os.environ.get("AUDIO_LYRICS_MODEL", "htdemucs")
LYRICS_TIMEOUT = max(60.0, float(os.environ.get("AUDIO_LYRICS_TIMEOUT_SECONDS", "900")))
CUSTOM_SEPARATOR = os.environ.get("AUDIO_LYRICS_SEPARATOR_CMD", "").strip()


class AgentFailure(Exception):
    def __init__(self, reason: str, *, requeue: bool = False):
        super().__init__(reason)
        self.reason = reason
        self.requeue = requeue


def separator_available() -> bool:
    return bool(CUSTOM_SEPARATOR or shutil.which("demucs"))


def supported_tasks() -> list[str]:
    tasks = ["transcription"]
    if LYRICS_ENABLED and separator_available():
        tasks.append("lyrics")
    return tasks


def _safe_name(value: str) -> str:
    name = Path(value or "audio").name
    cleaned = "".join(ch if ch.isalnum() or ch in "._-" else "_" for ch in name)
    return cleaned[:120] or "audio"


def _headers(lease_token: str | None = None) -> dict[str, str]:
    value = {"Authorization": f"Bearer {WORKER_TOKEN}"}
    if lease_token:
        value["X-Lease-Token"] = lease_token
    return value


async def _run_separator(input_path: Path, work_dir: Path) -> Path:
    output = work_dir / "vocals.wav"
    if CUSTOM_SEPARATOR:
        replacements = {
            "{input}": str(input_path),
            "{output}": str(output),
            "{output_dir}": str(work_dir),
        }
        command = shlex.split(CUSTOM_SEPARATOR)
        command = [
            _replace_all(part, replacements)
            for part in command
        ]
    else:
        executable = shutil.which("demucs")
        if not executable:
            raise AgentFailure("separation_failed")
        demucs_out = work_dir / "demucs"
        command = [
            executable,
            "--two-stems=vocals",
            "-n",
            LYRICS_MODEL,
            "-o",
            str(demucs_out),
            str(input_path),
        ]
        output = demucs_out / LYRICS_MODEL / input_path.stem / "vocals.wav"

    process = await asyncio.create_subprocess_exec(
        *command,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        stdout, stderr = await asyncio.wait_for(process.communicate(), timeout=LYRICS_TIMEOUT)
    except TimeoutError:
        process.kill()
        await process.wait()
        raise AgentFailure("separation_failed") from None
    if process.returncode != 0 or not output.is_file():
        log.error(
            "분리 실패 code=%s stdout=%r stderr=%r",
            process.returncode,
            stdout[-2000:],
            stderr[-4000:],
        )
        raise AgentFailure("separation_failed")
    return output


def _replace_all(value: str, replacements: dict[str, str]) -> str:
    for source, target in replacements.items():
        value = value.replace(source, target)
    return value


class AudioJobAgent:
    def __init__(self) -> None:
        self.stop = asyncio.Event()
        self.worker = httpx.AsyncClient(base_url=WORKER_BASE, timeout=httpx.Timeout(60, read=120))
        self.manager = httpx.AsyncClient(base_url=MANAGER_BASE, timeout=httpx.Timeout(120))

    async def close(self) -> None:
        await asyncio.gather(self.worker.aclose(), self.manager.aclose())

    async def run(self) -> None:
        tasks = supported_tasks()
        log.info("잡 에이전트 시작 — %s · 작업 %s", WORKER_BASE, ",".join(tasks))
        while not self.stop.is_set():
            try:
                job = await self.lease(tasks)
                if job is None:
                    await self._sleep(POLL_SECONDS)
                    continue
                await self.process(job)
            except httpx.HTTPError as exc:
                log.warning("Worker 연결 실패: %s", type(exc).__name__)
                await self._sleep(min(30, POLL_SECONDS * 3))
            except Exception:
                log.exception("잡 루프 예외")
                await self._sleep(POLL_SECONDS)

    async def _sleep(self, seconds: float) -> None:
        try:
            await asyncio.wait_for(self.stop.wait(), timeout=seconds)
        except TimeoutError:
            pass

    async def lease(self, tasks: list[str]) -> dict | None:
        response = await self.worker.post(
            "/api/audio/internal/lease",
            headers={**_headers(), "X-Audio-Tasks": ",".join(tasks)},
        )
        if response.status_code == 204:
            return None
        response.raise_for_status()
        value = response.json()
        if not isinstance(value, dict) or not value.get("id") or not value.get("leaseToken"):
            raise AgentFailure("agent_error")
        return value

    async def process(self, job: dict) -> None:
        job_id = str(job["id"])
        lease_token = str(job["leaseToken"])
        heartbeat = asyncio.create_task(self._heartbeat(job_id, lease_token))
        log.info("잡 시작 id=%s task=%s bytes=%s", job_id, job.get("task"), job.get("inputBytes"))
        try:
            with tempfile.TemporaryDirectory(prefix=f"audio-job-{job_id[:8]}-") as raw_dir:
                work_dir = Path(raw_dir)
                source = work_dir / _safe_name(str(job.get("inputName") or "audio"))
                await self._download(job_id, lease_token, source)
                audio = source
                if job.get("task") == "lyrics":
                    audio = await _run_separator(source, work_dir)
                payload = await self._transcribe(audio, job)
                await self._complete(job_id, lease_token, payload)
            log.info("잡 완료 id=%s", job_id)
        except AgentFailure as exc:
            log.warning("잡 중단 id=%s reason=%s requeue=%s", job_id, exc.reason, exc.requeue)
            if exc.requeue:
                await self._release(job_id, lease_token)
            else:
                await self._fail(job_id, lease_token, exc.reason)
        except httpx.HTTPError as exc:
            log.warning("잡 통신 실패 id=%s type=%s", job_id, type(exc).__name__)
            await self._release(job_id, lease_token)
        except Exception:
            log.exception("잡 처리 예외 id=%s", job_id)
            await self._fail(job_id, lease_token, "agent_error")
        finally:
            heartbeat.cancel()
            await asyncio.gather(heartbeat, return_exceptions=True)

    async def _heartbeat(self, job_id: str, lease_token: str) -> None:
        while True:
            await asyncio.sleep(HEARTBEAT_SECONDS)
            response = await self.worker.post(
                "/api/audio/internal/heartbeat",
                headers={
                    **_headers(lease_token),
                    "X-Job-Id": job_id,
                },
            )
            if response.status_code == 409:
                log.warning("lease가 사라졌습니다 id=%s", job_id)
                return
            response.raise_for_status()

    async def _download(self, job_id: str, lease_token: str, target: Path) -> None:
        try:
            async with self.worker.stream(
                "GET",
                f"/api/audio/internal/jobs/{job_id}/input",
                headers=_headers(lease_token),
            ) as response:
                if response.status_code == 404:
                    raise AgentFailure("download_failed")
                response.raise_for_status()
                with target.open("wb") as output:
                    async for chunk in response.aiter_bytes():
                        output.write(chunk)
        except httpx.HTTPError as exc:
            raise AgentFailure("download_failed", requeue=True) from exc
        if not target.is_file() or target.stat().st_size == 0:
            raise AgentFailure("download_failed")

    async def _transcribe(self, audio: Path, job: dict) -> dict:
        options = job.get("options") if isinstance(job.get("options"), dict) else {}
        data = {"model": AUDIO_MODEL, "response_format": "verbose_json"}
        for key in ("language", "prompt", "hotwords", "temperature"):
            if options.get(key) is not None:
                data[key] = str(options[key])
        headers = {"Authorization": f"Bearer {GPU_TOKEN}"} if GPU_TOKEN else {}
        try:
            with audio.open("rb") as stream:
                response = await self.manager.post(
                    "/v1/audio/transcriptions",
                    headers=headers,
                    data=data,
                    files={"file": (audio.name, stream, "audio/wav" if audio.suffix == ".wav" else None)},
                )
        except httpx.HTTPError as exc:
            raise AgentFailure("transcription_failed", requeue=True) from exc
        if response.status_code >= 500:
            raise AgentFailure("transcription_failed", requeue=True)
        if response.status_code != 200:
            log.warning("매니저 거절 status=%s body=%r", response.status_code, response.content[:1000])
            raise AgentFailure("transcription_failed")
        try:
            payload = response.json()
        except ValueError as exc:
            raise AgentFailure("transcription_failed") from exc
        if not isinstance(payload, dict) or not isinstance(payload.get("text"), str):
            raise AgentFailure("transcription_failed")
        return payload

    async def _complete(self, job_id: str, lease_token: str, payload: dict) -> None:
        response = await self.worker.put(
            f"/api/audio/internal/jobs/{job_id}/result",
            headers={**_headers(lease_token), "Content-Type": "application/json"},
            content=json.dumps(payload, ensure_ascii=False).encode(),
        )
        if response.status_code == 409:
            raise AgentFailure("agent_error")
        response.raise_for_status()

    async def _release(self, job_id: str, lease_token: str) -> None:
        try:
            await self.worker.post(
                f"/api/audio/internal/jobs/{job_id}/release",
                headers=_headers(lease_token),
            )
        except httpx.HTTPError:
            log.warning("release 보고 실패 id=%s — lease 만료가 회수합니다", job_id)

    async def _fail(self, job_id: str, lease_token: str, reason: str) -> None:
        try:
            await self.worker.post(
                f"/api/audio/internal/jobs/{job_id}/fail",
                headers={**_headers(lease_token), "X-Fail-Reason": reason},
            )
        except httpx.HTTPError:
            log.warning("실패 보고 실패 id=%s — lease 만료가 회수합니다", job_id)


async def _main() -> None:
    if not WORKER_TOKEN:
        raise SystemExit("AUDIO_JOB_TOKEN 이 비었습니다")
    logging.basicConfig(
        level=os.environ.get("AUDIO_JOB_LOG_LEVEL", "INFO"),
        format="[audio-agent %(asctime)s] %(levelname)s %(message)s",
    )
    agent = AudioJobAgent()
    loop = asyncio.get_running_loop()
    for name in ("SIGINT", "SIGTERM"):
        if hasattr(signal, name):
            try:
                loop.add_signal_handler(getattr(signal, name), agent.stop.set)
            except NotImplementedError:
                pass
    try:
        await agent.run()
    finally:
        await agent.close()


if __name__ == "__main__":
    asyncio.run(_main())
