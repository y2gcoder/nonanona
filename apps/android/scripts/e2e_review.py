#!/usr/bin/env python3
"""Android 접히는 기기 에뮬레이터 E2E(목록 먼저 영수증 검토, 로컬 Supabase 모드, adb + UI Automator, 표준 라이브러리만).

가상 영수증 10장 공유 → 목록에서 읽는 중·대기·확인 필요·읽지 못함 → 읽지 못한 사진만 다시 읽기(입력 유지) → 직접 입력
→ 값 고쳐 확인하고 다음 → 제안이 놓친 가림을 OCR 줄·가림 영역으로 고치고 미리보기 → 입력 중 SIGKILL → 다시 열어 이어서
→ 펴기(두 칸: 영수증 목록 옆 검토)·접기·큰 글자 → 올릴 곳 없음 → 참여 → 최종 확인 전 0건 → 취소 0건 → 구성원 아님 0건
→ 올리기 → 반복은 같은 지출 → 서버가 받은 사본·필드와 기기 디스크를 검사한다(apps/fixtures/review_e2e_check.py, iOS와 같은 검사).
사전 조건: mise run local:up, 접은(바깥 화면) 접히는 기기 에뮬레이터 하나(Pixel 9 Pro Fold 프로필, emu fold/unfold 지원).
사용: mise run android:e2e-review -- [증거 폴더]
"""

import json
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import adbui as u  # noqa: E402
import e2e as base  # noqa: E402  (같은 인자 순서: <apk> [증거 폴더])
import e2e_adaptive as adaptive  # noqa: E402
import e2e_local as local  # noqa: E402

PKG = base.PKG
OUT = base.OUT
FIXTURES = Path(__file__).resolve().parents[2] / "fixtures" / "receipts"
CHECK = FIXTURES.parent / "review_e2e_check.py"
CHECKER = FIXTURES.parent / "check_artifact.py"
NAMES = [f"receipt-r{i:02d}.png" for i in range(1, 11)]
WORK = Path(tempfile.mkdtemp(prefix="nonanona-review-"))
LOG = []
MERCHANT = "yukimi"  # 직접 입력은 화면 자판(Gboard) 키를 눌러 친다(대문자 전환 없이)
SUFFIX = " edit"


def log(msg):
    line = time.strftime("[%H:%M:%S] ") + msg
    print(line, flush=True)
    LOG.append(line)
    (OUT / "android-e2e-review.log").write_text("\n".join(LOG) + "\n", encoding="utf-8")


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


def draft_names():
    return base.run_as("ls files/receipt-import/drafts 2>/dev/null").split()


def draft_with(photos):
    """사진 수로 초안을 고른다(10장 초안과 EXIF 1장 초안)."""
    for name in draft_names():
        props = base.run_as(f"cat files/receipt-import/drafts/{name}/draft.properties")
        line = next((x for x in props.splitlines() if x.startswith("photos=")), "photos=")
        if len([n for n in line.split("=", 1)[1].split(",") if n.strip()]) == photos:
            return name
    return None


def pull_draft(name=None):
    """앱 전용 저장소의 초안 폴더를 호스트의 새 폴더로 꺼낸다(검사용, 기기에서는 지우지 않는다)."""
    name = name or until(lambda: draft_with(10) or next(iter(draft_names()), None), 30, "draft saved")
    raw = u.adb("exec-out", "run-as", PKG, "tar", "-c", "-C", "files/receipt-import/drafts", name, binary=True)
    dest = Path(tempfile.mkdtemp(dir=WORK, prefix="draft-"))
    archive = dest / "draft.tar"
    archive.write_bytes(raw)
    with tarfile.open(archive) as t:
        t.extractall(dest, filter="data")
    return dest / name


