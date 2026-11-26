#!/usr/bin/env python3
"""Android 에뮬레이터 E2E(adb + UI Automator, 표준 라이브러리만).

파일 앱 공유 → 로그인 전 초안 → 초대 링크 → 로그인 시트에서 프로세스 강제 종료(SIGKILL)
→ 런처 진입으로 다시 열기 → 초안·초대 유지 확인 → 테스트 로그인 → 초대받은 여행방.
사용: python3 -I apps/android/scripts/e2e.py <debug.apk> [증거 폴더]
"""

import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import adbui as u  # noqa: E402

PKG = "app.nonanona"
FIXTURE = Path(__file__).resolve().parents[2] / "fixtures" / "receipts/receipt-r01.png"
INVITE = "nonanona://invite/SYNTHINVITE01"
OUT = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(tempfile.mkdtemp(prefix="nonanona-android-e2e-"))
LOG = []


def log(msg):
    line = time.strftime("[%H:%M:%S] ") + msg
    print(line, flush=True)
    LOG.append(line)
    (OUT / "android-e2e.log").write_text("\n".join(LOG) + "\n", encoding="utf-8")


def shot(name):
    path = OUT / "screens" / f"{name}.png"
    u.screenshot(str(path))
    subprocess.run(["sips", "-Z", "1000", str(path)], capture_output=True, check=True)


def pid():
    return u.sh(f"pidof {PKG}", check=False).strip()


def run_as(cmd):
    return u.sh(f"run-as {PKG} sh -c '{cmd}'", check=False)


def state(label):
    drafts = run_as("ls files/receipt-import/drafts/*/draft.properties 2>/dev/null").split()
    photos = run_as("ls files/receipt-import/drafts/*/photo-* 2>/dev/null").split()
    invite = run_as("cat files/account/pending-invite.properties 2>/dev/null")
    code = next((line.split("=", 1)[1] for line in invite.splitlines() if line.startswith("code=")), "none")
    session = "yes" if run_as("ls no_backup/test-auth/session.properties 2>/dev/null").strip() else "no"
    text = (
        f"# {label}\napp_pid={pid()}\ndrafts={len(drafts)}\ndraft_photos={len(photos)}\n"
        f"pending_invite={code}\ntest_session={session}\n"
    )
    (OUT / f"android-state-{label}.txt").write_text(text, encoding="utf-8")
    log(text.strip().replace("\n", " | "))
    return dict(line.split("=", 1) for line in text.splitlines()[1:])


def share_from_files(name, folder="Nonanona"):
    """파일 앱에서 한 장 또는 여러 장(names 목록)을 골라 시스템 공유 메뉴로 노나노나에 보낸다."""
    names = [name] if isinstance(name, str) else list(name)
    u.sh("am force-stop com.google.android.documentsui")
    u.sh(
        "am start -a android.intent.action.VIEW -t vnd.android.document/root "
        '-d "content://com.android.externalstorage.documents/root/primary"'
    )
    u.wait(contains="Files on", timeout=20)
    u.tap(u.scroll_to(text="Pictures"))
    u.tap(u.scroll_to(text=folder))
    time.sleep(1)
    if u.find(desc="List view"):
        u.tap(u.find(desc="List view"))
    u.long_press(u.wait(text=names[0]))
    for other in names[1:]:
        u.tap(u.scroll_to(text=other))
    if len(names) > 1:
        assert u.wait(id="action_bar_title").text == f"{len(names)} selected"
    u.tap(u.wait(desc="Share"))
    u.wait(contains="Sharing", timeout=15)
    u.sh("input swipe 540 2000 540 600 400")
    time.sleep(1.5)
    shot("android-system-share-sheet")
    u.tap(u.wait(text="노나노나"))


def demo_status_bar(on):
    """문서용 화면의 상태 막대를 고정한다(시각·배터리·알림 아이콘)."""
    if not on:
        u.sh("am broadcast -a com.android.systemui.demo -e command exit")
        return
    u.sh("settings put global sysui_demo_allowed 1")
    for extra in [
        "-e command enter",
        "-e command clock -e hhmm 0941",
        "-e command battery -e level 100 -e plugged false",
        "-e command network -e wifi show -e level 4 -e mobile hide",
        "-e command notifications -e visible false",
    ]:
        u.sh(f"am broadcast -a com.android.systemui.demo {extra}")


