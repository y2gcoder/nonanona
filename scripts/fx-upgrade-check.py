#!/usr/bin/env python3
"""엔화 원화 기준 마이그레이션(20261124130000 이후 전부: 정정 정책 20261124150000, 확정 재시도 null-safe 20261124160000 포함) 업그레이드 검사. 로컬 DB를 바로 앞 마이그레이션까지 되돌려 예전 규칙(v1)으로
확정본과 검토 요청을 만든 뒤, 새 마이그레이션을 올리고 예전 자료가 그대로인지 본다. 끝나면 local:reset 상태로 되돌린다.

사용(저장소 루트, local:up 뒤): python3 -I scripts/fx-upgrade-check.py [결과 JSON 경로]
로컬 DB를 지우고 다시 만든다(가상 자료만 있다). 토큰·키·비밀번호는 출력하지 않는다.
"""

import importlib.util
import json
import sys
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BEFORE = "20261124120000"


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / file)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else None
    lb = load("local_backend", "local-backend.py")
    lb.reset(version=BEFORE)
    sc = load("settlement_contract", "settlement-contract.py")
    check, psql = sc.check, sc.psql
    env = lb.status()
    accounts = json.loads((lb.RUN / "accounts.json").read_text())
    host, member = sc.Client(env, *accounts["host"]), sc.Client(env, *accounts["member"])
    check("database is at the previous migration (no fx tables)",
          psql("select to_regclass('public.fx_quotes') is null") == "t")

    def submit(trip, day, amount, cur):
        st, body, _ = member.rpc("submit_manual_expense", p_trip=trip, p_request_id=str(uuid.uuid4()), p_expense_date=day,
                                 p_amount_minor=amount, p_currency=cur, p_merchant="가상 업그레이드")
        return body["expense_id"]

    def include(eid, krw, req=None):
        params = dict(p_expense=eid, p_expected_version=1, p_request_id=req or str(uuid.uuid4()), p_decision="include",
                      p_payer=host.uid, p_shares=[{"user_id": host.uid, "krw": krw - krw // 2},
                                                  {"user_id": member.uid, "krw": krw // 2}])
        if krw != 38000:
            params["p_krw_amount"] = krw
        return params, host.rpc("review_expense", **params)

    # 예전 규칙으로 확정한 방(A)과 열린 방(B: 검토한 지출 + 확인 필요 엔화 지출).
    trip_a = sc.new_trip(host.uid, member.uid)
    include(submit(trip_a, "2026-11-03", 1408, "JPY"), 13377)
    include(submit(trip_a, "2026-11-08", 38000, "KRW"), 38000)
    rev = host.rpc("get_room_ledger", p_trip=trip_a)[1]["revision"]
    fin_req = dict(p_trip=trip_a, p_expected_revision=rev, p_request_id=str(uuid.uuid4()))
    st, fin_body, _ = host.rpc("finalize_settlement", **fin_req)
    check("v1 finalize before the migration", st == 200)
    f_before = member.rpc("get_finalized_settlement", p_trip=trip_a)[1]
    row_before = psql(f"select md5(snapshot::text) || '|' || snapshot_sha256 || '|' || rule_version || '|' || included_total_krw "
                      f"from public.finalizations where trip_id = '{trip_a}'")
    trip_b = sc.new_trip(host.uid, member.uid)
    verified = submit(trip_b, "2026-11-03", 1408, "JPY")
    old_req, (st, old_resp, _) = include(verified, 13377)
    pending = submit(trip_b, "2026-11-03", 1276, "JPY")
    check("old review stored before the migration", st == 200 and not old_resp["replayed"])

    rc = lb.supabase("migration", "up", log_name="migration-up", check=False)
    check("migration applies on top of existing v1 data", rc == 0)
    lb.load_fx_fixture()

    check("v1 finalization row is byte-for-byte unchanged",
          psql(f"select md5(snapshot::text) || '|' || snapshot_sha256 || '|' || rule_version || '|' || included_total_krw "
               f"from public.finalizations where trip_id = '{trip_a}'") == row_before, before=row_before.split("|")[2])
    f_after = member.rpc("get_finalized_settlement", p_trip=trip_a)[1]
    check("v1 finalized settlement reads back identically (rule_version v1, no new keys)",
          f_after == f_before and f_after["rule_version"] == "explicit-krw-shares-v1"
          and all("is_estimate" not in e and "fx" not in e for e in f_after["snapshot"]["inputs"]["expenses"]))
    st, fin_replay, _ = host.rpc("finalize_settlement", **fin_req)
    check("v1 finalize key/revision sent before both FX migrations replays exactly after them",
          st == 200 and fin_replay == {"finalization_id": fin_body["finalization_id"], "version": fin_body["version"],
                                       "replayed": True}, got=fin_replay if st == 200 else st)
    for label, revision in (("a null revision", None), ("a different revision", rev + 1)):
        st, code, _ = host.rpc("finalize_settlement", **{**fin_req, "p_expected_revision": revision})
        check(f"that v1 key with {label} -> idempotency_conflict (no replay)", st == 409 and code == "idempotency_conflict",
              code=code)
    st, replay, _ = host.rpc("review_expense", **old_req)
    check("review sent before the migration replays with the same result after it",
          st == 200 and replay["replayed"] and replay["version"] == old_resp["version"])
    led = {e["expense_id"]: e for e in host.rpc("get_room_ledger", p_trip=trip_b)[1]["expenses"]}
    check("existing verified charge keeps its basis and is not an estimate",
          led[verified]["krw_basis"] == "verified_krw_charge" and led[verified]["is_estimate"] is False
          and led[verified]["fx"] is None and led[verified]["krw_amount"] == 13377)
    p = led[pending]["fx_proposal"]
    check("pending JPY expense now gets a server proposal (synthetic fixture)",
          p["status"] == "proposed" and p["rate_date"] == "2026-11-02" and p["krw"] == 11551 and p["data_origin"] == "fixture")
    st, _, _ = host.rpc("review_expense", p_expense=pending, p_expected_version=1, p_request_id=str(uuid.uuid4()),
                        p_decision="include", p_payer=host.uid, p_krw_amount=11551, p_krw_basis="reference_rate_estimate",
                        p_fx_quote_id=p["quote_id"], p_shares=[{"user_id": host.uid, "krw": 5776}, {"user_id": member.uid, "krw": 5775}])
    rev = host.rpc("get_room_ledger", p_trip=trip_b)[1]["revision"]
    st2, _, _ = host.rpc("finalize_settlement", p_trip=trip_b, p_expected_revision=rev, p_request_id=str(uuid.uuid4()))
    f_b = member.rpc("get_finalized_settlement", p_trip=trip_b)[1]
    check("after the migration, an estimate is approved and finalized as v2",
          st == 200 and st2 == 200 and f_b["rule_version"] == "explicit-krw-shares-v2"
          and f_b["snapshot"]["outputs"]["estimated_total_krw"] == 11551)

    lb.reset()
    failed = [c for c in sc.checks if not c["ok"]]
    summary = {"passed": len(sc.checks) - len(failed), "total": len(sc.checks), "checks": sc.checks}
    if out:
        out.write_text(json.dumps(summary, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"{summary['passed']}/{summary['total']} passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
