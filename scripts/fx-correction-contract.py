#!/usr/bin/env python3
"""확정 전 기준환율 정정 정책(ADR-0009) 서버 계약 시험. 로컬 Supabase에 실제 HTTP로 요청한다. 표준 라이브러리만 쓴다.

사용(저장소 루트, local:up 또는 local:reset 뒤): python3 -I scripts/fx-correction-contract.py [결과 JSON 경로]

* 기준환율은 가상 시험값(data_origin=fixture)만 남긴다. 출처 종류(fixture→ecos_live) 비교는 DB 소유자 트랜잭션 안에서 받고
  검사한 뒤 되돌린다(가상 값을 ecos_live로 남기지 않는다).
* 실행마다 1981~2000년 중 한 해의 6~8월을 쓴다(fx-contract.py의 2001~2020년 3~5월, 시드·앱 E2E의 2026년과 겹치지 않는다).
* 동시성은 DB 소유자 psql 세션이 트랜잭션을 열어 둔 채 기다리는 동안 다른 쪽 요청을 보내 확인한다.
* 토큰·키·비밀번호는 출력하지 않는다. 결과에는 검사 이름, HTTP 상태, 서버가 정한 코드만 남긴다.
"""

import datetime
import importlib.util
import json
import secrets
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / file)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


sc = load("settlement_contract", "settlement-contract.py")
fx = load("ecos_fx", "ecos-fx.py")
lb = sc.lb
check, psql, Client = sc.check, sc.psql, sc.Client


def detail(body):
    try:
        return json.loads((body or {}).get("details") or "null")
    except (ValueError, AttributeError):
        return None


def ingest_sql(values, start, end, origin="fixture"):
    text = json.dumps(fx.ecos_shape(values), ensure_ascii=False)
    tag = "$fxc" + secrets.token_hex(6) + "$"
    return f"select private.ingest_fx_response({tag}{text}{tag}::jsonb, '{start}', '{end}', '{origin}');"


