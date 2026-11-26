#!/usr/bin/env python3
"""Android 에뮬레이터 E2E(영수증 처리, adb + UI Automator, 표준 라이브러리만).

파일 앱에서 가상 영수증 10장 공유 → ML Kit 일본어 OCR(동시 2장) → 처리 도중 SIGKILL → 디스크 상태 확인
→ 런처로 다시 열어 이어서 처리 → 실패한 사진만 다시 읽기 → 개발용 확인으로 가림 사본 → 호스트에서 가림 픽셀·메타데이터 검사.
사용: python3 -I apps/android/scripts/e2e_receipts.py <debug.apk> [증거 폴더]   (테스트 구현체로 빌드한 debug APK)
"""

import collections
import json
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
CHECKER = FIXTURES.parent / "check_artifact.py"
NAMES = [f"receipt-r{i:02d}.png" for i in range(1, 11)]
LOG = []


def log(msg):
    line = time.strftime("[%H:%M:%S] ") + msg
    print(line, flush=True)
    LOG.append(line)
    (OUT / "android-e2e-receipts.log").write_text("\n".join(LOG) + "\n", encoding="utf-8")


def draft_dir():
    return "files/receipt-import/drafts/" + base.run_as("ls files/receipt-import/drafts").split()[0]


def manifest():
    text = base.run_as(f"cat {draft_dir()}/processing.json")
    return json.loads(text) if text.strip().startswith("{") else None


def summary(label):
    m = manifest()
    items = sorted(m["items"], key=lambda i: i["position"])
    data = {
        "label": label,
        "states": dict(collections.Counter(i["state"] for i in items)),
        "attempts": [i["attempts"] for i in items],
        "failures": {i["position"]: i["failure"] for i in items if i.get("failure")},
        "recoveredCount": m["recoveredCount"],
    }
    (OUT / f"android-receipts-state-{label}.json").write_text(json.dumps(data, ensure_ascii=False) + "\n")
    log(json.dumps(data, ensure_ascii=False))
    return m


def status(position):
    return u.texts_within(f"item_{position}_status")


def scroll_status(position):
    u.scroll_to(id=f"item_{position}_status")
    return status(position)


def main():
    apk = sys.argv[1]
    (OUT / "screens").mkdir(parents=True, exist_ok=True)
    log("fresh install, 10 synthetic receipts into Pictures/NonanonaReceipts")
    u.adb("uninstall", PKG, check=False)
    u.adb("install", "-r", apk)
    u.sh("rm -rf /sdcard/Pictures/NonanonaReceipts && mkdir -p /sdcard/Pictures/NonanonaReceipts")
    for name in NAMES:
        u.adb("push", str(FIXTURES / name), "/sdcard/Pictures/NonanonaReceipts/")
        u.sh(f"am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file:///sdcard/Pictures/NonanonaReceipts/{name}")
    # debug 빌드만 읽는 검증 설정: 처리를 늦추고 4번째 사진의 첫 시도를 실패시킨다.
    settings = 'printf "delayMillisPerItem=2500\\nfailFirstAttemptAtPosition=4\\n"'
    u.sh(f"run-as {PKG} sh -c 'mkdir -p files && {settings} > files/debug-processing.properties'")

    base.share_from_files(NAMES, folder="NonanonaReceipts")
    u.wait(id="draft_row", timeout=30)
    for _ in range(300):
        m = manifest()
        processed = sum(i["state"] in ("Ready", "Failed", "Confirmed") for i in m["items"]) if m else 0
        if processed >= 4:
            break
        time.sleep(0.3)
    assert 4 <= processed <= 6, processed
    victim = base.pid()
    u.sh(f"run-as {PKG} kill -9 {victim}")
    log(f"SIGKILL app pid {victim} with {processed}/10 processed")
    at_kill = summary("at-kill")
    assert any(i["state"] == "Processing" for i in at_kill["items"]), "photos must be mid-read at kill time"
    u.sh(f"run-as {PKG} rm -f files/debug-processing.properties")

    u.sh("input keyevent KEYCODE_HOME")
    u.sh(f"am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -f 0x10200000 -n {PKG}/.MainActivity")
    u.tap(u.wait(id="draft_row", timeout=20))
    u.wait(id="processing_recovered", timeout=20)
    for _ in range(400):
        if "읽음 10/10" in u.texts_within("processing_summary"):
            break
        time.sleep(0.5)
    assert "읽음 10/10" in u.texts_within("processing_summary"), u.texts_within("processing_summary")
    base.shot("android-receipts-after-resume")
    labels = {p: scroll_status(p) for p in range(1, 11)}
    failed = [p for p, t in labels.items() if t == ["읽지 못함"]]
    assert len(failed) == 2 and 4 in failed, labels
    unreadable = next(p for p in failed if p != 4)

    u.tap(u.scroll_to(id="item_4_retry"))
    for _ in range(120):
        if scroll_status(4) == ["확인 필요"]:
            break
        time.sleep(0.5)
    assert scroll_status(4) == ["확인 필요"]
    unreadable_attempts = next(i["attempts"] for i in manifest()["items"] if i["position"] == unreadable)
    u.tap(u.scroll_to(id=f"item_{unreadable}_retry"))
    for _ in range(120):
        item = next(i for i in manifest()["items"] if i["position"] == unreadable)
        if item["state"] == "Failed" and item["attempts"] == unreadable_attempts + 1:
            break
        time.sleep(0.5)
    else:
        raise AssertionError(f"unreadable receipt {unreadable} did not finish exactly one retry")
    after = {p: scroll_status(p) for p in range(1, 11)}
    assert after[unreadable] == ["읽지 못함"]
    for p in range(1, 11):
        if p != 4:
            assert labels[p] == after[p], (p, labels[p], after[p])

    confirm = 2 if unreadable == 1 else 1
    u.tap(u.scroll_to(id=f"item_{confirm}_debug_confirm"))
    for _ in range(60):
        if scroll_status(confirm) == ["확인함"]:
            break
        time.sleep(0.5)
    assert scroll_status(confirm) == ["확인함"]
    base.shot("android-receipts-confirmed")
    final = summary("final")

    item = next(i for i in final["items"] if i["state"] == "Confirmed")
    work = OUT / "artifact"
    work.mkdir(exist_ok=True)
    d = draft_dir()
    for remote, local in [(f"{d}/{item['photoFileName']}", work / "original"), (f"{d}/confirmed/{item['confirmed']['artifactFileName']}", work / "artifact")]:
        local.write_bytes(u.adb("exec-out", "run-as", PKG, "cat", remote, binary=True))
    r = subprocess.run([sys.executable, "-I", str(CHECKER), str(work / "original"), str(work / "artifact")], capture_output=True, text=True)
    (OUT / "android-receipts-artifact-check.json").write_text(r.stdout)
    log(r.stdout.strip())
    assert r.returncode == 0, "artifact check failed"
    log(f"proposals kept local: {len(base.run_as(f'ls {d}/proposals').split())} files in app-private storage only")
    log("PASS")


if __name__ == "__main__":
    main()
