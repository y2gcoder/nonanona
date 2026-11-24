#!/usr/bin/env python3
"""두 앱의 정정 상태 해석 시험에 쓰는 실제 서버 응답(가상 값)을 apps/fixtures/settlement/fx-responses/에 저장한다(ADR-0009).

사용(저장소 루트, local:up 뒤): python3 -I scripts/capture-fx-correction-responses.py
새 가상 여행방에 엔화 예상액 넷을 포함하고 가상 시험 환율을 정정해 장부(required·kept·unavailable·정정 없음)와 미리보기
(fx_correction_expense_ids), 확정 거절 응답(fx_correction_required)을 받는다. 끝나면 local:reset 상태로 되돌린다.
계정 ID는 고정한 가상 UUID로 바꾼다. 토큰은 저장하지 않는다.
"""

import datetime
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
    lb.reset()
    sc = load("settlement_contract", "settlement-contract.py")
    fx = load("ecos_fx", "ecos-fx.py")
    env = lb.status()
    accounts = json.loads((lb.RUN / "accounts.json").read_text())
    host, member = sc.Client(env, *accounts["host"]), sc.Client(env, *accounts["member"])
    trip = sc.new_trip(host.uid, member.uid)

    def submit(day, amount, merchant):
        st, body, _ = member.rpc("submit_manual_expense", p_trip=trip, p_request_id=str(uuid.uuid4()), p_expense_date=day,
                                 p_amount_minor=amount, p_currency="JPY", p_merchant=merchant)
        return body["expense_id"]

    def ledger():
        return {e["expense_id"]: e for e in host.rpc("get_room_ledger", p_trip=trip)[1]["expenses"]}

    def include(eid):
        e = ledger()[eid]
        p = e["fx_proposal"]
        st, body, _ = host.rpc("review_expense", p_expense=eid, p_expected_version=e["version"], p_request_id=str(uuid.uuid4()),
                               p_decision="include", p_payer=host.uid, p_krw_amount=p["krw"], p_krw_basis="reference_rate_estimate",
                               p_fx_quote_id=p["quote_id"], p_shares=[{"user_id": host.uid, "krw": p["krw"] - p["krw"] // 2},
                                                                      {"user_id": member.uid, "krw": p["krw"] // 2}])
        assert st == 200, (st, body)

    current = submit("2026-11-03", 1276, "みなと珈琲")
    required = submit("2026-11-04", 1500, "駅弁")
    kept = submit("2026-11-05", 1000, "コンビニ")
    unavailable = submit("2026-10-20", 2000, "空港バス")
    for eid in (current, required, kept, unavailable):
        include(eid)
    ok1, _ = fx.ingest_fixture(fx.ecos_shape({"2026-11-04": "904.20", "2026-11-05": "902.55"}),
                               datetime.date(2026, 11, 4), datetime.date(2026, 11, 5))
    ok2, _ = fx.ingest_fixture(fx.ecos_shape({}), datetime.date(2026, 10, 19), datetime.date(2026, 10, 20))
    assert ok1 and ok2
    e = ledger()[kept]
    st, _, _ = host.rpc("keep_fx_estimate", p_expense=kept, p_expected_version=e["version"], p_request_id=str(uuid.uuid4()),
                        p_replacement_quote_id=e["fx_proposal"]["quote_id"])
    assert st == 200
    led = host.rpc("get_room_ledger", p_trip=trip)[1]
    states = {x["expense_id"]: x["fx_correction"] for x in led["expenses"]}
    assert states == {current: None, required: "required", kept: "kept", unavailable: "unavailable"}, states
    preview = host.rpc("preview_settlement", p_trip=trip)[1]
    st, code, refused = host.rpc("finalize_settlement", p_trip=trip, p_expected_revision=preview["revision"],
                                 p_request_id=str(uuid.uuid4()))
    assert st == 409 and code == "fx_correction_required", (st, code)
    lb.reset()

    replace = {host.uid: "00000000-0000-4000-8000-00000000000a", member.uid: "00000000-0000-4000-8000-00000000000b"}
    OUT.mkdir(parents=True, exist_ok=True)
    for name, body in (("ledger-correction.json", led), ("preview-correction.json", preview),
                       ("finalize-correction-refused.json", refused)):
        text = json.dumps(body, ensure_ascii=False, indent=1, sort_keys=True)
        for real, fake in replace.items():
            text = text.replace(real, fake)
        assert not re.search(r"token|password|@example", text)
        (OUT / name).write_text(text + "\n", encoding="utf-8")
        print(f"[capture] {name}")


if __name__ == "__main__":
    main()
