#!/usr/bin/env python3
"""품목별 나누기 E2E(로컬 Supabase 모드, 방장 기기 하나, 표준 라이브러리만).

가상 방장(다라)이 가상 품목 영수증 2장(apps/fixtures/items)을 공유·확인하고 정산 여행방(가상 후쿠오카 정산)에 사본을 올린다.
i01(3,500엔, 공유 셋·한 사람 둘): 실제 기기 번역 제공자 상태를 기록 → 미리보기 대역(정해 둔 사전, 실제 번역 아님)으로
직접 적은 이름은 그대로 두고 첫 실패 뒤 다시 번역 → 31,500원은 나눠떨어지지 않아 남은 1원을 보임 → 채우기(서버에 아무것도 안 감)
→ 방장이 남은 1원을 정해 포함. i02(699엔, 외세·할인): 품목 합 698엔은 저절로 나누지 않음 → 조정 줄(할인 -50·세금 51)을
더하면 6,990원이 정확히 나뉨 → 앱 SIGKILL → 다시 열어도 계획이 남음 → 채우고 포함. 단계마다 서버의 지출·몫을 확인하고,
끝에 서버 DB 전체(pg_dump 데이터)와 저장소 객체 이름에 품목 이름·번역 이름·조정 줄 이름이 없는지 확인한다.

사전 조건: mise run local:up. iOS는 부팅한 시뮬레이터, Android는 실행 중인 에뮬레이터 하나(adb 기기 하나).
사용: python3 -I scripts/e2e-items.py ios <시뮬레이터 UDID> [증거 폴더]
      python3 -I scripts/e2e-items.py android [증거 폴더]
"""

import importlib.util
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLATFORM = sys.argv[1]
assert PLATFORM in ("ios", "android")
UDID = sys.argv[2] if PLATFORM == "ios" else None
rest = sys.argv[3:] if PLATFORM == "ios" else sys.argv[2:]
OUT = Path(rest[0]) if rest else Path(tempfile.mkdtemp(prefix="nonanona-items-"))
WORK = Path(tempfile.mkdtemp(prefix="nonanona-items-work-"))
(OUT / "screens").mkdir(parents=True, exist_ok=True)
IOS = ROOT / "apps" / "ios"
ANDROID = ROOT / "apps" / "android"
APK = ANDROID / "app" / "build" / "outputs" / "apk" / "debug" / "app-debug.apk"
FIXTURES = ROOT / "apps" / "fixtures" / "items"
NAMES = ["receipt-i01.png", "receipt-i02.png"]
TRIP = "가상 후쿠오카 정산"
APP_ID = "app.nonanona"
LOG = []
# 서버 어디에도 있으면 안 되는 글자: OCR 품목 이름(일본어), 번역·직접 적은 한국어 이름, 조정 줄 이름.
FORBIDDEN = ["枝豆", "鶏の唐揚げ", "生ビール", "ウーロン茶", "だし巻き", "おにぎり", "緑茶ボトル", "サンドイッチ",
             "풋콩", "닭튀김", "생맥주", "우롱차", "달걀말이", "(미리보기)", "소비세", "할인",
             # Android 화면 자판 도우미는 한글을 칠 수 없어 Android 단계는 이 ASCII 이름을 쓴다.
             "edamame-user", "disc-adj", "tax-adj"]

if PLATFORM == "android":
    sys.argv = [sys.argv[0], str(APK), str(OUT)]
    sys.path.insert(0, str(ANDROID / "scripts"))
    import adbui as u  # noqa: E402
    import e2e as abase  # noqa: E402

    PKG = abase.PKG

spec = importlib.util.spec_from_file_location("local_backend", ROOT / "scripts" / "local-backend.py")
lb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lb)


def log(msg):
    line = time.strftime("[%H:%M:%S] ") + msg
    print(line, flush=True)
    LOG.append(line)
    (OUT / f"e2e-items-{PLATFORM}.log").write_text("\n".join(LOG) + "\n", encoding="utf-8")


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)


def backend(*args):
    r = subprocess.run([sys.executable, "-I", str(ROOT / "scripts" / "local-backend.py"), *args], capture_output=True,
                       text=True, check=True)
    for line in r.stdout.strip().splitlines():
        log(line)


