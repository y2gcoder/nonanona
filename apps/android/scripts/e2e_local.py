#!/usr/bin/env python3
"""Android 에뮬레이터 E2E(로컬 Supabase 모드, adb + UI Automator, 표준 라이브러리만).

파일 앱 공유 → 초대 링크 → 로컬 가상 계정 로그인 → 실제 accept_invite → 같은 초대 반복 수락 → 만료·취소된 초대
→ API 게이트웨이 정지 중 참여(연결 실패) → 재시작 후 다시 시도 → 서버 세션 삭제 + 토큰 만료 대기 → 세션 만료
→ 초안·초대 유지 확인 → 다시 로그인 → 참여.
사전 조건: `mise run local:up` 뒤 `mise run android:e2e-local`(초기화 → 로컬 모드 debug 빌드 → 이 스크립트).
사용: python3 -I apps/android/scripts/e2e_local.py <debug.apk> [증거 폴더]
"""

import hashlib
import json
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import adbui as u  # noqa: E402
import e2e as base  # noqa: E402  (같은 인자 순서: <apk> [증거 폴더])

ANDROID = Path(__file__).resolve().parents[1]
BACKEND = ANDROID.parents[1] / "scripts" / "local-backend.py"
PKG = base.PKG
OUT = base.OUT
LOG = []


def log(msg):
    line = time.strftime("[%H:%M:%S] ") + msg
    print(line, flush=True)
    LOG.append(line)
    (OUT / "android-e2e-local.log").write_text("\n".join(LOG) + "\n", encoding="utf-8")


def backend(*args):
    r = subprocess.run([sys.executable, "-I", str(BACKEND), *args], capture_output=True, text=True, check=True)
    for line in r.stdout.strip().splitlines():
        log(line)
    return r.stdout


def report():
    out = backend("report")
    return json.loads(out[out.index("["):out.rindex("]") + 1])[0]


def assert_built_with_current_config():
    """빌드한 APK가 지금의 로컬 설정으로 만들어졌는지 해시로만 비교한다(값은 출력하지 않는다)."""
    props = dict(
        line.split("=", 1)
        for line in (ANDROID / "local-backend.properties").read_text(encoding="utf-8").splitlines()
        if "=" in line and not line.startswith("#")
    )
    build_config = next((ANDROID / "app" / "build" / "generated").rglob("debug/**/app/nonanona/BuildConfig.java"))
    built = dict(re.findall(r'String (LOCAL_\w+) = "([^"]*)";', build_config.read_text(encoding="utf-8")))
    digest = lambda v: hashlib.sha256(v.encode()).hexdigest()  # noqa: E731
    assert digest(built["LOCAL_TEST_PASSWORD"]) == digest(props["testPassword"]), "rebuild after local:reset"
    assert built["LOCAL_SUPABASE_URL"] == props["supabaseUrl"]


def state(label):
    drafts = base.run_as("ls files/receipt-import/drafts/*/draft.properties 2>/dev/null").split()
    invite = "yes" if base.run_as("ls files/account/pending-invite.properties 2>/dev/null").strip() else "no"
    local = "yes" if base.run_as("ls no_backup/local-auth/session.properties 2>/dev/null").strip() else "no"
    test = "yes" if base.run_as("ls no_backup/test-auth/session.properties 2>/dev/null").strip() else "no"
    values = {"drafts": str(len(drafts)), "pending_invite": invite, "local_session": local, "test_session": test}
    log(f"# {label} | " + " | ".join(f"{k}={v}" for k, v in values.items()))
    return values


def open_invite(code):
    u.sh(f"am start -a android.intent.action.VIEW -d nonanona://invite/{code}")
    u.wait(text="여행방에 초대받았어요", timeout=20)


def assert_room(name):
    u.wait(id="room_status", timeout=30)
    assert u.texts_within("room_status") == ["참여함"]
    assert u.find(text=name) and u.find(text="다라") and u.find(text="가나"), name


