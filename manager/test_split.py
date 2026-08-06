"""분할·병합의 순수 부분 시험. ffmpeg 없이 돕니다.

    uv run python test_split.py

경계 선정과 타임스탬프 보정은 **틀려도 조용합니다** — 전사문은 그럴듯하게
나오고 자막만 어긋납니다. 그래서 여기서 잡습니다.
"""

from __future__ import annotations

import sys

from split import merge_payloads, pick_boundaries, sectors_from_boundaries

FAIL: list[str] = []


def check(name: str, got, want) -> None:
    if got == want:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}\n       나온 것: {got!r}\n       기대한 것: {want!r}")
        FAIL.append(name)


print("── 경계 선정 ──")

# 짧으면 안 나눕니다. 섹터 하나면 분할의 이득도 손해도 없습니다.
check("섹터보다 짧으면 경계 없음", pick_boundaries([], 100, 180, 30), ([], 0))

# 360초 = 정확히 두 조각. 목표(180초) 창 안에 무음이 둘이면 **긴 쪽**을
# 고릅니다. 짧은 무음은 문장 안의 숨일 수 있고, 긴 무음이 문장 경계일
# 확률이 높습니다.
silences = [(170.0, 170.4), (185.0, 187.0)]
check("창 안에서 가장 긴 무음의 한가운데", pick_boundaries(silences, 360, 180, 30), ([186.0], 0))

# 창 안에 무음이 없으면 정각으로 자르고 **셉니다.** 안 세면 조용한 실패입니다.
check("무음이 없으면 정각 + 카운트", pick_boundaries([], 360, 180, 30), ([180.0], 1))

# **모든 조각이 목표 이하여야 합니다.** 400초를 180초 목표로 나누면 3조각
# (133초씩)입니다 — 2조각(171+228)으로 두면 마지막이 목표를 크게 넘습니다.
cuts, hard = pick_boundaries([], 400, 180, 30)
check("400초는 세 조각 (꼬리도 초과분도 없음)", (len(cuts) + 1, hard), (3, 2))
sec = sectors_from_boundaries(cuts, 400)
check("모든 조각이 목표 이하", all(e - s <= 180 + 0.01 for s, e in sec), True)

# 노래처럼 무음이 아예 없는 경우 — 전부 정각이고 그 횟수가 그대로 보여야 합니다.
cuts, hard = pick_boundaries([], 700, 180, 30)
check("무음 없는 700초의 정각 횟수", (len(cuts), hard), (3, 3))

# 경계는 반드시 증가해야 합니다. 안 그러면 길이 0 짜리 조각이 납니다.
b, _ = pick_boundaries([(10.0, 12.0)], 600, 180, 200)
check("경계가 단조 증가", all(b[i] < b[i + 1] for i in range(len(b) - 1)), True)

print("── 섹터 펼치기 ──")
check("경계를 (시작,끝) 으로", sectors_from_boundaries([186.0], 400.0), [(0.0, 186.0), (186.0, 400.0)])
check("경계가 없으면 통짜 하나", sectors_from_boundaries([], 90.0), [(0.0, 90.0)])

print("── 병합 ──")

parts = [
    {"text": "앞 조각입니다.", "language": "korean",
     "segments": [{"id": 0, "start": 0.0, "end": 2.0, "text": "앞 조각입니다."}]},
    {"text": "뒤 조각입니다.",
     "segments": [{"id": 0, "start": 1.0, "end": 3.0, "text": "뒤 조각입니다.",
                   "words": [{"word": "뒤", "start": 1.0, "end": 1.5}]}]},
]
merged = merge_payloads(parts, [0.0, 186.0], 400.0)

check("전사문이 순서대로 붙음", merged["text"], "앞 조각입니다. 뒤 조각입니다.")
# **여기가 제일 틀리기 쉬운 자리입니다.** 오프셋을 안 더하면 두 번째 조각부터
# 0초로 돌아가고, srt·vtt 가 통째로 깨집니다.
check("두 번째 조각에 오프셋이 더해짐",
      (merged["segments"][1]["start"], merged["segments"][1]["end"]), (187.0, 189.0))
check("단어 타임스탬프도 같이 밀림", merged["segments"][1]["words"][0]["start"], 187.0)
# id 는 조각마다 0 부터라 그대로 두면 중복됩니다.
check("id 를 다시 매김", [s["id"] for s in merged["segments"]], [0, 1])
# **원본 길이입니다.** 조각 합이 아니라요 — 합으로 차감하면 이용자가 더 냅니다.
check("duration 은 원본", merged["duration"], 400.0)
check("language 는 첫 조각 것", merged["language"], "korean")

# 세그먼트가 아예 없는 상류 응답(response_format 이 json 인 경우)도 안 죽어야 합니다.
plain = merge_payloads([{"text": "가"}, {"text": "나"}], [0.0, 10.0], 20.0)
check("세그먼트가 없어도 붙음", plain, {"text": "가 나", "duration": 20.0})

print()
if FAIL:
    print(f"실패 {len(FAIL)}건: {', '.join(FAIL)}")
    sys.exit(1)
print("전부 통과")
