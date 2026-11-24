#!/usr/bin/env python3
"""품목 나누기 제안 몫(ADR-0011) 서버 계약 시험. 로컬 Supabase에 실제 HTTP로 요청한다. 표준 라이브러리만 쓴다.

사용(저장소 루트, local:up 또는 local:reset 뒤, 20261124170000 마이그레이션 적용): python3 -I scripts/share-proposal-contract.py [결과 JSON]

* 실행마다 새 가상 여행방(방장·올린 회원·셋째 회원)과 바깥 계정을 만든다. 기준환율은 가상 시험값(data_origin=fixture)만,
  1961~1980년 중 한 해의 9~10월을 쓴다(다른 계약 시험·시드·앱 E2E의 날짜와 겹치지 않는다).
* 보는 것: 올린 사람만 제안(다른 구성원 uploader_only, 바깥 계정 trip_not_found), 정확한 양의 원 몫·구성원·합,
  원화 기준 묶기(KRW 원래 금액, 엔화 예상액의 고시값 식별, 방장이 포함한 실제 청구액), 지출 버전·고시값 정정에 따른 stale,
  재시도 수렴·같은 키 다른 내용 거절, 잠금 아래 방장 검토와의 경쟁, 제안이 장부 몫·revision·확정에 닿지 않음,
  보이는 사람(올린 사람·방장만), 확정 뒤 거절과 재시도, 표에 품목 글자 열이 없음.
* 토큰·키·비밀번호는 출력하지 않는다. 결과에는 검사 이름, HTTP 상태, 서버가 정한 코드만 남긴다.
"""

import datetime
import hashlib
import importlib.util
import json
import secrets
import sys
import threading
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
fxc = load("fx_correction_contract", "fx-correction-contract.py")
lb = sc.lb
check, psql, Client = sc.check, sc.psql, sc.Client


