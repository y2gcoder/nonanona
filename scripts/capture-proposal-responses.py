#!/usr/bin/env python3
"""두 앱의 제안 몫 해석 시험에 쓰는 실제 서버 응답(가상 값)을 apps/fixtures/settlement/proposal-responses/에 저장한다(ADR-0011).

사용(저장소 루트, local:up 뒤): python3 -I scripts/capture-proposal-responses.py
새 가상 여행방(방장·올린 회원·셋째 회원)에 사본으로 올린 지출 넷을 만들고 올린 회원이 제안을 보낸다:
KRW current, 엔화 예상액 current, 방장이 같은 몫으로 포함한 applied, 그 뒤 다시 검토돼 stale_expense.
세 사람의 장부와 제안 보내기 응답을 저장한다. DB를 지우지 않는다(새 여행방만 만든다).
계정 ID는 고정한 가상 UUID로 바꾼다. 토큰은 저장하지 않는다.
"""

import hashlib
import importlib.util
import json
import re
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "apps" / "fixtures" / "settlement" / "proposal-responses"


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / file)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    sc = load("settlement_contract", "settlement-contract.py")
    lb = sc.lb
    env = lb.status()
    accounts = json.loads((lb.RUN / "accounts.json").read_text())
    host, member = sc.Client(env, *accounts["host"]), sc.Client(env, *accounts["member"])
    third = sc.new_joiner(env, "라마")
    trip = sc.new_trip(host.uid, member.uid)
    sc.psql(f"insert into public.trip_members (trip_id, user_id, role, display_name) values ('{trip}', '{third.uid}', 'member', '라마')")

    def receipt(day, amount, currency, merchant, shade):
        req = str(uuid.uuid4())
        png = sc.tiny_png(shade)
        st, _ = member.upload(f"{trip}/{member.uid}/{req}.png", png)
        assert st == 200
        st, body, _ = member.rpc("submit_receipt_expense", p_trip=trip, p_request_id=req, p_expense_date=day,
                                 p_amount_minor=amount, p_currency=currency, p_merchant=merchant,
                                 p_artifact_sha256=hashlib.sha256(png).hexdigest())
        assert st == 200, body
        return body["expense_id"]

    def ledger(client=host):
        return {e["expense_id"]: e for e in client.rpc("get_room_ledger", p_trip=trip)[1]["expenses"]}

    def propose(eid, basis, total, shares, quote=None):
        e = ledger()[eid]
        st, body, raw = member.rpc("propose_expense_shares", p_expense=eid, p_expected_version=e["version"],
                                   p_request_id=str(uuid.uuid4()), p_krw_basis=basis, p_krw_total=total, p_fx_quote_id=quote,
                                   p_shares=shares)
        assert st == 200, body
        return raw

    def sh(h, m, t=None):
        out = [{"user_id": host.uid, "krw": h}, {"user_id": member.uid, "krw": m}]
        return out + ([{"user_id": third.uid, "krw": t}] if t else [])

    krw = receipt("2026-11-03", 10001, "KRW", "가상 분식", 201)
    jpy = receipt("2026-11-03", 1408, "JPY", "さくら食堂", 202)
    applied = receipt("2026-11-04", 9000, "KRW", "가상 카페", 203)
    stale = receipt("2026-11-04", 7000, "KRW", "가상 편의점", 204)
    submitted = propose(krw, "krw_original", 10001, sh(6000, 3001, 1000))
    p = ledger()[jpy]["fx_proposal"]
    assert p["status"] == "proposed", p
    k = p["krw"]
    propose(jpy, "reference_rate_estimate", k, sh(k - k // 2, k // 2), quote=p["quote_id"])
    propose(applied, "krw_original", 9000, sh(4500, 4500))
    propose(stale, "krw_original", 7000, sh(3500, 3500))
    for eid, shares in ((applied, sh(4500, 4500)), (stale, sh(6000, 1000))):
        e = ledger()[eid]
        st, _, _ = host.rpc("review_expense", p_expense=eid, p_expected_version=e["version"], p_request_id=str(uuid.uuid4()),
                            p_decision="include", p_payer=host.uid, p_shares=shares)
        assert st == 200
    led_host = host.rpc("get_room_ledger", p_trip=trip)[1]
    states = {x["expense_id"]: (x["share_proposal"] or {}).get("state") for x in led_host["expenses"]}
    assert states == {krw: "current", jpy: "current", applied: "applied", stale: "stale_expense"}, states
    led_member = member.rpc("get_room_ledger", p_trip=trip)[1]
    led_other = third.rpc("get_room_ledger", p_trip=trip)[1]
    assert all(x["share_proposal"] is None for x in led_other["expenses"])

    replace = {host.uid: "00000000-0000-4000-8000-00000000000a", member.uid: "00000000-0000-4000-8000-00000000000b",
               third.uid: "00000000-0000-4000-8000-00000000000c"}
    OUT.mkdir(parents=True, exist_ok=True)
    for name, body in (("ledger-host.json", led_host), ("ledger-uploader.json", led_member),
                       ("ledger-other-member.json", led_other), ("propose-submitted.json", submitted)):
        text = json.dumps(body, ensure_ascii=False, indent=1, sort_keys=True)
        for real, fake in replace.items():
            text = text.replace(real, fake)
        assert not re.search(r"token|password|@example", text)
        (OUT / name).write_text(text + "\n", encoding="utf-8")
        print(f"[capture] {name}")


if __name__ == "__main__":
    main()
