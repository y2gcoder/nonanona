#!/usr/bin/env python3
"""로컬 Supabase(Docker)와 앱의 로컬 debug 모드 설정을 다룬다. Python 표준 라이브러리만 쓴다.

사용(저장소 루트, mise 환경에서):
  python3 -I scripts/local-backend.py up            스택 시작 + reset
  python3 -I scripts/local-backend.py reset         DB 초기화 → 가상 계정 → 가상 여행방·초대 → 앱 설정 파일
  python3 -I scripts/local-backend.py down          스택 정지 + 앱 설정 파일 삭제(앱은 테스트 모드로 돌아간다)
  python3 -I scripts/local-backend.py api-stop|api-start   API 게이트웨이만 멈추고 다시 띄운다(연결 실패 재현)
  python3 -I scripts/local-backend.py revoke-sessions      가상 회원 계정의 서버 세션을 지운다(세션 만료 재현)
  python3 -I scripts/local-backend.py report               가상 회원 계정의 참여·초대 사용 수(비밀값 없음)

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
        rows = json.loads(out[start:end + 1]) if start >= 0 else out
        print(json.dumps(rows, ensure_ascii=False))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