def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else None
    env = lb.status()
    accounts = json.loads((lb.RUN / "accounts.json").read_text())
    host = Client(env, *accounts["host"])
    member = Client(env, *accounts["member"])
    third = sc.new_joiner(env, "라마")
    outsider = sc.new_joiner(env, "마바")

    year = 1961 + secrets.randbelow(20)
    B = datetime.date(year, 9, 1)

    def d(n):
        return (B + datetime.timedelta(days=n)).isoformat()

    def ingest(values, start, end):
        ok, res = fx.ingest_fixture(fx.ecos_shape({d(k): v for k, v in values.items()}),
                                    datetime.date.fromisoformat(d(start)), datetime.date.fromisoformat(d(end)))
        assert ok, res

    ingest({2: "900.00", 5: "905.25"}, 0, 9)  # d20 이후는 덮지 않는다(undetermined)

    trip = sc.new_trip(host.uid, member.uid)
    psql(f"insert into public.trip_members (trip_id, user_id, role, display_name) values ('{trip}', '{third.uid}', 'member', '라마')")

    def receipt(client, key, day, amount, currency):
        req = str(uuid.uuid4())
        png = sc.tiny_png(200 + len(key))
        sha = hashlib.sha256(png).hexdigest()
        st, _ = client.upload(f"{trip}/{client.uid}/{req}.png", png)
        assert st == 200, (key, st)
        st, body, _ = client.rpc("submit_receipt_expense", p_trip=trip, p_request_id=req, p_expense_date=day,
                                 p_amount_minor=amount, p_currency=currency, p_merchant=f"가상 {key}", p_artifact_sha256=sha)
        assert st == 200, (key, st, body)
        return body["expense_id"]

    ids = {
        "krw": receipt(member, "krw", d(3), 10001, "KRW"),
        "jpy": receipt(member, "jpy", d(5), 1408, "JPY"),
        "verified": receipt(member, "verified", d(6), 3500, "JPY"),
        "host_up": receipt(host, "host_up", d(7), 9000, "KRW"),
        "nofx": receipt(member, "nofx", d(25), 1000, "JPY"),
        "race": receipt(member, "race", d(8), 7000, "KRW"),
    }
    st, body, _ = member.rpc("submit_manual_expense", p_trip=trip, p_request_id=str(uuid.uuid4()), p_expense_date=d(4),
                             p_amount_minor=5000, p_currency="KRW", p_merchant="가상 직접")
    ids["manual"] = body["expense_id"]

    def ledger(client=host):
        st, body, _ = client.rpc("get_room_ledger", p_trip=trip)
        assert st == 200, st
        return {e["expense_id"]: e for e in body["expenses"]}, body

    def exp(key, client=host):
        return ledger(client)[0][ids[key]]

    def shares(**by):
        who = {"host": host.uid, "member": member.uid, "third": third.uid, "outsider": outsider.uid}
        return [{"user_id": who[k], "krw": v} for k, v in by.items()]

    def propose(key, basis, total, sh, client=member, version=None, quote=None, request=None):
        e = exp(key)
        req = request or str(uuid.uuid4())
        st, body, raw = client.rpc("propose_expense_shares", p_expense=ids[key],
                                   p_expected_version=e["version"] if version is None else version, p_request_id=req,
                                   p_krw_basis=basis, p_krw_total=total, p_fx_quote_id=quote, p_shares=sh)
        return st, body, req

    def revision():
        return ledger()[1]["revision"]

    # ------------------------------------------------------------ 올린 사람만, 정확한 몫
    rev0 = revision()
    good = shares(host=6000, member=3001, third=1000)
    st, body, req = propose("krw", "krw_original", 10001, good)
    check("uploader proposes exact positive KRW shares", st == 200 and body["replayed"] is False, status=st)
    first_id = body.get("proposal_id") if st == 200 else None
    st, body, _ = propose("krw", "krw_original", 10001, list(reversed(good)), request=req)
    check("same key, same content (any share order) replays the same proposal",
          st == 200 and body["replayed"] and body["proposal_id"] == first_id, status=st)
    st, code, _ = propose("krw", "krw_original", 10001, shares(host=6001, member=3000, third=1000), request=req)
    check("same key with different shares -> idempotency_conflict", st == 409 and code == "idempotency_conflict", code=code)
    st, code, _ = propose("krw", "krw_original", 10001, good, client=host, request=req)
    check("same key from another account is not a replay -> idempotency_conflict", st == 409 and code == "idempotency_conflict",
          code=code)
    st, code, _ = propose("krw", "krw_original", 10001, good, client=host)
    check("host (not the uploader) cannot propose -> uploader_only", st == 403 and code == "uploader_only", code=code)
    st, code, _ = propose("krw", "krw_original", 10001, good, client=third)
    check("another member cannot propose -> uploader_only", st == 403 and code == "uploader_only", code=code)
    st, code, _ = outsider.rpc("propose_expense_shares", p_expense=ids["krw"], p_expected_version=1,
                               p_request_id=str(uuid.uuid4()), p_krw_basis="krw_original", p_krw_total=10001, p_shares=good)
    check("outsider -> trip_not_found (no existence leak)", st == 404 and code == "trip_not_found", code=code)
    st, code, _ = outsider.rpc("propose_expense_shares", p_expense=str(uuid.uuid4()), p_expected_version=1,
                               p_request_id=str(uuid.uuid4()), p_krw_basis="krw_original", p_krw_total=1, p_shares=good)
    check("unknown expense -> trip_not_found", st == 404 and code == "trip_not_found", code=code)
    st, code, _ = propose("host_up", "krw_original", 9000, shares(host=4500, member=4500), client=member)
    check("member cannot propose for the host's upload -> uploader_only", st == 403 and code == "uploader_only", code=code)
    st, body, _ = propose("host_up", "krw_original", 9000, shares(host=4500, member=4500), client=host)
    check("a host who uploaded the receipt may propose for it (other device)", st == 200, status=st)

    bad = {
        "zero share": shares(host=10001, member=0),
        "negative share": shares(host=10002, member=-1),
        "fractional share": [{"user_id": host.uid, "krw": 5000.5}, {"user_id": member.uid, "krw": 5000.5}],
        "string amount": [{"user_id": host.uid, "krw": "10001"}],
        "non-member beneficiary": shares(host=5001, outsider=5000),
        "duplicate member": [{"user_id": host.uid, "krw": 5001}, {"user_id": host.uid, "krw": 5000}],
        "extra key (item name)": [{"user_id": host.uid, "krw": 10001, "name": "唐揚げ"}],
        "not an array": {"user_id": host.uid, "krw": 10001},
        "empty": [],
    }
    for name, sh in bad.items():
        st, code, _ = propose("krw", "krw_original", 10001, sh)
        check(f"{name} -> shares_invalid", st == 400 and code == "shares_invalid", code=code)
    st, code, _ = propose("krw", "krw_original", 10001, shares(host=6000, member=4000))
    check("shares not summing to the total -> shares_mismatch (no silent remainder)", st == 400 and code == "shares_mismatch",
          code=code)
    st, code, _ = propose("krw", "krw_original", 10000, shares(host=6000, member=4000))
    check("KRW total different from the amount -> krw_mismatch", st == 400 and code == "krw_mismatch", code=code)
    for basis in ("reference_rate_estimate", "verified_krw_charge", "acquisition_cost", "made_up", None):
        st, code, _ = propose("krw", basis, 10001, good)
        check(f"KRW expense with basis {basis} -> basis_invalid", st == 400 and code == "basis_invalid", code=code)
    st, code, _ = propose("krw", "krw_original", 10001, good, version=99)
    check("proposal bound to an old/unknown version -> stale_expense", st == 409 and code == "stale_expense", code=code)
    st, code, _ = member.rpc("propose_expense_shares", p_expense=ids["manual"], p_expected_version=1,
                             p_request_id=str(uuid.uuid4()), p_krw_basis="krw_original", p_krw_total=5000,
                             p_shares=shares(member=5000))
    check("manual entry (no receipt, no items) -> invalid_fields", st == 400 and code == "invalid_fields", code=code)

    # ------------------------------------------------------------ 제안은 장부에 닿지 않는다 / 보이는 사람
    e = exp("krw")
    check("a proposal does not change the expense (still pending, no shares, same version)",
          e["status"] == "pending" and e["shares"] == [] and e["version"] == 1)
    check("a proposal does not bump the room revision", revision() == rev0)
    p = e["share_proposal"]
    check("host sees the current proposal (basis, total, exact shares, state)",
          p and p["state"] == "current" and p["krw_total"] == 10001 and p["krw_basis"] == "krw_original"
          and sorted((s["user_id"], s["krw"]) for s in p["shares"]) == sorted((s["user_id"], s["krw"]) for s in good)
          and p["proposed_by"] == member.uid and p["expense_version"] == 1)
    check("uploader sees their proposal", exp("krw", member)["share_proposal"]["proposal_id"] == first_id)
    check("another member does not see it (null)", exp("krw", third)["share_proposal"] is None)
    check("the proposal payload has only ids, version, basis, total and shares",
          set(p) == {"proposal_id", "proposed_by", "expense_version", "krw_basis", "krw_total", "fx_quote_id", "shares",
                     "proposed_at", "state"} and all(set(s) == {"user_id", "krw"} for s in p["shares"]))
    for client, who in ((member, "uploader"), (third, "member"), (host, "host")):
        for table in ("expense_share_proposals", "expense_share_proposal_lines"):
            st, raw = lb.http(env, "GET", f"/rest/v1/{table}?select=*", token=client.token)
            check(f"{who} cannot read {table} directly", st in (401, 403, 404) or raw.strip() == b"[]", status=st)
    cols = psql("""select string_agg(table_name || '.' || column_name || ':' || data_type, ',' order by table_name, column_name)
                   from information_schema.columns where table_schema = 'public'
                   and table_name in ('expense_share_proposals', 'expense_share_proposal_lines')""")
    check("proposal tables have no item text columns (only ids, numbers, basis, fingerprint, time)",
          cols == ",".join(sorted([
              "expense_share_proposal_lines.krw:bigint", "expense_share_proposal_lines.proposal_id:uuid",
              "expense_share_proposal_lines.trip_id:uuid", "expense_share_proposal_lines.user_id:uuid",
              "expense_share_proposals.created_at:timestamp with time zone", "expense_share_proposals.expense_id:uuid",
              "expense_share_proposals.expense_version:integer", "expense_share_proposals.fingerprint:text",
              "expense_share_proposals.fx_quote_id:uuid", "expense_share_proposals.id:uuid",
              "expense_share_proposals.krw_basis:text", "expense_share_proposals.krw_total:bigint",
              "expense_share_proposals.proposed_by:uuid", "expense_share_proposals.request_id:uuid",
              "expense_share_proposals.seq:bigint", "expense_share_proposals.trip_id:uuid"])), cols=cols)
    try:
        psql(f"update public.expense_share_proposals set krw_total = 1 where trip_id = '{trip}'")
        immutable = False
    except AssertionError:
        immutable = True
    check("proposal rows cannot be changed even by the table owner", immutable)

    # ------------------------------------------------------------ 방장이 확인하고 기존 검토로 포함(자동 적용 없음)
    second = shares(host=5001, member=5000)
    st, body, _ = propose("krw", "krw_original", 10001, second)
    check("uploader can send a newer proposal; the ledger shows the latest", st == 200
          and exp("krw")["share_proposal"]["proposal_id"] == body["proposal_id"])
    st, body, _ = host.rpc("review_expense", p_expense=ids["krw"], p_expected_version=1, p_request_id=str(uuid.uuid4()),
                           p_decision="include", p_payer=host.uid, p_shares=second)
    e = exp("krw")
    check("host includes with the proposed shares via review_expense -> applied",
          st == 200 and e["status"] == "included" and e["share_proposal"]["state"] == "applied"
          and sorted(s["krw"] for s in e["shares"]) == [5000, 5001])
    st, code, _ = propose("krw", "krw_original", 10001, good, version=1)
    check("a proposal for the reviewed (old) version -> stale_expense", st == 409 and code == "stale_expense", code=code)

    # ------------------------------------------------------------ 엔화: 예상액 고시값에 묶기, 정정 뒤 stale
    j = exp("jpy", member)
    prop = j["fx_proposal"]
    check("uploader sees the reference-rate proposal for the JPY expense", prop and prop["status"] == "proposed")
    krw = prop["krw"]
    split = shares(host=krw - krw // 3, member=krw // 3)
    st, code, _ = propose("jpy", "reference_rate_estimate", krw + 1, shares(host=krw - krw // 3 + 1, member=krw // 3),
                          quote=prop["quote_id"])
    check("JPY estimate total different from the quote's KRW -> krw_mismatch", st == 400 and code == "krw_mismatch", code=code)
    st, code, _ = propose("jpy", "reference_rate_estimate", krw, split, quote=str(uuid.uuid4()))
    check("unknown quote -> stale_quote", st == 409 and code == "stale_quote", code=code)
    st, code, _ = propose("jpy", "reference_rate_estimate", krw, split)
    check("estimate without a quote -> basis_invalid", st == 400 and code == "basis_invalid", code=code)
    st, code, _ = propose("jpy", "verified_krw_charge", krw, split)
    check("JPY verified charge before the host set it -> basis_invalid (uploader does not set KRW)",
          st == 400 and code == "basis_invalid", code=code)
    st, code, _ = propose("jpy", "krw_original", 1408, shares(member=1408))
    check("JPY with krw_original -> basis_invalid", st == 400 and code == "basis_invalid", code=code)
    st, body, _ = propose("jpy", "reference_rate_estimate", krw, split, quote=prop["quote_id"])
    check("uploader proposes against the quote the host also sees", st == 200, status=st)
    check("host sees it current with the same quote", exp("jpy")["share_proposal"]["state"] == "current"
          and exp("jpy")["share_proposal"]["fx_quote_id"] == prop["quote_id"])
    ingest({5: "906.75"}, 5, 5)  # 그 지출일 고시값 정정
    e = exp("jpy")
    new = e["fx_proposal"]
    check("after an ECOS correction the proposal is stale_basis (not applied, not rewritten)",
          e["share_proposal"]["state"] == "stale_basis" and e["share_proposal"]["krw_total"] == krw and new["krw"] != krw,
          old=krw, new=new.get("krw"))
    st, code, _ = propose("jpy", "reference_rate_estimate", krw, split, quote=prop["quote_id"])
    check("re-proposing with the superseded quote -> stale_quote", st == 409 and code == "stale_quote", code=code)
    k2 = new["krw"]
    split2 = shares(host=k2 - k2 // 3, member=k2 // 3)
    st, _, _ = propose("jpy", "reference_rate_estimate", k2, split2, quote=new["quote_id"])
    check("re-proposing with the corrected quote is current", st == 200 and exp("jpy")["share_proposal"]["state"] == "current")
    ingest({5: "906.75"}, 5, 5)  # 같은 값 다시 받기(다른 quote_id)
    check("a same-value re-ingest keeps the proposal current (one identity comparison)",
          exp("jpy")["share_proposal"]["state"] == "current")
    st, _, _ = host.rpc("review_expense", p_expense=ids["jpy"], p_expected_version=exp("jpy")["version"],
                        p_request_id=str(uuid.uuid4()), p_decision="include", p_payer=member.uid, p_krw_amount=k2,
                        p_shares=split2, p_krw_basis="reference_rate_estimate", p_fx_quote_id=exp("jpy")["fx_proposal"]["quote_id"])
    check("host includes the JPY expense with the proposal's estimate and shares -> applied",
          st == 200 and exp("jpy")["share_proposal"]["state"] == "applied", status=st)

    # 방장이 실제 청구액으로 포함한 뒤에만 그 원화로 제안할 수 있다.
    v = exp("verified")
    st, _, _ = host.rpc("review_expense", p_expense=ids["verified"], p_expected_version=v["version"],
                        p_request_id=str(uuid.uuid4()), p_decision="include", p_payer=host.uid, p_krw_amount=31999,
                        p_shares=shares(host=16000, member=15999))
    v = exp("verified", member)
    st, code, _ = propose("verified", "verified_krw_charge", 32000, shares(host=16000, member=16000))
    check("verified charge total must equal the host's included KRW -> krw_mismatch", st == 400 and code == "krw_mismatch",
          code=code)
    st, code, _ = propose("verified", "acquisition_cost", 31999, shares(host=16000, member=15999))
    check("a basis the host did not choose -> basis_invalid", st == 400 and code == "basis_invalid", code=code)
    st, code, _ = propose("verified", "reference_rate_estimate", 31999, shares(host=16000, member=15999),
                          quote=v["fx_proposal"]["quote_id"])
    check("estimate whose total is not the quote's KRW -> krw_mismatch", st == 400 and code == "krw_mismatch", code=code)
    st, _, _ = propose("verified", "verified_krw_charge", 31999, shares(host=10000, member=11999, third=10000))
    check("uploader proposes three-way shares of the host's verified charge", st == 200
          and exp("verified")["share_proposal"]["state"] == "current")

    nofx = exp("nofx", member)
    check("no quote covers the date -> undetermined (no estimate to bind)", nofx["fx_proposal"]["status"] == "undetermined")
    st, code, _ = propose("nofx", "reference_rate_estimate", 1000, shares(member=1000), quote=prop["quote_id"])
    check("estimate proposal on an undetermined date -> stale_quote (no invented basis)", st == 409 and code == "stale_quote",
          code=code)

    # ------------------------------------------------------------ 잠금 아래 방장 검토와 경쟁
    # 방장 쪽 트랜잭션이 여행방을 잠근 채 지출 버전을 올리는 동안 보낸 제안은 기다렸다가 stale_expense로 끝난다.
    race_version = exp("race")["version"]
    holder = fxc.run_background(
        f"begin; select 1 from public.trips where id = '{trip}' for update; select pg_sleep(1.5);"
        f" update public.expenses set version = version + 1 where id = '{ids['race']}'; commit;\n")
    time.sleep(0.4)
    result = {}

    def send():
        result["r"] = member.rpc("propose_expense_shares", p_expense=ids["race"], p_expected_version=race_version,
                                 p_request_id=str(uuid.uuid4()), p_krw_basis="krw_original", p_krw_total=7000,
                                 p_shares=shares(host=3500, member=3500))
    t0 = time.monotonic()
    th = threading.Thread(target=send)
    th.start()
    th.join(10)
    holder.wait(10)
    st, code, _ = result["r"]
    check("a proposal racing a review waits for the room lock and is rejected stale_expense",
          st == 409 and code == "stale_expense" and time.monotonic() - t0 > 0.8, code=code)
    # 두 제안이 동시에 오면 둘 다 같은 버전에 묶여 들어가고, 장부는 나중 것을 보인다.
    res = []

    def send2(n):
        res.append(member.rpc("propose_expense_shares", p_expense=ids["race"], p_expected_version=race_version + 1,
                              p_request_id=str(uuid.uuid4()), p_krw_basis="krw_original", p_krw_total=7000,
                              p_shares=shares(host=7000 - n, member=n)))
    ths = [threading.Thread(target=send2, args=(n,)) for n in (1000, 2000)]
    [t.start() for t in ths]
    [t.join(10) for t in ths]
    check("two concurrent proposals both succeed (serialized)", len(res) == 2 and all(r[0] == 200 for r in res))
    latest = psql(f"select krw from public.expense_share_proposal_lines l join public.expense_share_proposals p on p.id = l.proposal_id "
                  f"where p.expense_id = '{ids['race']}' and l.user_id = '{member.uid}' order by p.seq desc limit 1")
    check("ledger shows the later of the two", str(exp("race")["share_proposal"]["shares"][[s["user_id"] for s in
          exp("race")["share_proposal"]["shares"]].index(member.uid)]["krw"]) == latest)

    # ------------------------------------------------------------ 확정: 제안은 확정에 닿지 않는다
    for key in ("race", "host_up", "nofx", "manual"):
        e = exp(key)
        if key == "nofx":
            st, _, _ = host.rpc("review_expense", p_expense=ids[key], p_expected_version=e["version"],
                                p_request_id=str(uuid.uuid4()), p_decision="hold", p_hold_reason="원화 미정")
        else:
            st, _, _ = host.rpc("review_expense", p_expense=ids[key], p_expected_version=e["version"],
                                p_request_id=str(uuid.uuid4()), p_decision="include", p_payer=host.uid,
                                p_shares=shares(host=e["amount_minor"] - 1500, member=1500))
        assert st == 200, (key, st)
    check("the 'race' expense was accepted with host shares, not the proposal",
          exp("race")["share_proposal"]["state"] == "stale_expense")
    check("the verified expense keeps a current proposal the host did not accept",
          exp("verified")["share_proposal"]["state"] == "current")
    pv = host.rpc("preview_settlement", p_trip=trip)[1]
    check("a current, unaccepted proposal does not block finalization (ready)", pv["ready"] is True)
    st, f, _ = host.rpc("finalize_settlement", p_trip=trip, p_expected_revision=pv["revision"], p_request_id=str(uuid.uuid4()))
    check("finalize succeeds", st == 200, status=st)
    st, fin, _ = member.rpc("get_finalized_settlement", p_trip=trip)
    snap = fin["snapshot"]
    snap_text = json.dumps(snap, ensure_ascii=False)
    check("snapshot has no proposal data", "proposal" not in snap_text and "share_proposal" not in snap_text)
    se = {x["expense_id"]: x for x in snap["inputs"]["expenses"]}
    check("snapshot keeps the host's accepted shares (verified: 16,000 / 15,999, not the 3-way proposal)",
          sorted(s["krw"] for s in se[ids["verified"]]["shares"]) == [15999, 16000])
    total = sum(x["krw_amount"] for x in snap["inputs"]["expenses"] if x["kind"] == "shared")
    check("exact final sums: shared total = sum of included KRW = sum of shares; balances net to zero",
          total == snap["outputs"]["included_total_krw"]
          and all(sum(s["krw"] for s in x["shares"]) == x["krw_amount"] for x in snap["inputs"]["expenses"] if x["kind"] == "shared")
          and sum(b["net_krw"] for b in snap["outputs"]["balances"]) == 0)
    st, code, _ = propose("verified", "verified_krw_charge", 31999, shares(host=10000, member=11999, third=10000))
    check("propose after finalize -> trip_finalized", st == 409 and code == "trip_finalized", code=code)
    st, body, _ = propose("krw", "krw_original", 10001, good, version=1, request=req)
    check("replay of an earlier proposal after finalize converges", st == 200 and body["replayed"] and body["proposal_id"] == first_id)
    led = ledger()[0]
    check("finalized ledger: accepted proposals 'applied', others 'closed'",
          led[ids["krw"]]["share_proposal"]["state"] == "applied" and led[ids["verified"]]["share_proposal"]["state"] == "closed"
          and led[ids["race"]]["share_proposal"]["state"] == "closed")
    st2, fin2, _ = host.rpc("get_finalized_settlement", p_trip=trip)
    check("finalized snapshot unchanged afterwards", fin2 == fin)

    failed = [c for c in sc.checks if not c["ok"]]
    summary = {"passed": len(sc.checks) - len(failed), "total": len(sc.checks), "year": year, "checks": sc.checks}
    if out:
        out.write_text(json.dumps(summary, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    for c in failed:
        print("FAIL", c["check"], {k: v for k, v in c.items() if k not in ("check", "ok")})
    print(f"{summary['passed']}/{summary['total']} passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
