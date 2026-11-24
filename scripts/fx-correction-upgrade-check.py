#!/usr/bin/env python3
"""확정 전 기준환율 정정 정책 마이그레이션(20261124150000) 업그레이드 검사. 로컬 DB를 바로 앞 마이그레이션(20261124130000)까지
되돌려 그 규칙으로 v2 확정본, 확정 요청, 검토 요청, "더 새 고시값이 있다"고만 알리던 포함 예상액을 만든 뒤 새 마이그레이션을 올려
예전 자료가 그대로인지, 정정된 예상액은 이제 방장 결정 전까지 확정을 막는지 본다. 끝나면 local:reset 상태로 되돌린다.

사용(저장소 루트, local:up 뒤): python3 -I scripts/fx-correction-upgrade-check.py [결과 JSON 경로]
로컬 DB를 지우고 다시 만든다(가상 자료만 있다). 토큰·키·비밀번호는 출력하지 않는다.
"""

import datetime
import importlib.util
import json
import sys
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BEFORE = "20261124130000"


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / file)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else None
    lb = load("local_backend", "local-backend.py")
    lb.reset(version=BEFORE)
    lb.load_fx_fixture()
    sc = load("settlement_contract", "settlement-contract.py")
    fx = load("ecos_fx", "ecos-fx.py")
    check, psql = sc.check, sc.psql
    env = lb.status()
    accounts = json.loads((lb.RUN / "accounts.json").read_text())
    host, member = sc.Client(env, *accounts["host"]), sc.Client(env, *accounts["member"])
    check("database is at the previous migration (no keep decisions)",
          psql("select to_regclass('public.fx_keep_decisions') is null") == "t")

    def submit(trip, day, amount):
        st, body, _ = member.rpc("submit_manual_expense", p_trip=trip, p_request_id=str(uuid.uuid4()), p_expense_date=day,
                                 p_amount_minor=amount, p_currency="JPY", p_merchant="가상 업그레이드")
        return body["expense_id"]

    def ledger(trip):
        return {e["expense_id"]: e for e in host.rpc("get_room_ledger", p_trip=trip)[1]["expenses"]}

    def include_estimate(trip, eid, req=None):
        e = ledger(trip)[eid]
        p = e["fx_proposal"]
        half = p["krw"] // 2
        params = dict(p_expense=eid, p_expected_version=e["version"], p_request_id=req or str(uuid.uuid4()),
                      p_decision="include", p_payer=host.uid, p_krw_amount=p["krw"], p_krw_basis="reference_rate_estimate",
                      p_fx_quote_id=p["quote_id"], p_shares=[{"user_id": host.uid, "krw": p["krw"] - half},
                                                              {"user_id": member.uid, "krw": half}])
        return params, host.rpc("review_expense", **params)

    # A: 예전 규칙으로 확정한 v2 확정본(예상액 포함). B: 열린 방, 포함 예상액 + 그 뒤 정정(예전에는 알리기만 했다).
    trip_a = sc.new_trip(host.uid, member.uid)
    include_estimate(trip_a, submit(trip_a, "2026-11-04", 1500))
    rev_a = host.rpc("get_room_ledger", p_trip=trip_a)[1]["revision"]
    fin_req = dict(p_trip=trip_a, p_expected_revision=rev_a, p_request_id=str(uuid.uuid4()))
    st, fin_body, _ = host.rpc("finalize_settlement", **fin_req)
    check("v2 finalize before the migration", st == 200)
    row_sql = (f"select md5(snapshot::text) || '|' || snapshot_sha256 || '|' || rule_version || '|' || included_total_krw "
               f"from public.finalizations where trip_id = '{trip_a}'")
    row_before = psql(row_sql)
    f_before = member.rpc("get_finalized_settlement", p_trip=trip_a)[1]

    trip_b = sc.new_trip(host.uid, member.uid)
    pinned = submit(trip_b, "2026-11-04", 1500)
    old_review, (st, old_resp, _) = include_estimate(trip_b, pinned)
    check("old estimate review stored before the migration", st == 200 and not old_resp["replayed"])
    ok, _ = fx.ingest_fixture(fx.ecos_shape({"2026-11-04": "904.80"}), datetime.date(2026, 11, 4), datetime.date(2026, 11, 4))
    led = ledger(trip_b)
    check("before the migration a correction only flagged fx_superseded (no correction state)",
          ok and led[pinned]["fx_superseded"] is True and "fx_correction" not in led[pinned])

    rc = lb.supabase("migration", "up", log_name="migration-up", check=False)
    check("migration applies on top of existing data", rc == 0)

    check("v2 finalization row is byte-for-byte unchanged", psql(row_sql) == row_before)
    check("finalized settlement reads back identically", member.rpc("get_finalized_settlement", p_trip=trip_a)[1] == f_before)
    st, replay, _ = host.rpc("finalize_settlement", **fin_req)
    check("finalize sent before the migration replays with the same result after it",
          st == 200 and replay == {"finalization_id": fin_body["finalization_id"], "version": fin_body["version"],
                                   "replayed": True})
    st, code, _ = host.rpc("finalize_settlement", **{**fin_req, "p_expected_revision": None})
    check("that v2 key with a null revision -> idempotency_conflict (no replay)", st == 409 and code == "idempotency_conflict",
          code=code)
    st, replay, _ = host.rpc("review_expense", **old_review)
    check("estimate review sent before the migration replays with the same result after it",
          st == 200 and replay["replayed"] and replay["version"] == old_resp["version"])

    e = ledger(trip_b)[pinned]
    check("existing pinned estimate is not repriced and now needs a host decision",
          e["krw_amount"] == 13554 and e["fx"]["rate"] == "903.60" and e["is_estimate"] is True
          and e["fx_correction"] == "required" and e["fx_superseded"] is True and e["fx_proposal"]["rate"] == "904.80")
    rev_b = host.rpc("get_room_ledger", p_trip=trip_b)[1]["revision"]
    st, code, _ = host.rpc("finalize_settlement", p_trip=trip_b, p_expected_revision=rev_b, p_request_id=str(uuid.uuid4()))
    check("finalize of the open trip is now blocked -> fx_correction_required", st == 409 and code == "fx_correction_required")
    st, body, _ = host.rpc("keep_fx_estimate", p_expense=pinned, p_expected_version=e["version"], p_request_id=str(uuid.uuid4()),
                           p_replacement_quote_id=e["fx_proposal"]["quote_id"])
    check("host keeps the pinned estimate after the upgrade", st == 200 and ledger(trip_b)[pinned]["fx_correction"] == "kept")
    st, _, _ = host.rpc("finalize_settlement", p_trip=trip_b, p_expected_revision=body["revision"], p_request_id=str(uuid.uuid4()))
    f_b = member.rpc("get_finalized_settlement", p_trip=trip_b)[1]
    x = f_b["snapshot"]["inputs"]["expenses"][0]
    check("finalized as v2 with the pinned estimate still labelled estimated",
          st == 200 and f_b["rule_version"] == "explicit-krw-shares-v2" and x["is_estimate"] is True
          and x["krw_amount"] == 13554 and x["fx"]["rate"] == "903.60")

    lb.reset()
    failed = [c for c in sc.checks if not c["ok"]]
    summary = {"passed": len(sc.checks) - len(failed), "total": len(sc.checks), "checks": sc.checks}
    if out:
        out.write_text(json.dumps(summary, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"{summary['passed']}/{summary['total']} passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