def server(label, expect=None):
    """정산 여행방의 지출·몫(값은 가상 자료). 비밀값·토큰은 없다."""
    r = lb.rows(f"""select
        (select coalesce(json_agg(json_build_object('amount_minor', e.amount_minor, 'currency', e.currency, 'merchant', e.merchant,
           'status', e.status, 'krw_amount', e.krw_amount, 'krw_basis', e.krw_basis, 'payer', pm.display_name,
           'shares', (select json_object_agg(sm.display_name, s.krw)
                      from public.expense_shares s join public.trip_members sm on sm.trip_id = s.trip_id and sm.user_id = s.user_id
                      where s.expense_id = e.id)) order by e.amount_minor), '[]'::json)
           from public.expenses e left join public.trip_members pm on pm.trip_id = e.trip_id and pm.user_id = e.payer_id
           where e.trip_id = (select id from public.trips where name = '{TRIP}')) as expenses
        """, "items-e2e-report")[0]
    (OUT / f"server-{PLATFORM}-{label}.json").write_text(json.dumps(r, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    log(f"server {label}: {json.dumps(r['expenses'], ensure_ascii=False)}")
    if expect:
        expect({e["amount_minor"]: e for e in r["expenses"]})


def no_item_text_on_server():
    """서버 DB 전체(데이터만)와 저장소 객체 이름·메타데이터에 품목 글자가 없는지 본다. 가린 사본 PNG 픽셀은 기존 승인 범위다."""
    container = lb.rows("select 1 as ok", "items-e2e-ping") and "supabase_db_nonanona-local"
    dump = subprocess.run(["docker", "exec", container, "pg_dump", "-U", "postgres", "--data-only", "--no-owner",
                           # 마이그레이션 원문(SQL 주석)은 앱 자료가 아니다.
                           "--exclude-schema=supabase_migrations", "postgres"],
                          capture_output=True, check=True).stdout.decode("utf-8", errors="replace")
    hits = {w: dump.count(w) for w in FORBIDDEN if w in dump}
    # 대조: 허용 필드(가게 이름)는 덤프에 있어야 한다. 없으면 덤프가 앱 자료를 담지 않은 것이다.
    control = {w: dump.count(w) for w in ("架空居酒屋", "架空マート")}
    assert all(control.values()), control
    result = {"dump_bytes": len(dump), "forbidden_hits": hits, "checked": FORBIDDEN, "allowed_merchant_hits": control}
    (OUT / f"server-{PLATFORM}-no-item-text.json").write_text(json.dumps(result, ensure_ascii=False, indent=1) + "\n")
    log(f"server dump {len(dump)} bytes, item text hits: {hits}")
    assert not hits, hits


def expect_pending_no_shares(by):
    e = by[3500]
    assert e["status"] == "pending" and e["shares"] is None and e["krw_amount"] is None, e


def expect_i01_included(by):
    e = by[3500]
    assert (e["status"], e["payer"], e["krw_amount"], e["krw_basis"]) == ("included", "다라", 31500, "verified_krw_charge"), e
    assert e["shares"] == {"다라": 19958, "가나": 11542}, e["shares"]
    assert by[699]["status"] == "pending" and by[699]["shares"] is None


def expect_i02_included(by):
    e = by[699]
    assert (e["status"], e["payer"], e["krw_amount"]) == ("included", "다라", 6990), e
    assert e["shares"] == {"다라": 3345, "가나": 3645}, e["shares"]


# ---------------------------------------------------------------- iOS
def ios_build():
    log("iOS build-for-testing (Debug, local backend mode)")
    with open(WORK / "ios-build.log", "w") as f:
        run(["xcodebuild", "build-for-testing", "-project", "Nonanona.xcodeproj", "-scheme", "Nonanona",
             "-destination", f"platform=iOS Simulator,id={UDID}", "-derivedDataPath", str(WORK / "dd")],
            cwd=IOS, stdout=f, stderr=subprocess.STDOUT)
    subprocess.run(["xcrun", "simctl", "uninstall", UDID, APP_ID], capture_output=True)
    run(["xcrun", "simctl", "install", UDID, str(WORK / "dd/Build/Products/Debug-iphonesimulator/Nonanona.app")])


def ios_launch(translation=""):
    env = {"SIMCTL_CHILD_NONANONA_LOCAL_ACCOUNT": "host", "SIMCTL_CHILD_NONANONA_ITEM_TRANSLATION": translation}
    run(["xcrun", "simctl", "launch", "--terminate-running-process", UDID, APP_ID], env={**__import__("os").environ, **env},
        capture_output=True)
    time.sleep(2)
    log(f"iOS launch (item translation: {translation or 'Apple Translation'})")


def ios_kill():
    out = subprocess.run(["xcrun", "simctl", "spawn", UDID, "launchctl", "list"], capture_output=True, text=True).stdout
    pid = next((ln.split()[0] for ln in out.splitlines() if "UIKitApplication:app.nonanona[" in ln and ln.split()[0].isdigit()), None)
    assert pid, "app is running"
    subprocess.run(["kill", "-9", pid])
    log(f"iOS SIGKILL pid {pid}")


def ios_test(name):
    d = Path(tempfile.mkdtemp(dir=WORK, prefix=name + "."))
    log(f"iOS test {name}")
    env = {**__import__("os").environ, "TEST_RUNNER_EXPECT_LOCAL_BACKEND": "1"}
    with open(d / "test.log", "w") as f:
        r = subprocess.run(["xcodebuild", "test-without-building", "-project", "Nonanona.xcodeproj", "-scheme", "Nonanona",
                            "-destination", f"platform=iOS Simulator,id={UDID}", "-derivedDataPath", str(WORK / "dd"),
                            "-resultBundlePath", str(d / "result.xcresult"),
                            f"-only-testing:NonanonaUITests/ItemSplitUITests/{name}"],
                           cwd=IOS, stdout=f, stderr=subprocess.STDOUT, env=env)
    text = (d / "test.log").read_text(errors="replace")
    (d / "export").mkdir()
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(d / "result.xcresult"),
                    "--output-path", str(d / "export")], capture_output=True)
    manifest = d / "export" / "manifest.json"
    if manifest.exists():
        for test in json.loads(manifest.read_text()):
            for a in test.get("attachments", []):
                f = d / "export" / a["exportedFileName"]
                shot = a.get("suggestedHumanReadableName", f.stem).split("_0_")[0]
                if f.suffix == ".png":
                    subprocess.run(["sips", "-Z", "1000", str(f), "--out", str(OUT / "screens" / f"{shot}.png")], capture_output=True)
                elif f.suffix == ".txt":
                    log(f"  attachment {shot}: {f.read_text(errors='replace').strip()}")
    if r.returncode != 0 or " passed " not in text:
        for line in text.splitlines():
            if "error:" in line or "failed" in line:
                log("  " + line.strip()[:300])
        raise SystemExit(f"iOS test {name} failed (log: {d / 'test.log'})")
    log(f"iOS test {name} passed")


