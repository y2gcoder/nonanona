#!/usr/bin/env python3
"""Android 에뮬레이터 E2E(로컬 Supabase 모드, 영수증 올리기, adb + UI Automator, 표준 라이브러리만).

가상 영수증 2장 공유 → 1장만 확인 → 초대로 여행방 참여 → 올릴 곳·장수 최종 확인 창(아직 서버에 아무것도 없음)
→ 오프라인 실패 → 구성원이 아닌 여행방(실패, 아무것도 안 생김) → 세션 만료 → 다시 로그인 → 사본만 올라가고 끊김
→ 다시 시도로 지출 1건 → 반복은 같은 지출 → 앱을 다시 열어 올려도 같은 지출 → 서버 사본·필드·비구성원 접근 검사.
사전 조건: mise run local:up. 사용: mise run android:e2e-upload -- [증거 폴더]
"""

import hashlib
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import adbui as u  # noqa: E402
import e2e as base  # noqa: E402  (같은 인자 순서: <apk> [증거 폴더])
import e2e_local as local  # noqa: E402

PKG = base.PKG
OUT = base.OUT
FIXTURES = Path(__file__).resolve().parents[2] / "fixtures" / "receipts"
CHECKER = FIXTURES.parent / "check_artifact.py"
NAMES = ["receipt-r01.png", "receipt-r02.png"]
LOG = []


def log(msg):
    line = time.strftime("[%H:%M:%S] ") + msg
    print(line, flush=True)
    LOG.append(line)
    (OUT / "android-e2e-upload.log").write_text("\n".join(LOG) + "\n", encoding="utf-8")


def backend(*args):
    r = subprocess.run([sys.executable, "-I", str(local.BACKEND), *args], capture_output=True, text=True, check=True)
    for line in r.stdout.strip().splitlines():
        log(line)
    return r.stdout


def report(expect):
    r = json.loads(backend("upload-report").strip().splitlines()[-1])
    summary = {k: r[k] for k in ("objects", "expenses", "objects_without_expense", "expenses_without_object")}
    log(f"server: {json.dumps(summary)}")
    for k, v in expect.items():
        assert summary[k] == v, (k, summary)
    return r


def text_of(id_):
    n = u.find(id=id_)
    return n.text if n else None


def wait_status(text, timeout=45):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if text_of("upload_status") == text:
            return
        time.sleep(0.5)
    raise AssertionError(f"upload status {text_of('upload_status')!r} != {text!r}")


def upload_with_final_confirmation():
    start = u.wait(id="upload_start", timeout=20)
    for _ in range(40):
        if u.find(id="upload_start").enabled:
            break
        time.sleep(0.5)
    u.tap(u.find(id="upload_start"))
    u.tap(u.wait(text="올리기", timeout=10))
    _ = start


def open_draft():
    u.tap(u.wait(id="draft_row", timeout=20))
    u.wait(id="upload_section", timeout=15)


