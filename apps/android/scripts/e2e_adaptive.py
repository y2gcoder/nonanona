#!/usr/bin/env python3
"""Android 접히는 기기 에뮬레이터 E2E(적응형 화면, 테스트 구현체, adb + UI Automator, 표준 라이브러리만).

펼친 안쪽 화면에서 초안 둘 공유 → 사진 2장 초안을 목록 옆에 연다(두 칸) → 읽는 중에 접기(바깥 화면, 한 칸)·펴기·반쯤 접기
(두 칸이 접힘 양쪽) → 사진별 시도 횟수 1(중복 OCR 없음) → 반쯤 접은 채 로그인 시트·올리기 최종 확인이 접힘을 피하는지
→ 확인 창을 연 채 접기·펴기(같은 올릴 곳·장수) → 한 번만 올림 → 가로 + 큰 글자, 낮고 좁은 창(wm size)에서 스크롤로 모든 버튼에 닿기.
사용: python3 -I apps/android/scripts/e2e_adaptive.py <debug.apk> [증거 폴더]
  실행 중인 접히는 기기 에뮬레이터 하나(예: Pixel 9 Pro Fold 프로필, emu fold/unfold/posture 지원)가 필요하다.
"""

import json
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import adbui as u  # noqa: E402
import e2e as base  # noqa: E402  (같은 인자 순서: <apk> [증거 폴더])

PKG = base.PKG
OUT = base.OUT
FIXTURES = Path(__file__).resolve().parents[2] / "fixtures" / "receipts"
LOG = []


def log(msg):
    line = time.strftime("[%H:%M:%S] ") + msg
    print(line, flush=True)
    LOG.append(line)
    (OUT / "android-e2e-adaptive.log").write_text("\n".join(LOG) + "\n", encoding="utf-8")


def emu(*args):
    out = u.adb("emu", *args)
    assert "OK" in out, out


def active_display():
    """켜진 물리 화면의 id와 크기. 접으면 바깥 화면, 펴면 안쪽 화면이 켜진다."""
    for m in re.finditer(r'DisplayDeviceInfo\{"[^"]*": uniqueId="local:(\d+)", (\d+) x (\d+).*?state (\w+),', u.sh("dumpsys display")):
        if m.group(4) == "ON":
            return m.group(1), int(m.group(2)), int(m.group(3))
    raise RuntimeError("no display is on")


def shot(name):
    display, _, _ = active_display()
    path = OUT / "screens" / f"{name}.png"
    u.sh(f"screencap -d {display} -p /sdcard/adaptive.png")
    u.adb("pull", "/sdcard/adaptive.png", str(path))
    subprocess.run(["sips", "-Z", "1000", str(path)], capture_output=True, check=True)


base.shot = shot  # 공유 흐름(e2e.share_from_files)의 화면 기록도 켜진 화면을 고른다


def settle(seconds=2.5):
    time.sleep(seconds)
    u.sh("wm dismiss-keyguard", check=False)  # 접으면 바깥 화면이 잠금 화면부터 보인다(시스템 기본: 위로 밀어 계속하기)
    time.sleep(1)


def hinge_x():
    """에뮬레이터 프로필의 세로 접힘 위치(px). 안쪽 화면 가운데다."""
    _, width, _ = active_display()
    return width // 2


def attempts(label):
    drafts = {}
    for d in base.run_as("ls files/receipt-import/drafts").split():
        m = json.loads(base.run_as(f"cat files/receipt-import/drafts/{d}/processing.json"))
        items = sorted(m["items"], key=lambda i: i["position"])
        drafts[len(items)] = {"attempts": [i["attempts"] for i in items], "states": [i["state"] for i in items]}
    log(json.dumps({"label": label, "drafts_by_photo_count": drafts}, ensure_ascii=False))
    assert sorted(drafts) == [1, 2], drafts
    assert all(a == 1 for d in drafts.values() for a in d["attempts"]), "every photo read exactly once"
    return drafts


def panes():
    nodes = u.dump()
    return u.find(nodes, id="home_screen"), u.find(nodes, id="draft_screen")


def summary():
    return " ".join(u.texts_within("processing_summary"))