def ios_main():
    ios_build()
    run(["xcrun", "simctl", "addmedia", UDID, *[str(FIXTURES / n) for n in NAMES]])
    for _ in range(30):
        if f"{APP_ID}.share" in subprocess.run(["xcrun", "simctl", "spawn", UDID, "pluginkit", "-mA", "-p",
                                                 "com.apple.share-services"], capture_output=True, text=True).stdout:
            break
        time.sleep(1)
    ios_launch()
    ios_test("testI1_ShareItemReceipts")
    ios_launch()
    ios_test("testI2_ConfirmLoginUpload")
    server("uploaded", lambda by: [assert_pending(by[a]) for a in (3500, 699)])
    ios_test("testI3a_RealTranslatorStatus")
    ios_launch("preview-fail-once")
    ios_test("testI3b_MixedSplitRemainderFillsExactWithoutSending")
    server("filled-not-sent", expect_pending_no_shares)
    ios_test("testI4_HostDecidesRemainderAndIncludes")
    server("i01-included", expect_i01_included)
    ios_test("testI5_AdjustmentsMakeExactThenStop")
    server("i02-planned-not-sent", lambda by: assert_pending(by[699]))
    ios_kill()
    ios_launch("preview")
    ios_test("testI6_ReopenKeepsPlanApplyAndInclude")
    server("i02-included", expect_i02_included)
    device_plans_ios()


def device_plans_ios():
    """기기 안 품목 계획 파일(초안 폴더 items/)을 증거로 남긴다(가상 자료)."""
    group = subprocess.run(["xcrun", "simctl", "get_app_container", UDID, APP_ID, "group.app.nonanona"], capture_output=True,
                           text=True, check=True).stdout.strip()
    plans = sorted(Path(group).glob("receipt-import/drafts/*/items/*.json"))
    copy_plans(plans)


