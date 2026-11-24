#!/usr/bin/env python3
"""두 기기 품목 나누기 제안 E2E(ADR-0011, 로컬 Supabase 모드, iOS 시뮬레이터 + Android 에뮬레이터, 표준 라이브러리만).

한 기기는 가상 회원(가나, 영수증을 올린 사람), 다른 기기는 가상 방장(다라)이다. 실행마다 새 가상 여행방을 만든다(DB를 지우지 않는다).
1. 올린 회원: 가상 품목 영수증 i01(3,500엔, 2026-11-05) 공유 → 확인 → 로그인 → 여행방에 사본 올리기.
2. 올린 회원: 장부에서 "품목으로 나눠 방장에게 제안" → 품목마다 낼 사람 → 가상 시험 환율 902.15의 예상 금액 31,575원은
   1원이 남아, 고르기 전에는 보낼 수 없음 → 가나에게 → 확인 창(보낼 값과 "품목 … 보내지 않아요") → 보내기, 같은 내용을 다시 동의해 한 번 더.
   서버: 같은 값 제안 2건(다라 20,005·가나 11,570), 지출은 그대로 확인 필요·몫 없음, 방 revision 그대로.
3. 스크립트가 그 지출일 가상 시험 환율을 903.15로 정정 → 방장 검토: "원화 기준이 바뀌어 쓸 수 없어요", 채우기 없음.
   올린 회원 장부: "원화 기준이 바뀌어 … 다시 보내 주세요".
4. 올린 회원: 다시 열면 남은 원 선택이 지워져 있음 → 다라에게 → 31,610원(다라 20,028·가나 11,582)으로 다시 보내기.
5. 방장: 제안(기준·사람마다 제안/입력)을 보고 "직접 나누기에 채우기" → 결제자 다라 → 포함하기. 서버: 포함·예상 기준·몫 = 제안.
6. 스크립트가 방장 계정으로 확정 → 확정본 몫·합계·잔액이 정확하고 제안이 없음. 올린 회원 장부: "같은 몫으로 포함", 제안 단추 없음.
7. 두 앱이 오간 모든 REST/RPC JSON 본문(로그인 본문·헤더 제외)과 서버 DB 전체(pg_dump 데이터)에 품목 글자가 없고,
   제안 요청 본문은 허용한 키뿐이며 동의한 보내기마다 요청 키가 새롭다(같은 내용을 다시 동의해도 새 행, 가장 최근은 같은 값).
끝에 그 지출일 가상 시험 환율을 902.15로 되돌린다.

두 앱의 백엔드 주소는 빌드할 때 정해진다. 빌드하는 동안만 앱 설정 파일(gitignore)의 포트를 기록 프록시(54399)로 바꾸고 곧 되돌린다.

사전 조건: mise run local:up, 부팅한 iOS 시뮬레이터, 실행 중인 Android 에뮬레이터(여럿이면 ANDROID_SERIAL로 고른다).
사용: python3 -I scripts/e2e-proposals.py <iOS 시뮬레이터 UDID> <올린 회원 기기: ios|android> [증거 폴더]
"""

import datetime
import http.client
import http.server
import importlib.util
import json
import os
import re
import secrets
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UDID, UPLOADER = sys.argv[1], sys.argv[2]
assert UPLOADER in ("ios", "android")
HOST_PLATFORM = "android" if UPLOADER == "ios" else "ios"
OUT = Path(sys.argv[3]) if len(sys.argv) > 3 else Path(tempfile.mkdtemp(prefix="nonanona-proposals-"))
WORK = Path(tempfile.mkdtemp(prefix="nonanona-proposals-work-"))
(OUT / "screens").mkdir(parents=True, exist_ok=True)
IOS = ROOT / "apps" / "ios"
ANDROID = ROOT / "apps" / "android"
APK = ANDROID / "app" / "build" / "outputs" / "apk" / "debug" / "app-debug.apk"
FIXTURES = ROOT / "apps" / "fixtures" / "items"
APP_ID = "app.nonanona"
TRIP = "가상 제안 E2E " + secrets.token_hex(3)
DAY = "2026-11-05"
PROXY_PORT = 54399
LOG = []
# 어디에도(오간 본문·서버 DB) 있으면 안 되는 글자: i01 품목 이름(OCR 원문, 실제 OCR이 다르게 읽은 글자 포함), 번역 이름.
ITEM_WORDS = ["枝豆", "唐揚げ", "唐場げ", "生ビール", "ウーロン茶", "だし巻き", "玉子", "풋콩", "닭튀김", "생맥주", "우롱차",
              "달걀말이", "(미리보기)"]
