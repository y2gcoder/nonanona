#!/usr/bin/env python3
"""두 앱의 응답 해석 시험에 쓰는 실제 서버 응답(가상 값)을 apps/fixtures/settlement/fx-responses/에 저장한다.

사용(저장소 루트, local:up 뒤): python3 -I scripts/capture-fx-responses.py
로컬 DB를 앞 마이그레이션으로 되돌려 v1 확정본을 만들고, 새 마이그레이션을 올린 뒤 엔화 기준(실제 청구액·환전 원가·
기준환율 예상·확인 못 한 날짜)의 장부·미리보기·v2 확정본을 받는다. 끝나면 local:reset 상태로 되돌린다.
기준환율은 가상 시험값(data_origin=fixture)이다. 계정 ID·토큰은 저장하지 않는다(ID는 가상 UUID로 바꾼다).
"""

import importlib.util
import json
import re
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "apps" / "fixtures" / "settlement" / "fx-responses"


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / file)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    lb = load("local_backend", "local-backend.py")
    lb.reset(version="20261124120000")
    sc = load("settlement_contract", "settlement-contract.py")
    env = lb.status()
    accounts = json.loads((lb.RUN / "accounts.json").read_text())
    host, member = sc.Client(env, *accounts["host"]), sc.Client(env, *accounts["member"])
    names = {}

    def submit(trip, day, amount, cur, merchant):
        st, body, _ = member.rpc("submit_manual_expense", p_trip=trip, p_request_id=str(uuid.uuid4()), p_expense_date=day,
                                 p_amount_minor=amount, p_currency=cur, p_merchant=merchant)
        return body["expense_id"]

    def pair(krw):
        return [{"user_id": host.uid, "krw": krw - krw // 2}, {"user_id": member.uid, "krw": krw // 2}]

    def review(eid, **kw):
        st, body, _ = host.rpc("review_expense", p_expense=eid, p_expected_version=1, p_request_id=str(uuid.uuid4()),
                               p_decision="include", p_payer=host.uid, **kw)
        assert st == 200, (st, body)

    def finalize(trip):
        rev = host.rpc("get_room_ledger", p_trip=trip)[1]["revision"]
        st, _, _ = host.rpc("finalize_settlement", p_trip=trip, p_expected_revision=rev, p_request_id=str(uuid.uuid4()))
        assert st == 200
        return member.rpc("get_finalized_settlement", p_trip=trip)[1]

    # v1(앞 마이그레이션): 실제 청구액 엔화 + 원화.
    v1_trip = sc.new_trip(host.uid, member.uid)
    review(submit(v1_trip, "2026-11-03", 1408, "JPY", "さくら食堂"), p_krw_amount=13377, p_shares=pair(13377))
    review(submit(v1_trip, "2026-11-08", 38000, "KRW", "입장권"), p_shares=pair(38000))
    final_v1 = finalize(v1_trip)
    assert lb.supabase("migration", "up", log_name="migration-up", check=False) == 0
    lb.load_fx_fixture()

    trip = sc.new_trip(host.uid, member.uid)
    actual = submit(trip, "2026-11-03", 1408, "JPY", "さくら食堂")
    acq = submit(trip, "2026-11-03", 8000, "JPY", "현금 공동 지출")
    est = submit(trip, "2026-11-03", 1276, "JPY", "みなと珈琲")
    pending = submit(trip, "2026-11-04", 1500, "JPY", "駅弁")
    undetermined = submit(trip, "2026-12-01", 2000, "JPY", "미래 날짜")
    review(actual, p_krw_amount=13377, p_shares=pair(13377))
    review(acq, p_krw_basis="acquisition_cost", p_acq_krw=95000, p_acq_foreign_minor=10000, p_krw_amount=76000,
           p_shares=pair(76000))
    proposal = host.rpc("get_room_ledger", p_trip=trip)[1]
    p_est = next(e for e in proposal["expenses"] if e["expense_id"] == est)["fx_proposal"]
    review(est, p_krw_basis="reference_rate_estimate", p_fx_quote_id=p_est["quote_id"], p_krw_amount=p_est["krw"],
           p_shares=pair(p_est["krw"]))
    ledger = host.rpc("get_room_ledger", p_trip=trip)[1]
    preview = host.rpc("preview_settlement", p_trip=trip)[1]
    host.rpc("review_expense", p_expense=pending, p_expected_version=1, p_request_id=str(uuid.uuid4()), p_decision="hold",
             p_hold_reason="원화 청구액 확인 대기")
    host.rpc("review_expense", p_expense=undetermined, p_expected_version=1, p_request_id=str(uuid.uuid4()),
             p_decision="hold", p_hold_reason="원화 청구액 확인 대기")
    final_v2 = finalize(trip)
    lb.reset()

    # 실제 계정 ID 대신 고정한 가상 UUID(두 앱 시험이 이름으로 가리킨다).
    replace = {host.uid: "00000000-0000-4000-8000-00000000000a", member.uid: "00000000-0000-4000-8000-00000000000b"}
    OUT.mkdir(parents=True, exist_ok=True)
    for name, body in (("ledger-open.json", ledger), ("preview-open.json", preview), ("final-v1.json", final_v1),
                       ("final-v2.json", final_v2)):
        text = json.dumps(body, ensure_ascii=False, indent=1, sort_keys=True)
        for real, fake in replace.items():
            text = text.replace(real, fake)
        assert not re.search(r"token|password|@example", text)
        (OUT / name).write_text(text + "\n", encoding="utf-8")
        print(f"[capture] {name}")


if __name__ == "__main__":
    main()