def copy_plans(plans):
    assert len(plans) == 2, plans
    for p in plans:
        data = json.loads(p.read_text())
        (OUT / f"device-{PLATFORM}-plan-{p.stem}.json").write_text(json.dumps(data, ensure_ascii=False, indent=1) + "\n")
        log(f"device plan {p.stem}: {len(data['lines'])} lines, ids {[l['id'] for l in data['lines']]}")


def assert_pending(e):
    assert e["status"] == "pending" and e["shares"] is None, e


# ---------------------------------------------------------------- Android
def until(fn, timeout=30, what=""):
    deadline = time.time() + timeout
    while time.time() < deadline:
        v = fn()
        if v:
            return v
        time.sleep(0.5)
    raise AssertionError(f"timed out: {what}")


def a_text(id_):
    n = u.find(id=id_)
    return n.text if n else None


def a_texts(id_):
    return " ".join(u.texts_within(id_))


def hide_keyboard():
    if "mInputShown=true" in u.sh("dumpsys input_method | grep mInputShown", check=False):
        u.back()


def reach(screen, **query):
    """화면(screen) 목록 안에서 위아래로 넘겨 가리지 않는 자리로 가져온다."""
    hide_keyboard()
    for direction in [1] * 10 + [-1] * 20:
        nodes = u.dump()
        hit = u.find(nodes, **query)
        box = u.find(nodes, id=screen)
        # 목록은 위 앱 막대(상태 막대 포함 약 230px) 밑으로도 이어진다. 그 아래로 내려온 것만 누를 수 있다.
        top = box.bounds[1] + 300 if box else 0
        bottom = box.bounds[3] - 20 if box else 10**6
        if hit and top <= hit.bounds[1] and hit.bounds[3] <= bottom:
            # 넘긴 목록이 아직 미끄러지는 중이면 누르기가 다른 칸에 맞는다. 자리가 멈춘 뒤에 돌려준다.
            time.sleep(0.8)
            again = u.find(id=query["id"]) if "id" in query else u.find(**query)
            if again and again.bounds == hit.bounds:
                return again
            continue
        if not box:
            time.sleep(0.5)
            continue
        x1, y1, x2, y2 = box.bounds
        x, a, b = (x1 + x2) // 2, top + (y2 - top) // 4, top + 3 * (y2 - top) // 4
        start, end = (b, a) if direction == 1 else (a, b)
        u.sh(f"input swipe {x} {start} {x} {end} 400")
        time.sleep(0.7)
    raise TimeoutError(f"not reachable in {screen}: {query}")


def ime_numeric():
    # 지금 입력기에 붙은 칸(dumpsys 앞쪽 줄). 숫자 칸은 0x2, 글자 칸은 0x8001 등.
    out = u.sh("dumpsys input_method | grep -m1 inputType=", check=False)
    return "inputType=0x2 " in out


def type_into(screen, id_, value):
    """칸을 눌러 포커스가 그 칸에 있는지(품목 금액은 숫자 자판) 본 뒤에만 지우고 친다. 빗나가면 다른 칸을 지우지 않고 다시 누른다."""
    # 품목 줄은 이름(글자 자판) 바로 아래 금액(숫자 자판)이 있어 빗나가면 자판 종류로 알 수 있다. 다른 칸은 자판이 떴는지만 본다.
    numeric = True if id_.endswith("_amount") and id_.startswith("item_ocr-") else False if id_.endswith("_name") else None
    for _ in range(3):
        field = reach(screen, id=id_)
        u.tap(field)
        time.sleep(1.0)
        shown = "mInputShown=true" in u.sh("dumpsys input_method | grep mInputShown", check=False)
        if shown and (numeric is None or ime_numeric() == numeric):
            break
        log(f"  tap on {id_} focused another field; retry")
        hide_keyboard()
    else:
        raise AssertionError(f"could not focus {id_}")
    current = until(lambda: u.find(id=id_), 10, f"{id_} visible").text or ""
    u.sh("input keyevent KEYCODE_MOVE_END")
    if current:
        u.sh("input keyevent " + " ".join(["KEYCODE_DEL"] * (len(current) + 2)))
    if value.isascii():
        u.sh(f"input text '{value}'")
    else:
        u.ime_type(value)
    time.sleep(0.5)
    hide_keyboard()
    got = reach(screen, id=id_).text or ""
    assert got == value, f"{id_} = {got!r}, want {value!r}"


def a_launch():
    u.sh(f"am start -n {PKG}/.MainActivity")
    time.sleep(2.5)


