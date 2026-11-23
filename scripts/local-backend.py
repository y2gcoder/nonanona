#!/usr/bin/env python3
"""로컬 Supabase(Docker)와 앱의 로컬 debug 모드 설정을 다룬다. Python 표준 라이브러리만 쓴다.

사용(저장소 루트, mise 환경에서):
  python3 -I scripts/local-backend.py up            스택 시작 + reset
  python3 -I scripts/local-backend.py reset         DB 초기화 → 가상 계정 → 가상 여행방·초대 → 앱 설정 파일
  python3 -I scripts/local-backend.py down          스택 정지 + 앱 설정 파일 삭제(앱은 테스트 모드로 돌아간다)
  python3 -I scripts/local-backend.py api-stop|api-start   API 게이트웨이만 멈추고 다시 띄운다(연결 실패 재현)
  python3 -I scripts/local-backend.py revoke-sessions      가상 회원 계정의 서버 세션을 지운다(세션 만료 재현)
  python3 -I scripts/local-backend.py report               가상 회원 계정의 참여·초대 사용 수(비밀값 없음)
  python3 -I scripts/local-backend.py upload-report        올린 객체·지출 행 수와 지출 열 이름(비밀값·ID 없음)
  python3 -I scripts/local-backend.py fetch-artifact <파일> 올린 가림 사본을 관리자 권한으로 내려받는다(검사용)
  python3 -I scripts/local-backend.py fetch-artifacts <폴더> 올린 사본을 모두 <폴더>/<해시>.png로 내려받는다(검사용)
  python3 -I scripts/local-backend.py membership-remove|membership-restore   회원을 "가상 오사카 여행"에서 빼고 되돌린다
  python3 -I scripts/local-backend.py outsider-check       구성원이 아닌 가상 계정이 지출·객체에 닿지 못하는지 확인

키, 토큰, 가상 계정 비밀번호는 화면에 내지 않는다. CLI 출력은 supabase/.run/(gitignore, 권한 700)에만 남기고,
앱이 읽을 값은 gitignore된 apps/android/local-backend.properties, apps/ios/Config/Local.xcconfig에만 쓴다.
"""

import json
import os
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUN = ROOT / "supabase" / ".run"
ANDROID_CONFIG = ROOT / "apps" / "android" / "local-backend.properties"
IOS_CONFIG = ROOT / "apps" / "ios" / "Config" / "Local.xcconfig"
FIXTURE = ROOT / "supabase" / "fixtures" / "local-trip-invites.sql"
PROJECT_ID = "nonanona-local"
# 가상 계정. example.com은 예약된 도메인이라 실제 주소가 아니다.
HOST = ("host.local@example.com", "다라")
MEMBER = ("member.local@example.com", "가나")
# 호스트에서 본 API 주소와 각 기기에서 본 주소(Android 에뮬레이터는 10.0.2.2가 호스트다).
API_PORT = 54321
DEVICE_URLS = {"ios": f"http://127.0.0.1:{API_PORT}", "android": f"http://10.0.2.2:{API_PORT}"}


def log(msg):
    print(f"[local-backend] {msg}", flush=True)


def supabase(*args, log_name=None, check=True):
    """CLI 출력은 키가 섞일 수 있으므로 화면 대신 .run/ 아래 파일로만 보낸다."""
    RUN.mkdir(parents=True, exist_ok=True)
    os.chmod(RUN, 0o700)
    out = RUN / f"{log_name or args[0]}.log"
    with open(out, "w", encoding="utf-8") as f:
        os.chmod(out, 0o600)
        r = subprocess.run(["supabase", *args], cwd=ROOT, stdin=subprocess.DEVNULL, stdout=f, stderr=subprocess.STDOUT)
    if check and r.returncode != 0:
        sys.exit(f"[local-backend] supabase {args[0]} failed (exit {r.returncode}); see supabase/.run/{out.name}")
    return r.returncode


