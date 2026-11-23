#!/usr/bin/env python3
"""두 기기 정산 E2E(로컬 Supabase 모드, iOS 시뮬레이터 + Android 에뮬레이터, 표준 라이브러리만).

한 기기는 가상 방장(다라), 다른 기기는 가상 회원(가나)으로 같은 시드 여행방(가상 후쿠오카 정산)을 정산한다.
회원: 영수증 3장 공유 → 2장 확인 + 읽지 못한 1장은 값만 직접 입력 → 홈에서 로그인·여행방 열기 → 사본 2장 올리기
→ 직접 입력은 따로 최종 확인 뒤 올리기 → 다시 올려도 같은 지출 → 같은 지출이 보이지만 검토·확정 동작은 없음.
방장: 로그인 → 외화 13,377원(반씩 안 나뉨 → 직접 나누기) 포함, 외화 1건 보류, KRW 직접 입력 반씩 포함 → 미리보기
→ (스크립트가 회원 계정으로 지출 1건 추가) → 확정이 오래된 revision으로 거절 → 새 미리보기 → 늦은 지출 보류 → 확정.
두 기기: 같은 확정본(확정 번호·송금·제외) → 두 앱을 SIGKILL 뒤 다시 열어도 같음. 단계마다 서버 행을 확인한다.

사전 조건: mise run local:up, 부팅한 iOS 시뮬레이터 하나와 실행 중인 Android 에뮬레이터 하나(adb 기기 하나).
사용: python3 -I scripts/e2e-settlement.py <iOS 시뮬레이터 UDID> <방장 기기: ios|android> [증거 폴더]
"""

import hashlib
import importlib.util
import json
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UDID, HOST_PLATFORM = sys.argv[1], sys.argv[2]
assert HOST_PLATFORM in ("ios", "android")
MEMBER_PLATFORM = "android" if HOST_PLATFORM == "ios" else "ios"
OUT = Path(sys.argv[3]) if len(sys.argv) > 3 else Path(tempfile.mkdtemp(prefix="nonanona-settlement-"))
WORK = Path(tempfile.mkdtemp(prefix="nonanona-settlement-work-"))
(OUT / "screens").mkdir(parents=True, exist_ok=True)
IOS = ROOT / "apps" / "ios"
ANDROID = ROOT / "apps" / "android"
APK = ANDROID / "app" / "build" / "outputs" / "apk" / "debug" / "app-debug.apk"
FIXTURES = ROOT / "apps" / "fixtures" / "receipts"
NAMES = ["receipt-r01.png", "receipt-r02.png", "receipt-r10.png"]
TRIP = "가상 후쿠오카 정산"
APP_ID = "app.nonanona"
LOG = []

# Android 도우미(adbui, e2e.py)는 sys.argv[2]를 증거 폴더로 읽는다.
sys.argv = [sys.argv[0], str(APK), str(OUT)]
sys.path.insert(0, str(ANDROID / "scripts"))
import adbui as u  # noqa: E402
import e2e as abase  # noqa: E402

spec = importlib.util.spec_from_file_location("local_backend", ROOT / "scripts" / "local-backend.py")
lb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lb)
PKG = abase.PKG


def log(msg):
    line = time.strftime("[%H:%M:%S] ") + msg
    print(line, flush=True)
    LOG.append(line)
    (OUT / "e2e-settlement.log").write_text("\n".join(LOG) + "\n", encoding="utf-8")


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)


def backend(*args):
    r = subprocess.run([sys.executable, "-I", str(ROOT / "scripts" / "local-backend.py"), *args], capture_output=True,
                       text=True, check=True)
    for line in r.stdout.strip().splitlines():
        log(line)
    return r.stdout