# 기기 안 품목 계획 파일의 키(두 앱). 오간 본문에 있으면 계획이 새어 나간 것이다.
PLAN_KEYS = ["originalText", "originalName", "amountText", "sourceLineIDs", "sourceLineIds", "nameSource", "assignees"]
FORBIDDEN = ITEM_WORDS + PLAN_KEYS
ALLOWED_PROPOSE_KEYS = {"p_expense", "p_expected_version", "p_request_id", "p_krw_basis", "p_krw_total", "p_fx_quote_id",
                        "p_shares"}

sys.argv = [sys.argv[0], str(APK), str(OUT)]
sys.path.insert(0, str(ANDROID / "scripts"))
import adbui as u  # noqa: E402
import e2e as abase  # noqa: E402


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / file)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


lb = load("local_backend", "local-backend.py")
sc = load("settlement_contract", "settlement-contract.py")
fx = load("ecos_fx", "ecos-fx.py")
PKG = abase.PKG


def log(msg):
    line = time.strftime("[%H:%M:%S] ") + msg
    print(line, flush=True)
    LOG.append(line)
    (OUT / f"e2e-proposals-{UPLOADER}-uploader.log").write_text("\n".join(LOG) + "\n", encoding="utf-8")


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)


def until(fn, timeout=30, what=""):
    deadline = time.time() + timeout
    while time.time() < deadline:
        v = fn()
        if v:
            return v
        time.sleep(0.5)
    raise AssertionError(f"timed out: {what}")


# ---------------------------------------------------------------- 기록 프록시(로컬 Supabase 앞)
TRAFFIC = []
TRAFFIC_LOCK = threading.Lock()


class Proxy(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _forward(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        conn = http.client.HTTPConnection("127.0.0.1", 54321, timeout=60)
        headers = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "connection", "accept-encoding")}
        conn.request(self.command, self.path, body=body, headers=headers)
        r = conn.getresponse()
        data = r.read()
        self.send_response(r.status)
        for k, v in r.getheaders():
            if k.lower() not in ("transfer-encoding", "connection", "content-length"):
                self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        conn.close()
        self._record(body, r, data)

    def _record(self, body, r, data):
        path = self.path.split("?", 1)[0]
        ua = (self.headers.get("User-Agent") or "").lower()
        client = "android" if ("dalvik" in ua or "okhttp" in ua) else "ios" if ("cfnetwork" in ua or "darwin" in ua) else "other"
        entry = {"method": self.command, "path": path, "status": r.status, "client": client}
        # 로그인·토큰 본문(비밀번호·토큰)과 모든 헤더는 남기지 않는다. 사본 PNG는 길이만.
        if path.startswith("/auth/"):
            entry["note"] = "auth body omitted"
        elif path.startswith("/storage/"):
            entry["request_bytes"], entry["response_bytes"] = len(body), len(data)
        else:
            entry["request"] = body.decode("utf-8", "replace")
            entry["response"] = data.decode("utf-8", "replace")
        with TRAFFIC_LOCK:
            TRAFFIC.append(entry)

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = _forward


def start_proxy():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PROXY_PORT), Proxy)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    log(f"recording proxy on 127.0.0.1:{PROXY_PORT} -> 54321")
    return server


def with_proxy_configs(build):
    """빌드하는 동안만 앱 설정의 포트를 프록시로 바꾼다(파일은 gitignore, 값은 출력하지 않는다)."""
    files = [lb.ANDROID_CONFIG, lb.IOS_CONFIG]
    saved = {f: f.read_text(encoding="utf-8") for f in files}
    try:
        for f, text in saved.items():
            assert ":54321" in text, f"{f.name} should point at the local stack"
            f.write_text(text.replace(":54321", f":{PROXY_PORT}"), encoding="utf-8")
        build()
    finally:
        for f, text in saved.items():
            f.write_text(text, encoding="utf-8")
            os.chmod(f, 0o600)
        log("app configs restored")


# ---------------------------------------------------------------- 서버
def set_fx(rate):
    ok, res = fx.ingest_fixture(fx.ecos_shape({DAY: rate}), datetime.date.fromisoformat(DAY), datetime.date.fromisoformat(DAY))
    assert ok, res
    log(f"synthetic fixture rate for {DAY}: {rate}")


