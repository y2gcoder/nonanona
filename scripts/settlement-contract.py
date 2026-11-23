#!/usr/bin/env python3
"""정산 서버 계약 시험. 로컬 Supabase에 실제 HTTP(앱과 같은 Data API·Storage 경로)로 요청한다. 표준 라이브러리만 쓴다.

사용(저장소 루트, local:up 또는 local:reset 뒤): python3 -I scripts/settlement-contract.py [결과 JSON 경로]

실행마다 새 가상 여행방(방장·회원)과 새 비구성원 계정을 만들므로 다시 실행해도 된다. 앱 E2E가 쓰는 시드 여행방은 건드리지 않는다.
토큰·비밀번호·키는 출력하지 않는다. 결과에는 검사 이름, HTTP 상태, 서버가 정한 코드만 남긴다.
"""

import concurrent.futures
import importlib.util
import json
import secrets
import struct
import subprocess
import sys
import threading
import time
import uuid
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("local_backend", ROOT / "scripts" / "local-backend.py")
lb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lb)

EXAMPLES = json.loads((ROOT / "apps" / "fixtures" / "settlement" / "examples.json").read_text(encoding="utf-8"))
checks = []


def check(name, ok, **info):
    checks.append({"check": name, "ok": bool(ok), **info})
    print(("PASS " if ok else "FAIL ") + name + (f" {info}" if info else ""), flush=True)


def tiny_png():
    """가상 1×1 PNG(실제 영수증 아님)."""
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    raw = b"\x00\xff\xff\xff"
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)) + \
        chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


class Client:
    def __init__(self, env, email, password):
        self.env = env
        st, raw = lb.http(env, "POST", "/auth/v1/token?grant_type=password", {"email": email, "password": password})
        assert st == 200, f"login failed for a synthetic account: HTTP {st}"
        body = json.loads(raw)
        self.token = body["access_token"]
        self.uid = body["user"]["id"]

    def rpc(self, name, **params):
        st, raw = lb.http(self.env, "POST", f"/rest/v1/rpc/{name}", params, token=self.token)
        body = None
        try:
            body = json.loads(raw) if raw else None
        except ValueError:
            pass
        return st, (body if st < 300 else lb.code_of(raw)), body

    def upload(self, path, data):
        return lb.http(self.env, "POST", f"/storage/v1/object/receipts/{path}", token=self.token, raw=data,
                       content_type="image/png")


def new_trip(host_uid, member_uid):
    name = "가상 계약 시험 " + secrets.token_hex(3)
    r = lb.rows(f"""with t as (insert into public.trips (name, host_id) values ('{name}', '{host_uid}') returning id),
        m as (insert into public.trip_members (trip_id, user_id, role, display_name, joined_at)
              select t.id, '{host_uid}'::uuid, 'host', '다라', now() - interval '1 minute' from t
              union all select t.id, '{member_uid}'::uuid, 'member', '가나', now() from t returning trip_id)
        select (select id from t) as id""", "contract-trip")
    return r[0]["id"]


DB_CONTAINER = "supabase_db_nonanona-local"