def a_settings(translation=""):
    """방장 계정과 번역 제공자(비우면 기기 번역 서비스, preview는 미리보기 대역)를 정하고 앱을 다시 띄운다."""
    lines = "localAccount=host\\n" + (f"itemTranslation={translation}\\n" if translation else "")
    abase.run_as(f'printf "{lines}" > files/debug-processing.properties')
    u.sh(f"am force-stop {PKG}")
    a_launch()
    log(f"Android launch (item translation: {translation or 'platform TranslationManager'})")


def a_install():
    log("Android assembleDebug (local backend mode)")
    with open(WORK / "android-build.log", "w") as f:
        run(["./gradlew", ":app:assembleDebug"], cwd=ANDROID, stdout=f, stderr=subprocess.STDOUT)
    u.adb("uninstall", PKG, check=False)
    u.adb("install", "-r", str(APK))
    u.sh("settings put system font_scale 1.0")
    u.sh("rm -rf /sdcard/Pictures/NonanonaItems && mkdir -p /sdcard/Pictures/NonanonaItems")
    for name in NAMES:
        u.adb("push", str(FIXTURES / name), "/sdcard/Pictures/NonanonaItems/")
        u.sh(f"am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file:///sdcard/Pictures/NonanonaItems/{name}")
    a_launch()
    a_settings()


def a_shot(name):
    abase.shot(name)


def a_home():
    for _ in range(6):
        if u.find(id="home_screen"):
            return
        u.back()
        time.sleep(0.5)
    u.wait(id="home_screen", timeout=10)


def a_login():
    a_home()
    if u.find(id="home_login"):
        u.tap(u.find(id="home_login"))
        u.tap(u.wait(id="login_google", timeout=15))
    until(lambda: a_texts("account_status") == "로그인됨 · 다라", 20, "signed in")


def a_open_trip():
    a_home()
    u.tap(reach("home_screen", text=TRIP))
    u.wait(id="room_screen", timeout=20)


def a_open_expense(amount):
    u.tap(u.wait(id="room_refresh", timeout=10))
    time.sleep(1.5)
    for _ in range(3):
        for i in range(1, 5):
            node = u.find(id=f"expense_{i}")
            if node is None:
                try:
                    node = reach("room_screen", id=f"expense_{i}")
                except TimeoutError:
                    continue
            if any(amount in t for t in u.texts_within(f"expense_{i}")):
                u.tap(reach("room_screen", id=f"expense_{i}"))
                u.wait(id="expense_review_screen", timeout=10)
                return
        time.sleep(1)
    raise AssertionError(f"expense {amount}")


def a_chip(screen, prefix, name):
    for i in (1, 2):
        if name in u.texts_within(f"{prefix}_{i}"):
            return reach(screen, id=f"{prefix}_{i}")
    raise AssertionError(f"no {prefix} chip for {name}")


def a_open_item_split(amount, krw):
    a_login()
    a_open_trip()
    a_open_expense(amount)
    reach("expense_review_screen", id="review_payer_1")
    u.tap(a_chip("expense_review_screen", "review_payer", "다라"))
    type_into("expense_review_screen", "review_krw", krw)
    hide_keyboard()
    u.tap(reach("expense_review_screen", id="review_item_split"))
    u.wait(id="item_split_screen", timeout=10)


def person(line, name):
    reach("item_split_screen", id=f"item_{line}_person_1")
    u.tap(a_chip("item_split_screen", f"item_{line}_person", name))
    time.sleep(0.3)


def share_row(text):
    for i in (1, 2, 3):
        try:
            reach("item_split_screen", id=f"items_share_{i}")
        except TimeoutError:
            break
        if text in a_texts(f"items_share_{i}"):
            return True
    raise AssertionError(f"no share row with {text}")


def status():
    return a_text("items_translation_status") or ""


def a_real_translator_status():
    a_open_item_split("3,500 JPY", "31500")
    until(lambda: "확인 중" not in status(), 20, "availability checked")
    first = status()
    log(f"  Android real translator status: {first}")
    assert "미리보기" not in first
    after = None
    if u.find(id="items_translate"):
        u.tap(u.find(id="items_translate"))
        until(lambda: "번역하는 중" not in status(), 30, "translate finished")
        after = status()
        log(f"  Android real translator after translate: {after}")
    (OUT / "android-real-translator.json").write_text(json.dumps({"status": first, "after_translate": after}, ensure_ascii=False) + "\n")
    a_shot("android-items-real-translator")