def server(label, expect=None):
    """여행방의 지출·몫·확정 행(값은 가상 자료). 비밀값·토큰은 없다."""
    r = lb.rows(f"""select
        (select revision from public.trips where name = '{TRIP}') as revision,
        (select status from public.trips where name = '{TRIP}') as status,
        (select count(*) from storage.objects o where o.bucket_id = 'receipts'
           and split_part(o.name, '/', 1) = (select id::text from public.trips where name = '{TRIP}')) as objects,
        (select coalesce(json_agg(json_build_object('entry', e.entry, 'merchant', e.merchant, 'amount_minor', e.amount_minor,
           'currency', e.currency, 'status', e.status, 'version', e.version, 'krw_amount', e.krw_amount, 'krw_basis', e.krw_basis,
           'hold_reason', e.hold_reason, 'uploaded_by', ub.display_name, 'payer', pm.display_name,
           'shares', (select json_agg(json_build_object(sm.display_name, s.krw) order by sm.display_name)
                      from public.expense_shares s join public.trip_members sm on sm.trip_id = s.trip_id and sm.user_id = s.user_id
                      where s.expense_id = e.id)) order by e.created_at), '[]'::json)
           from public.expenses e
           join public.trip_members ub on ub.trip_id = e.trip_id and ub.user_id = e.uploaded_by
           left join public.trip_members pm on pm.trip_id = e.trip_id and pm.user_id = e.payer_id
           where e.trip_id = (select id from public.trips where name = '{TRIP}')) as expenses,
        (select count(*) from public.finalizations f join public.trips t on t.id = f.trip_id where t.name = '{TRIP}') as finalizations,
        (select f.id::text from public.finalizations f join public.trips t on t.id = f.trip_id where t.name = '{TRIP}') as finalization_id,
        (select f.snapshot -> 'outputs' from public.finalizations f join public.trips t on t.id = f.trip_id where t.name = '{TRIP}') as outputs
        """, "settlement-e2e-report")[0]
    (OUT / f"server-{label}.json").write_text(json.dumps(r, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    brief = {k: r[k] for k in ("revision", "status", "objects", "finalizations")}
    brief["expenses"] = [(e["merchant"], e["status"]) for e in r["expenses"]]
    log(f"server {label}: {json.dumps(brief, ensure_ascii=False)}")
    if expect:
        expect(r)
    return r


# ---------------------------------------------------------------- iOS
def ios_build():
    log("iOS build-for-testing (Debug, local backend mode)")
    with open(WORK / "ios-build.log", "w") as f:
        run(["xcodebuild", "build-for-testing", "-project", "Nonanona.xcodeproj", "-scheme", "Nonanona",
             "-destination", f"platform=iOS Simulator,id={UDID}", "-derivedDataPath", str(WORK / "dd")],
            cwd=IOS, stdout=f, stderr=subprocess.STDOUT)
    subprocess.run(["xcrun", "simctl", "uninstall", UDID, APP_ID], capture_output=True)
    run(["xcrun", "simctl", "install", UDID, str(WORK / "dd/Build/Products/Debug-iphonesimulator/Nonanona.app")])


def ios_launch():
    env = {"SIMCTL_CHILD_NONANONA_LOCAL_ACCOUNT": "host" if HOST_PLATFORM == "ios" else "member"}
    run(["xcrun", "simctl", "launch", "--terminate-running-process", UDID, APP_ID], env={**__import__("os").environ, **env},
        capture_output=True)
    time.sleep(2)


def ios_kill():
    out = subprocess.run(["xcrun", "simctl", "spawn", UDID, "launchctl", "list"], capture_output=True, text=True).stdout
    pid = next((ln.split()[0] for ln in out.splitlines() if "UIKitApplication:app.nonanona[" in ln and ln.split()[0].isdigit()), None)
    if pid:
        subprocess.run(["kill", "-9", pid])
        log(f"iOS SIGKILL pid {pid}")


def ios_test(name, **env):
    d = Path(tempfile.mkdtemp(dir=WORK, prefix=name + "."))
    log(f"iOS test {name}")
    extra = {f"TEST_RUNNER_{k}": v for k, v in {"EXPECT_LOCAL_BACKEND": "1", **env}.items()}
    with open(d / "test.log", "w") as f:
        r = subprocess.run(["xcodebuild", "test-without-building", "-project", "Nonanona.xcodeproj", "-scheme", "Nonanona",
                            "-destination", f"platform=iOS Simulator,id={UDID}", "-derivedDataPath", str(WORK / "dd"),
                            "-resultBundlePath", str(d / "result.xcresult"),
                            f"-only-testing:NonanonaUITests/SettlementUITests/{name}"],
                           cwd=IOS, stdout=f, stderr=subprocess.STDOUT, env={**__import__("os").environ, **extra})
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
    if r.returncode != 0 or "** TEST EXECUTE SUCCEEDED **" not in text and " passed " not in text:
        for line in text.splitlines():
            if "error:" in line or "failed" in line:
                log("  " + line.strip()[:300])
        raise SystemExit(f"iOS test {name} failed (log: {d / 'test.log'})")
    log(f"iOS test {name} passed")


# ---------------------------------------------------------------- Android
def a_text(id_):
    n = u.find(id=id_)
    return n.text if n else None


def a_texts(id_):
    return " ".join(u.texts_within(id_))


def until(fn, timeout=30, what=""):
    deadline = time.time() + timeout
    while time.time() < deadline:
        v = fn()
        if v:
            return v
        time.sleep(0.5)
    raise AssertionError(f"timed out: {what}")


def hide_keyboard():
    if "mInputShown=true" in u.sh("dumpsys input_method | grep mInputShown", check=False):
        u.back()


def reach(screen, **query):
    """화면(screen) 목록 안에서 위아래로 넘겨 가리지 않는 자리로 가져온다."""
    hide_keyboard()
    for direction in [1] * 8 + [-1] * 16:
        nodes = u.dump()
        hit = u.find(nodes, **query)
        box = u.find(nodes, id=screen)
        top = box.bounds[1] + 150 if box else 0
        bottom = box.bounds[3] - 20 if box else 10**6
        if hit and top <= hit.bounds[1] and hit.bounds[3] <= bottom:
            return hit
        if not box:
            time.sleep(0.5)
            continue
        x1, y1, x2, y2 = box.bounds
        x, a, b = (x1 + x2) // 2, top + (y2 - top) // 4, top + 3 * (y2 - top) // 4
        start, end = (b, a) if direction == 1 else (a, b)
        u.sh(f"input swipe {x} {start} {x} {end} 400")
        time.sleep(0.7)
    raise TimeoutError(f"not reachable in {screen}: {query}")


def type_into(screen, id_, value, ime=True):
    field = reach(screen, id=id_)
    u.tap(field)
    time.sleep(0.8)
    current = until(lambda: u.find(id=id_), 10, f"{id_} visible").text or ""
    u.sh("input keyevent KEYCODE_MOVE_END")
    if current:
        u.sh("input keyevent " + " ".join(["KEYCODE_DEL"] * (len(current) + 2)))
    if ime:
        u.ime_type(value)
    else:
        u.sh("input text " + value)
    until(lambda: (u.find(id=id_).text or "") == value, 10, f"{id_} = {value!r}")


def a_shot(name):
    abase.shot(name)


def a_launch():
    u.sh(f"am start -n {PKG}/.MainActivity")
    time.sleep(2)


def a_install():
    log("Android assembleDebug (local backend mode)")
    with open(WORK / "android-build.log", "w") as f:
        run(["./gradlew", ":app:assembleDebug"], cwd=ANDROID, stdout=f, stderr=subprocess.STDOUT)
    u.adb("uninstall", PKG, check=False)
    u.adb("install", "-r", str(APK))
    u.sh("settings put system font_scale 1.0")
    u.sh("rm -rf /sdcard/Pictures/NonanonaSettle && mkdir -p /sdcard/Pictures/NonanonaSettle")
    for name in NAMES:
        u.adb("push", str(FIXTURES / name), "/sdcard/Pictures/NonanonaSettle/")
        u.sh(f"am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file:///sdcard/Pictures/NonanonaSettle/{name}")
    a_launch()
    account = "host" if HOST_PLATFORM == "android" else "member"
    abase.run_as(f'printf "localAccount={account}\\n" > files/debug-processing.properties')
    u.sh(f"am force-stop {PKG}")
    a_launch()


def a_home():
    for _ in range(5):
        if u.find(id="home_screen"):
            return
        u.back()
    u.wait(id="home_screen", timeout=10)


def a_login(name):
    a_home()
    if u.find(id="home_login"):
        u.tap(u.find(id="home_login"))
        u.tap(u.wait(id="login_google", timeout=15))
    until(lambda: a_texts("account_status") == f"로그인됨 · {name}", 20, "signed in")


def a_open_trip():
    a_home()
    # 방장은 시드 여행방 여러 곳의 구성원이다. 이름으로 그 행을 고른다.
    u.tap(reach("home_screen", text=TRIP))
    u.wait(id="room_screen", timeout=20)


def a_refresh():
    u.tap(u.wait(id="room_refresh", timeout=10))
    time.sleep(1.5)


def a_expense_index(amount):
    """장부에서 원래 금액으로 지출 행(expense_N)을 찾는다(가게 이름은 기기 OCR마다 다르게 읽힐 수 있다)."""
    for i in range(1, 8):
        node = u.find(id=f"expense_{i}")
        if node is None:
            try:
                node = reach("room_screen", id=f"expense_{i}")
            except TimeoutError:
                return None
        if any(amount in t for t in u.texts_within(f"expense_{i}")):
            return i
    return None


def a_open_expense(amount):
    i = until(lambda: a_expense_index(amount), 20, f"expense {amount}")
    u.tap(reach("room_screen", id=f"expense_{i}"))
    u.wait(id="expense_review_screen", timeout=10)


def a_upload(start_id, status_id, expected):
    u.tap(reach("draft_screen", id=start_id))
    u.tap(u.wait(text="올리기", timeout=10))
    until(lambda: a_text(status_id) == expected, 45, f"{status_id} = {expected}")


def a_member_share_confirm_manual():
    abase.share_from_files(NAMES, folder="NonanonaSettle")
    u.tap(u.wait(id="draft_row", timeout=30))
    until(lambda: a_texts("processing_summary") == "읽음 3/3", 120, "all read")
    for position in (1, 2, 3):
        if u.find(id=f"item_{position}_status") is None:
            reach("draft_screen", id=f"item_{position}_status")
        if a_texts(f"item_{position}_status") == "확인 필요":
            u.tap(reach("draft_screen", id=f"item_{position}_debug_confirm"))
            until(lambda: a_texts(f"item_{position}_status") == "확인함", 20, f"item {position} confirmed")
    u.tap(reach("draft_screen", id="open_first_failed"))
    u.wait(id="review_screen", timeout=10)
    type_into("review_screen", "review_merchant", "ticket")
    type_into("review_screen", "review_amount", "38000")
    type_into("review_screen", "review_date", "20261108")
    hide_keyboard()
    u.tap(reach("review_screen", id="review_currency_KRW"))
    a_shot("android-settlement-manual-entry")
    hide_keyboard()
    button = until(lambda: (lambda b: b if b and b.enabled else None)(u.find(id="review_confirm_next")), 10, "confirm enabled")
    u.tap(button)
    u.wait(id="draft_screen", timeout=15)


def a_member_upload():
    a_login("가나")
    a_open_trip()
    u.wait(text="아직 올라온 지출이 없어요.", timeout=15)
    a_home()
    u.tap(u.wait(id="draft_row", timeout=20))
    assert reach("draft_screen", id="upload_destination").text == f"올릴 곳: {TRIP}"
    assert u.find(text="확인한 영수증 2장") and u.find(id="upload_manual_excluded")
    a_upload("upload_start", "upload_status", "올림 2장(이미 올린 0장 포함)")
    u.tap(reach("draft_screen", id="manual_upload_start"))
    u.wait(text=f"‘{TRIP}’에 직접 입력 1건을 올릴까요?", timeout=10)
    a_shot("android-settlement-manual-consent")
    u.tap(u.wait(text="올리기", timeout=10))
    until(lambda: a_text("manual_upload_status") == "올림 1건(이미 올린 0건 포함)", 45, "manual uploaded")
    a_upload("manual_upload_start", "manual_upload_status", "올림 1건(이미 올린 1건 포함)")


def a_member_sees_without_host_actions():
    a_open_trip()
    a_refresh()
    for i in (1, 2, 3):
        reach("room_screen", id=f"expense_{i}")
    a_shot("android-settlement-member-ledger")
    u.tap(reach("room_screen", id=f"expense_{a_expense_index('38,000 KRW')}"))
    time.sleep(1)
    assert not u.find(id="expense_review_screen"), "회원은 지출 검토를 열 수 없다"
    u.tap(reach("room_screen", id="open_settlement"))
    u.wait(id="settlement_status", timeout=15)
    assert not u.find(id="settlement_finalize"), "회원에게는 확정 버튼이 없다"
    a_shot("android-settlement-member-preview")
    u.back()


def stored_artifact():
    """r01 지출의 장부 해시와, 서버 Storage에 실제로 저장된 객체(관리 키로 받음)의 해시. 둘이 같아야 한다."""
    row = lb.rows(f"""select e.artifact_path as path, e.artifact_sha256 as sha from public.expenses e
        join public.trips t on t.id = e.trip_id where t.name = '{TRIP}' and e.amount_minor = 1408""", "settlement-e2e-artifact")[0]
    env = lb.status()
    st, raw = lb.http(env, "GET", "/storage/v1/object/receipts/" + row["path"], key=env["SECRET_KEY"], token=env["SECRET_KEY"])
    assert st == 200, st
    stored = hashlib.sha256(raw).hexdigest()
    assert stored == row["sha"], "stored object differs from the ledger hash"
    (OUT / "receipt-artifact.json").write_text(json.dumps({"ledger_sha256": row["sha"], "stored_object_sha256": stored,
                                                          "bytes": len(raw)}) + "\n")
    log(f"stored masked copy sha256 {stored[:8]}… ({len(raw)} bytes) equals the ledger hash")
    return stored


def a_receipt_view(prefix):
    """방장 검토 화면에서 가림 사본 보기(Android): 확인 해시 = 저장된 사본, 다시 열면 지워짐, 직접 입력은 증빙 없음,
    서버에 닿지 않으면 다시 시도할 수 있는 실패(검토는 그대로), 다시 시도, 큰 글자·가로."""
    a_open_expense("1,408 JPY")
    u.tap(reach("expense_review_screen", id="review_receipt_show"))
    node = until(lambda: u.find(id="review_receipt_verified"), 20, "receipt shown")
    assert node.text == f"올린 사본과 같아요 · 확인 {prefix}", node.text
    image = u.find(id="review_receipt_image")
    assert image and image.desc == "가린 영수증 사본", image
    a_shot("android-settlement-receipt-shown")
    u.back()
    a_open_expense("1,408 JPY")
    assert reach("expense_review_screen", id="review_receipt_show"), "다시 열면 다시 눌러야 받는다"
    assert not u.find(id="review_receipt_image")
    u.back()
    a_open_expense("38,000 KRW")
    assert reach("expense_review_screen", id="review_receipt_none").text == "증빙 없음 · 직접 입력이라 사진이 없어요."
    assert not u.find(id="review_receipt_show")
    u.back()
    a_open_expense("1,408 JPY")
    backend("api-stop")
    try:
        u.tap(reach("expense_review_screen", id="review_receipt_show"))
        node = until(lambda: u.find(id="review_receipt_failure"), 30, "receipt network failure")
        assert node.text == "인터넷에 연결할 수 없어요. 연결을 확인하고 다시 시도해 주세요.", node.text
        assert u.find(id="review_receipt_retry")
        assert reach("expense_review_screen", id="review_payer_1").enabled, "사본을 못 받아도 검토할 수 있다"
        a_shot("android-settlement-receipt-network-failure")
    finally:
        backend("api-start")
    u.tap(reach("expense_review_screen", id="review_receipt_retry"))
    node = until(lambda: u.find(id="review_receipt_verified"), 20, "receipt shown after retry")
    assert node.text.endswith(prefix)
    u.sh("settings put system font_scale 2.0")
    time.sleep(2)
    assert reach("expense_review_screen", id="review_receipt_verified").text.endswith(prefix), "큰 글자에서도 같은 사본"
    a_shot("android-settlement-receipt-large-text")
    u.sh("settings put system font_scale 1.0")
    u.sh("settings put system accelerometer_rotation 0")
    u.sh("settings put system user_rotation 1")
    time.sleep(3)
    assert reach("expense_review_screen", id="review_receipt_verified").text.endswith(prefix), "가로에서도 같은 사본"
    a_shot("android-settlement-receipt-landscape")
    u.sh("settings put system user_rotation 0")
    time.sleep(3)
    u.back()
    u.wait(id="room_screen", timeout=10)
    assert not u.find(id="review_receipt_image")


def a_pick_member(prefix, name):
    for i in (1, 2):
        if name in u.texts_within(f"{prefix}_{i}"):
            u.tap(reach("expense_review_screen", id=f"{prefix}_{i}"))
            return
    raise AssertionError(f"no {prefix} chip for {name}")


def a_host_review():
    a_login("다라")
    a_open_trip()
    a_refresh()
    until(lambda: a_texts("room_pending") == "확인 필요 3건", 15, "3 pending")
    a_shot("android-settlement-host-ledger-pending")
    a_open_expense("1,408 JPY")
    reach("expense_review_screen", id="review_payer_1")
    a_pick_member("review_payer", "다라")
    type_into("expense_review_screen", "review_krw", "13377")
    hide_keyboard()
    assert "1원이 남아요" in (reach("expense_review_screen", id="review_share_problem").text or ""), "odd remainder blocks even split"
    assert not reach("expense_review_screen", id="review_include").enabled
    a_shot("android-settlement-review-not-divisible")
    u.tap(reach("expense_review_screen", id="review_mode_exact"))
    type_into("expense_review_screen", "review_exact_1", "6688")
    type_into("expense_review_screen", "review_exact_2", "6688")
    hide_keyboard()
    assert "1원이 남았어요" in (reach("expense_review_screen", id="review_share_problem").text or "")
    type_into("expense_review_screen", "review_exact_2", "6689")
    hide_keyboard()
    a_shot("android-settlement-review-exact")
    u.tap(reach("expense_review_screen", id="review_include"))
    u.wait(id="room_screen", timeout=15)
    until(lambda: not u.find(id="expense_review_screen"), 15, "review closes")

    a_open_expense("1,276 JPY")
    u.tap(reach("expense_review_screen", id="review_hold"))
    u.tap(u.wait(id="hold_reason_1", timeout=10))
    until(lambda: not u.find(id="expense_review_screen"), 15, "review closes")

    a_open_expense("38,000 KRW")
    assert reach("expense_review_screen", id="review_krw_fixed")
    a_pick_member("review_payer", "다라")
    assert u.wait(text="한 사람 19,000원 · 합계 38,000원", timeout=5)
    u.tap(reach("expense_review_screen", id="review_include"))
    until(lambda: not u.find(id="expense_review_screen"), 15, "review closes")
    u.wait(id="room_screen", timeout=10)
    assert not u.find(id="room_pending")
    a_shot("android-settlement-host-ledger-reviewed")


def a_preview():
    u.tap(reach("room_screen", id="open_settlement"))
    until(lambda: u.texts_within("transfer_1") == ["가나 → 다라", "25,689원"], 15, "transfer 1")
    assert u.texts_within("settlement_total") == ["함께 쓴 돈", "51,377원"]
    assert any("보류: 원화 청구액 확인 대기" in t for t in u.texts_within("excluded_1"))
    a_shot("android-settlement-preview")


def a_finalize_stale_then_ok():
    u.tap(reach("settlement_screen", id="settlement_finalize"))
    u.tap(u.wait(id="finalize_confirm", timeout=10))
    u.wait(id="settlement_refreshed", timeout=15)
    assert u.find(id="settlement_pending")
    assert not reach("settlement_screen", id="settlement_finalize").enabled
    a_shot("android-settlement-finalize-stale")
    u.back()
    u.wait(id="room_screen", timeout=10)
    a_open_expense("5,000 KRW")
    u.tap(reach("expense_review_screen", id="review_hold"))
    u.tap(u.wait(id="hold_reason_2", timeout=10))
    until(lambda: not u.find(id="expense_review_screen"), 15, "review closes")
    u.tap(reach("room_screen", id="open_settlement"))
    until(lambda: (lambda b: b if b and b.enabled else None)(u.find(id="settlement_finalize")), 15, "finalize enabled")
    assert u.texts_within("transfer_1") == ["가나 → 다라", "25,689원"]
    u.tap(u.find(id="settlement_finalize"))
    u.wait(id="finalize_confirm", timeout=10)
    a_shot("android-settlement-finalize-confirm")
    u.tap(u.find(id="finalize_confirm"))
    until(lambda: u.texts_within("settlement_status") == ["정산 확정됨"], 20, "finalized")


def a_final(prefix, shot):
    a_open_trip()
    a_refresh()
    u.wait(id="room_finalized", timeout=20)
    u.tap(reach("room_screen", id="open_settlement"))
    node = u.wait(id="settlement_final_id", timeout=20)
    assert node.text.startswith(f"확정 번호 {prefix}"), node.text
    assert u.texts_within("transfer_1") == ["가나 → 다라", "25,689원"]
    assert not u.find(id="transfer_2")
    assert u.texts_within("settlement_total") == ["함께 쓴 돈", "51,377원"]
    assert not u.find(id="settlement_finalize")
    reach("settlement_screen", id="excluded_2")
    assert any("보류" in t for t in u.texts_within("excluded_1")) and any("보류" in t for t in u.texts_within("excluded_2"))
    a_shot(shot)


# ---------------------------------------------------------------- 흐름
def late_member_expense():
    """방장이 미리보기를 본 뒤 회원 계정이 지출 하나를 더 올린다(실제 HTTP, 앱과 같은 RPC)."""
    env = lb.status()
    accounts = json.loads((lb.RUN / "accounts.json").read_text())
    st, raw = lb.http(env, "POST", "/auth/v1/token?grant_type=password",
                      {"email": accounts["member"][0], "password": accounts["member"][1]})
    token = json.loads(raw)["access_token"]
    trip = lb.rows(f"select id from public.trips where name = '{TRIP}'", "settlement-e2e-trip")[0]["id"]
    st, raw = lb.http(env, "POST", "/rest/v1/rpc/submit_manual_expense",
                      {"p_trip": trip, "p_request_id": str(uuid.uuid4()), "p_expense_date": "2026-11-09",
                       "p_amount_minor": 5000, "p_currency": "KRW", "p_merchant": "late"}, token=token)
    assert st == 200, (st, lb.code_of(raw))
    log("member account added a late manual expense via the same RPC")


def main():
    log(f"host={HOST_PLATFORM} member={MEMBER_PLATFORM} evidence={OUT}")
    backend("reset")
    ios_build()
    run(["xcrun", "simctl", "addmedia", UDID, *[str(FIXTURES / n) for n in NAMES]])
    for _ in range(30):
        if f"{APP_ID}.share" in subprocess.run(["xcrun", "simctl", "spawn", UDID, "pluginkit", "-mA", "-p",
                                                 "com.apple.share-services"], capture_output=True, text=True).stdout:
            break
        time.sleep(1)
    a_install()
    ios_launch()

    # 회원
    if MEMBER_PLATFORM == "ios":
        ios_test("testM1_ShareReceipts")
        ios_launch()
        ios_test("testM2_ConfirmTwoAndEnterOneManually")
        ios_test("testM3_LoginOpenTripUploadReceiptsAndManual")
    else:
        a_member_share_confirm_manual()
        a_member_upload()

    def uploaded(r):
        assert r["objects"] == 2 and len(r["expenses"]) == 3, r
        assert sorted(e["entry"] for e in r["expenses"]) == ["manual", "receipt", "receipt"]
        assert all(e["status"] == "pending" and e["payer"] is None and e["uploaded_by"] == "가나" for e in r["expenses"])
        manual = next(e for e in r["expenses"] if e["entry"] == "manual")
        assert (manual["merchant"], manual["amount_minor"], manual["currency"]) == ("ticket", 38000, "KRW"), manual
    server("after-member-upload", uploaded)

    if MEMBER_PLATFORM == "ios":
        ios_test("testM4_MemberSeesSameExpensesWithoutHostActions")
    else:
        a_member_sees_without_host_actions()

    # 방장
    if HOST_PLATFORM == "ios":
        ios_test("testH1_LoginAndReviewIncludeAndHold")
    else:
        a_host_review()

    def reviewed(r):
        by = {(e["amount_minor"], e["currency"]): e for e in r["expenses"]}
        s = by[(1408, "JPY")]
        assert (s["status"], s["payer"], s["krw_amount"], s["krw_basis"]) == ("included", "다라", 13377, "verified_krw_charge"), s
        assert s["shares"] == [{"가나": 6689}, {"다라": 6688}], s["shares"]
        assert (by[(1276, "JPY")]["status"], by[(1276, "JPY")]["hold_reason"]) == ("held", "원화 청구액 확인 대기")
        t = by[(38000, "KRW")]
        assert (t["status"], t["krw_amount"], t["krw_basis"], t["shares"]) == ("included", 38000, "krw_original",
                                                                               [{"가나": 19000}, {"다라": 19000}]), t
        assert r["status"] == "open" and r["finalizations"] == 0
    before_view = server("after-host-review", reviewed)

    prefix = stored_artifact()[:8]
    if HOST_PLATFORM == "ios":
        ios_test("testH1b_ViewMaskedReceipt", ARTIFACT_SHA_PREFIX=prefix)
        backend("api-stop")
        try:
            ios_test("testH1c_ReceiptNetworkFailureDoesNotBlockReview")
        finally:
            backend("api-start")
        run(["xcrun", "simctl", "ui", UDID, "content_size", "accessibility-extra-extra-extra-large"])
        try:
            ios_test("testH1d_RetryThenLargeTextAndLandscape", ARTIFACT_SHA_PREFIX=prefix)
        finally:
            run(["xcrun", "simctl", "ui", UDID, "content_size", "large"])
    else:
        a_receipt_view(prefix)
    after_view = server("after-receipt-view", reviewed)
    assert after_view["revision"] == before_view["revision"], "사본 보기는 아무것도 쓰지 않는다"

    if HOST_PLATFORM == "ios":
        ios_test("testH2_OpenPreview")
    else:
        a_preview()
    late_member_expense()
    if HOST_PLATFORM == "ios":
        ios_test("testH3_FinalizeStaleThenHoldLateThenFinalize")
    else:
        a_finalize_stale_then_ok()

    def finalized(r):
        assert r["status"] == "finalized" and r["finalizations"] == 1, r
        out = r["outputs"]
        assert out["included_total_krw"] == 51377 and [t["krw"] for t in out["transfers"]] == [25689], out
        assert sorted(x["reason"] for x in out["excluded"]) == ["결제 여부 불명확", "원화 청구액 확인 대기"], out
    final = server("after-finalize", finalized)
    prefix = final["finalization_id"][:8]
    log(f"finalization id prefix {prefix}")

    def both_see_final(tag):
        if HOST_PLATFORM == "ios":
            ios_test("testH4_HostSeesFinalizedSettlement", FINAL_ID_PREFIX=prefix)
            a_final(prefix, f"android-settlement-member-final{tag}")
        else:
            a_final(prefix, f"android-settlement-host-final{tag}")
            ios_test("testM5_MemberSeesFinalizedSettlement", FINAL_ID_PREFIX=prefix)

    both_see_final("")
    # 두 앱을 강제로 끝낸 뒤 다시 연다. 기기는 다시 계산하지 않고 서버의 같은 확정본을 그린다.
    ios_kill()
    pid = u.sh(f"pidof {PKG}", check=False).strip()
    abase.run_as(f"kill -9 {pid}")
    until(lambda: not u.sh(f"pidof {PKG}", check=False).strip(), 10, "android app process gone")
    log(f"Android SIGKILL pid {pid}")
    ios_launch()
    a_launch()
    both_see_final("-after-reopen")
    after = server("after-reopen", finalized)
    assert after["finalization_id"] == final["finalization_id"] and after["outputs"] == final["outputs"]
    assert after["revision"] == final["revision"], "다시 열기는 아무것도 쓰지 않는다"
    (OUT / "outsider-check.json").write_text(backend("outsider-check"))
    log("PASS")


if __name__ == "__main__":
    main()