def status():
    r = subprocess.run(["supabase", "status", "-o", "json"], cwd=ROOT, stdin=subprocess.DEVNULL,
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("[local-backend] local stack is not running: run `up` first")
    start, end = r.stdout.find("{"), r.stdout.rfind("}")
    values = json.loads(r.stdout[start:end + 1])
    missing = [k for k in ("API_URL", "PUBLISHABLE_KEY", "SECRET_KEY") if not values.get(k)]
    if missing:
        sys.exit(f"[local-backend] status is missing {missing}; available names: {sorted(values)}")
    return values


def admin_create_user(env, email, display_name, password):
    req = urllib.request.Request(
        env["API_URL"] + "/auth/v1/admin/users",
        method="POST",
        data=json.dumps({"email": email, "password": password, "email_confirm": True,
                         "user_metadata": {"display_name": display_name}}).encode(),
        headers={"apikey": env["SECRET_KEY"], "Authorization": "Bearer " + env["SECRET_KEY"],
                 "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return resp.status
    except urllib.error.HTTPError as e:
        body = json.loads(e.read() or b"{}")
        sys.exit(f"[local-backend] create user failed: HTTP {e.code} {body.get('error_code') or body.get('code')}")


def write_private(path, text):
    path.write_text(text, encoding="utf-8")
    os.chmod(path, 0o600)


def write_app_configs(env, password):
    key = env["PUBLISHABLE_KEY"]
    write_private(ANDROID_CONFIG, "\n".join([
        "# scripts/local-backend.py가 만든 로컬 debug 설정(gitignore). 지우면 debug 앱은 테스트 모드로 돌아간다.",
        "backend=local",
        f"supabaseUrl={DEVICE_URLS['android']}",
        f"publishableKey={key}",
        f"testEmail={MEMBER[0]}",
        f"testPassword={password}",
        "",
    ]))
    # xcconfig에서 //는 주석이라 URL의 //를 $()로 끊는다.
    url = DEVICE_URLS["ios"].replace("//", "/$()/")
    write_private(IOS_CONFIG, "\n".join([
        "// scripts/local-backend.py가 만든 로컬 debug 설정(gitignore). 지우면 debug 앱은 테스트 모드로 돌아간다.",
        "NONANONA_BACKEND = local",
        f"NONANONA_LOCAL_SUPABASE_URL = {url}",
        f"NONANONA_LOCAL_PUBLISHABLE_KEY = {key}",
        f"NONANONA_LOCAL_TEST_EMAIL = {MEMBER[0]}",
        f"NONANONA_LOCAL_TEST_PASSWORD = {password}",
        "",
    ]))


def query(sql, log_name):
    supabase("db", "query", sql, log_name=log_name)
    return (RUN / f"{log_name}.log").read_text(encoding="utf-8")


def reset():
    supabase("db", "reset", log_name="db-reset")
    env = status()
    log("migrations applied")
    member_password = secrets.token_urlsafe(24)
    admin_create_user(env, HOST[0], HOST[1], secrets.token_urlsafe(24))  # 방장은 로그인하지 않는다
    admin_create_user(env, MEMBER[0], MEMBER[1], member_password)
    log("synthetic accounts created (host, member)")
    supabase("db", "query", "--file", str(FIXTURE), log_name="fixture")
    log("synthetic trips (3) and invites (5) inserted")
    write_app_configs(env, member_password)
    log("app configs written (gitignored): apps/android/local-backend.properties, apps/ios/Config/Local.xcconfig")


def gateway_container():
    r = subprocess.run(["docker", "ps", "-a", "--filter", f"label=com.supabase.cli.project={PROJECT_ID}",
                        "--format", "{{.Names}}"], capture_output=True, text=True, check=True)
    names = [n for n in r.stdout.split() if n.startswith(("supabase_kong_", "supabase_envoy_"))]
    if len(names) != 1:
        sys.exit(f"[local-backend] expected one API gateway container, found {names}")
    return names[0]


def wait_for_gateway(timeout=60):
    """게이트웨이가 다시 응답할 때까지 기다린다. 응답 코드만 보고 본문은 읽지 않는다."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{API_PORT}/auth/v1/health", timeout=2)
            return
        except urllib.error.HTTPError as e:
            if e.code < 500:
                return
        except OSError:
            pass
        time.sleep(1)
    sys.exit("[local-backend] API gateway did not come back")


UPLOAD_TRIP = "가상 오사카 여행"


def rows(sql, log_name):
    out = query(sql, log_name)
    start, end = out.find("["), out.rfind("]")
    return json.loads(out[start:end + 1]) if start >= 0 else []


def http(env, method, path, body=None, token=None, key=None, raw=None, content_type="application/json", headers=None):
    """상태 코드와 서버가 정한 코드만 돌려준다(본문 원문은 필요할 때만, 화면에는 내지 않는다)."""
    h = {"apikey": key or env["PUBLISHABLE_KEY"], "Content-Type": content_type, **(headers or {})}
    if token:
        h["Authorization"] = "Bearer " + token
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(env["API_URL"] + path, method=method, data=data, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def code_of(raw):
    try:
        b = json.loads(raw or b"{}")
    except ValueError:
        return None
    if isinstance(b, list):
        return f"{len(b)} rows"
    return b.get("error_code") or (b.get("message") if str(b.get("code", "")).startswith("PT") else None) \
        or b.get("code") or b.get("error") or b.get("statusCode")


def upload_trip_ids():
    r = rows(f"""select t.id as trip, u.id as member from public.trips t, auth.users u
               where t.name = '{UPLOAD_TRIP}' and u.email = '{MEMBER[0]}'""", "upload-ids")
    return r[0]["trip"], r[0]["member"]


def upload_report():
    r = rows(f"""select
        (select count(*) from storage.objects where bucket_id = 'receipts') as objects,
        (select count(*) from public.expenses) as expenses,
        (select count(*) from public.expenses e where not exists (
           select 1 from storage.objects o where o.bucket_id = 'receipts' and o.name = e.artifact_path)) as expenses_without_object,
        (select count(*) from storage.objects o where o.bucket_id = 'receipts' and not exists (
           select 1 from public.expenses e where e.artifact_path = o.name)) as objects_without_expense,
        (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
           where table_schema = 'public' and table_name = 'expenses') as expense_columns,
        (select json_agg(json_build_object('date', expense_date, 'amount_minor', amount_minor, 'currency', currency,
           'merchant', merchant)) from public.expenses) as expense_fields""", "upload-report")
    print(json.dumps(r[0], ensure_ascii=False))


def outsider_check():
    env = status()
    trip, _ = upload_trip_ids()
    objects = rows("select name from storage.objects where bucket_id = 'receipts' order by created_at limit 1", "outsider-objects")
    password = secrets.token_urlsafe(24)
    email = "outsider.local@example.com"
    if not rows(f"select 1 as x from auth.users where email = '{email}'", "outsider-exists"):
        admin_create_user(env, email, "마바", password)
    else:
        query(f"select 1", "outsider-noop")
        sys.exit("[local-backend] outsider already exists: run reset first")
    st, raw = http(env, "POST", "/auth/v1/token?grant_type=password", {"email": email, "password": password})
    token = json.loads(raw)["access_token"]
    uid = json.loads(raw)["user"]["id"]
    png = (ROOT / "apps" / "fixtures" / "receipts" / "receipt-r01.png").read_bytes()
    checks = []

    def check(name, result, ok):
        checks.append({"check": name, "status": result[0], "code": code_of(result[1]), "denied": ok(result)})

    check("select expenses", http(env, "GET", "/rest/v1/expenses?select=id", token=token), lambda r: r[0] == 200 and json.loads(r[1]) == [])
    check("select trips", http(env, "GET", "/rest/v1/trips?select=id", token=token), lambda r: r[0] == 200 and json.loads(r[1]) == [])
    check("list trip objects", http(env, "POST", "/storage/v1/object/list/receipts", {"prefix": trip + "/"}, token=token),
          lambda r: r[0] == 200 and json.loads(r[1]) == [])
    if objects:
        check("download member object", http(env, "GET", "/storage/v1/object/authenticated/receipts/" + objects[0]["name"], token=token),
              lambda r: r[0] >= 400)
    check("upload into trip folder", http(env, "POST", f"/storage/v1/object/receipts/{trip}/{uid}/{secrets.token_hex(4)}0000-0000-0000-0000-000000000000.png",
                                          token=token, raw=png, content_type="image/png"), lambda r: r[0] >= 400)
    check("submit expense rpc", http(env, "POST", "/rest/v1/rpc/submit_receipt_expense", {
        "p_trip": trip, "p_request_id": "00000000-0000-4000-8000-000000000001", "p_expense_date": "2026-11-03",
        "p_amount_minor": 1408, "p_currency": "JPY", "p_merchant": "x", "p_artifact_sha256": "0" * 64}, token=token),
        lambda r: r[0] == 404 and code_of(r[1]) == "trip_not_found")
    check("anon select expenses", http(env, "GET", "/rest/v1/expenses?select=id"), lambda r: r[0] >= 400 or json.loads(r[1]) == [])
    print(json.dumps(checks, ensure_ascii=False))
    if not all(c["denied"] for c in checks):
        sys.exit("[local-backend] outsider check FAILED")


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "up":
        supabase("start", log_name="start")
        log("local stack started")
        reset()
    elif cmd == "reset":
        reset()
    elif cmd == "down":
        supabase("stop", "--no-backup", log_name="stop", check=False)
        for path in (ANDROID_CONFIG, IOS_CONFIG):
            path.unlink(missing_ok=True)
        log("local stack stopped, app configs removed")
    elif cmd in ("api-stop", "api-start"):
        name = gateway_container()
        subprocess.run(["docker", cmd.split("-")[1], name], capture_output=True, check=True)
        if cmd == "api-start":
            wait_for_gateway()
        log(f"API gateway {'stopped' if cmd == 'api-stop' else 'started and answering'}")
    elif cmd == "revoke-sessions":
        query(f"delete from auth.sessions where user_id = (select id from auth.users where email = '{MEMBER[0]}')",
              "revoke-sessions")
        log("member sessions deleted on the server (refresh tokens no longer valid)")
    elif cmd == "report":
        out = query(f"""
          select
            (select count(*) from public.trip_members m join auth.users u on u.id = m.user_id
              where u.email = '{MEMBER[0]}') as member_trips,
            (select count(*) from public.trip_invites where used_by is not null) as used_invites,
            (select count(*) from auth.sessions s join auth.users u on u.id = s.user_id
              where u.email = '{MEMBER[0]}') as member_sessions
        """, "report")
        start, end = out.find("["), out.rfind("]")
        result = json.loads(out[start:end + 1]) if start >= 0 else out
        print(json.dumps(result, ensure_ascii=False))
    elif cmd == "upload-report":
        upload_report()
    elif cmd == "fetch-artifact":
        env = status()
        path = rows("select artifact_path as p from public.expenses order by created_at limit 1", "fetch-path")[0]["p"]
        st, raw = http(env, "GET", "/storage/v1/object/receipts/" + path, key=env["SECRET_KEY"], token=env["SECRET_KEY"])
        if st != 200:
            sys.exit(f"[local-backend] fetch failed: HTTP {st}")
        Path(sys.argv[2]).write_bytes(raw)
        log("fetched the uploaded artifact (admin) for host inspection")
    elif cmd == "fetch-artifacts":
        # 서버가 받은 모든 사본을 <폴더>/<artifact_sha256>.png로 꺼낸다(관리자 키, 호스트 검사용).
        env = status()
        out = Path(sys.argv[2])
        out.mkdir(parents=True, exist_ok=True)
        for row in rows("select artifact_path as p, artifact_sha256 as h from public.expenses order by created_at", "fetch-paths"):
            st, raw = http(env, "GET", "/storage/v1/object/receipts/" + row["p"], key=env["SECRET_KEY"], token=env["SECRET_KEY"])
            if st != 200:
                sys.exit(f"[local-backend] fetch failed: HTTP {st}")
            (out / f"{row['h']}.png").write_bytes(raw)
        log("fetched every uploaded artifact (admin) for host inspection")
    elif cmd == "membership-remove":
        query(f"""delete from public.trip_members where role = 'member'
                  and trip_id = (select id from public.trips where name = '{UPLOAD_TRIP}')
                  and user_id = (select id from auth.users where email = '{MEMBER[0]}')""", "membership-remove")
        log("member removed from the upload trip (destination now invalid for the app)")
    elif cmd == "membership-restore":
        query(f"""insert into public.trip_members (trip_id, user_id, role, display_name)
                  select t.id, u.id, 'member', '{MEMBER[1]}' from public.trips t, auth.users u
                  where t.name = '{UPLOAD_TRIP}' and u.email = '{MEMBER[0]}' on conflict do nothing""", "membership-restore")
        log("member restored to the upload trip")
    elif cmd == "outsider-check":
        outsider_check()
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