def scroll_in(node_id, **query):
    """한 목록(node_id) 안에서 위아래로 넘기며 찾는다(화면 크기와 상관없이 그 목록의 범위 안에서 민다)."""
    for direction in [1] * 8 + [-1] * 16:
        nodes = u.dump()
        hit = u.find(nodes, **query)
        box = u.find(nodes, id=node_id)
        if hit and (box is None or (box.bounds[1] <= hit.bounds[1] and hit.bounds[3] <= box.bounds[3])):
            return hit
        x1, y1, x2, y2 = box.bounds
        x, top, bottom = (x1 + x2) // 2, y1 + (y2 - y1) // 4, y2 - (y2 - y1) // 4
        a, b = (bottom, top) if direction == 1 else (top, bottom)
        u.sh(f"input swipe {x} {a} {x} {b} 300")
        time.sleep(0.6)
    raise TimeoutError(f"not found in {node_id}: {query}")


def one_side_of_hinge(node, label):
    x = hinge_x()
    assert node.bounds[2] <= x or node.bounds[0] >= x, f"{label} crosses the hinge at x={x}: {node.bounds}"
    log(f"{label} {node.bounds} stays on one side of the hinge (x={x})")


def open_two_photo_draft():
    for _ in range(3):  # 한 칸 배치에서 다른 화면이 위에 있으면 목록으로 돌아간다
        if u.find(id="home_screen"):
            break
        u.back()
    u.tap(scroll_in("home_screen", contains="사진 2장"))
    u.wait(id="draft_screen", timeout=10)
    assert "/2" in summary(), summary()