def main():
    apk = sys.argv[1]
    (OUT / "screens").mkdir(parents=True, exist_ok=True)
    local.assert_built_with_current_config()
    log("fresh install (local backend mode), 2 synthetic receipts into Pictures/NonanonaUpload")
    u.adb("uninstall", PKG, check=False)
    u.adb("install", "-r", apk)
    u.sh("mkdir -p /sdcard/Pictures/NonanonaUpload")
    for name in NAMES:
        u.adb("push", str(FIXTURES / name), "/sdcard/Pictures/NonanonaUpload/")
        u.sh(f"am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file:///sdcard/Pictures/NonanonaUpload/{name}")
    # debug 빌드만 읽는 검증 설정: 처음으로 사본이 올라간 직후 지출 행을 만들기 전에 끊긴 것처럼 실패한다.
    u.sh(f"am start -n {PKG}/.MainActivity")
    time.sleep(2)
    base.run_as('printf "uploadFailAfterStorageOnce=true\\n" > files/debug-processing.properties')
    u.sh(f"am force-stop {PKG}")

    base.share_from_files(NAMES, folder="NonanonaUpload")
    open_draft()
    for _ in range(120):
        if text_of("processing_summary") == "읽음 2/2":
            break
        time.sleep(0.5)
    u.tap(u.wait(id="item_1_debug_confirm", timeout=20))
    for _ in range(60):
        if u.texts_within("item_1_status") == ["확인함"]:
            break
        time.sleep(0.5)
    assert u.texts_within("item_1_status") == ["확인함"]
    assert u.texts_within("item_2_status") == ["확인 필요"], "두 번째 사진은 확인하지 않는다"
    assert u.find(text="참여한 여행방이 없어요. 초대 링크로 참여한 뒤 올릴 수 있어요.")

    local.open_invite("SYNTHLOCAL0001")
    u.tap(u.wait(id="invite_primary"))
    u.tap(u.wait(id="login_google", timeout=15))
    local.assert_room("가상 오사카 여행")
    u.back()
    open_draft()
    assert text_of("upload_destination") == "올릴 곳: 가상 오사카 여행"
    assert u.find(text="확인한 영수증 1장")
    u.tap(u.wait(id="upload_start"))
    u.wait(text="‘가상 오사카 여행’에 영수증 1장을 올릴까요?", timeout=10)
    base.shot("android-upload-final-confirmation")
    report({"objects": 0, "expenses": 0})
    log("before final confirmation: nothing on the server")

    backend("api-stop")
    u.tap(u.wait(text="올리기"))
    wait_status("인터넷에 연결할 수 없어요. 연결을 확인하고 다시 시도해 주세요.")
    backend("api-start")
    report({"objects": 0, "expenses": 0})

    backend("membership-remove")
    upload_with_final_confirmation()
    wait_status("이 여행방에 올릴 수 없어요. 여행방 구성원인지 확인해 주세요.")
    base.shot("android-upload-invalid-destination")
    report({"objects": 0, "expenses": 0})
    backend("membership-restore")

    backend("revoke-sessions")
    log("wait 35s for the stored access token to expire")
    time.sleep(35)
    upload_with_final_confirmation()
    wait_status("로그인이 만료됐어요. 다시 로그인한 뒤 다시 올려 주세요.")
    u.tap(u.wait(id="upload_login"))
    u.tap(u.wait(id="login_google", timeout=15))
    time.sleep(2)
    upload_with_final_confirmation()
    wait_status("인터넷에 연결할 수 없어요. 연결을 확인하고 다시 시도해 주세요.")
    report({"objects": 1, "expenses": 0, "objects_without_expense": 1})
    log("partial failure: object stored, no expense row (not visible as an expense)")

    upload_with_final_confirmation()
    wait_status("올림 1장(이미 올린 0장 포함)")
    upload_with_final_confirmation()
    wait_status("올림 1장(이미 올린 1장 포함)")
    base.shot("android-upload-done")
    report({"objects": 1, "expenses": 1, "objects_without_expense": 0})

    # 다시 열 때는 실패 주입을 끈다(파일을 지우지 않고 값만 바꾼다).
    base.run_as('printf "uploadFailAfterStorageOnce=false\\n" > files/debug-processing.properties')
    victim = base.pid()
    u.sh(f"run-as {PKG} kill -9 {victim}")
    log(f"SIGKILL app pid {victim}, reopen from launcher")
    u.sh("input keyevent KEYCODE_HOME")
    u.sh(f"am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -f 0x10200000 -n {PKG}/.MainActivity")
    time.sleep(2)
    local.open_invite("SYNTHLOCAL0001")
    u.tap(u.wait(id="invite_primary"))
    local.assert_room("가상 오사카 여행")
    u.back()
    open_draft()
    upload_with_final_confirmation()
    wait_status("올림 1장(이미 올린 1장 포함)")
    final = report({"objects": 1, "expenses": 1, "objects_without_expense": 0, "expenses_without_object": 0})
    (OUT / "android-upload-server-report.json").write_text(json.dumps(final, ensure_ascii=False) + "\n")

    work = Path(tempfile.mkdtemp(prefix="nonanona-upload-"))
    backend("fetch-artifact", str(work / "received.png"))
    d = local_draft_dir = "files/receipt-import/drafts/" + base.run_as("ls files/receipt-import/drafts").split()[0]
    manifest = json.loads(base.run_as(f"cat {d}/processing.json"))
    confirmed = [i for i in manifest["items"] if i["state"] == "Confirmed"]
    assert len(confirmed) == 1
    item = confirmed[0]
    received = (work / "received.png").read_bytes()
    originals = [u.adb("exec-out", "run-as", PKG, "cat", f"{d}/{i['photoFileName']}", binary=True) for i in manifest["items"]]
    (work / "device-original").write_bytes(u.adb("exec-out", "run-as", PKG, "cat", f"{local_draft_dir}/{item['photoFileName']}", binary=True))
    facts = {
        "confirmed_items_on_device": len(confirmed),
        "items_on_device": len(manifest["items"]),
        "received_equals_confirmed_artifact": hashlib.sha256(received).hexdigest() == item["confirmed"]["artifactSha256"],
        "received_equals_any_original": any(o == received for o in originals),
        "confirmed_fields": item["confirmed"]["fields"],
        "server_fields": final["expense_fields"],
    }
    log(json.dumps(facts, ensure_ascii=False))
    assert facts["received_equals_confirmed_artifact"] and not facts["received_equals_any_original"]
    r = subprocess.run([sys.executable, "-I", str(CHECKER), str(work / "device-original"), str(work / "received.png")], capture_output=True, text=True)
    (OUT / "android-upload-artifact-check.json").write_text(r.stdout)
    log(r.stdout.strip())
    assert r.returncode == 0
    outsider = backend("outsider-check")
    (OUT / "android-upload-outsider.json").write_text(outsider)
    log("PASS")


if __name__ == "__main__":
    main()