def capture_core_screen_variants():
    """핵심 화면(로그인 전 홈: 초안 + 초대)을 라이트·다크·큰 글자로 찍는다. 설정 변경 뒤 화면 상태가 유지되는지도 본다."""
    demo_status_bar(True)
    try:
        time.sleep(1)
        shot("android-home-light")
        u.sh("cmd uimode night yes")
        time.sleep(2.5)
        demo_status_bar(True)
        time.sleep(1)
        assert u.find(id="pending_invite_card") and u.find(id="draft_row"), "state survives dark mode switch"
        shot("android-home-dark")
        u.sh("cmd uimode night no")
        u.sh("settings put system font_scale 2.0")
        time.sleep(2.5)
        demo_status_bar(True)
        time.sleep(1)
        assert u.find(id="pending_invite_card"), "state survives font scale change"
        shot("android-home-large-text")
    finally:
        u.sh("settings put system font_scale 1.0")
        u.sh("cmd uimode night no")
        demo_status_bar(False)
        time.sleep(2)
    log("captured core screen: light, dark, font_scale 2.0")


def open_invite(code):
    u.sh(f"am start -a android.intent.action.VIEW -d nonanona://invite/{code}")
    u.wait(text="여행방에 초대받았어요", timeout=20)


def invite_failures_recover():
    """debug 테스트 구현체의 가상 초대 코드로 실패와 복구를 확인한다. 앞 단계의 초안과 로그인 상태를 이어 쓴다."""
    # 연결 실패 → 같은 초대로 다시 시도 → 참여.
    open_invite("SYNTHOFFLINE01")
    u.tap(u.wait(id="invite_primary"))
    u.wait(contains="인터넷에 연결할 수 없어요", timeout=15)
    assert u.texts_within("invite_primary") == ["다시 시도"]
    shot("android-invite-network-failure")
    u.tap(u.wait(id="invite_primary"))
    u.wait(id="room_status", timeout=20)
    u.back()

    # 만료된 초대 → 새 링크 요청 문구, 다시 시도 버튼 없음, 초대 카드 사라짐.
    open_invite("SYNTHEXPIRED01")
    u.tap(u.wait(id="invite_primary"))
    u.wait(contains="방장에게 새 링크를 요청해 주세요", timeout=15)
    assert u.texts_within("invite_status") == ["초대 만료됨"]
    assert not u.find(id="invite_primary"), "expired invite offers no retry"
    shot("android-invite-expired")
    u.back()
    u.wait(id="draft_row", timeout=15)
    assert not u.find(id="pending_invite_card")

    # 세션 만료 → 로그아웃 상태지만 초안과 초대는 남음 → 다시 로그인 → 같은 초대로 참여.
    open_invite("SYNTHSESSION01")
    u.tap(u.wait(id="invite_primary"))
    u.wait(contains="로그인이 만료됐어요", timeout=15)
    assert u.texts_within("invite_primary") == ["다시 로그인하기"]
    shot("android-invite-session-expired")
    expired = state("after-session-expired")
    assert expired["drafts"] == "1" and expired["pending_invite"] == "SYNTHSESSION01" and expired["test_session"] == "no", expired
    u.back()
    u.wait(id="pending_invite_card", timeout=15)
    assert u.texts_within("account_status") == ["로그인 안 됨"] and u.find(id="draft_row")
    u.tap(u.wait(id="pending_invite_open"))
    u.tap(u.wait(id="invite_primary"))
    u.tap(u.wait(id="login_google", timeout=15))
    u.wait(id="room_status", timeout=20)
    after = state("after-invite-failures")
    assert after["drafts"] == "1" and after["pending_invite"] == "none" and after["test_session"] == "yes", after
    log("invite failures: network retry, expired without retry, session expired re-login")