def psql(sql):
    """로컬 DB 소유자 권한 SQL(검사용). 결과 글자만 돌려준다."""
    r = subprocess.run(["docker", "exec", "-i", DB_CONTAINER, "psql", "-U", "postgres", "-tAq", "-v", "ON_ERROR_STOP=1", "-c", sql],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr[-300:]
    return r.stdout.strip()


def invite(trip, host_uid):
    code = "SYNTHJOIN" + secrets.token_hex(6).upper()
    psql(f"insert into public.trip_invites (trip_id, token_hash, created_by, expires_at) "
         f"values ('{trip}', private.token_hash('{code}'), '{host_uid}', now() + interval '1 hour')")
    return code


def trip_state(trip, uid):
    """revision·상태·확정본 해시·이 계정의 구성원 여부·이 방 초대들의 사용 상태."""
    row = psql(f"""select t.revision || '|' || t.status || '|' ||
        coalesce((select string_agg(f.snapshot_sha256, ',' order by f.version) from public.finalizations f where f.trip_id = t.id), '-') || '|' ||
        (select count(*) from public.trip_members m where m.trip_id = t.id and m.user_id = '{uid}') || '|' ||
        (select count(*) from public.trip_members m where m.trip_id = t.id) || '|' ||
        (select count(*) from public.trip_invites i where i.trip_id = t.id and i.used_by is not null)
        from public.trips t where t.id = '{trip}'""")
    rev, status, snaps, me, members, used = row.split("|")
    return {"revision": int(rev), "status": status, "snapshots": snaps, "joined": int(me), "members": int(members), "used_invites": int(used)}


def new_joiner(env, name):
    email = f"joiner.{secrets.token_hex(4)}@example.com"
    password = secrets.token_urlsafe(24)
    lb.admin_create_user(env, email, name, password)
    return Client(env, email, password)


def join_after_finalize(env, host, member):
    """확정된 방에는 새로 참여할 수 없다: 잠금 뒤, 쓰기 전에 거절하고(초대·구성원·revision·확정본 그대로)
    이미 그 초대로 참여한 계정의 재시도만 기존 결과로 수렴한다. 순서를 잠금으로 정해 두 순서를 모두 본다."""
    # 1) 순차: 확정 전에 참여한 사람의 재시도는 수렴, 확정 뒤 새 초대 수락은 거절.
    trip = new_trip(host.uid, member.uid)
    early = new_joiner(env, "라마")
    early_code = invite(trip, host.uid)
    st, body, _ = early.rpc("accept_invite", p_token=early_code, p_display_name="라마")
    check("join before finalize succeeds", st == 200 and body["replayed"] is False, status=st)
    rev = trip_state(trip, early.uid)["revision"]
    st, body, _ = host.rpc("finalize_settlement", p_trip=trip, p_expected_revision=rev, p_request_id=str(uuid.uuid4()))
    check("finalize the join test trip", st == 200, status=st)
    late = new_joiner(env, "바사")
    late_code = invite(trip, host.uid)
    before = trip_state(trip, late.uid)
    st, code, _ = late.rpc("accept_invite", p_token=late_code, p_display_name="바사")
    after = trip_state(trip, late.uid)
    check("first-time join of a finalized trip -> trip_finalized", st == 409 and code == "trip_finalized", status=st, code=code)
    check("rejected join changes nothing (revision, snapshot, members, invites)", before == after and after["joined"] == 0,
          before=before, after=after)
    st, code, _ = late.rpc("accept_invite", p_token=late_code, p_display_name="바사")
    check("retrying the rejected join is rejected the same way", st == 409 and code == "trip_finalized" and trip_state(trip, late.uid) == after)
    replay_before = trip_state(trip, early.uid)
    st, body, _ = early.rpc("accept_invite", p_token=early_code, p_display_name="라마")
    check("exact replay by the member who joined before finalize still converges without changes",
          st == 200 and body["replayed"] is True and replay_before["joined"] == 1 and trip_state(trip, early.uid) == replay_before,
          status=st)

    # 2) 잠금으로 순서를 정한다: 여행방 행을 잠근 채 두 요청을 차례로 대기열에 넣고 풀어 준다.
    def gated(first, second):
        holder = subprocess.Popen(["docker", "exec", "-i", DB_CONTAINER, "psql", "-U", "postgres", "-tAq", "-c",
                                   f"begin; select 1 from public.trips where id = '{gtrip}' for update; select pg_sleep(4); commit;"],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(0.8)
        out = {}
        threads = []
        for name, fn in (first, second):
            waiting = int(psql("select count(*) from pg_locks where not granted"))
            t = threading.Thread(target=lambda n=name, f=fn: out.__setitem__(n, f()))
            t.start()
            threads.append(t)
            deadline = time.time() + 3
            while int(psql("select count(*) from pg_locks where not granted")) <= waiting and time.time() < deadline:
                time.sleep(0.05)
        for t in threads:
            t.join()
        holder.wait()
        return out

    # 2a) 확정이 먼저 대기열에 들어가면: 확정 성공, 참여는 trip_finalized, 확정본에 참여자 없음.
    gtrip = new_trip(host.uid, member.uid)
    joiner = new_joiner(env, "아자")
    code = invite(gtrip, host.uid)
    rev = trip_state(gtrip, joiner.uid)["revision"]
    out = gated(("finalize", lambda: host.rpc("finalize_settlement", p_trip=gtrip, p_expected_revision=rev, p_request_id=str(uuid.uuid4()))),
                ("join", lambda: joiner.rpc("accept_invite", p_token=code, p_display_name="아자")))
    state = trip_state(gtrip, joiner.uid)
    members_in_snapshot = psql(f"select jsonb_array_length(snapshot -> 'inputs' -> 'members') from public.finalizations where trip_id = '{gtrip}'")
    check("gated finalize-then-join: finalize commits, join -> trip_finalized",
          out["finalize"][0] == 200 and out["join"][0] == 409 and out["join"][1] == "trip_finalized", codes=[out["finalize"][1:2], out["join"][1]])
    check("gated finalize-then-join: no member, invite unused, revision only from finalize, snapshot without joiner",
          state["joined"] == 0 and state["used_invites"] == 0 and state["revision"] == rev + 1 and state["status"] == "finalized"
          and members_in_snapshot == "2", state=state)

    # 2b) 참여가 먼저 대기열에 들어가면: 참여 성공, 미리 본 revision의 확정은 stale_revision, 방은 열린 채.
    gtrip = new_trip(host.uid, member.uid)
    joiner = new_joiner(env, "차카")
    code = invite(gtrip, host.uid)
    rev = trip_state(gtrip, joiner.uid)["revision"]
    out = gated(("join", lambda: joiner.rpc("accept_invite", p_token=code, p_display_name="차카")),
                ("finalize", lambda: host.rpc("finalize_settlement", p_trip=gtrip, p_expected_revision=rev, p_request_id=str(uuid.uuid4()))))
    state = trip_state(gtrip, joiner.uid)
    check("gated join-then-finalize: join commits, finalize -> stale_revision",
          out["join"][0] == 200 and out["finalize"][0] == 409 and out["finalize"][1] == "stale_revision", codes=[out["join"][0], out["finalize"][1]])
    check("gated join-then-finalize: joined, invite used, room still open without a snapshot",
          state["joined"] == 1 and state["used_invites"] == 1 and state["status"] == "open" and state["snapshots"] == "-"
          and state["revision"] == rev + 1, state=state)


def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else None
    env = lb.status()
    accounts = json.loads((lb.RUN / "accounts.json").read_text())
    host = Client(env, *accounts["host"])
    member = Client(env, *accounts["member"])
    outsider_email = f"outsider.contract.{secrets.token_hex(4)}@example.com"
    outsider_password = secrets.token_urlsafe(24)
    lb.admin_create_user(env, outsider_email, "마바", outsider_password)
    outsider = Client(env, outsider_email, outsider_password)
    trip = new_trip(host.uid, member.uid)
    who = {"host": host, "member": member}
    uid = {"host": host.uid, "member": member.uid}

    # ------------------------------------------------------------ 읽기·권한
    st, trips, _ = member.rpc("list_my_trips")
    check("member lists the trip", st == 200 and any(t["trip_id"] == trip and t["my_role"] == "member" for t in trips))
    st, ledger, _ = host.rpc("get_room_ledger", p_trip=trip)
    check("host ledger: open, revision 1, two members with ids", st == 200 and ledger["status"] == "open"
          and ledger["revision"] == 1 and {m["user_id"] for m in ledger["members"]} == {host.uid, member.uid}
          and ledger["my_role"] == "host")
    for name, params in [("get_room_ledger", {"p_trip": trip}), ("preview_settlement", {"p_trip": trip}),
                         ("get_finalized_settlement", {"p_trip": trip}),
                         ("submit_manual_expense", {"p_trip": trip, "p_request_id": str(uuid.uuid4()),
                                                    "p_expense_date": "2026-11-08", "p_amount_minor": 1000,
                                                    "p_currency": "KRW", "p_merchant": "x"}),
                         ("finalize_settlement", {"p_trip": trip, "p_expected_revision": 1,
                                                  "p_request_id": str(uuid.uuid4())})]:
        st, code, _ = outsider.rpc(name, **params)
        check(f"outsider {name} -> trip_not_found", st == 404 and code == "trip_not_found", status=st, code=code)
    st, trips, _ = outsider.rpc("list_my_trips")
    check("outsider lists no trips", st == 200 and trips == [])
    for table in ("expenses", "expense_shares", "finalizations", "trip_events", "settlement_requests", "trips"):
        st, raw = lb.http(env, "GET", f"/rest/v1/{table}?select=*&trip_id=eq.{trip}" if table != "trips" else
                          f"/rest/v1/trips?select=id&id=eq.{trip}", token=outsider.token)
        ok = (st == 200 and json.loads(raw) == []) or st in (401, 403, 404)
        check(f"outsider select {table} sees nothing", ok, status=st)
    for table, row in (("expenses", {"trip_id": trip}), ("expense_shares", {"trip_id": trip}),
                       ("finalizations", {"trip_id": trip}), ("trips", {"name": "x", "host_id": host.uid})):
        st, raw = lb.http(env, "POST", f"/rest/v1/{table}", row, token=host.token)
        check(f"host direct insert into {table} is refused", st in (401, 403), status=st, code=lb.code_of(raw))
    st, raw = lb.http(env, "PATCH", f"/rest/v1/expenses?trip_id=eq.{trip}", {"status": "included"}, token=host.token)
    check("host direct update of expenses is refused", st in (401, 403), status=st)

    # ------------------------------------------------------------ 제출: 사본 지출과 직접 입력, 재시도
    expense_ids = {}
    png = tiny_png()
    for ex in EXAMPLES["settlement"]["expenses"]:
        submitter = member if ex["key"] in ("r01", "ticket", "souvenir") else host
        req = str(uuid.uuid4())
        if ex["entry"] == "receipt":
            sha = __import__("hashlib").sha256(png + ex["key"].encode()).hexdigest()
            st, _ = submitter.upload(f"{trip}/{submitter.uid}/{req}.png", png)
            check(f"{ex['key']}: upload masked copy", st == 200, status=st)
            params = dict(p_trip=trip, p_request_id=req, p_expense_date=ex["date"], p_amount_minor=ex["amount_minor"],
                          p_currency=ex["currency"], p_merchant=ex["merchant"], p_artifact_sha256=sha)
            st, body, _ = submitter.rpc("submit_receipt_expense", **params)
            st2, body2, _ = submitter.rpc("submit_receipt_expense", **params)
            check(f"{ex['key']}: receipt submit then replay converges", st == 200 and st2 == 200 and not body["replayed"]
                  and body2["replayed"] and body2["expense_id"] == body["expense_id"])
        else:
            params = dict(p_trip=trip, p_request_id=req, p_expense_date=ex["date"], p_amount_minor=ex["amount_minor"],
                          p_currency=ex["currency"], p_merchant=ex["merchant"])
            st, body, _ = submitter.rpc("submit_manual_expense", **params)
            st2, body2, _ = submitter.rpc("submit_manual_expense", **params)
            check(f"{ex['key']}: manual submit then replay converges", st == 200 and st2 == 200 and not body["replayed"]
                  and body2["replayed"] and body2["expense_id"] == body["expense_id"])
            st3, code3, _ = submitter.rpc("submit_manual_expense", **{**params, "p_amount_minor": ex["amount_minor"] + 1})
            check(f"{ex['key']}: same request key, different content -> idempotency_conflict",
                  st3 == 409 and code3 == "idempotency_conflict", status=st3, code=code3)
        expense_ids[ex["key"]] = body["expense_id"]
    st, code, _ = member.rpc("submit_manual_expense", p_trip=trip, p_request_id=str(uuid.uuid4()),
                             p_expense_date="2026-11-08", p_amount_minor=0, p_currency="KRW", p_merchant="x")
    check("manual with zero amount -> invalid_fields", st == 400 and code == "invalid_fields", status=st, code=code)
    st, code, _ = member.rpc("submit_manual_expense", p_trip=trip, p_request_id=str(uuid.uuid4()),
                             p_expense_date="2026-11-08", p_amount_minor=100, p_currency="KRW", p_merchant="a\nb")
    check("manual with control characters in merchant -> invalid_fields", st == 400 and code == "invalid_fields",
          status=st, code=code)

    st, ledger, _ = member.rpc("get_room_ledger", p_trip=trip)
    by_id = {e["expense_id"]: e for e in ledger["expenses"]}
    check("member sees every expense, all pending, roles separate",
          st == 200 and len(ledger["expenses"]) == 4 and all(e["status"] == "pending" and e["payer_id"] is None
                                                            for e in ledger["expenses"])
          and by_id[expense_ids["r01"]]["uploaded_by"] == member.uid and by_id[expense_ids["r02"]]["uploaded_by"] == host.uid
          and by_id[expense_ids["ticket"]]["entry"] == "manual" and not by_id[expense_ids["ticket"]]["has_artifact"])
    st, host_ledger, _ = host.rpc("get_room_ledger", p_trip=trip)
    check("host and member see the same expenses", host_ledger["expenses"] == ledger["expenses"]
          and host_ledger["revision"] == ledger["revision"] == 5)

    # ------------------------------------------------------------ 검토: 권한·검사·재시도·동시성
    r01 = by_id[expense_ids["r01"]]
    base = dict(p_expense=r01["expense_id"], p_expected_version=1, p_decision="include", p_payer=host.uid)
    st, code, _ = member.rpc("review_expense", **base, p_request_id=str(uuid.uuid4()), p_krw_amount=13377,
                             p_shares=[{"user_id": member.uid, "krw": 13377}])
    check("member review -> host_only", st == 403 and code == "host_only", status=st, code=code)
    st, code, _ = outsider.rpc("review_expense", **base, p_request_id=str(uuid.uuid4()), p_krw_amount=13377,
                               p_shares=[{"user_id": host.uid, "krw": 13377}])
    check("outsider review -> trip_not_found", st == 404 and code == "trip_not_found", status=st, code=code)
    st, code, _ = host.rpc("review_expense", **base, p_request_id=str(uuid.uuid4()),
                           p_shares=[{"user_id": host.uid, "krw": 1408}])
    check("foreign currency without verified KRW -> krw_unverified (no automatic conversion)",
          st == 400 and code == "krw_unverified", status=st, code=code)
    st, code, _ = host.rpc("review_expense", **base, p_request_id=str(uuid.uuid4()), p_krw_amount=13377,
                           p_shares=[{"user_id": host.uid, "krw": 6688}, {"user_id": member.uid, "krw": 6688}])
    check("shares that leave 1 won -> shares_mismatch (server does not pick who gets the remainder)",
          st == 400 and code == "shares_mismatch", status=st, code=code)
    for label, shares in [("fractional", [{"user_id": host.uid, "krw": 6688.5}, {"user_id": member.uid, "krw": 6688.5}]),
                          ("duplicate member", [{"user_id": host.uid, "krw": 6688}, {"user_id": host.uid, "krw": 6689}]),
                          ("non-member", [{"user_id": outsider.uid, "krw": 13377}]),
                          ("string amount", [{"user_id": host.uid, "krw": "13377"}]),
                          ("negative", [{"user_id": host.uid, "krw": 13378}, {"user_id": member.uid, "krw": -1}]),
                          ("empty", [])]:
        st, code, _ = host.rpc("review_expense", **base, p_request_id=str(uuid.uuid4()), p_krw_amount=13377, p_shares=shares)
        check(f"shares {label} -> shares_invalid", st == 400 and code == "shares_invalid", status=st, code=code)
    st, code, _ = host.rpc("review_expense", **{**base, "p_payer": outsider.uid}, p_request_id=str(uuid.uuid4()),
                           p_krw_amount=13377, p_shares=[{"user_id": host.uid, "krw": 13377}])
    check("payer outside the trip -> payer_required", st == 400 and code == "payer_required", status=st, code=code)
    st, code, _ = host.rpc("review_expense", p_expense=r01["expense_id"], p_expected_version=1, p_decision="hold",
                           p_request_id=str(uuid.uuid4()))
    check("hold without reason -> hold_reason_required", st == 400 and code == "hold_reason_required", status=st, code=code)
    st, ledger, _ = host.rpc("get_room_ledger", p_trip=trip)
    check("rejected reviews changed nothing", ledger["revision"] == 5 and all(e["version"] == 1 for e in ledger["expenses"]))

    # 같은 지출, 같은 버전에 서로 다른 두 검토가 동시에 오면 하나만 반영되고 늦은 쪽은 stale_expense.
    def review(req, payer):
        return host.rpc("review_expense", **{**base, "p_payer": payer}, p_request_id=req, p_krw_amount=13377,
                        p_shares=[{"user_id": host.uid, "krw": 6688}, {"user_id": member.uid, "krw": 6689}])
    reqs = [str(uuid.uuid4()), str(uuid.uuid4())]
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        results = list(pool.map(review, reqs, [host.uid, member.uid]))
    statuses = sorted(r[0] for r in results)
    winner = next(i for i, r in enumerate(results) if r[0] == 200)
    loser = 1 - winner
    check("concurrent reviews of one version: exactly one commits, the other is stale_expense",
          statuses == [200, 409] and results[loser][1] == "stale_expense", codes=[r[1] for r in results])
    # 이긴 쪽 결과를 예제(결제자=방장)로 맞춘다: 결제자가 회원이었다면 새 버전으로 다시 검토한다.
    st, replay, _ = review(reqs[winner], [host.uid, member.uid][winner])
    check("same review request replays the stored result", st == 200 and replay["replayed"]
          and replay["version"] == results[winner][1]["version"])
    st, code, _ = host.rpc("review_expense", **base, p_request_id=reqs[winner], p_krw_amount=13376,
                           p_shares=[{"user_id": host.uid, "krw": 13376}])
    check("same review key, different content -> idempotency_conflict", st == 409 and code == "idempotency_conflict",
          status=st, code=code)
    if winner == 1:
        st, body, _ = host.rpc("review_expense", **{**base, "p_expected_version": 2}, p_request_id=str(uuid.uuid4()),
                               p_krw_amount=13377, p_shares=[{"user_id": host.uid, "krw": 6688},
                                                             {"user_id": member.uid, "krw": 6689}])
        check("re-review with the current version", st == 200 and body["version"] == 3)

    st, ledger, _ = host.rpc("get_room_ledger", p_trip=trip)
    by_id = {e["expense_id"]: e for e in ledger["expenses"]}
    reviewed_revision_before = ledger["revision"]
    for ex in EXAMPLES["settlement"]["expenses"][1:]:
        e = by_id[expense_ids[ex["key"]]]
        rv = ex["review"]
        params = dict(p_expense=e["expense_id"], p_expected_version=e["version"], p_request_id=str(uuid.uuid4()),
                      p_decision=rv["decision"])
        if rv["decision"] == "include":
            params.update(p_payer=uid[rv["payer"]], p_shares=[{"user_id": uid[k], "krw": v} for k, v in rv["shares"].items()])
            if "krw_amount" in rv:
                params["p_krw_amount"] = rv["krw_amount"]
        else:
            params["p_hold_reason"] = rv["hold_reason"]
        st, body, _ = host.rpc("review_expense", **params)
        check(f"{ex['key']}: host {rv['decision']}", st == 200 and body["status"] == ("included" if rv["decision"] == "include" else "held"),
              status=st, code=body if st >= 300 else None)
    st, code, _ = host.rpc("review_expense", p_expense=expense_ids["ticket"], p_expected_version=2, p_decision="include",
                           p_request_id=str(uuid.uuid4()), p_payer=host.uid, p_krw_amount=38001,
                           p_shares=[{"user_id": host.uid, "krw": 38001}])
    check("KRW expense with a different KRW amount -> krw_unverified", st == 400 and code == "krw_unverified",
          status=st, code=code)

    # ------------------------------------------------------------ 미리보기
    st, preview, _ = member.rpc("preview_settlement", p_trip=trip)
    exp = EXAMPLES["settlement"]["expected"]
    names = {host.uid: "host", member.uid: "member"}
    key_of = {v: k for k, v in expense_ids.items()}
    check("member preview: server-calculated transfers match the shared example",
          st == 200 and preview["ready"] and preview["included_total_krw"] == exp["included_total_krw"]
          and [{"from": names[t["from"]], "to": names[t["to"]], "krw": t["krw"]} for t in preview["transfers"]] == exp["transfers"]
          and {names[b["user_id"]]: b["net_krw"] for b in preview["balances"]} == exp["balances"]
          and [{"key": key_of[x["expense_id"]], "kind": x["kind"], "reason": x["reason"]} for x in preview["excluded"]] == exp["excluded"])

    # ------------------------------------------------------------ 확정: 권한·오래된 버전·확인 필요·동시성·재시도
    rev = preview["revision"]
    st, code, _ = member.rpc("finalize_settlement", p_trip=trip, p_expected_revision=rev, p_request_id=str(uuid.uuid4()))
    check("member finalize -> host_only", st == 403 and code == "host_only", status=st, code=code)
    late_req = str(uuid.uuid4())
    st, late, _ = member.rpc("submit_manual_expense", p_trip=trip, p_request_id=late_req, p_expense_date="2026-11-09",
                             p_amount_minor=5000, p_currency="KRW", p_merchant="늦은 지출")
    check("member adds an expense after the host previewed", st == 200)
    st, code, body = host.rpc("finalize_settlement", p_trip=trip, p_expected_revision=rev, p_request_id=str(uuid.uuid4()))
    details = json.loads(body.get("details") or "{}") if isinstance(body, dict) else {}
    check("finalize with the previewed revision -> stale_revision with the new change",
          st == 409 and code == "stale_revision" and details.get("current_revision") == rev + 1
          and [c["action"] for c in details.get("changes", [])] == ["expense_submitted"], status=st, code=code)
    st, code, _ = host.rpc("finalize_settlement", p_trip=trip, p_expected_revision=rev + 1, p_request_id=str(uuid.uuid4()))
    check("finalize while an expense is pending -> pending_review", st == 409 and code == "pending_review", status=st, code=code)
    st, body, _ = host.rpc("review_expense", p_expense=late["expense_id"], p_expected_version=1, p_decision="hold",
                           p_request_id=str(uuid.uuid4()), p_hold_reason="결제 여부 불명확")
    check("host holds the late expense", st == 200)
    st, preview, _ = host.rpc("preview_settlement", p_trip=trip)
    check("held expenses are omitted from the transfers", preview["ready"]
          and [t["krw"] for t in preview["transfers"]] == [exp["transfers"][0]["krw"]] and len(preview["excluded"]) == 3)
    rev = preview["revision"]

    reqs = [str(uuid.uuid4()), str(uuid.uuid4())]
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        results = list(pool.map(lambda r: host.rpc("finalize_settlement", p_trip=trip, p_expected_revision=rev, p_request_id=r), reqs))
    ok = [r for r in results if r[0] == 200]
    bad = [r for r in results if r[0] != 200]
    check("two different finalize requests at once: exactly one commits, the other trip_finalized",
          len(ok) == 1 and len(bad) == 1 and bad[0][1] == "trip_finalized", codes=[r[1] for r in results])
    fin = ok[0][1]
    win_req = reqs[results.index(ok[0])]
    st, again, _ = host.rpc("finalize_settlement", p_trip=trip, p_expected_revision=rev, p_request_id=win_req)
    check("finalize retry with the same request id returns the same finalization",
          st == 200 and again["replayed"] and again["finalization_id"] == fin["finalization_id"] and again["version"] == 1)
    st, code, _ = host.rpc("finalize_settlement", p_trip=trip, p_expected_revision=rev - 1, p_request_id=win_req)
    check("same finalize key with a different revision -> idempotency_conflict", st == 409 and code == "idempotency_conflict",
          status=st, code=code)
    count = lb.rows(f"select count(*) as n from public.finalizations where trip_id = '{trip}'", "contract-count")[0]["n"]
    check("exactly one finalization row", count == 1)

    # ------------------------------------------------------------ 확정 뒤
    st, f_member, _ = member.rpc("get_finalized_settlement", p_trip=trip)
    st2, f_host, _ = host.rpc("get_finalized_settlement", p_trip=trip)
    snap = f_member["snapshot"]
    check("member and host read the identical frozen snapshot", st == st2 == 200 and f_member == f_host
          and f_member["finalization_id"] == fin["finalization_id"] and snap["reviewed_revision"] == rev)
    check("snapshot hash matches its content as stored", lb.rows(
        f"select (encode(sha256(convert_to(snapshot::text, 'UTF8')), 'hex') = snapshot_sha256) as ok "
        f"from public.finalizations where trip_id = '{trip}'", "contract-hash")[0]["ok"] is True)
    # 스냅숏 입력만으로 독립 재계산한 결과가 서버 결과와 같은지.
    net = {m["user_id"]: 0 for m in snap["inputs"]["members"]}
    for e in snap["inputs"]["expenses"]:
        if e["kind"] == "shared":
            net[e["payer_id"]] += e["krw_amount"]
            for s in e["shares"]:
                net[s["user_id"]] -= s["krw"]
    check("independent recomputation from frozen inputs equals frozen outputs",
          {b["user_id"]: b["net_krw"] for b in snap["outputs"]["balances"]} == net
          and sum(e["krw_amount"] for e in snap["inputs"]["expenses"] if e["kind"] == "shared") == snap["outputs"]["included_total_krw"])
    check("frozen inputs keep original amount, currency, KRW basis and shares",
          any(e["currency"] == "JPY" and e["amount_minor"] == 1408 and e["krw_amount"] == 13377
              and e["krw_basis"] == "verified_krw_charge" and sorted(s["krw"] for s in e["shares"]) == [6688, 6689]
              for e in snap["inputs"]["expenses"]))
    st, code, _ = member.rpc("submit_manual_expense", p_trip=trip, p_request_id=str(uuid.uuid4()), p_expense_date="2026-11-09",
                             p_amount_minor=100, p_currency="KRW", p_merchant="확정 뒤")
    check("after finalize: new manual expense -> trip_finalized", st == 409 and code == "trip_finalized", status=st, code=code)
    st, body, _ = member.rpc("submit_manual_expense", p_trip=trip, p_request_id=late_req, p_expense_date="2026-11-09",
                             p_amount_minor=5000, p_currency="KRW", p_merchant="늦은 지출")
    check("after finalize: replay of an earlier submission still converges", st == 200 and body["replayed"])
    st, ledger, _ = host.rpc("get_room_ledger", p_trip=trip)
    e = next(x for x in ledger["expenses"] if x["expense_id"] == late["expense_id"])
    st, code, _ = host.rpc("review_expense", p_expense=e["expense_id"], p_expected_version=e["version"], p_decision="hold",
                           p_request_id=str(uuid.uuid4()), p_hold_reason="다른 사유")
    check("after finalize: review -> trip_finalized", st == 409 and code == "trip_finalized", status=st, code=code)
    st, code, _ = host.rpc("finalize_settlement", p_trip=trip, p_expected_revision=ledger["revision"], p_request_id=str(uuid.uuid4()))
    check("after finalize: a new finalize -> trip_finalized", st == 409 and code == "trip_finalized", status=st, code=code)
    st = lb.supabase("db", "query", f"update public.finalizations set included_total_krw = 0 where trip_id = '{trip}'",
                     log_name="contract-immutable", check=False)
    check("finalization rows cannot be changed even by the table owner", st != 0)
    st, f_after, _ = member.rpc("get_finalized_settlement", p_trip=trip)
    check("snapshot unchanged afterwards", f_after == f_member)
    st, preview, _ = member.rpc("preview_settlement", p_trip=trip)
    check("preview after finalize says not ready", st == 200 and preview["status"] == "finalized" and not preview["ready"])

    # ------------------------------------------------------------ 기존 경로 회귀: 시드 여행방의 사본 올리기 권한
    seeded, _ = lb.upload_trip_ids()
    st, code, _ = outsider.rpc("submit_receipt_expense", p_trip=seeded, p_request_id=str(uuid.uuid4()),
                               p_expense_date="2026-11-03", p_amount_minor=1408, p_currency="JPY", p_merchant="x",
                               p_artifact_sha256="0" * 64)
    check("existing receipt submit still refuses outsiders", st == 404 and code == "trip_not_found", status=st, code=code)
    st, code, _ = host.rpc("submit_receipt_expense", p_trip=trip, p_request_id=str(uuid.uuid4()),
                           p_expense_date="2026-11-03", p_amount_minor=1408, p_currency="JPY", p_merchant="x",
                           p_artifact_sha256="0" * 64)
    check("existing receipt submit refuses a finalized trip", st == 409 and code == "trip_finalized", status=st, code=code)

    join_after_finalize(env, host, member)

    failed = [c for c in checks if not c["ok"]]
    summary = {"passed": len(checks) - len(failed), "total": len(checks), "checks": checks}
    if out:
        out.write_text(json.dumps(summary, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"{summary['passed']}/{summary['total']} passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