def new_trip(host_uid, member_uid):
    rows = lb.rows(f"""with t as (insert into public.trips (name, host_id) values ('{TRIP}', '{host_uid}') returning id),
        m as (insert into public.trip_members (trip_id, user_id, role, display_name, joined_at)
              select t.id, '{host_uid}'::uuid, 'host', '다라', now() - interval '1 minute' from t
              union all select t.id, '{member_uid}'::uuid, 'member', '가나', now() from t returning trip_id)
        select (select id from t) as id""", "proposal-e2e-trip")
    return rows[0]["id"]


def server(label, trip, expect=None):
    r = lb.rows(f"""select
        (select revision from public.trips where id = '{trip}') as revision,
        (select status from public.trips where id = '{trip}') as status,
        (select coalesce(json_agg(json_build_object('amount_minor', e.amount_minor, 'currency', e.currency, 'status', e.status,
           'version', e.version, 'krw_amount', e.krw_amount, 'krw_basis', e.krw_basis, 'fx_rate', e.fx_rate::text,
           'uploaded_by', ub.display_name, 'payer', pm.display_name,
           'shares', (select json_object_agg(sm.display_name, s.krw) from public.expense_shares s
                      join public.trip_members sm on sm.trip_id = s.trip_id and sm.user_id = s.user_id where s.expense_id = e.id))),
           '[]'::json)
           from public.expenses e join public.trip_members ub on ub.trip_id = e.trip_id and ub.user_id = e.uploaded_by
           left join public.trip_members pm on pm.trip_id = e.trip_id and pm.user_id = e.payer_id where e.trip_id = '{trip}') as expenses,
        (select coalesce(json_agg(json_build_object('version', p.expense_version, 'basis', p.krw_basis, 'total', p.krw_total,
           'by', pb.display_name, 'request_id', p.request_id,
           'shares', (select json_object_agg(lm.display_name, l.krw) from public.expense_share_proposal_lines l
                      join public.trip_members lm on lm.trip_id = l.trip_id and lm.user_id = l.user_id where l.proposal_id = p.id))
           order by p.seq), '[]'::json)
           from public.expense_share_proposals p join public.trip_members pb on pb.trip_id = p.trip_id and pb.user_id = p.proposed_by
           where p.trip_id = '{trip}') as proposals,
        (select f.snapshot from public.finalizations f where f.trip_id = '{trip}') as snapshot
        """, "proposal-e2e-report")[0]
    (OUT / f"server-{UPLOADER}-uploader-{label}.json").write_text(json.dumps(r, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    brief = {"revision": r["revision"], "status": r["status"],
             "expenses": [(e["status"], e["krw_amount"], e["shares"]) for e in r["expenses"]],
             "proposals": [(p["total"], p["shares"]) for p in r["proposals"]]}
    log(f"server {label}: {json.dumps(brief, ensure_ascii=False)}")
    if expect:
        expect(r)
    return r


def no_item_text_anywhere():
    dump = subprocess.run(["docker", "exec", sc.DB_CONTAINER, "pg_dump", "-U", "postgres", "--data-only", "--no-owner",
                           "--exclude-schema=supabase_migrations", "postgres"],
                          capture_output=True, check=True).stdout.decode("utf-8", errors="replace")
    db_hits = {w: dump.count(w) for w in ITEM_WORDS if w in dump}
    assert "架空居酒屋" in dump, "control: the allowed merchant field is in the dump"
    with TRAFFIC_LOCK:
        traffic = list(TRAFFIC)
    (OUT / f"traffic-{UPLOADER}-uploader.json").write_text(json.dumps(traffic, ensure_ascii=False, indent=1) + "\n",
                                                          encoding="utf-8")
    text_hits = {}
    for t in traffic:
        for side in ("request", "response"):
            for w in FORBIDDEN:
                if w in t.get(side, ""):
                    text_hits.setdefault(w, []).append(f"{t['method']} {t['path']} {side}")
    proposes = [json.loads(t["request"]) for t in traffic if t["path"] == "/rest/v1/rpc/propose_expense_shares"]
    keys_ok = all(set(p) == ALLOWED_PROPOSE_KEYS and all(set(s) == {"user_id", "krw"} for s in p["p_shares"]) for p in proposes)
    rpc_paths = sorted({t["path"] for t in traffic if t["path"].startswith("/rest/")})
    result = {"db_dump_bytes": len(dump), "db_item_text_hits": db_hits, "traffic_entries": len(traffic),
              "traffic_item_text_hits": text_hits, "propose_requests": len(proposes), "propose_keys_only_allowed": keys_ok,
              "propose_request_ids": [p["p_request_id"] for p in proposes], "rest_paths_seen": rpc_paths,
              "clients": sorted({t["client"] for t in traffic})}
    (OUT / f"no-item-text-{UPLOADER}-uploader.json").write_text(json.dumps(result, ensure_ascii=False, indent=1) + "\n")
    log(f"traffic {len(traffic)} entries, item text hits {text_hits}; db dump {len(dump)} bytes, hits {db_hits}; "
        f"propose requests {len(proposes)} keys-only {keys_ok}")
    assert not db_hits and not text_hits and keys_ok, result
    # 보내기 단계마다 같은 내용을 두 번 동의해 보낸다. 동의한 보내기마다 새 요청 키다(불확실한 재시도만 같은 키, 단위 시험).
    ids = [p["p_request_id"] for p in proposes]
    assert len(ids) == 4 and len(set(ids)) == 4, ids
    clients = {t["client"] for t in traffic}
    assert {"ios", "android"} <= clients, f"both apps went through the recording proxy: {clients}"
    assert "/rest/v1/rpc/propose_expense_shares" in rpc_paths and "/rest/v1/rpc/get_room_ledger" in rpc_paths


# ---------------------------------------------------------------- iOS
def ios_build():
    log("iOS build-for-testing (Debug, local backend mode through the recording proxy)")
    with open(WORK / "ios-build.log", "w") as f:
        run(["xcodebuild", "build-for-testing", "-project", "Nonanona.xcodeproj", "-scheme", "Nonanona",
             "-destination", f"platform=iOS Simulator,id={UDID}", "-derivedDataPath", str(WORK / "dd")],
            cwd=IOS, stdout=f, stderr=subprocess.STDOUT)


def ios_install():
    subprocess.run(["xcrun", "simctl", "uninstall", UDID, APP_ID], capture_output=True)
    run(["xcrun", "simctl", "install", UDID, str(WORK / "dd/Build/Products/Debug-iphonesimulator/Nonanona.app")])


def ios_launch(account):
    env = {"SIMCTL_CHILD_NONANONA_LOCAL_ACCOUNT": account}
    run(["xcrun", "simctl", "launch", "--terminate-running-process", UDID, APP_ID], env={**os.environ, **env}, capture_output=True)
    time.sleep(2)


def ios_test(name, **values):
    d = Path(tempfile.mkdtemp(dir=WORK, prefix=name + "."))
    log(f"iOS test {name}")
    extra = {f"TEST_RUNNER_{k}": v for k, v in {"EXPECT_LOCAL_BACKEND": "1", "P_TRIP": TRIP, **values}.items()}
    with open(d / "test.log", "w") as f:
        r = subprocess.run(["xcodebuild", "test-without-building", "-project", "Nonanona.xcodeproj", "-scheme", "Nonanona",
                            "-destination", f"platform=iOS Simulator,id={UDID}", "-derivedDataPath", str(WORK / "dd"),
                            "-resultBundlePath", str(d / "result.xcresult"),
                            f"-only-testing:NonanonaUITests/ProposalUITests/{name}"],
                           cwd=IOS, stdout=f, stderr=subprocess.STDOUT, env={**os.environ, **extra})
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
    if r.returncode != 0 or " passed " not in text:
        for line in text.splitlines():
            if "error:" in line or "failed" in line:
                log("  " + line.strip()[:400])
        raise SystemExit(f"iOS test {name} failed (log: {d / 'test.log'})")
    log(f"iOS test {name} passed")


# ---------------------------------------------------------------- Android
def a_text(id_):
    n = u.find(id=id_)
    return n.text if n else None


def a_texts(id_):
    return " ".join(u.texts_within(id_))


def hide_keyboard():
    if "mInputShown=true" in u.sh("dumpsys input_method | grep mInputShown", check=False):
        u.back()


def reach(screen, **query):
    hide_keyboard()
    for direction in [1] * 12 + [-1] * 24:
        nodes = u.dump()
        hit = u.find(nodes, **query)
        box = u.find(nodes, id=screen)
        top = box.bounds[1] + 300 if box else 0
        bottom = box.bounds[3] - 20 if box else 10**6
        if hit and top <= hit.bounds[1] and hit.bounds[3] <= bottom:
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


def selected(tag):
    out = u.sh("uiautomator dump /sdcard/ui.xml >/dev/null 2>&1; cat /sdcard/ui.xml", check=False)
    m = re.search(r'<node[^>]*resource-id="' + re.escape(tag) + r'"[^>]*>', out)
    return bool(m and ('selected="true"' in m.group(0) or 'checked="true"' in m.group(0)))


def type_into(screen, id_, value):
    for _ in range(3):
        u.tap(reach(screen, id=id_))
        time.sleep(1.0)
        if "mInputShown=true" in u.sh("dumpsys input_method | grep mInputShown", check=False):
            break
        hide_keyboard()
    current = until(lambda: u.find(id=id_), 10, f"{id_} visible").text or ""
    u.sh("input keyevent KEYCODE_MOVE_END")
    if current:
        u.sh("input keyevent " + " ".join(["KEYCODE_DEL"] * (len(current) + 2)))
    u.sh(f"input text '{value}'")
    time.sleep(0.5)
    hide_keyboard()
    assert (reach(screen, id=id_).text or "") == value


def a_launch():
    u.sh(f"am start -n {PKG}/.MainActivity")
    time.sleep(2.5)


def a_account(account):
    lines = "localAccount=host\\n" if account == "host" else ""
    abase.run_as(f'printf "{lines}" > files/debug-processing.properties')
    u.sh(f"am force-stop {PKG}")
    a_launch()
    log(f"Android launch as {account}")


def a_build():
    log("Android assembleDebug (local backend mode through the recording proxy)")
    with open(WORK / "android-build.log", "w") as f:
        run(["./gradlew", ":app:assembleDebug"], cwd=ANDROID, stdout=f, stderr=subprocess.STDOUT)


def a_install():
    u.adb("uninstall", PKG, check=False)
    u.adb("install", "-r", str(APK))
    u.sh("settings put system font_scale 1.0")
    u.sh("rm -rf /sdcard/Pictures/NonanonaProposal && mkdir -p /sdcard/Pictures/NonanonaProposal")
    u.adb("push", str(FIXTURES / "receipt-i01.png"), "/sdcard/Pictures/NonanonaProposal/")
    u.sh("am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file:///sdcard/Pictures/NonanonaProposal/receipt-i01.png")
    a_launch()


def a_shot(name):
    abase.shot(name)


def a_home():
    for _ in range(6):
        if u.find(id="home_screen"):
            return
        u.back()
        time.sleep(0.5)
    u.wait(id="home_screen", timeout=10)


def a_login(name):
    a_home()
    if u.find(id="home_login"):
        u.tap(u.find(id="home_login"))
        u.tap(u.wait(id="login_google", timeout=15))
    until(lambda: a_texts("account_status") == f"로그인됨 · {name}", 20, "signed in")


def a_open_trip(name):
    a_login(name)
    a_home()
    u.tap(reach("home_screen", text=TRIP))
    u.wait(id="room_screen", timeout=20)
    u.tap(u.wait(id="room_refresh", timeout=10))
    time.sleep(1.5)


def a_upload():
    a_account("member")
    abase.share_from_files(["receipt-i01.png"], folder="NonanonaProposal")
    # 가상 여행방이 많으면 초안 줄이 홈 목록 아래에 있다. 넘겨서 찾는다.
    until(lambda: u.find(id="home_screen"), 30, "home after share")
    u.tap(reach("home_screen", id="draft_row"))
    until(lambda: a_texts("processing_summary") == "읽음 1/1", 120, "read")
    u.tap(reach("draft_screen", id="item_1_debug_confirm"))
    until(lambda: a_texts("item_1_status") == "확인함", 20, "confirmed")
    a_open_trip("가나")
    a_home()
    u.tap(reach("home_screen", id="draft_row"))
    assert reach("draft_screen", id="upload_destination").text == f"올릴 곳: {TRIP}"
    u.tap(reach("draft_screen", id="upload_start"))
    u.tap(u.wait(text="올리기", timeout=10))
    until(lambda: a_text("upload_status") == "올림 1장(이미 올린 0장 포함)", 45, "uploaded")


def a_chip(screen, prefix, name):
    for i in (1, 2, 3):
        if name in u.texts_within(f"{prefix}_{i}"):
            return reach(screen, id=f"{prefix}_{i}")
    raise AssertionError(f"no {prefix} chip for {name}")


def a_person_on(line, name):
    reach("item_split_screen", id=f"item_{line}_person_1")
    for i in (1, 2):
        tag = f"item_{line}_person_{i}"
        if name in u.texts_within(tag):
            if not selected(tag):
                u.tap(reach("item_split_screen", id=tag))
                until(lambda: selected(tag), 5, f"{tag} on")
            return
    raise AssertionError(f"no person chip {line} {name}")


def a_send(consent):
    u.tap(reach("item_split_screen", id="items_propose"))
    u.wait(text="방장에게 제안을 보낼까요?", timeout=10)
    body = " ".join(n.text for n in u.dump() if n.text)
    assert "품목 이름·품목 금액·영수증 글자는 보내지 않아요" in body and consent in body, body
    # Compose 대화 상자는 따로 창이라 testTag가 resource-id로 드러나지 않는다(올리기 확인 창과 같이 글자로 찾는다).
    u.tap(u.wait(text="보내기", timeout=5))
    until(lambda: u.find(id="items_proposal_sent") or reach("item_split_screen", id="items_proposal_sent"), 20, "sent")


def a_propose(basis, remainder, preview, consent, shot):
    a_open_trip("가나")
    u.tap(reach("room_screen", id="propose_items_1"))
    u.wait(id="item_split_screen", timeout=15)
    assert "방장에게는 사람마다 부담 금액(원)만" in reach("item_split_screen", id="items_privacy").text
    assert basis in reach("item_split_screen", id="items_proposal_basis").text
    for line in ("ocr-4", "ocr-6", "ocr-12"):
        a_person_on(line, "가나")
        a_person_on(line, "다라")
    a_person_on("ocr-8", "다라")
    amount = reach("item_split_screen", id="item_ocr-8_amount").text
    if amount != "1320":
        # 실제 OCR(ML Kit)이 ¥를 4로 읽는 경우: 올린 사람이 금액을 고치면 확인한 것으로 본다(ADR-0010 대가).
        type_into("item_split_screen", "item_ocr-8_amount", "1320")
    elif u.find(id="item_ocr-8_check"):
        u.tap(reach("item_split_screen", id="item_ocr-8_check"))
    a_person_on("ocr-10", "가나")
    assert "남은 원을 낼 사람을 골라 주세요. 저절로 정하지 않아요." in reach("item_split_screen", id="items_remainder").text
    assert not reach("item_split_screen", id="items_propose").enabled, "cannot send before the remainder is chosen"
    a_shot(f"android-proposal-remainder-unchosen-{shot}")
    for i in (1, 2):
        tag = f"items_remainder_{i}"
        if a_texts(tag).startswith(remainder) or remainder in a_texts(tag).split("이(가)")[0]:
            u.tap(reach("item_split_screen", id=tag))
            break
    got = until(lambda: a_text("items_proposal_preview"), 5, "preview")
    assert got == preview, got
    a_shot(f"android-proposal-ready-{shot}")
    a_send(consent)
    a_send(consent)
    state = reach("item_split_screen", id="items_proposal_state").text
    assert state == "보낸 제안: 방장 확인을 기다려요.", state
    a_shot(f"android-proposal-sent-{shot}")


def a_uploader_state(expected, no_propose=False, shot="state"):
    a_open_trip("가나")
    until(lambda: (reach("room_screen", id="expense_proposal_1").text == expected), 15, "uploader state")
    if no_propose:
        assert not u.find(id="propose_items_1")
    a_shot(f"android-proposal-uploader-{shot}")


def a_open_review():
    a_open_trip("다라")
    u.tap(reach("room_screen", id="expense_1"))
    u.wait(id="expense_review_screen", timeout=10)


def a_host_stale(expected):
    a_open_review()
    assert reach("expense_review_screen", id="review_proposal_state").text == expected
    assert not u.find(id="review_proposal_fill")
    a_shot("android-proposal-host-stale")
    a_home()


def a_host_fill_include(host_basis, rows):
    a_open_review()
    state = reach("expense_review_screen", id="review_proposal_state").text
    assert state.startswith("지금 지출 값에 맞는 제안이에요."), state
    assert host_basis in reach("expense_review_screen", id="review_proposal_basis").text
    for i, expected in enumerate(rows, 1):
        reach("expense_review_screen", id=f"review_proposal_row_{i}")
        assert expected in a_texts(f"review_proposal_row_{i}"), (i, expected, a_texts(f"review_proposal_row_{i}"))
    a_shot("android-proposal-host-current")
    u.tap(reach("expense_review_screen", id="review_proposal_fill"))
    until(lambda: (reach("expense_review_screen", id="review_proposal_match").text == "입력한 몫이 제안과 같아요."), 10, "match")
    reach("expense_review_screen", id="review_payer_1")
    u.tap(a_chip("expense_review_screen", "review_payer", "다라"))
    assert reach("expense_review_screen", id="review_include").enabled
    a_shot("android-proposal-host-filled")
    u.tap(reach("expense_review_screen", id="review_include"))
    u.wait(id="room_screen", timeout=15)
    until(lambda: not u.find(id="expense_review_screen"), 15, "review closes")


# ---------------------------------------------------------------- 시나리오
FIRST = {"basis": "예상 금액 31,575원", "remainder": "가나", "preview": "보낼 몫: 다라 20,005원 · 가나 11,570원",
         "consent": "다라 20,005원, 가나 11,570원 (합계 31,575원, 기준환율 예상 금액)"}
SECOND = {"basis": "예상 금액 31,610원", "remainder": "다라", "preview": "보낼 몫: 다라 20,028원 · 가나 11,582원",
          "consent": "다라 20,028원, 가나 11,582원 (합계 31,610원, 기준환율 예상 금액)"}
STALE_HOST = "제안 뒤 원화 기준(기준환율)이 바뀌어 쓸 수 없어요. 올린 사람이 다시 보내야 해요."
STALE_UPLOADER = "보낸 제안: 원화 기준(기준환율)이 바뀌어 방장이 쓸 수 없어요. 새 값으로 다시 보내 주세요."
APPLIED_UPLOADER = "보낸 제안과 같은 몫으로 방장이 포함했어요."


def uploader_upload():
    if UPLOADER == "ios":
        ios_launch("member")
        ios_test("testU1_ShareI01")
        ios_launch("member")
        ios_test("testU2_ConfirmLoginUpload")
    else:
        a_upload()


def uploader_propose(v, shot):
    if UPLOADER == "ios":
        ios_launch("member")
        ios_test("testU3_ProposeWithExplicitRemainder", P_BASIS=v["basis"], P_REMAINDER=v["remainder"],
                 P_PREVIEW=v["preview"], P_CONSENT=v["consent"])
    else:
        a_account("member")
        a_propose(v["basis"], v["remainder"], v["preview"], v["consent"], shot)


def uploader_state(expected, no_propose=False, shot="state"):
    if UPLOADER == "ios":
        ios_launch("member")
        ios_test("testU4_UploaderSeesState", P_STATE=expected, P_NO_PROPOSE="1" if no_propose else "0", P_SHOT=shot)
    else:
        a_account("member")
        a_uploader_state(expected, no_propose, shot)


def host_stale():
    if HOST_PLATFORM == "ios":
        ios_launch("host")
        ios_test("testH1_HostSeesStaleProposal", P_STATE=STALE_HOST)
    else:
        a_account("host")
        a_host_stale(STALE_HOST)


def host_fill_include():
    rows = ["제안 20,028원", "제안 11,582원"]
    if HOST_PLATFORM == "ios":
        ios_launch("host")
        ios_test("testH2_HostFillsConfirmsAndIncludes", P_HOST_BASIS="예상 금액 31,610원(기준환율)", P_ROWS=";".join(rows))
    else:
        a_account("host")
        a_host_fill_include("예상 금액 31,610원(기준환율)", rows)


def main():
    log(f"uploader={UPLOADER} host={HOST_PLATFORM} trip={TRIP} evidence={OUT} android={os.environ.get('ANDROID_SERIAL', '-')}")
    env = lb.status()
    accounts = json.loads((lb.RUN / "accounts.json").read_text())
    # 로컬 스택의 JWT는 30초짜리다(앱의 갱신 경로를 시험하려고). 서버 쪽 호출마다 새로 로그인한다.
    class Fresh:
        def __init__(self, key):
            self.key = key
            self.uid = sc.Client(env, *accounts[key]).uid

        def rpc(self, name, **params):
            st, body, raw = sc.Client(env, *accounts[self.key]).rpc(name, **params)
            if name == "get_room_ledger":
                assert st == 200, (name, st, body)
            return st, body, raw

    host, member = Fresh("host"), Fresh("member")
    set_fx("902.15")
    trip = new_trip(host.uid, member.uid)
    proxy = start_proxy()
    try:
        with_proxy_configs(lambda: (ios_build(), a_build()))
        ios_install()
        run(["xcrun", "simctl", "addmedia", UDID, str(FIXTURES / "receipt-i01.png")])
        for _ in range(30):
            if f"{APP_ID}.share" in subprocess.run(["xcrun", "simctl", "spawn", UDID, "pluginkit", "-mA", "-p",
                                                     "com.apple.share-services"], capture_output=True, text=True).stdout:
                break
            time.sleep(1)
        a_install()

        uploader_upload()
        def uploaded(r):
            assert [(e["status"], e["uploaded_by"], e["shares"]) for e in r["expenses"]] == [("pending", "가나", None)], r
        base = server("uploaded", trip, uploaded)
        uploader_propose(FIRST, "first")

        def first_sent(r):
            # 같은 내용을 두 번 동의해 보냈다: 행 둘(같은 값), 가장 최근도 같은 값.
            assert [(p["total"], p["shares"], p["basis"], p["by"]) for p in r["proposals"]] == [
                (31575, {"다라": 20005, "가나": 11570}, "reference_rate_estimate", "가나")] * 2, r["proposals"]
            e = r["expenses"][0]
            assert (e["status"], e["shares"], e["krw_amount"]) == ("pending", None, None), e
            assert r["revision"] == base["revision"], "a proposal does not bump the room revision"
        server("first-proposal", trip, first_sent)

        set_fx("903.15")
        led = {e["expense_id"]: e for e in host.rpc("get_room_ledger", p_trip=trip)[1]["expenses"]}
        assert [e["share_proposal"]["state"] for e in led.values()] == ["stale_basis"], led
        host_stale()
        uploader_state(STALE_UPLOADER, shot="stale")
        uploader_propose(SECOND, "second")
        def second_sent(r):
            assert [p["total"] for p in r["proposals"]] == [31575, 31575, 31610, 31610], r["proposals"]
            assert r["proposals"][-1]["shares"] == {"다라": 20028, "가나": 11582}, r["proposals"]
            assert r["expenses"][0]["status"] == "pending" and r["expenses"][0]["shares"] is None
        server("second-proposal", trip, second_sent)

        host_fill_include()

        def included(r):
            e = r["expenses"][0]
            assert (e["status"], e["payer"], e["krw_amount"], e["krw_basis"], e["fx_rate"]) == (
                "included", "다라", 31610, "reference_rate_estimate", "903.15"), e
            assert e["shares"] == {"다라": 20028, "가나": 11582}, e["shares"]
        server("included", trip, included)
        led = host.rpc("get_room_ledger", p_trip=trip)[1]
        assert led["expenses"][0]["share_proposal"]["state"] == "applied", led["expenses"][0]["share_proposal"]
        uploader_state(APPLIED_UPLOADER, shot="applied")

        pv = host.rpc("preview_settlement", p_trip=trip)[1]
        assert pv["ready"], pv
        st, f, _ = host.rpc("finalize_settlement", p_trip=trip, p_expected_revision=pv["revision"], p_request_id=str(uuid.uuid4()))
        assert st == 200, (st, f)
        log("host finalized through the API")

        def finalized(r):
            snap = r["snapshot"]
            text = json.dumps(snap, ensure_ascii=False)
            assert "proposal" not in text, "snapshot has no proposal data"
            [x] = snap["inputs"]["expenses"]
            assert sorted(s["krw"] for s in x["shares"]) == [11582, 20028] and x["krw_amount"] == 31610
            assert snap["outputs"]["included_total_krw"] == 31610 and sum(b["net_krw"] for b in snap["outputs"]["balances"]) == 0
            assert [t["krw"] for t in snap["outputs"]["transfers"]] == [11582], snap["outputs"]["transfers"]
        server("finalized", trip, finalized)
        st, code, _ = member.rpc("propose_expense_shares", p_expense=led["expenses"][0]["expense_id"],
                                 p_expected_version=led["expenses"][0]["version"], p_request_id=str(uuid.uuid4()),
                                 p_krw_basis="reference_rate_estimate", p_krw_total=31610,
                                 p_fx_quote_id=led["expenses"][0]["fx"]["quote_id"],
                                 p_shares=[{"user_id": host.uid, "krw": 20028}, {"user_id": member.uid, "krw": 11582}])
        assert st == 409 and code == "trip_finalized", (st, code)
        uploader_state(APPLIED_UPLOADER, no_propose=True, shot="finalized")
        no_item_text_anywhere()
    finally:
        proxy.shutdown()
        set_fx("902.15")
    log("PASS")


if __name__ == "__main__":
    main()