def a_mixed_remainder():
    a_open_item_split("3,500 JPY", "31500")
    assert u.find(id="items_privacy")
    until(lambda: "미리보기 대역 · 실제 번역 아님" in status(), 10, "preview translator")
    type_into("item_split_screen", "item_ocr-4_name", "edamame-user")
    hide_keyboard()
    u.tap(reach("item_split_screen", id="items_translate"))
    until(lambda: status() == "번역하지 못했어요. 다시 시도하거나 이름을 직접 적어 주세요.", 10, "first translate fails")
    u.tap(reach("item_split_screen", id="items_translate"))
    # 사전은 원래 글자로 만든 대역이다. ML Kit은 鶏の唐揚げ를 鶏の唐場げ로, 生ビール 2杯를 生ビール2杯로 읽어(실제 OCR 차이)
    # 그 두 줄은 사전에 없고 이름이 비어 남는다(직접 적는 길). 몇 개를 채웠는지는 기록한다.
    filled = until(lambda: status() if "이름을 채웠어요" in status() else None, 10, "translated")
    log(f"  preview translation: {filled}")
    assert reach("item_split_screen", id="item_ocr-10_name").text == "우롱차(미리보기)"
    assert reach("item_split_screen", id="item_ocr-10_source").text == "미리보기 대역 · 실제 번역 아님"
    assert reach("item_split_screen", id="item_ocr-4_name").text == "edamame-user"
    assert "生ビール" in reach("item_split_screen", id="item_ocr-8_original").text
    a_shot("android-items-translated")
    assert reach("item_split_screen", id="items_problem").text == "'edamame-user'을(를) 낼 사람을 골라 주세요."
    for line in ("ocr-4", "ocr-6", "ocr-12"):
        person(line, "가나")
        person(line, "다라")
    person("ocr-8", "다라")
    assert "확인이 필요해요" in reach("item_split_screen", id="items_problem").text
    amount = reach("item_split_screen", id="item_ocr-8_amount").text
    flags = a_texts("item_ocr-8_flags")
    log(f"  ocr-8 as read by ML Kit: amount {amount!r}, flags {flags!r}")
    (OUT / "android-ocr-8.json").write_text(json.dumps({"amount": amount, "flags": flags}, ensure_ascii=False) + "\n")
    if amount != "1320":
        # 실제 OCR이 ¥를 4로 읽는 경우(합계 초과 표시가 붙는다): 방장이 금액을 고치면 확인한 것으로 본다.
        type_into("item_split_screen", "item_ocr-8_amount", "1320")
        hide_keyboard()
    else:
        u.tap(reach("item_split_screen", id="item_ocr-8_check"))
    until(lambda: not u.find(id="item_ocr-8_flags"), 10, "ocr-8 checked")
    person("ocr-10", "가나")
    remainder = reach("item_split_screen", id="items_remainder").text
    assert remainder == '원 단위로 나눠떨어지지 않아 1원이 남아요. 채운 뒤 "직접 나누기"에서 누가 낼지 정해 주세요.', remainder
    share_row("19,957원")
    share_row("11,542원")
    a_shot("android-items-remainder")
    u.tap(reach("item_split_screen", id="items_apply"))
    u.wait(id="expense_review_screen", timeout=10)
    until(lambda: not u.find(id="item_split_screen"), 10, "item split closed")
    assert "1원이 남았어요" in reach("expense_review_screen", id="review_share_problem").text
    assert not reach("expense_review_screen", id="review_include").enabled
    a_shot("android-items-filled-exact-remainder")


def a_host_fixes_remainder():
    # 값이 있으면 칸 이름표가 트리에 없다. 채운 내림 몫으로 다라(19,957원) 칸을 고른다.
    for i in (1, 2):
        if reach("expense_review_screen", id=f"review_exact_{i}").text == "19957":
            type_into("expense_review_screen", f"review_exact_{i}", "19958")
            break
    else:
        raise AssertionError("no exact field for 다라")
    hide_keyboard()
    assert not u.find(id="review_share_problem")
    u.tap(reach("expense_review_screen", id="review_include"))
    u.wait(id="room_screen", timeout=15)
    until(lambda: not u.find(id="expense_review_screen"), 15, "review closes")


