"""
섹터 분할 — 오디오를 무음에서 자르고, 조각 결과를 다시 붙입니다.

**왜 나누나.** 속도가 아닙니다. 1시간이 64초라 속도로는 나눌 이유가 없습니다
(12차 5장). 되살린 근거는 셋입니다 — plan.md 4-3:

  ① 1시간 통짜에서 반복 환각이 실제로 났습니다
  ② 프롬프트 효과가 뒤로 갈수록 옅어집니다 → 조각마다 다시 넣어야 합니다
  ③ 문맥 사슬을 끊는 파라미터가 speaches 에 없습니다 → 조각내는 것이 유일한 개입

**공짜가 아닙니다.** 요청당 고정비(디코딩·VAD 약 1초, 2-3)가 **섹터 수만큼
곱해집니다.** 33분을 3분씩 나누면 11조각이라 고정비만 11초입니다. 동시 2건에
페널티가 없다는 실측(2-3)이 이걸 상쇄하는 근거이고, 그래서 기본 동시성이
2입니다 — **실측한 폭까지만 씁니다.**
"""

from __future__ import annotations

import asyncio
import json
import math
import logging
import re
import shutil

log = logging.getLogger("manager.split")

FFMPEG = "ffmpeg"
FFPROBE = "ffprobe"


def have_ffmpeg() -> bool:
    return bool(shutil.which(FFMPEG)) and bool(shutil.which(FFPROBE))


async def _run(*args: str) -> tuple[int, bytes, bytes]:
    proc = await asyncio.create_subprocess_exec(
        *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
    )
    out, err = await proc.communicate()
    return proc.returncode or 0, out, err


async def probe_duration(path: str) -> float | None:
    """원본 길이. **차감이 이 값에 걸립니다.**

    조각 길이의 합이 아니라 **원본**이어야 합니다. 겹침을 두면 합이 원본보다
    길어지고, 그걸로 차감하면 이용자가 더 냅니다 (plan.md 4-3).
    """
    code, out, _ = await _run(
        FFPROBE, "-v", "error", "-print_format", "json", "-show_format", path
    )
    if code != 0:
        return None
    try:
        return float(json.loads(out)["format"]["duration"])
    except (ValueError, KeyError, TypeError):
        return None


_SILENCE_START = re.compile(r"silence_start:\s*(-?[\d.]+)")
_SILENCE_END = re.compile(r"silence_end:\s*(-?[\d.]+)")


async def detect_silences(path: str, noise_db: int, min_seconds: float) -> list[tuple[float, float]]:
    """무음 구간 목록. ffmpeg 의 `silencedetect` 를 씁니다.

    **speaches 안에서 도는 VAD 로는 못 합니다.** 그건 whisper 앞에서 조용히
    돌 뿐 경계를 밖으로 안 내줍니다 (task 1-7). 우리가 자를 지점은 우리가
    따로 찾아야 합니다.
    """
    code, _, err = await _run(
        FFMPEG, "-nostdin", "-i", path,
        "-af", f"silencedetect=noise={noise_db}dB:d={min_seconds}",
        "-f", "null", "-",
    )
    text = err.decode("utf-8", "replace")
    if code != 0:
        log.warning("silencedetect 실패 (code %s) — 무음을 못 찾은 것으로 봅니다", code)
        return []
    spans: list[tuple[float, float]] = []
    start: float | None = None
    for line in text.splitlines():
        m = _SILENCE_START.search(line)
        if m:
            start = float(m.group(1))
            continue
        m = _SILENCE_END.search(line)
        if m and start is not None:
            spans.append((start, float(m.group(1))))
            start = None
    return spans


def pick_boundaries(
    silences: list[tuple[float, float]],
    duration: float,
    target: float,
    tolerance: float,
) -> tuple[list[float], int]:
    """자를 지점을 고릅니다. 순수 함수라 ffmpeg 없이 시험됩니다.

    **정각에서 자르지 않습니다.** 단어 한가운데가 끊기면 그 조각의 앞뒤가
    오인식되거나 환각으로 흐릅니다 (plan.md 4-3) — 환각을 줄이려고 나누는
    것이니 정각 절단은 목적을 거스릅니다.

    `target` 은 **상한이자 목표**입니다. 조각 수를 올림으로 정하고 그만큼 균등
    분할한 뒤, 각 목표 지점 ±tolerance 안에서 **가장 긴 무음의 한가운데**를
    고릅니다. 가장 가까운 것이 아니라 가장 긴 것을 고르는 이유는, 짧은 무음은
    문장 안의 숨일 수 있고 긴 무음이 문장 경계일 확률이 높아서입니다.

    창 안에 무음이 없으면 **정각으로 자르고 그 횟수를 셉니다.** 통계로 안 남기면
    "조용히 실패" 가 됩니다 — 노래처럼 무음이 없는 오디오가 정확히 그 경우입니다.

    돌려주는 것: (경계 목록, 정각으로 자른 횟수)
    """
    duration, target, tolerance = float(duration), float(target), float(tolerance)
    if duration <= target:
        return [], 0

    # **조각 수를 먼저 정하고 균등하게 폅니다.** 목표의 배수로 끊으면 끝에
    # 자투리가 남고(400초를 3분씩 → 34초짜리 꼬리), 그 자투리를 앞에 붙이면
    # 이번엔 마지막 조각이 목표를 크게 넘습니다(228초). **목표를 넘는 조각이
    # 생기면 분할의 목적이 그만큼 흐려집니다** — 목표는 환각을 끊으려고 둔
    # 상한이니까요. 올림해서 나누면 **모든 조각이 목표 이하**이고 꼬리도
    # 안 생깁니다.
    count = math.ceil(duration / target)
    spacing = duration / count

    boundaries: list[float] = []
    hard_cuts = 0
    for k in range(1, count):
        goal = spacing * k
        low, high = goal - tolerance, goal + tolerance
        # 이미 지난 경계보다 뒤여야 합니다. 안 그러면 길이 0 짜리 조각이 납니다.
        floor = boundaries[-1] if boundaries else 0.0
        low = max(low, floor + 1.0)

        best: tuple[float, float] | None = None  # (무음 길이, 자를 지점)
        for s, e in silences:
            mid = (s + e) / 2
            if low <= mid <= high:
                span = e - s
                if best is None or span > best[0]:
                    best = (span, mid)

        if best is not None:
            boundaries.append(round(best[1], 3))
        else:
            boundaries.append(round(max(low, min(goal, duration - 1.0)), 3))
            hard_cuts += 1

    return boundaries, hard_cuts