def main():
    apk = sys.argv[1]
    (OUT / "screens").mkdir(parents=True, exist_ok=True)
    log("fresh install, synthetic receipt into Pictures/Nonanona")
    u.adb("uninstall", PKG, check=False)
    u.adb("install", "-r", apk)
    u.sh("mkdir -p /sdcard/Pictures/Nonanona")
    u.adb("push", str(FIXTURE), "/sdcard/Pictures/Nonanona/")
    u.sh(
        "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE "
        f"-d file:///sdcard/Pictures/Nonanona/{FIXTURE.name}"
    )
    # debug 빌드는 로컬 Supabase 모드를 위해 INTERNET을 요청한다. release APK에 없는지는 release 확인에서 본다.

    # 1) 앱이 꺼진 상태에서 파일 앱 공유 메뉴로 받는다(콜드 스타트).
    u.sh(f"am force-stop {PKG}")
    assert not pid()
    share_from_files(FIXTURE.name)
    u.wait(id="draft_row", timeout=30)
    assert u.texts_within("account_status") == ["로그인 안 됨"], "signed out while sharing"
    shot("android-home-after-share")

    # 2) 메신저의 링크를 누른 것과 같은 VIEW 인텐트로 초대를 연다(대상 컴포넌트를 지정하지 않는다).
    u.sh(f"am start -a android.intent.action.VIEW -d {INVITE}")
    u.wait(text="여행방에 초대받았어요", timeout=20)
    shot("android-invite-signed-out")
    u.tap(u.wait(id="invite_primary"))
    u.wait(id="login_google", timeout=15)
    assert u.find(id="login_test_notice"), "debug build labels the test login"
    shot("android-login-sheet")

    # 3) 로그인이 끝나기 전에 프로세스를 SIGKILL로 끝낸다.
    victim = pid()
    assert victim, "app must be running at the login sheet"
    u.sh(f"run-as {PKG} kill -9 {victim}")
    for _ in range(20):
        if not pid():
            break
        time.sleep(0.25)
    log(f"SIGKILL app pid {victim} while the login sheet is open (sign-in not completed)")
    before = state("after-kill-before-sign-in")
    assert before["app_pid"] == "" and before["drafts"] == "1" and before["draft_photos"] == "1"
    assert before["pending_invite"] == "SYNTHINVITE01" and before["test_session"] == "no", before

    # 4) 런처가 보내는 것과 같은 MAIN/LAUNCHER 인텐트로 다시 연다.
    u.sh("input keyevent KEYCODE_HOME")
    # NEW_TASK | RESET_TASK_IF_NEEDED: 홈 화면 아이콘을 누를 때 런처가 붙이는 플래그.
    u.sh(f"am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -f 0x10200000 -n {PKG}/.MainActivity")
    u.wait(text="여행방에 초대받았어요", timeout=20)
    log("reopened from launcher: back on the invite")
    u.back()
    u.wait(id="draft_row", timeout=15)
    assert u.texts_within("account_status") == ["로그인 안 됨"]
    assert u.find(id="pending_invite_card")
    shot("android-home-signed-out-with-invite")
    capture_core_screen_variants()

    # 5) 테스트 로그인 → 초대받은 여행방.
    u.tap(u.wait(id="pending_invite_open"))
    u.tap(u.wait(id="invite_primary"))
    u.tap(u.wait(id="login_google", timeout=15))
    u.wait(id="room_status", timeout=20)
    assert u.texts_within("room_status") == ["참여함"]
    assert u.find(text="가상 도쿄 여행") and u.find(text="다라") and u.find(text="가나")
    shot("android-room")
    u.back()
    u.wait(text="로그인됨 · 가나", timeout=15)
    assert u.texts_within("account_status") == ["로그인됨 · 가나"]
    assert u.find(id="draft_row"), "draft stays after sign-in"
    assert not u.find(id="pending_invite_card"), "accepted invite is cleared"
    shot("android-home-signed-in")
    after = state("after-sign-in-and-join")
    assert after["drafts"] == "1" and after["pending_invite"] == "none" and after["test_session"] == "yes", after
    invite_failures_recover()
    log("PASS")


if __name__ == "__main__":
    main()