def a_adjustments():
    a_open_item_split("699 JPY", "6990")
    person("ocr-2", "다라")
    person("ocr-4", "가나")
    person("ocr-6", "가나")
    person("ocr-6", "다라")
    assert reach("item_split_screen", id="items_problem").text == "줄 합계가 영수증 합계와 1 JPY 달라요. 저절로 나누지 않아요."
    assert reach("item_split_screen", id="items_difference")
    assert reach("item_split_screen", id="items_summary_ocr-8"), "할인 줄은 요약에만 있다"
    a_shot("android-items-mismatch")
    u.tap(reach("item_split_screen", id="items_add_adjustment"))
    type_into("item_split_screen", "item_manual-1_name", "disc-adj")
    type_into("item_split_screen", "item_manual-1_amount", "-50")
    hide_keyboard()
    person("manual-1", "다라")
    u.tap(reach("item_split_screen", id="items_add_adjustment"))
    type_into("item_split_screen", "item_manual-2_name", "tax-adj")
    type_into("item_split_screen", "item_manual-2_amount", "51")
    hide_keyboard()
    person("manual-2", "가나")
    person("manual-2", "다라")
    share_row("3,345원")
    share_row("3,645원")
    assert not u.find(id="items_remainder")
    a_shot("android-items-exact")


def a_reopen_apply_include():
    a_open_item_split("699 JPY", "6990")
    assert reach("item_split_screen", id="item_manual-1_name").text == "disc-adj"
    assert reach("item_split_screen", id="item_manual-2_amount").text == "51"
    share_row("3,345원")
    share_row("3,645원")
    a_shot("android-items-reopened")
    u.tap(reach("item_split_screen", id="items_apply"))
    u.wait(id="expense_review_screen", timeout=10)
    until(lambda: not u.find(id="item_split_screen"), 10, "item split closed")
    assert not u.find(id="review_share_problem")
    u.tap(reach("expense_review_screen", id="review_include"))
    u.wait(id="room_screen", timeout=15)
    until(lambda: not u.find(id="expense_review_screen"), 15, "review closes")


def android_main():
    a_install()
    abase.share_from_files(NAMES, folder="NonanonaItems")
    u.tap(u.wait(id="draft_row", timeout=30))
    until(lambda: a_texts("processing_summary") == "읽음 2/2", 120, "all read")
    for position in (1, 2):
        u.tap(reach("draft_screen", id=f"item_{position}_debug_confirm"))
        until(lambda: a_texts(f"item_{position}_status") == "확인함", 20, f"item {position} confirmed")
    a_login()
    a_open_trip()
    a_home()
    u.tap(u.wait(id="draft_row", timeout=20))
    assert reach("draft_screen", id="upload_destination").text == f"올릴 곳: {TRIP}"
    u.tap(reach("draft_screen", id="upload_start"))
    u.tap(u.wait(text="올리기", timeout=10))
    until(lambda: a_text("upload_status") == "올림 2장(이미 올린 0장 포함)", 45, "uploaded")
    server("uploaded", lambda by: [assert_pending(by[a]) for a in (3500, 699)])
    a_real_translator_status()
    a_settings("preview-fail-once")
    a_mixed_remainder()
    server("filled-not-sent", expect_pending_no_shares)
    a_host_fixes_remainder()
    server("i01-included", expect_i01_included)
    a_adjustments()
    server("i02-planned-not-sent", lambda by: assert_pending(by[699]))
    u.sh(f"am force-stop {PKG}")
    pid = u.sh(f"pidof {PKG}", check=False).strip()
    assert not pid, pid
    log("Android app process killed (force-stop)")
    a_settings("preview")
    a_reopen_apply_include()
    server("i02-included", expect_i02_included)
    plans = abase.run_as("ls files/receipt-import/drafts/*/items/").split()
    local = Path(tempfile.mkdtemp(dir=WORK, prefix="plans."))
    files = []
    for draft in abase.run_as("ls files/receipt-import/drafts").split():
        for name in abase.run_as(f"ls files/receipt-import/drafts/{draft}/items").split():
            f = local / name
            f.write_text(abase.run_as(f"cat files/receipt-import/drafts/{draft}/items/{name}"), encoding="utf-8")
            files.append(f)
    log(f"device plan files: {plans}")
    copy_plans(sorted(files))


# ---------------------------------------------------------------- main
def main():
    log(f"platform={PLATFORM} evidence={OUT}")
    backend("reset")
    if PLATFORM == "ios":
        ios_main()
    else:
        android_main()
    no_item_text_on_server()
    log("PASS")


if __name__ == "__main__":
    main()
