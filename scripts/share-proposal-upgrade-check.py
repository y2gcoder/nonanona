#!/usr/bin/env python3
"""제안 범위 마이그레이션(20261124180000) 업그레이드 검사(ADR-0011, 표준 라이브러리만, DB를 지우지 않는다).

사용(저장소 루트):
  python3 -I scripts/share-proposal-upgrade-check.py prepare   # 20261124170000까지 적용된 상태에서
  supabase migration up                                         # 20261124180000 적용
  python3 -I scripts/share-proposal-upgrade-check.py verify [결과 JSON]

prepare: 새 가상 여행방에 USD 사본 지출을 올리고 방장이 실제 청구액으로 포함한 뒤, 올린 회원이 예전 RPC로 USD 실제 청구액
제안을 보낸다(앱은 이 제안을 읽지 못한다). KRW 지출에는 정상 제안을 보낸다. 여행방·요청 키를 supabase/.run/에 남긴다.
verify: 같은 여행방의 장부가 방장·올린 회원에게 그대로 읽히고(USD 지출의 제안은 null, KRW 제안은 그대로 current),
예전 USD 행·같은 요청 키의 재시도는 예전 결과(replayed)로 수렴하며, 새 USD 제안은 basis_invalid로 거절된다.
"""

import hashlib
import importlib.util
import json
import sys
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("settlement_contract", ROOT / "scripts" / "settlement-contract.py")
sc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sc)
lb = sc.lb
STATE = lb.RUN / "share-proposal-upgrade.json"


def clients():
    env = lb.status()
    accounts = json.loads((lb.RUN / "accounts.json").read_text())
    return env, (lambda: sc.Client(env, *accounts["host"])), (lambda: sc.Client(env, *accounts["member"]))


def receipt(member, trip, day, amount, currency, shade):
    req = str(uuid.uuid4())
    png = sc.tiny_png(shade)
    st, _ = member.upload(f"{trip}/{member.uid}/{req}.png", png)
    assert st == 200, st
    st, body, _ = member.rpc("submit_receipt_expense", p_trip=trip, p_request_id=req, p_expense_date=day, p_amount_minor=amount,
                             p_currency=currency, p_merchant="가상 업그레이드", p_artifact_sha256=hashlib.sha256(png).hexdigest())
    assert st == 200, body
    return body["expense_id"]


def prepare():
    _, H, M = clients()
    host, member = H(), M()
    trip = sc.new_trip(host.uid, member.uid)
    usd = receipt(member, trip, "1971-03-03", 4200, "USD", 211)
    krw = receipt(member, trip, "1971-03-03", 9001, "KRW", 212)
    st, body, _ = H().rpc("review_expense", p_expense=usd, p_expected_version=1, p_request_id=str(uuid.uuid4()),
                          p_decision="include", p_payer=host.uid, p_krw_amount=56789,
                          p_shares=[{"user_id": host.uid, "krw": 30000}, {"user_id": member.uid, "krw": 26789}])
    assert st == 200, body
    usd_req = str(uuid.uuid4())
    usd_shares = [{"user_id": host.uid, "krw": 28000}, {"user_id": member.uid, "krw": 28789}]
    st, body, _ = M().rpc("propose_expense_shares", p_expense=usd, p_expected_version=2, p_request_id=usd_req,
                          p_krw_basis="verified_krw_charge", p_krw_total=56789, p_shares=usd_shares)
    assert st == 200, ("the pre-migration RPC accepts a USD verified-charge proposal", st, body)
    krw_req = str(uuid.uuid4())
    krw_shares = [{"user_id": host.uid, "krw": 5001}, {"user_id": member.uid, "krw": 4000}]
    st, body, _ = M().rpc("propose_expense_shares", p_expense=krw, p_expected_version=1, p_request_id=krw_req,
                          p_krw_basis="krw_original", p_krw_total=9001, p_shares=krw_shares)
    assert st == 200, body
    STATE.write_text(json.dumps({"trip": trip, "usd": usd, "krw": krw, "usd_req": usd_req, "usd_shares": usd_shares,
                                 "krw_req": krw_req, "krw_shares": krw_shares}) + "\n")
    print(f"[upgrade] prepared trip with a legacy USD verified-charge proposal ({STATE.name})")


def verify(out):
    s = json.loads(STATE.read_text())
    _, H, M = clients()
    for name, client in (("host", H), ("uploader", M)):
        st, body, _ = client().rpc("get_room_ledger", p_trip=s["trip"])
        sc.check(f"{name} ledger still readable after the upgrade", st == 200, status=st)
        by = {e["expense_id"]: e for e in body["expenses"]}
        sc.check(f"{name}: legacy USD proposal is not exposed (null)", by[s["usd"]]["share_proposal"] is None)
        sc.check(f"{name}: the KRW proposal is unchanged and current",
                 by[s["krw"]]["share_proposal"] and by[s["krw"]]["share_proposal"]["state"] == "current")
    st, body, _ = M().rpc("propose_expense_shares", p_expense=s["usd"], p_expected_version=2, p_request_id=s["usd_req"],
                          p_krw_basis="verified_krw_charge", p_krw_total=56789, p_shares=s["usd_shares"])
    sc.check("exact replay of the legacy USD request converges to its stored result", st == 200 and body["replayed"] is True,
             status=st)
    st, code, _ = M().rpc("propose_expense_shares", p_expense=s["usd"], p_expected_version=2, p_request_id=str(uuid.uuid4()),
                          p_krw_basis="verified_krw_charge", p_krw_total=56789, p_shares=s["usd_shares"])
    sc.check("a new USD verified-charge proposal is rejected after the upgrade", st == 400 and code == "basis_invalid", code=code)
    st, body, _ = M().rpc("propose_expense_shares", p_expense=s["krw"], p_expected_version=1, p_request_id=s["krw_req"],
                          p_krw_basis="krw_original", p_krw_total=9001, p_shares=s["krw_shares"])
    sc.check("exact replay of a KRW proposal is unchanged", st == 200 and body["replayed"] is True and body.get("latest") is True)
    rows = sc.psql(f"select count(*) from public.expense_share_proposals where trip_id = '{s['trip']}'")
    sc.check("legacy rows are kept (immutable), not deleted", rows == "2", rows=rows)
    failed = [c for c in sc.checks if not c["ok"]]
    summary = {"passed": len(sc.checks) - len(failed), "total": len(sc.checks), "checks": sc.checks}
    if out:
        Path(out).write_text(json.dumps(summary, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"{summary['passed']}/{summary['total']} passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    if sys.argv[1] == "prepare":
        prepare()
    else:
        verify(sys.argv[2] if len(sys.argv) > 2 else None)