def sectors_from_boundaries(boundaries: list[float], duration: float) -> list[tuple[float, float]]:
    """경계를 (시작, 끝) 쌍으로 폅니다. **겹침은 두지 않습니다.**

    겹침을 두면 병합에서 중복을 걷어내야 하는데, 그 판정이 되뱉기 제거보다
    훨씬 애매합니다(같은 말이 실제로 두 번 나올 수 있습니다). 무음에서 자르면
    겹침 없이도 단어가 안 깨지므로, 그쪽을 정확히 하는 데 걸겠습니다.
    """
    points = [0.0, *boundaries, duration]
    return [(points[i], points[i + 1]) for i in range(len(points) - 1) if points[i + 1] - points[i] > 0.05]


async def cut_sector(src: str, dst: str, start: float, end: float) -> bool:
    """조각 하나를 16kHz 모노 WAV 로 뽑습니다.

    **컨테이너를 그대로 자르지 않고 디코딩합니다.** whisper 가 어차피 16kHz
    모노로 바꿔 쓰고, 재인코딩하면 mp3 프레임 경계나 가변 비트레이트 때문에
    `-ss` 가 어긋나는 문제가 사라집니다.
    """
    code, _, err = await _run(
        FFMPEG, "-nostdin", "-v", "error", "-y",
        "-ss", f"{start:.3f}", "-to", f"{end:.3f}", "-i", src,
        "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", dst,
    )
    if code != 0:
        log.error("조각 추출 실패 %.1f~%.1f — %s", start, end, err.decode("utf-8", "replace")[:300])
        return False
    return True


def merge_payloads(parts: list[dict], offsets: list[float], duration: float | None) -> dict:
    """조각 결과를 하나로 붙입니다.

    **타임스탬프에 섹터 시작 오프셋을 더합니다.** 각 조각의 시각은 그 조각
    기준이라, 그냥 이어붙이면 두 번째부터 0초로 돌아갑니다 — srt·vtt(5-0)가
    통째로 깨지는 자리입니다.

    **`id` 는 여기서 다시 매깁니다.** 조각마다 0 부터 시작하니 그대로 두면
    중복됩니다. (Worker 의 되뱉기 제거는 id 를 보존하는데, 그건 상류 로그와
    대조하려는 것이고 여기는 애초에 대조할 원본 번호가 없습니다.)

    **`duration` 은 원본입니다.** 조각 길이의 합이 아닙니다.
    """
    texts: list[str] = []
    segments: list[dict] = []
    words: list[dict] = []
    language = None
    next_id = 0

    for part, offset in zip(parts, offsets):
        text = str(part.get("text") or "").strip()
        if text:
            texts.append(text)
        if language is None and part.get("language"):
            language = part["language"]

        for seg in part.get("segments") or []:
            if not isinstance(seg, dict):
                continue
            shifted = dict(seg)
            shifted["id"] = next_id
            next_id += 1
            for key in ("start", "end"):
                if isinstance(seg.get(key), (int, float)):
                    shifted[key] = round(seg[key] + offset, 3)
            # 단어 단위 타임스탬프도 같이 밀어야 합니다 (timestamp_granularities[]).
            if isinstance(seg.get("words"), list):
                shifted["words"] = [_shift_word(w, offset) for w in seg["words"]]
            segments.append(shifted)

        for word in part.get("words") or []:
            words.append(_shift_word(word, offset))

    merged: dict = {"text": " ".join(texts)}
    if language is not None:
        merged["language"] = language
    if duration is not None:
        merged["duration"] = duration
    if segments:
        merged["segments"] = segments
    if words:
        merged["words"] = words
    return merged


def _shift_word(word: object, offset: float) -> object:
    if not isinstance(word, dict):
        return word
    out = dict(word)
    for key in ("start", "end"):
        if isinstance(word.get(key), (int, float)):
            out[key] = round(word[key] + offset, 3)
    return out