def main():
    apk = sys.argv[1]
    (OUT / "screens").mkdir(parents=True, exist_ok=True)
    u.sh("settings put system font_scale 1.0")
    u.sh("settings put system accelerometer_rotation 0")
    u.sh("settings put system user_rotation 0")
    u.sh("wm size reset")
    emu("unfold")
    emu("posture", "3")
    settle()
    _, width, height = active_display()
    log(f"inner display {width}x{height}px (unfolded)")

    log("fresh install, synthetic receipts r01-r03, processing delay 30000ms per photo")
    u.adb("uninstall", PKG, check=False)
    u.adb("install", "-r", apk)
    u.sh("rm -rf /sdcard/Pictures/NonanonaAdaptive && mkdir -p /sdcard/Pictures/NonanonaAdaptive")
    names = [f"receipt-r0{i}.png" for i in (1, 2, 3)]
    for name in names:
        u.adb("push", str(FIXTURES / name), "/sdcard/Pictures/NonanonaAdaptive/")
        u.sh(f"am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file:///sdcard/Pictures/NonanonaAdaptive/{name}")
    u.sh(f"am start -n {PKG}/.MainActivity")
    time.sleep(2)
    base.run_as('printf "delayMillisPerItem=30000\\n" > files/debug-processing.properties')
    u.sh(f"am force-stop {PKG}")

    # 사진 1장 초안을 먼저, 사진 2장 초안을 나중에 담아 2장 초안을 여는 동안 아직 읽는 중이게 한다.
    base.share_from_files(names[2], folder="NonanonaAdaptive")
    u.wait(id="draft_row", timeout=30)
    base.share_from_files(names[:2], folder="NonanonaAdaptive")
    time.sleep(2)

    # 1) 펼친 안쪽 화면(expanded 폭): 목록 옆에 초안.
    open_two_photo_draft()
    home, draft = panes()
    assert home and draft, "unfolded: list and draft side by side"
    reading = summary()
    assert "읽음 2/2" not in reading, f"must still be reading: {reading}"
    log(f"unfolded: two panes, {reading}")
    shot("android-adaptive-unfolded-two-panes")

    # 2) 접기: 바깥 화면(compact 폭)에서 같은 초안이 한 칸으로.
    emu("fold")
    settle()
    _, w, h = active_display()
    home, draft = panes()
    assert draft and not home, "folded: single pane with the same draft"
    log(f"folded outer {w}x{h}px: single pane, {summary()}")
    shot("android-adaptive-folded-single-pane")

    # 3) 다시 펴기: 두 칸, 같은 초안.
    emu("unfold")
    settle()
    home, draft = panes()
    assert home and draft, "unfolded again: two panes"
    log(f"unfolded again: two panes, {summary()}")

    # 4) 반쯤 접기(책 자세, 세로 separating hinge): 두 칸이 접힘 양쪽에.
    emu("posture", "2")
    settle()
    home, draft = panes()
    assert home and draft, "half-opened: two panes"
    x = hinge_x()
    assert home.bounds[2] <= x <= draft.bounds[0], f"panes must sit on both sides of the hinge x={x}: {home} {draft}"
    log(f"half-opened: list {home.bounds} | hinge x={x} | draft {draft.bounds}")
    shot("android-adaptive-half-opened")

    for _ in range(180):
        if "읽음 2/2" in summary():
            break
        time.sleep(0.5)
    assert "읽음 2/2" in summary(), summary()
    attempts("after-fold-unfold-half-open-while-reading")

    # 5) 반쯤 접은 채: 개발용 확인 → 초대 → 로그인 시트가 접힘을 피한다.
    u.tap(scroll_in("draft_screen", id="item_1_debug_confirm"))
    for _ in range(60):
        if u.texts_within("item_1_status") == ["확인함"]:
            break
        time.sleep(0.5)
    base.open_invite("SYNTHINVITE01")
    u.tap(u.wait(id="invite_primary"))
    sheet = u.wait(id="login_sheet", timeout=10)
    one_side_of_hinge(sheet, "login sheet")
    shot("android-adaptive-half-opened-login-sheet")
    u.tap(u.wait(id="login_google"))
    u.wait(text="참여함", timeout=20)

    # 6) 최종 확인 창: 접힘을 피하고, 접기·펴기 뒤에도 같은 올릴 곳·장수로 남는다.
    open_two_photo_draft()
    u.tap(scroll_in("draft_screen", id="upload_start"))
    title = u.wait(contains="에 영수증 1장을 올릴까요?", timeout=10)
    text = title.text
    one_side_of_hinge(title, "upload confirmation title")
    one_side_of_hinge(u.find(id="upload_final"), "upload confirmation button")
    shot("android-adaptive-half-opened-confirmation")
    emu("fold")
    settle()
    assert u.wait(text=text, timeout=10), "folded: same confirmation"
    shot("android-adaptive-folded-confirmation")
    emu("unfold")
    emu("posture", "3")
    settle()
    assert u.wait(text=text, timeout=10), "unfolded: same confirmation"
    u.tap(u.wait(id="upload_final"))
    for _ in range(40):
        if u.texts_within("upload_status") == ["올림 1장(이미 올린 0장 포함)"]:
            break
        time.sleep(0.5)
    assert u.texts_within("upload_status") == ["올림 1장(이미 올린 0장 포함)"], u.texts_within("upload_status")
    assert not u.find(contains="올릴까요?"), "confirmation closed after one upload"
    log(f"confirmation '{text}' survived fold/unfold, uploaded once")

    # 7) 가로 + 큰 글자(font_scale 2.0): 같은 초안, 마지막 행까지 스크롤, 로그인 시트 버튼까지 스크롤.
    u.sh("settings put system font_scale 2.0")
    u.sh("settings put system user_rotation 1")
    settle(3)
    assert u.wait(id="draft_screen", timeout=10) and "/2" in summary(), "same draft after rotation + font scale"
    scroll_in("draft_screen", id="item_2_status")
    shot("android-adaptive-landscape-large-text")
    base.open_invite("SYNTHSESSION01")
    u.tap(u.wait(id="invite_primary"))
    u.wait(text="다시 로그인하기", timeout=15)
    u.tap(u.wait(id="invite_primary"))
    u.wait(id="login_sheet", timeout=10)
    u.tap(scroll_in("login_sheet", id="login_google"))
    u.wait(text="참여함", timeout=20)
    log("landscape + font_scale 2.0: reached last photo row and login button by scrolling")

    # 8) 낮고 좁은 창(대표 크기: 분할 화면의 한쪽처럼 compact 폭·compact 높이).
    u.sh("settings put system font_scale 1.0")
    u.sh("settings put system user_rotation 0")
    u.sh("wm size 1300x1000")
    settle(3)
    open_two_photo_draft()
    home, draft = panes()
    assert draft and not home, "short narrow window: single pane"
    scroll_in("draft_screen", id="item_2_status")
    shot("android-adaptive-short-narrow")
    log("wm size 1300x1000 (533x410dp): single pane, scrolls to last row")

    attempts("final")
    log("PASS")


if __name__ == "__main__":
    try:
        main()
    finally:
        u.sh("wm size reset", check=False)
        u.sh("settings put system font_scale 1.0", check=False)
        u.sh("settings put system user_rotation 0", check=False)
        u.sh("settings put system accelerometer_rotation 1", check=False)