def inspect(*args, out=None, draft=None):
    cmd = [sys.executable, "-I", str(CHECK), *args, "--draft", str(pull_draft(draft)), "--fixtures", str(FIXTURES)]
    if out:
        cmd += ["--out", str(out)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    for line in r.stdout.strip().splitlines():
        log(line)
    assert r.returncode == 0, r.stderr
    return dict(line.split("=", 1) for line in r.stdout.splitlines() if "=" in line and not line.startswith("{"))


def text(id_):
    n = u.find(id=id_)
    return n.text if n else None


def texts(id_):
    return " ".join(u.texts_within(id_))


def until(fn, timeout=30, what=""):
    deadline = time.time() + timeout
    while time.time() < deadline:
        v = fn()
        if v:
            return v
        time.sleep(0.5)
    raise AssertionError(f"timed out: {what}")


def reach(screen, **query):
    """목록(screen) 안에서 위아래로 넘겨, 상단 막대와 하단 확인 막대에 가리지 않는 자리로 가져온다."""
    hide_keyboard()
    for direction in [1] * 10 + [-1] * 20:
        nodes = u.dump()
        hit = u.find(nodes, **query)
        box = u.find(nodes, id=screen)
        bar = u.find(nodes, id="review_confirm_hint")
        top = box.bounds[1] + 200 if box else 0
        bottom = bar.bounds[1] - 10 if bar and screen == "review_screen" else (box.bounds[3] if box else 10**6)
        if hit and top <= hit.bounds[1] and hit.bounds[3] <= bottom:
            return hit
        x1, y1, x2, y2 = box.bounds
        y2 = min(y2, bottom)  # 하단 확인 막대 위에서만 민다
        x, a, b = (x1 + x2) // 2, top + (y2 - top) // 4, top + 3 * (y2 - top) // 4
        start, end = (b, a) if direction == 1 else (a, b)
        u.sh(f"input swipe {x} {start} {x} {end} 400")
        time.sleep(0.7)
    raise TimeoutError(f"not reachable in {screen}: {query}")


def type_into(id_, value, screen="review_screen", ime=False):
    """입력 칸을 비우고 친다. ime=True면 화면 자판(Gboard)의 키를 눌러 실제 입력기를 거친다."""
    field = reach(screen, id=id_)
    u.tap(field)
    time.sleep(0.8)
    # 자판이 올라오는 동안 칸이 잠깐 덤프에서 빠질 수 있다. 다시 보일 때까지 기다린다.
    current = until(lambda: u.find(id=id_), 10, f"{id_} visible after focus").text or ""
    u.sh("input keyevent KEYCODE_MOVE_END")
    if current:
        u.sh("input keyevent " + " ".join(["KEYCODE_DEL"] * (len(current) + 2)))
    if ime:
        u.ime_type(value)
    else:
        u.sh("input text " + value.replace(" ", "%s"))
    until(lambda: (u.find(id=id_).text or "") == value, 10, f"{id_} = {value!r}")


def write_faults(*parts):
    """debug 빌드의 저장 실패 주입(경로 조각). 인자가 없으면 끈다."""
    if parts:
        base.run_as('printf "' + "\\n".join(parts) + '\\n" > files/receipt-import/debug-fail-writes')
    else:
        base.run_as("rm -f files/receipt-import/debug-fail-writes")


def append_into(id_, suffix):
    u.tap(reach("review_screen", id=id_))
    u.sh("input keyevent KEYCODE_MOVE_END")
    u.sh("input text " + suffix.replace(" ", "%s"))
    time.sleep(0.5)


def hide_keyboard():
    if "mInputShown=true" in u.sh("dumpsys input_method | grep mInputShown", check=False):
        u.back()


def title():
    return text("review_title")


def open_from_list(position):
    """검토 화면에서 목록으로 돌아가 그 번호의 영수증을 연다(두 칸이면 목록이 옆에 있다)."""
    if not u.find(id="draft_screen"):
        u.back()
    u.wait(id="draft_screen", timeout=10)
    u.tap(reach("draft_screen", id=f"item_{position}_open"))
    until(lambda: title() == f"사진 {position}", 10, f"open {position}")


def confirm_next():
    before = title()
    hide_keyboard()
    button = u.find(id="review_confirm_next")
    assert button and button.enabled, "확인하고 다음을 누를 수 있어야 한다"
    u.tap(button)
    return until(lambda: title() if title() not in (None, before) else None, 15, "next receipt opens")


def main():
    apk = sys.argv[1]
    (OUT / "screens").mkdir(parents=True, exist_ok=True)
    local.assert_built_with_current_config()
    u.sh("svc power stayon true")
    u.sh("input keyevent KEYCODE_WAKEUP")
    adaptive.settle(1)
    log(f"active display {adaptive.active_display()} (fold emulator, folded = outer phone screen)")
    log("fresh install (local backend mode), 10 synthetic receipts into Pictures/NonanonaReview")
    u.adb("uninstall", PKG, check=False)
    u.adb("install", "-r", apk)
    u.sh("settings put system font_scale 1.0")
    u.sh("rm -rf /sdcard/Pictures/NonanonaReview && mkdir -p /sdcard/Pictures/NonanonaReview")
    for name in NAMES:
        u.adb("push", str(FIXTURES / name), "/sdcard/Pictures/NonanonaReview/")
        u.sh(f"am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file:///sdcard/Pictures/NonanonaReview/{name}")
    # debug 빌드만 읽는 검증 설정: 처리를 늦추고, 파일 앱 선택 순서로 1번(r01)의 가림 제안을 비운다(놓친 가림 재현).
    u.sh(f"am start -n {PKG}/.MainActivity")
    time.sleep(2)
    base.run_as('printf "delayMillisPerItem=2500\\ndropSuggestionsAtPosition=1\\n" > files/debug-processing.properties')
    u.sh(f"am force-stop {PKG}")

    base.share_from_files(NAMES, folder="NonanonaReview")
    order = inspect("order")
    log(f"photo order {order['ORDER']}; r10 at {order['FAILED_POSITION']}; r01 at {order['MISSED_POSITION']}")
    assert order["MISSED_POSITION"] == "1", "파일 앱 선택 순서로 r01이 1번이어야 가림 제안을 비운 사진이 r01이다"
    failed_position = int(order["FAILED_POSITION"])

    # 1. 목록이 먼저: 읽는 중과 대기를 나눠 보이고, 다 읽으면 확인 필요 9 · 읽지 못함 1
    u.tap(u.wait(id="draft_row", timeout=30))
    until(lambda: "읽는 중 2" in texts("queue_breakdown") and "대기" in texts("queue_breakdown"), 30, "processing + queued")
    log(f"queue while processing: {texts('queue_breakdown')}")
    base.shot("android-review-queue-processing")
    until(lambda: texts("processing_summary") == "읽음 10/10", 120, "all read")
    until(lambda: texts("queue_breakdown") == "확인 필요 9 · 읽지 못함 1", 10, "breakdown after read")
    assert texts("review_start") == "확인할 영수증 검토 (9)", texts("review_start")
    assert texts("review_summary") == "확인 0/10"
    base.shot("android-review-queue-ready")

    # 2. 읽지 못한 사진: 입력이 다시 읽기를 지나도 남고, 다시 실패한 뒤 직접 입력으로 확인
    u.tap(reach("draft_screen", id="open_first_failed"))
    until(lambda: title() == f"사진 {failed_position}", 10, "failed photo opens")
    assert texts("review_status") == "읽지 못함"
    assert not u.find(id="review_confirm_next").enabled, "값이 없으면 확인할 수 없다"
    assert reach("review_screen", id="review_date_problem"), "왜 확인할 수 없는지 보인다"
    type_into("review_merchant", MERCHANT, ime=True)
    type_into("review_amount", "1760", ime=True)
    hide_keyboard()
    u.tap(reach("review_screen", id="review_retry"))
    until(lambda: texts("review_status") in ("대기 중", "읽는 중"), 10, "retrying")
    base.shot("android-review-retrying")
    until(lambda: texts("review_status") == "읽지 못함", 60, "failed again")
    assert reach("review_screen", id="review_amount").text == "1760", "다시 읽기를 지나도 입력이 남는다"
    # 날짜 칸은 숫자 자판이다. 구분자 키 없이 숫자 8자리를 화면 자판으로 치면 2026-11-08로 받는다.
    type_into("review_date", "20261108", ime=True)
    assert not u.find(id="review_date_problem"), "숫자 8자리 날짜를 받아야 한다"
    hide_keyboard()
    base.shot("android-review-manual-entry")
    nxt = confirm_next()
    log(f"manual entry confirmed, next opened: {nxt}")
    assert texts("review_progress") == "확인 1/10"
    inspect("manual", "--merchant", MERCHANT, out=OUT / "android-review-manual-check.json")
    plan = inspect("plan", "--missed", "1")
    log(f"plan {plan}")

    # 3. 값 고치기 → 확인하고 다음
    if title() != f"사진 {plan['EDIT_POSITION']}":
        open_from_list(int(plan["EDIT_POSITION"]))
    amount = int(reach("review_screen", id="review_amount").text.replace(",", ""))
    type_into("review_amount", str(amount + 10))
    append_into("review_merchant", SUFFIX)
    hide_keyboard()
    base.shot("android-review-edited")
    confirm_next()
    assert texts("review_progress") == "확인 2/10"
    inspect("edited", "--position", plan["EDIT_POSITION"], "--suffix", SUFFIX, out=OUT / "android-review-edited-check.json")

    # 4. 놓친 가림 고치기: OCR 줄 켜기 + 가림 영역 더하기 → 가린 사본 미리보기 → 확인
    if title() != "사진 1":
        open_from_list(1)
    assert texts("mask_count") == "가림 0곳", "제안이 놓친 상태에서 시작한다"
    base.shot("android-review-missed-mask")
    line_ids = [x for x in plan["MASK_LINE_IDS"].split(",") if x]
    for lid in line_ids:
        row = reach("review_screen", id=f"mask_line_{lid}")
        assert not row.checked
        u.tap(row)
        until(lambda: u.find(id=f"mask_line_{lid}").checked, 5, f"line {lid} masked")
    u.tap(reach("review_screen", id="mask_add_region"))
    target = (int(plan["BAND_TOP"]), int(plan["BAND_HEIGHT"]))

    def band():
        nums = [int("".join(c for c in w if c.isdigit())) for w in reach("review_screen", id="region_1_value").text.replace("–", " ").split() if any(c.isdigit() for c in w)]
        return nums[1], nums[2] - nums[1]  # "직접 더한 영역 1 · 위에서 47–53%"

    while band()[0] != target[0]:
        u.tap(reach("review_screen", id="region_1_down" if band()[0] < target[0] else "region_1_up"))
    while band()[1] != target[1]:
        u.tap(reach("review_screen", id="region_1_grow" if band()[1] < target[1] else "region_1_shrink"))
    expected = len(line_ids) + 1
    assert texts("mask_count") == f"가림 {expected}곳" or reach("review_screen", id="mask_count").text == f"가림 {expected}곳"
    base.shot("android-review-mask-corrected")
    u.tap(reach("review_screen", id="review_view_masked"))
    preview = u.wait(id="review_preview", timeout=20)
    assert preview.desc.startswith(f"가린 사본 미리보기, 가림 {expected}곳"), preview.desc
    base.shot("android-review-masked-preview")
    u.tap(reach("review_screen", id="review_view_original"))
    confirm_next()
    assert texts("review_progress") == "확인 3/10"
    inspect("masked", "--position", "1", out=OUT / "android-review-missed-mask-check.json")

    # 5. 입력만 하고 → 저장 실패 주입(입력 저장, 확인) → 앱 종료 → 다시 열어 이어서
    type_into("review_amount", "999")
    hide_keyboard()
    base.shot("android-review-before-kill")
    typed_title = title()
    write_faults("reviews/")
    type_into("review_amount", "888")
    hide_keyboard()
    until(lambda: u.find(id="review_save_error"), 10, "save error shown")
    assert reach("review_screen", id="review_amount").text == "888", "저장하지 못해도 화면의 입력은 남는다"
    adaptive.shot("android-review-save-failed")
    write_faults("reviews/", "processing.json")
    u.tap(u.find(id="review_confirm_next"))
    until(lambda: u.find(id="review_confirm_error"), 10, "confirm error shown")
    assert title() == typed_title, "확인을 저장하지 못하면 다음 사진으로 가지 않는다"
    adaptive.shot("android-review-confirm-failed")
    reach("review_screen", id="review_status")
    assert texts("review_progress") == "확인 3/10" and texts("review_status") == "확인 필요"
    write_faults()
    typed = inspect("typed")["TYPED_POSITION"]  # 디스크에는 마지막으로 쓴 입력(999)이 남았다
    log(f"injected storage failures: draft save and confirm surfaced, photo {typed} still unconfirmed with durable 999")
    victim = base.pid()
    u.sh(f"run-as {PKG} kill -9 {victim}")
    log(f"SIGKILL app pid {victim} while photo {typed} has unconfirmed input; reopen from launcher")
    inspect("states", "--label", "after-kill", out=OUT / "android-review-state-after-kill.json")
    u.sh("input keyevent KEYCODE_HOME")
    u.sh(f"am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -f 0x10200000 -n {PKG}/.MainActivity")
    u.tap(u.wait(id="draft_row", timeout=20))
    until(lambda: texts("review_summary") == "확인 3/10", 15, "progress kept")
    assert texts("review_start") == "확인할 영수증 검토 (7)"
    assert u.texts_within(f"item_{typed}_status") == ["확인 필요"] or reach("draft_screen", id=f"item_{typed}_status")
    base.shot("android-review-after-restart-list")
    open_from_list(int(typed))
    assert reach("review_screen", id="review_amount").text == "999", "확인하지 않은 입력이 앱을 다시 열어도 남는다"
    type_into("review_merchant", "fold")
    hide_keyboard()

    # 6. 펴기(두 칸: 영수증 목록 옆 검토) → 접기: 같은 영수증, 같은 입력
    adaptive.emu("unfold")
    adaptive.settle()
    nodes = u.dump()
    assert u.find(nodes, id="draft_screen") and u.find(nodes, id="review_screen"), "펼치면 영수증 목록 옆에 검토 화면"
    assert title() == f"사진 {typed}"
    assert reach("review_screen", id="review_merchant").text == "fold"
    adaptive.one_side_of_hinge(u.find(id="review_confirm_next"), "review confirm button")
    adaptive.one_side_of_hinge(u.find(id="review_screen"), "review pane")
    adaptive.shot("android-review-unfolded-two-pane")
    adaptive.emu("fold")
    adaptive.settle()
    assert title() == f"사진 {typed}" and reach("review_screen", id="review_amount").text == "999"

    # 7. 큰 글자(2.0): 같은 영수증, 스크롤로 마지막 조작까지 닿는다
    u.sh("settings put system font_scale 2.0")
    adaptive.settle()
    assert title() == f"사진 {typed}"
    assert reach("review_screen", id="review_amount").text == "999"
    assert reach("review_screen", id="mask_add_region").text == "가림 영역 더하기" or u.texts_within("mask_add_region") == ["가림 영역 더하기"]
    assert u.find(id="review_confirm_next").enabled
    adaptive.shot("android-review-large-text")
    u.sh("settings put system font_scale 1.0")
    adaptive.settle()
    u.back()  # 목록으로(확인하지 않고 나가도 확인되지 않는다)
    until(lambda: texts("review_summary") == "확인 3/10", 10, "leaving is not confirming")

    # 8. 올리기: 올릴 곳 없음 → 참여 → 최종 확인 전·취소·구성원 아님은 0건 → 올리기 → 반복은 같은 지출
    assert reach("draft_screen", text="참여한 여행방이 없어요. 초대 링크로 참여한 뒤 올릴 수 있어요.")
    assert not u.find(id="upload_start"), "올릴 곳이 없으면 올리기 버튼이 없다"
    local.open_invite("SYNTHLOCAL0001")
    u.tap(u.wait(id="invite_primary"))
    u.tap(u.wait(id="login_google", timeout=15))
    local.assert_room("가상 오사카 여행")
    u.back()
    u.tap(u.wait(id="draft_row", timeout=20))
    assert reach("draft_screen", id="upload_destination").text == "올릴 곳: 가상 오사카 여행"
    assert u.find(text="확인한 영수증 2장") and u.find(id="upload_manual_excluded")
    u.tap(reach("draft_screen", id="upload_start"))
    u.wait(text="‘가상 오사카 여행’에 영수증 2장을 올릴까요?", timeout=10)
    base.shot("android-review-final-confirmation")
    report({"objects": 0, "expenses": 0})
    log("final confirmation open: nothing on the server")
    u.tap(u.wait(text="취소"))
    u.gone(text="올리기", timeout=5)
    report({"objects": 0, "expenses": 0})

    def upload():
        start = reach("draft_screen", id="upload_start")
        until(lambda: u.find(id="upload_start").enabled, 20, "upload enabled")
        u.tap(start)
        u.tap(u.wait(text="올리기", timeout=10))

    def status(expected):
        until(lambda: text("upload_status") == expected, 45, f"upload status {expected}")

    backend("membership-remove")
    upload()
    status("이 여행방에 올릴 수 없어요. 여행방 구성원인지 확인해 주세요.")
    base.shot("android-review-unauthorized")
    report({"objects": 0, "expenses": 0})
    backend("membership-restore")
    upload()
    status("올림 2장(이미 올린 0장 포함)")
    upload()
    status("올림 2장(이미 올린 2장 포함)")
    base.shot("android-review-uploaded")
    final = report({"objects": 2, "expenses": 2, "objects_without_expense": 0, "expenses_without_object": 0})
    (OUT / "android-review-server-report.json").write_text(json.dumps(final, ensure_ascii=False) + "\n")
    backend("fetch-artifacts", str(WORK / "received"))
    inspect("received", "--received", str(WORK / "received"), "--report", str(OUT / "android-review-server-report.json"),
            "--checker", str(CHECKER), out=OUT / "android-review-received-check.json")
    inspect("states", "--label", "final", out=OUT / "android-review-state-final.json")
    (OUT / "android-review-outsider.json").write_text(backend("outsider-check"))
    exif_rotated_photo()
    log("PASS")


def exif_rotated_photo():
    """EXIF 방향(6)이 붙은 가상 JPEG: 검토 화면의 원본이 똑바로 보이고, 확인한 사본이 똑바로 선 크기로 민감한 줄을 가린다."""
    base.run_as("rm -f files/debug-processing.properties")
    u.sh(f"am force-stop {PKG}")
    jpg = WORK / "receipt-r01-exif6.jpg"
    subprocess.run([sys.executable, "-I", str(FIXTURES.parent / "make_exif_rotated.py"), str(FIXTURES / "receipt-r01.png"), str(jpg)],
                   check=True, capture_output=True)
    u.sh("rm -rf /sdcard/Pictures/NonanonaExif && mkdir -p /sdcard/Pictures/NonanonaExif")
    u.adb("push", str(jpg), "/sdcard/Pictures/NonanonaExif/")
    u.sh("am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file:///sdcard/Pictures/NonanonaExif/receipt-r01-exif6.jpg")
    base.share_from_files(["receipt-r01-exif6.jpg"], folder="NonanonaExif")
    u.tap(u.wait(id="draft_row", timeout=30))  # 최신 초안(EXIF 1장)이 맨 위
    until(lambda: texts("processing_summary") == "읽음 1/1", 60, "exif photo read")
    u.tap(reach("draft_screen", id="item_1_open"))
    until(lambda: title() == "사진 1" and texts("review_status") == "확인 필요", 15, "exif photo review")
    hide_keyboard()
    box = u.wait(id="review_original", timeout=10)
    display, _, _ = adaptive.active_display()
    u.sh(f"screencap -d {display} -p /sdcard/exif-ui.png")
    u.adb("pull", "/sdcard/exif-ui.png", str(WORK / "exif-ui.png"))
    adaptive.shot("android-review-exif-original")
    exif_draft = draft_with(1)
    inspect("align", "--screenshot", str(WORK / "exif-ui.png"), "--bounds", ",".join(map(str, box.bounds)),
            out=OUT / "android-review-exif-ui-alignment.json", draft=exif_draft)
    confirm_list = u.find(id="review_confirm_next")
    u.tap(confirm_list)
    u.wait(id="draft_screen", timeout=15)
    inspect("rotated", "--position", "1", out=OUT / "android-review-exif-artifact.json", draft=exif_draft)


if __name__ == "__main__":
    main()
