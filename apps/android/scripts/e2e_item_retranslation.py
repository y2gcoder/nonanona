#!/usr/bin/env python3
"""실제 앱에서 미리보기 재번역 → force-stop → 같은 품목 화면 → 제안 적용을 검증한다.

사용: ANDROID_SERIAL=emulator-PORT python3 -I apps/android/scripts/e2e_item_retranslation.py <test debug.apk> [증거 폴더]
지정한 전용 에뮬레이터에 가상 영수증과 장부를 준비한다. 실제 로그인·번역 서비스는 사용하지 않는다.
"""

import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import e2e as base  # noqa: E402

u = base.u
PKG = base.PKG
FIXTURE = Path(__file__).resolve().parents[2] / "fixtures/items/receipt-i01.png"
FOLDER = "NonanonaRetranslation"
TRIP = "가상 재번역 여행"
LINE = "ocr-10"
NAME = "우롱차(미리보기)"


def stop():
    u.sh(f"am force-stop {PKG}")
    assert not base.pid(), "이전 앱 프로세스가 종료되어야 한다"


def launch():
    u.sh(f"am start -n {PKG}/.MainActivity")
    u.wait(id="home_screen", timeout=30)


def open_items(restoring=False):
    u.tap(u.wait(text=TRIP, timeout=30))
    u.tap(u.wait(id="expense_1", timeout=30))
    u.wait(id="expense_review_screen")
    u.tap(u.scroll_to(id="review_item_split"))
    if restoring:
        u.wait(text="품목명 다시 번역")
    else:
        u.wait(id="item_split_screen")


def main():
    assert re.fullmatch(r"emulator-\d+", os.environ.get("ANDROID_SERIAL", "")), "전용 에뮬레이터 serial이 필요하다"
    assert u.sh("getprop ro.kernel.qemu").strip() == "1"
    (base.OUT / "screens").mkdir(parents=True, exist_ok=True)
    u.adb("uninstall", PKG, check=False)
    u.adb("install", "-r", sys.argv[1])
    u.sh(f"run-as {PKG} mkdir -p files")
    u.sh(f"printf 'itemRetranslation=preview\\ne2eRetranslationLedger=true\\n' | run-as {PKG} tee files/debug-processing.properties")
    u.sh(f"mkdir -p /sdcard/Pictures/{FOLDER}")
    u.adb("push", str(FIXTURE), f"/sdcard/Pictures/{FOLDER}/")
    u.sh(f"am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file:///sdcard/Pictures/{FOLDER}/{FIXTURE.name}")
    launch()
    base.share_from_files(FIXTURE.name, folder=FOLDER)
    u.tap(u.wait(id="draft_row", timeout=30))
    u.tap(u.wait(id="item_1_debug_confirm", timeout=60))
    u.wait(text="확인함", timeout=20)

    u.back()
    u.tap(u.wait(id="home_login"))
    u.tap(u.wait(id="login_google"))
    open_items()
    u.tap(u.scroll_to(id=f"item_{LINE}_retranslate", timeout=60))
    u.tap(u.wait(text="확인하고 다시 번역"))
    u.wait(text=NAME)
    draft = base.run_as("ls files/receipt-import/drafts").strip()
    photo = "photo-01.json"
    retranslation = f"files/receipt-import/drafts/{draft}/retranslations/{photo}"
    item_file = f"files/receipt-import/drafts/{draft}/items/{photo}"
    assert base.run_as(f"ls {retranslation}").strip() == retranslation
    assert not base.run_as(f"ls {item_file}").strip()
    base.shot("before-force-stop")
    base.log("미리보기 제안을 표시하고 기록을 저장함")

    stop()
    base.log("am force-stop 뒤 앱 PID가 없음을 확인함")
    launch()
    open_items(restoring=True)
    u.wait(text=NAME)
    base.shot("restored")
    base.log("새 프로세스에서 같은 품목 화면의 제안을 복원함")
    fault = "files/receipt-import/debug-fail-writes"
    u.sh(f"printf 'items/\\n' | run-as {PKG} tee {fault}")
    u.tap(u.wait(text="이 이름 사용"))
    u.wait(text="품목을 기기에 저장하지 못했어요.")
    assert not base.run_as(f"ls {item_file}").strip()
    assert base.run_as(f"ls {retranslation}").strip() == retranslation
    base.run_as(f"rm {fault}")
    u.tap(u.wait(text="다시 저장"))
    u.wait(id="item_split_screen")
    assert u.scroll_to(id=f"item_{LINE}_name", timeout=60).text == NAME
    plan = json.loads(base.run_as(f"cat {item_file}"))
    accepted = next(item for item in plan["lines"] if item["id"] == LINE)
    assert accepted["name"] == NAME and accepted["nameSource"] == "user"
    assert not base.run_as(f"ls {retranslation}").strip()
    base.shot("applied")
    base.log("PASS: 실제 프로세스 종료 뒤 제안 복원, 화면과 기기 계획에 적용, 실제 계획 쓰기 실패 뒤 다시 저장, 결과 파일 삭제")


if __name__ == "__main__":
    main()