def main():
    apk = sys.argv[1]
    (OUT / "screens").mkdir(parents=True, exist_ok=True)
    assert_built_with_current_config()
    log("fresh install (local backend mode), synthetic receipt into Pictures/Nonanona")
    u.adb("uninstall", PKG, check=False)
    u.adb("install", "-r", apk)
    u.sh("mkdir -p /sdcard/Pictures/Nonanona")
    u.adb("push", str(base.FIXTURE), "/sdcard/Pictures/Nonanona/")
    u.sh(f"am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file:///sdcard/Pictures/Nonanona/{base.FIXTURE.name}")
    u.sh(f"am force-stop {PKG}")
    base.share_from_files(base.FIXTURE.name)
    u.wait(id="draft_row", timeout=30)

    # 1) 로그인 → 실제 초대 수락 → 같은 초대 반복 수락.
    open_invite("SYNTHLOCAL0001")
    u.tap(u.wait(id="invite_primary"))
    u.wait(id="login_google", timeout=15)
    assert u.texts_within("login_test_notice") == ["로컬 테스트 계정 · 실제 소셜 로그인이 아니에요"]
    base.shot("android-local-login-sheet")
    u.tap(u.find(id="login_google"))
    assert_room("가상 오사카 여행")
    base.shot("android-local-room")
    u.back()
    open_invite("SYNTHLOCAL0001")
    assert u.texts_within("invite_primary") == ["참여하기"]
    u.tap(u.find(id="invite_primary"))
    assert_room("가상 오사카 여행")
    u.back()

    # 2) 만료·취소된 초대: 새 링크 요청, 다시 시도 없음.
    open_invite("SYNTHLOCALEXPIRED")
    u.tap(u.wait(id="invite_primary"))
    u.wait(contains="초대 링크가 만료됐어요", timeout=20)
    assert not u.find(id="invite_primary")
    base.shot("android-local-invite-expired")
    u.back()
    open_invite("SYNTHLOCALREVOKED")
    u.tap(u.wait(id="invite_primary"))
    u.wait(contains="이 초대 링크는 쓸 수 없어요", timeout=20)
    assert u.texts_within("invite_status") == ["쓸 수 없는 초대"] and not u.find(id="invite_primary")
    base.shot("android-local-invite-invalid")
    u.back()
    log(f"after accept/repeat/expired/revoked: {report()}")

    # 3) 서버에 닿지 않을 때 → 초대 유지 → 서버가 돌아오면 다시 시도로 참여.
    open_invite("SYNTHLOCALRETRY")
    backend("api-stop")
    u.tap(u.wait(id="invite_primary"))
    u.wait(contains="인터넷에 연결할 수 없어요", timeout=30)
    assert u.texts_within("invite_primary") == ["다시 시도"]
    base.shot("android-local-network-failure")
    unreachable = state("while-server-unreachable")
    assert unreachable["pending_invite"] == "yes" and unreachable["drafts"] == "1", unreachable
    backend("api-start")
    u.tap(u.find(id="invite_primary"))
    assert_room("가상 교토 여행")
    u.back()

    # 4) 서버 세션 삭제 + 액세스 토큰 만료 → 갱신 거절 → 세션 만료 → 초안·초대 유지 → 다시 로그인 → 참여.
    backend("revoke-sessions")
    log("wait 35s so the stored access token reaches its 30s expiry and the app must refresh")
    time.sleep(35)
    open_invite("SYNTHLOCALRELOG")
    u.tap(u.wait(id="invite_primary"))
    u.wait(contains="로그인이 만료됐어요", timeout=30)
    assert u.texts_within("invite_primary") == ["다시 로그인하기"]
    base.shot("android-local-session-expired")
    expired = state("after-session-expired")
    assert expired == {"drafts": "1", "pending_invite": "yes", "local_session": "no", "test_session": "no"}, expired
    u.back()
    u.wait(id="pending_invite_card", timeout=15)
    assert u.texts_within("account_status") == ["로그인 안 됨"] and u.find(id="draft_row")
    u.tap(u.wait(id="pending_invite_open"))
    u.tap(u.wait(id="invite_primary"))
    u.tap(u.wait(id="login_google", timeout=15))
    assert_room("가상 나라 여행")
    u.back()
    u.wait(text="로그인됨 · 가나", timeout=15)
    final = state("after-reauth")
    assert final == {"drafts": "1", "pending_invite": "no", "local_session": "yes", "test_session": "no"}, final
    server = report()
    (OUT / "android-local-server-report.json").write_text(json.dumps(server) + "\n", encoding="utf-8")
    assert server["member_trips"] == 3 and server["used_invites"] == 3, server
    log("PASS")


if __name__ == "__main__":
    main()