def background_psql(sql):
    """DB 소유자 세션을 따로 띄운다(트랜잭션을 열어 둔 채 기다리는 쪽)."""
    return subprocess.Popen(["docker", "exec", "-i", sc.DB_CONTAINER, "psql", "-U", "postgres", "-tAq", "-v", "ON_ERROR_STOP=1"],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def run_background(sql):
    p = background_psql(sql)
    p.stdin.write(sql)
    p.stdin.close()
    return p


def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else None
    env = lb.status()
    accounts = json.loads((lb.RUN / "accounts.json").read_text())
    host = Client(env, *accounts["host"])
    member = Client(env, *accounts["member"])
    outsider_email = f"outsider.fxc.{secrets.token_hex(4)}@example.com"
    outsider_password = secrets.token_urlsafe(24)
    lb.admin_create_user(env, outsider_email, "마바", outsider_password)
    outsider = Client(env, outsider_email, outsider_password)

    year = 1981 + secrets.randbelow(20)
    B = datetime.date(year, 6, 1)

    def d(n):
        return (B + datetime.timedelta(days=n)).isoformat()

    def ingest(values, start, end):
        ok, res = fx.ingest_fixture(fx.ecos_shape({d(k): v for k, v in values.items()}),
                                    datetime.date.fromisoformat(d(start)), datetime.date.fromisoformat(d(end)))
        assert ok, res
        return res

    ingest({2: "900.00", 5: "901.00", 8: "902.00", 11: "903.00", 14: "904.00", 17: "905.00", 20: "906.00",
            23: "907.00", 26: "908.00"}, 0, 29)
    ingest({42: "910.00"}, 40, 45)  # d30~d39는 덮지 않는다(정정으로 고시값이 사라지면 undetermined가 된다)

    trip = sc.new_trip(host.uid, member.uid)
    specs = {"keep": (d(2), 1000), "apply": (d(5), 1001), "manual": (d(8), 1000), "repeat": (d(11), 1000),
             "gone": (d(44), 1000), "gone2": (d(45), 1000), "origin": (d(17), 1000), "held": (d(20), 1000),
             "current": (d(23), 1000), "race": (d(26), 1000)}
    ids = {}
    for key, (day, amount) in specs.items():
        st, body, _ = member.rpc("submit_manual_expense", p_trip=trip, p_request_id=str(uuid.uuid4()), p_expense_date=day,
                                 p_amount_minor=amount, p_currency="JPY", p_merchant=f"가상 {key}")
        assert st == 200, (key, st, body)
        ids[key] = body["expense_id"]

    def ledger(client=host):
        st, body, _ = client.rpc("get_room_ledger", p_trip=trip)
        return {e["expense_id"]: e for e in body["expenses"]}, body

    def exp(key):
        return ledger()[0][ids[key]]

    def pair(krw):
        half = krw // 2
        split = [half, half] if krw % 2 == 0 else [half + 1, half]  # 결제자(방장)가 1원 더(ADR-0007)
        return [{"user_id": host.uid, "krw": split[0]}, {"user_id": member.uid, "krw": split[1]}]

    def include_estimate(key, shares=None, quote=None, krw=None):
        e = exp(key)
        p = e["fx_proposal"]
        krw = krw if krw is not None else p["krw"]
        return host.rpc("review_expense", p_expense=e["expense_id"], p_expected_version=e["version"],
                        p_request_id=str(uuid.uuid4()), p_decision="include", p_payer=host.uid, p_krw_amount=krw,
                        p_shares=shares or pair(krw), p_krw_basis="reference_rate_estimate",
                        p_fx_quote_id=quote or p["quote_id"])

    def keep(key, quote=None, version=None, request=None, client=host):
        e = exp(key)
        return client.rpc("keep_fx_estimate", p_expense=e["expense_id"],
                          p_expected_version=e["version"] if version is None else version,
                          p_request_id=request or str(uuid.uuid4()),
                          p_replacement_quote_id=quote or e["fx_proposal"]["quote_id"])

    def preview():
        return host.rpc("preview_settlement", p_trip=trip)[1]

    def state(key):
        return exp(key)["fx_correction"]

    # ------------------------------------------------------------ 포함(예상액)
    for key in specs:
        if key == "manual":
            st, _, _ = include_estimate(key, shares=[{"user_id": host.uid, "krw": 3000}, {"user_id": member.uid, "krw": 6020}])
        else:
            st, _, _ = include_estimate(key)
        assert st == 200, (key, st)
    st, _, _ = host.rpc("review_expense", p_expense=ids["held"], p_expected_version=exp("held")["version"],
                        p_request_id=str(uuid.uuid4()), p_decision="hold", p_hold_reason="결제 여부 불명확")
    led, _ = ledger()
    check("all estimates included with their pinned quotes; nothing to decide yet",
          all(led[ids[k]]["fx_correction"] is None and led[ids[k]]["fx_superseded"] is False for k in specs)
          and preview()["ready"] and preview()["fx_correction_expense_ids"] == [])
    check("held estimate keeps its pinned quote but is excluded", led[ids["held"]]["status"] == "held"
          and led[ids["held"]]["krw_basis"] == "reference_rate_estimate")

    # ------------------------------------------------------------ 정정 → 확정 차단
    rev0 = preview()["revision"]
    # 정정 받기가 덮는 기간의 다른 날짜 값은 그대로 다시 온다(빠지면 그날은 고시가 없어진 것 = 그것도 정정이다).
    ingest({2: "900.50", 5: "901.40", 8: "902.10", 11: "903.20", 14: "904.00", 17: "905.00", 20: "906.50",
            23: "907.00", 26: "908.00"}, 0, 29)
    led, _ = ledger()
    check("a material correction marks included estimates as required (not repriced)",
          all(led[ids[k]]["fx_correction"] == "required" and led[ids[k]]["fx_superseded"] is True for k in
              ("keep", "apply", "manual", "repeat"))
          and led[ids["keep"]]["krw_amount"] == 9000 and led[ids["keep"]]["fx"]["rate"] == "900.00"
          and led[ids["keep"]]["fx_proposal"]["rate"] == "900.50" and led[ids["keep"]]["fx_proposal"]["krw"] == 9005
          and led[ids["keep"]]["is_estimate"] is True)
    check("held estimate is flagged superseded but never blocks (excluded as before)",
          led[ids["held"]]["fx_superseded"] is True and led[ids["held"]]["fx_correction"] is None)
    check("uncorrected estimates stay current", led[ids["current"]]["fx_correction"] is None
          and led[ids["origin"]]["fx_correction"] is None)
    check("member sees the same correction state (read only)",
          ledger(member)[0][ids["keep"]]["fx_correction"] == "required")
    p = preview()
    check("correction alone does not bump the trip revision", p["revision"] == rev0)
    check("preview is not ready and lists the blocking expenses in ledger order",
          not p["ready"] and p["fx_correction_expense_ids"] == [ids["keep"], ids["apply"], ids["manual"], ids["repeat"]]
          and p["pending_expense_ids"] == [], blocking=p["fx_correction_expense_ids"])
    check("preview totals still use the pinned amounts", p["estimated_total_krw"] == sum(
        led[ids[k]]["krw_amount"] for k in specs if k != "held"))
    st, code, body = host.rpc("finalize_settlement", p_trip=trip, p_expected_revision=rev0, p_request_id=str(uuid.uuid4()))
    check("first finalize is blocked -> fx_correction_required with the expense ids",
          st == 409 and code == "fx_correction_required"
          and detail(body) == {"expense_ids": [ids["keep"], ids["apply"], ids["manual"], ids["repeat"]]}, status=st, code=code)
    st, code, _ = host.rpc("finalize_settlement", p_trip=trip, p_expected_revision=rev0 - 1, p_request_id=str(uuid.uuid4()))
    check("an older revision is still rejected as stale_revision first", st == 409 and code == "stale_revision", code=code)
    st, code, _ = member.rpc("finalize_settlement", p_trip=trip, p_expected_revision=rev0, p_request_id=str(uuid.uuid4()))
    check("member finalize -> host_only", st == 403 and code == "host_only", code=code)

    # ------------------------------------------------------------ 고정 금액 유지(keep)
    old_quote = exp("keep")["fx"]["quote_id"]
    for who, client, want_st, want in (("member", member, 403, "host_only"), ("outsider", outsider, 404, "trip_not_found")):
        st, code, _ = keep("keep", client=client)
        check(f"{who} cannot keep -> {want}", st == want_st and code == want, status=st, code=code)
    e = exp("keep")
    st, raw = lb.http(env, "POST", "/rest/v1/rpc/keep_fx_estimate",
                      {"p_expense": e["expense_id"], "p_expected_version": e["version"], "p_request_id": str(uuid.uuid4()),
                       "p_replacement_quote_id": e["fx_proposal"]["quote_id"]})
    check("anonymous cannot keep", st in (401, 403, 404), status=st)
    for label, kw, want in [("with the pinned (old) quote instead of the replacement", dict(quote=old_quote), "stale_quote"),
                            ("with an unknown quote", dict(quote=str(uuid.uuid4())), "stale_quote"),
                            ("with an old expense version", dict(version=e["version"] - 1), "stale_expense")]:
        st, code, _ = keep("keep", **kw)
        check(f"keep {label} -> {want}", st == 409 and code == want, status=st, code=code)
    st, code, _ = keep("current", quote=exp("current")["fx_proposal"]["quote_id"])
    check("keep when nothing changed -> fx_not_superseded", st == 409 and code == "fx_not_superseded", code=code)
    st, code, _ = keep("held", quote=exp("held")["fx_proposal"]["quote_id"])
    check("keep on a held estimate -> fx_not_superseded (held is excluded)", st == 409 and code == "fx_not_superseded", code=code)
    check("rejected keeps changed nothing", exp("keep")["version"] == e["version"] and preview()["revision"] == rev0)

    req = str(uuid.uuid4())
    seen_quote = e["fx_proposal"]["quote_id"]
    # 방장이 보는 사이 같은 값이 다시 들어왔다(다른 quote_id): 본 고시값으로 유지할 수 있다.
    ingest({2: "900.50"}, 1, 2)
    check("identical refetch gives a new quote id with the same identity",
          exp("keep")["fx_proposal"]["quote_id"] != seen_quote and exp("keep")["fx_correction"] == "required")
    st, body, _ = keep("keep", quote=seen_quote, request=req)
    e2 = exp("keep")
    check("host keeps the pinned estimate with the replacement seen before an identical refetch",
          st == 200 and body["version"] == e["version"] + 1 and body["revision"] == rev0 + 1 and not body["replayed"]
          and e2["fx_correction"] == "kept" and e2["fx_superseded"] is True and e2["krw_amount"] == 9000
          and e2["fx"]["rate"] == "900.00" and e2["is_estimate"] is True and e2["krw_basis"] == "reference_rate_estimate"
          and e2["shares"] == e["shares"], status=st)
    st, body2, _ = host.rpc("keep_fx_estimate", p_expense=ids["keep"], p_expected_version=e["version"], p_request_id=req,
                            p_replacement_quote_id=seen_quote)
    check("same keep request replays the same result", st == 200 and body2["replayed"] and body2["version"] == body["version"]
          and body2["revision"] == body["revision"])
    st, code, _ = host.rpc("keep_fx_estimate", p_expense=ids["keep"], p_expected_version=e["version"], p_request_id=req,
                           p_replacement_quote_id=old_quote)
    check("same keep key with different contents -> idempotency_conflict", st == 409 and code == "idempotency_conflict")
    st, code, _ = keep("keep")
    check("keep again after keeping -> fx_not_superseded", st == 409 and code == "fx_not_superseded", code=code)
    ingest({2: "900.50"}, 2, 2)
    check("another identical refetch after the keep does not invalidate it", state("keep") == "kept")
    n = psql(f"select count(*) from public.fx_keep_decisions where expense_id = '{ids['keep']}' and expense_version = {e2['version']}"
             f" and replacement_rate = 900.50 and replacement_data_origin = 'fixture' and pinned_quote_id = '{old_quote}'")
    check("the keep decision is stored bound to the expense version and replacement identity", n == "1")
    for sql in (f"update public.fx_keep_decisions set replacement_rate = 1 where expense_id = '{ids['keep']}'",
                f"delete from public.fx_keep_decisions where expense_id = '{ids['keep']}'"):
        rc, _, _ = fx.psql(sql)
        check(f"keep decisions are immutable even for the owner: {sql.split()[0]}", rc != 0)
    st, raw = lb.http(env, "GET", "/rest/v1/fx_keep_decisions?select=*", token=host.token)
    check("app roles cannot read keep decisions directly", st in (401, 403, 404) or json.loads(raw) == [], status=st)
    rc, outp, _ = fx.psql(f"begin; update public.expenses set version = version + 1 where id = '{ids['keep']}';"
                          f" select private.fx_correction(e) from public.expenses e where e.id = '{ids['keep']}'; rollback;")
    check("a keep is bound to its expense version (another version would need a new decision)",
          rc == 0 and outp.splitlines()[-1] == "required", got=outp.splitlines()[-1:])

    # ------------------------------------------------------------ 반복 정정
    st, _, _ = keep("repeat")
    check("repeat: first correction kept", st == 200 and state("repeat") == "kept")
    kept_quote = exp("repeat")["fx_proposal"]["quote_id"]
    ingest({11: "903.30"}, 9, 11)
    check("repeat: another material correction invalidates the keep", state("repeat") == "required"
          and exp("repeat")["fx_proposal"]["rate"] == "903.30")
    st, code, _ = keep("repeat", quote=kept_quote)
    check("repeat: keeping with the earlier replacement -> stale_quote", st == 409 and code == "stale_quote", code=code)
    st, _, _ = keep("repeat")
    check("repeat: host decides again and keeps", st == 200 and state("repeat") == "kept")
    ingest({11: "903.40"}, 11, 11)
    ingest({11: "903.30"}, 11, 11)
    check("repeat: A->B kept, then C, then back to B still needs a new decision (C applied in between)",
          state("repeat") == "required")
    st, _, _ = keep("repeat")
    check("repeat: third decision recorded", st == 200 and state("repeat") == "kept"
          and psql(f"select count(*) from public.fx_keep_decisions where expense_id = '{ids['repeat']}'") == "3")

    # ------------------------------------------------------------ 새 예상액 적용(기존 검토)
    a = exp("apply")
    st, code, _ = include_estimate("apply", quote=a["fx"]["quote_id"], krw=a["krw_amount"])
    check("apply: re-including with the old pinned quote -> stale_quote", st == 409 and code == "stale_quote", code=code)
    st, code, _ = include_estimate("apply", krw=a["krw_amount"], shares=a["shares"])
    check("apply: new quote with the old KRW -> krw_mismatch (server never adjusts)", st == 400 and code == "krw_mismatch")
    st, body, _ = include_estimate("apply")
    a2 = exp("apply")
    check("apply: new estimate with recomputed even shares (payer +1)",
          st == 200 and a2["krw_amount"] == 9023 and a2["fx"]["rate"] == "901.40" and a2["fx_correction"] is None
          and {s["user_id"]: s["krw"] for s in a2["shares"]} == {host.uid: 4512, member.uid: 4511})
    m = exp("manual")
    st, code, _ = include_estimate("manual", shares=m["shares"])
    check("apply with manual shares: old exact shares are not silently adjusted -> shares_mismatch",
          st == 400 and code == "shares_mismatch", code=code)
    st, body, _ = include_estimate("manual", shares=[{"user_id": host.uid, "krw": 3000}, {"user_id": member.uid, "krw": 6021}])
    m2 = exp("manual")
    check("apply with explicit new manual shares", st == 200 and m2["krw_amount"] == 9021
          and {s["user_id"]: s["krw"] for s in m2["shares"]} == {host.uid: 3000, member.uid: 6021}
          and m2["fx_correction"] is None)

    # ------------------------------------------------------------ 정정 뒤 고시값이 없어짐(undetermined)
    ingest({}, 42, 42)  # 42일의 고시값을 지운 정정(INFO-200)
    g = exp("gone")
    check("gone: correction removes the only quote -> proposal undetermined, state unavailable",
          g["fx_proposal"]["status"] == "undetermined" and g["fx_correction"] == "unavailable"
          and exp("gone2")["fx_correction"] == "unavailable" and g["krw_amount"] == 9100)
    st, code, body = keep("gone", quote=g["fx"]["quote_id"])
    check("gone: keep is not possible -> fx_replacement_unavailable",
          st == 409 and code == "fx_replacement_unavailable"
          and (detail(body) or {}).get("fx_proposal", {}).get("status") == "undetermined", code=code)
    st, code, _ = include_estimate("gone", quote=g["fx"]["quote_id"], krw=9100)
    check("gone: re-including the old estimate -> stale_quote (no auto-repricing)", st == 409 and code == "stale_quote")
    p = preview()
    check("gone: blocks finalize", ids["gone"] in p["fx_correction_expense_ids"] and not p["ready"])
    st, _, _ = host.rpc("review_expense", p_expense=ids["gone"], p_expected_version=g["version"],
                        p_request_id=str(uuid.uuid4()), p_decision="include", p_payer=host.uid, p_krw_amount=9150,
                        p_shares=pair(9150))
    check("gone: host resolves with the verified actual charge (existing review)",
          st == 200 and exp("gone")["krw_basis"] == "verified_krw_charge" and exp("gone")["fx_correction"] is None)
    st, _, _ = host.rpc("review_expense", p_expense=ids["gone2"], p_expected_version=exp("gone2")["version"],
                        p_request_id=str(uuid.uuid4()), p_decision="hold", p_hold_reason="원화 청구액 확인 대기")
    check("gone2: host resolves by holding (excluded, no blocking)", st == 200 and exp("gone2")["fx_correction"] is None)

    # ------------------------------------------------------------ 출처 종류: 같은 값의 fixture → ecos_live도 정정이다
    rc, outp, err = fx.psql("begin; " + ingest_sql({d(17): "905.00"}, d(17), d(17), "ecos_live")
                            + f" select private.fx_correction(e) || ',' || private.fx_superseded(e) from public.expenses e"
                              f" where e.id = '{ids['origin']}'; rollback;")
    check("same value with a different provenance (fixture -> ecos_live) is a material change, consistently",
          rc == 0 and outp.splitlines()[-1] == "required,true", got=outp.splitlines()[-1:] if rc == 0 else err[-200:])
    check("that live-labelled synthetic value was rolled back", psql(
        "select count(*) from public.fx_ingestions where data_origin = 'ecos_live'") == "0"
        and state("origin") is None)

    # ------------------------------------------------------------ 동시성 1: 받기가 진행 중이면 확정은 기다렸다가 그 값으로 본다
    st, _, _ = keep("keep") if state("keep") == "required" else (200, None, None)
    p = preview()
    check("everything decided: preview ready", p["ready"] and p["fx_correction_expense_ids"] == [], blocking=p["fx_correction_expense_ids"])
    proc = run_background("begin; " + ingest_sql({d(26): "908.90"}, d(26), d(26)) + " select pg_sleep(3); commit;")
    time.sleep(1.0)
    t = time.monotonic()
    st, code, body = host.rpc("finalize_settlement", p_trip=trip, p_expected_revision=p["revision"], p_request_id=str(uuid.uuid4()))
    waited = time.monotonic() - t
    proc.wait(timeout=30)
    check("finalize waits for an in-flight ingestion and then sees its correction -> fx_correction_required",
          proc.returncode == 0 and st == 409 and code == "fx_correction_required" and waited >= 1.2
          and detail(body) == {"expense_ids": [ids["race"]]}, status=st, code=code, waited=round(waited, 2))

    # ------------------------------------------------------------ 동시성 2: 보는 사이 또 정정되면 유지는 기다렸다가 거절
    seen = exp("race")["fx_proposal"]["quote_id"]
    proc = run_background("begin; " + ingest_sql({d(26): "908.95"}, d(26), d(26)) + " select pg_sleep(3); commit;")
    time.sleep(1.0)
    t = time.monotonic()
    st, code, _ = keep("race", quote=seen)
    waited = time.monotonic() - t
    proc.wait(timeout=30)
    check("keep racing a newer correction waits and is rejected -> stale_quote", proc.returncode == 0 and st == 409
          and code == "stale_quote" and waited >= 1.2, code=code, waited=round(waited, 2))
    st, _, _ = keep("race")
    check("keep with the current replacement", st == 200 and state("race") == "kept")

    # ------------------------------------------------------------ 동시성 3: 확정이 먼저 잠그면 받기는 그 뒤에 들어간다
    p = preview()
    check("preview ready again", p["ready"])
    final_req = str(uuid.uuid4())
    claims = json.dumps({"sub": host.uid, "role": "authenticated"})
    proc = run_background(f"begin; select set_config('request.jwt.claims', '{claims}', true); set local role authenticated;"
                          f" select public.finalize_settlement('{trip}', {p['revision']}, '{final_req}'); "
                          f" select pg_sleep(3); commit;")
    time.sleep(1.0)
    t = time.monotonic()
    ok, res = fx.ingest_fixture(fx.ecos_shape({d(26): "909.00"}),
                                datetime.date.fromisoformat(d(26)), datetime.date.fromisoformat(d(26)))
    waited = time.monotonic() - t
    proc.wait(timeout=30)
    fin_out, fin_err = proc.stdout.read(), proc.stderr.read()
    check("an ingestion arriving during a finalize waits for it (finalize committed first)",
          proc.returncode == 0 and ok and waited >= 1.2 and '"replayed": false' in fin_out, waited=round(waited, 2),
          err=fin_err[-200:])
    st, f1, _ = member.rpc("get_finalized_settlement", p_trip=trip)
    snap = f1["snapshot"]
    by = {x["expense_id"]: x for x in snap["inputs"]["expenses"]}
    check("finalized snapshot keeps kept estimates pinned and labelled estimated",
          f1["rule_version"] == "explicit-krw-shares-v2" and by[ids["keep"]]["krw_amount"] == 9000
          and by[ids["keep"]]["fx"]["rate"] == "900.00" and by[ids["keep"]]["is_estimate"] is True
          and by[ids["race"]]["fx"]["rate"] == "908.00" and by[ids["race"]]["is_estimate"] is True
          and by[ids["apply"]]["fx"]["rate"] == "901.40" and by[ids["gone"]]["krw_basis"] == "verified_krw_charge"
          and all("fx_correction" not in x and "fx_proposal" not in x for x in snap["inputs"]["expenses"]))
    est_total = sum(x["krw_amount"] for x in snap["inputs"]["expenses"] if x["kind"] == "shared" and x["is_estimate"])
    check("snapshot estimated total is the pinned estimates", snap["outputs"]["estimated_total_krw"] == est_total)
    st, body, _ = host.rpc("finalize_settlement", p_trip=trip, p_expected_revision=p["revision"], p_request_id=final_req)
    check("exact finalize replay after later corrections returns the same finalization (no new check)",
          st == 200 and body["replayed"] and body["finalization_id"] == f1["finalization_id"])
    st, code, _ = host.rpc("finalize_settlement", p_trip=trip, p_expected_revision=p["revision"] - 1, p_request_id=final_req)
    check("same finalize key with a different revision -> idempotency_conflict", st == 409 and code == "idempotency_conflict")
    st, f2, _ = member.rpc("get_finalized_settlement", p_trip=trip)
    check("the finalized snapshot is unchanged by the later ingestion", f2 == f1)
    led, raw = ledger()
    check("finalized ledger shows no live proposal, superseded flag or correction state",
          all(x["fx_proposal"] is None and x["fx_superseded"] is False and x["fx_correction"] is None for x in led.values()))
    st, code, _ = keep("race", quote=seen)
    check("keep after finalize -> trip_finalized", st == 409 and code == "trip_finalized", code=code)

    failed = [c for c in sc.checks if not c["ok"]]
    summary = {"passed": len(sc.checks) - len(failed), "total": len(sc.checks), "year": year, "checks": sc.checks}
    if out:
        out.write_text(json.dumps(summary, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"{summary['passed']}/{summary['total']} passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
