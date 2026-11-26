#!/usr/bin/env python3
"""엔화 원화 기준(ADR-0008) 서버 계약 시험. 로컬 Supabase에 실제 HTTP로 요청한다. 표준 라이브러리만 쓴다.

사용(저장소 루트, local:up 또는 local:reset 뒤): python3 -I scripts/fx-contract.py [결과 JSON 경로]

* 기준환율은 가상 시험값(data_origin=fixture)만 넣는다. 실행마다 2001~2020년 중 한 해의 3~5월을 골라 쓰므로 다시 실행해도
  앞 실행의 받기 기록과 겹치지 않고, 시드 여행방·앱 E2E가 쓰는 2026년 값과도 겹치지 않는다.
* ECOS live 길(ingest_ecos_jpy_rates, service_role)은 거절되는 입력만 보낸다(가상 값을 ecos_live로 남기지 않는다).
* 토큰·키·비밀번호는 출력하지 않는다. 결과에는 검사 이름, HTTP 상태, 서버가 정한 코드만 남긴다.
"""

import datetime
import importlib.util
import json
import secrets
import sys
import uuid
from fractions import Fraction
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
EXAMPLES = sc.EXAMPLES


def half_up(fr):
    """양수 분수의 원 단위 반올림(.5 올림). 서버와 따로 구현한 계산."""
    return (2 * fr.numerator + fr.denominator) // (2 * fr.denominator)


def fx_count():
    return psql("select (select count(*) from public.fx_ingestions) || '|' || (select count(*) from public.fx_quotes)")


def live(env, response, start, end):
    st, raw = lb.http(env, "POST", "/rest/v1/rpc/ingest_ecos_jpy_rates",
                      {"p_response": response, "p_start": start, "p_end": end}, token=env["SECRET_KEY"], key=env["SECRET_KEY"])
    return st, lb.code_of(raw)


def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else None
    env = lb.status()
    accounts = json.loads((lb.RUN / "accounts.json").read_text())
    host = Client(env, *accounts["host"])
    member = Client(env, *accounts["member"])
    outsider_email = f"outsider.fx.{secrets.token_hex(4)}@example.com"
    outsider_password = secrets.token_urlsafe(24)
    lb.admin_create_user(env, outsider_email, "마바", outsider_password)
    outsider = Client(env, outsider_email, outsider_password)

    year = 2001 + secrets.randbelow(20)
    B = datetime.date(year, 3, 1)

    def d(n):
        return (B + datetime.timedelta(days=n)).isoformat()

    def vals(**by_offset):
        return {d(int(k[1:])): v for k, v in by_offset.items()}

    # ------------------------------------------------------------ 공통 예제: SQL 환산이 앱과 같은 답
    conv = EXAMPLES["krw_conversions"]
    for c in conv["acquisition"]:
        got = psql(f"select private.acq_krw({c['amount_minor']}, {c['krw_paid']}, {c['foreign_minor']})")
        want = half_up(Fraction(c["amount_minor"] * c["krw_paid"], c["foreign_minor"]))
        check(f"acquisition example {c['amount_minor']}x{c['krw_paid']}/{c['foreign_minor']}",
              int(got) == want and (c["krw"] is None or c["krw"] == want), got=got)
    for c in conv["reference_rate"]:
        got = psql(f"select private.fx_krw({c['amount_minor']}, '{c['rate']}'::numeric, {c['quote_unit']})")
        want = half_up(Fraction(c["amount_minor"]) * Fraction(c["rate"]) / c["quote_unit"])
        check(f"reference example {c['amount_minor']}x{c['rate']}/{c['quote_unit']}",
              int(got) == want and (c["krw"] is None or c["krw"] == want), got=got)

    # ------------------------------------------------------------ 받기: 원문 검사(거절되면 아무것도 남지 않음)
    good = fx.ecos_shape(vals(d2="905.25"))
    row = good["StatisticSearch"]["row"][0]

    def with_row(**change):
        r = {**row, **change}
        return {"StatisticSearch": {"list_total_count": 1, "row": [r]}}

    t0 = psql("select now()")  # 이 실행의 어떤 받기 기록보다 앞선 시각(as-of 검사)
    before = fx_count()
    bad_inputs = [
        ("not an object", [1, 2], "fx_response_invalid"),
        ("missing row array", {"StatisticSearch": {"list_total_count": 1}}, "fx_response_invalid"),
        ("truncated page (total != rows)", {"StatisticSearch": {"list_total_count": 2, "row": [row]}}, "fx_response_invalid"),
        ("empty row array", {"StatisticSearch": {"list_total_count": 0, "row": []}}, "fx_response_invalid"),
        ("other series", with_row(STAT_CODE="731Y003"), "fx_response_invalid"),
        ("other item (USD)", with_row(ITEM_CODE1="0000001"), "fx_response_invalid"),
        ("renamed item", with_row(ITEM_NAME1="원/일본엔"), "fx_response_invalid"),
        ("other unit", with_row(UNIT_NAME="달러"), "fx_response_invalid"),
        ("numeric DATA_VALUE (not text)", with_row(DATA_VALUE=905.25), "fx_response_invalid"),
        ("grouped digits", with_row(DATA_VALUE="1,905.25"), "fx_response_invalid"),
        ("negative", with_row(DATA_VALUE="-905.25"), "fx_response_invalid"),
        ("zero", with_row(DATA_VALUE="0"), "fx_response_invalid"),
        ("five decimals", with_row(DATA_VALUE="905.25001"), "fx_response_invalid"),
        ("exponent", with_row(DATA_VALUE="9.0525E2"), "fx_response_invalid"),
        ("blank", with_row(DATA_VALUE=""), "fx_response_invalid"),
        ("impossible date", with_row(TIME=f"{year}0231"), "fx_response_invalid"),
        ("date outside requested range", with_row(TIME=d(40).replace("-", "")), "fx_response_invalid"),
        ("duplicate date", {"StatisticSearch": {"list_total_count": 2, "row": [row, row]}}, "fx_response_invalid"),
        ("ECOS invalid key result", {"RESULT": {"CODE": "INFO-100", "MESSAGE": "x"}}, "fx_source_error"),
        ("ECOS server error result", {"RESULT": {"CODE": "ERROR-500", "MESSAGE": "x"}}, "fx_source_error"),
    ]
    for label, body, want in bad_inputs:
        st, code = live(env, body, d(0), d(19))
        check(f"ingest rejects {label} -> {want}", st >= 400 and code == want, status=st, code=code)
    today = datetime.datetime.now(fx.KST).date()
    for label, a, b in [("range ending today (KST)", today - datetime.timedelta(days=3), today),
                        ("range in the future", today + datetime.timedelta(days=1), today + datetime.timedelta(days=5)),
                        ("start after end", datetime.date(year, 3, 9), datetime.date(year, 3, 1)),
                        ("range over 366 days", datetime.date(year, 1, 1), datetime.date(year + 1, 1, 3))]:
        st, code = live(env, fx.ecos_shape({}), a.isoformat(), b.isoformat())
        check(f"ingest rejects {label} -> fx_range_invalid", st == 400 and code == "fx_range_invalid", status=st, code=code)
    check("rejected ingests stored nothing", fx_count() == before, before=before, after=fx_count())
    for who, client in (("host", host), ("member", member)):
        st, code, _ = client.rpc("ingest_ecos_jpy_rates", p_response=good, p_start=d(0), p_end=d(19))
        check(f"{who} (authenticated) cannot ingest", st in (401, 403, 404), status=st, code=code)
    st, raw = lb.http(env, "POST", "/rest/v1/rpc/ingest_ecos_jpy_rates", {"p_response": good, "p_start": d(0), "p_end": d(19)})
    check("anonymous cannot ingest", st in (401, 403, 404), status=st)
    for table in ("fx_ingestions", "fx_quotes"):
        st, raw = lb.http(env, "GET", f"/rest/v1/{table}?select=*", token=host.token)
        check(f"authenticated cannot read {table}", st in (401, 403, 404) or json.loads(raw) == [], status=st)
    check("all of the above stored nothing", fx_count() == before)
    ok, res = fx.ingest_fixture(good, datetime.date.fromisoformat(d(0)), datetime.date.fromisoformat(d(19)))
    check("owner-only fixture path refuses the same malformed rows too",
          not fx.ingest_fixture(with_row(DATA_VALUE="1e3"), datetime.date.fromisoformat(d(0)),
                                datetime.date.fromisoformat(d(19)))[0])
    check("a valid fixture response is stored with data_origin=fixture", ok and res["data_origin"] == "fixture")
    for sql in ("update public.fx_quotes set rate = 1 where ingestion_id = '%s'" % res["ingestion_id"],
                "delete from public.fx_quotes where ingestion_id = '%s'" % res["ingestion_id"],
                "update public.fx_ingestions set data_origin = 'ecos_live' where id = '%s'" % res["ingestion_id"]):
        rc, _, _ = fx.psql(sql)
        check(f"fx rows are immutable even for the owner: {sql.split()[0]}", rc != 0)

    # ------------------------------------------------------------ 정하기(as-of): 지출일과 그 앞 고시일만
    ok1, run1 = fx.ingest_fixture(fx.ecos_shape(vals(d2="905.25", d4="903.60", d9="910.00", d12="912.00")),
                                  datetime.date.fromisoformat(d(0)), datetime.date.fromisoformat(d(19)))
    ok2, run_gap = fx.ingest_fixture(fx.ecos_shape(vals(d40="920.00")), datetime.date.fromisoformat(d(40)),
                                     datetime.date.fromisoformat(d(80)))
    ok3, run_empty = fx.ingest_fixture(fx.ecos_shape({}), datetime.date.fromisoformat(d(81)), datetime.date.fromisoformat(d(85)))
    check("fixture runs stored (including an empty INFO-200 run)", ok1 and ok2 and ok3 and run_empty["rows"] == 0)

    def proposal(day, amount, as_of="now()"):
        return json.loads(psql(f"select private.fx_proposal('JPY', '{day}', {amount}, {as_of})") or "null")

    p = proposal(d(3), 1408)
    check("unpublished expense date uses the latest earlier published date (not a later one)",
          p["status"] == "proposed" and p["rate_date"] == d(2) and p["rate"] == "905.25" and p["krw"] == 12746, p=p)
    p = proposal(d(2), 1408)
    check("published expense date uses that date", p["rate_date"] == d(2) and p["quote_unit"] == 100)
    check("a rate published after the expense date is never used", proposal(d(3), 1)["rate_date"] == d(2)
          and proposal(d(1), 1)["status"] == "undetermined")
    check("rate is exact text with fixed decimals, quote unit 100, series metadata",
          p["rate"] == "905.25" and p["stat_code"] == "731Y001" and p["item_code"] == "0000002"
          and p["item_name"] == "원/일본엔(100엔)" and p["unit_name"] == "원" and p["source"] == "bok_ecos"
          and p["data_origin"] == "fixture")
    check("positive .5 rounds up per expense (200 JPY x 905.25/100 = 1810.5 -> 1811)", proposal(d(2), 200)["krw"] == 1811)
    check("date before any coverage -> undetermined", proposal(d(-1), 1000)["status"] == "undetermined")
    check("date not yet covered by any run -> undetermined", proposal(d(25), 1000)["status"] == "undetermined")
    check("fallback crosses up to 31 covered days without a quote", proposal(d(70), 1000)["rate_date"] == d(40))
    check("more than 31 covered days without a quote -> unavailable (no stale fallback)",
          proposal(d(75), 1000)["status"] == "unavailable")
    check("an empty (INFO-200) run determines its days: unavailable, not undetermined",
          proposal(d(81), 1000)["status"] == "unavailable"
          and proposal(d(81), 1000, f"'{t0}'::timestamptz")["status"] == "undetermined")
    check("historical as-of: before the run existed the date was undetermined",
          proposal(d(3), 1408, f"'{t0}'::timestamptz")["status"] == "undetermined")
    check("non-JPY currency has no proposal", json.loads(psql(f"select private.fx_proposal('USD', '{d(3)}', 100, now())") or "null") is None)

    # ------------------------------------------------------------ 검토: 기준 고르기와 승인
    trip = sc.new_trip(host.uid, member.uid)
    specs = [("est", d(3), 1408, "JPY"), ("upd", d(9), 1000, "JPY"), ("same", d(3), 200, "JPY"),
             ("acq", d(3), 1408, "JPY"), ("actual", d(3), 1276, "JPY"), ("undet", d(25), 5000, "JPY"),
             ("usd", d(3), 1000, "USD"), ("krw", d(3), 38000, "KRW")]
    ids = {}
    for key, day, amount, cur in specs:
        st, body, _ = member.rpc("submit_manual_expense", p_trip=trip, p_request_id=str(uuid.uuid4()), p_expense_date=day,
                                 p_amount_minor=amount, p_currency=cur, p_merchant=f"가상 {key}")
        ids[key] = body["expense_id"]

    def ledger(client=host):
        st, body, _ = client.rpc("get_room_ledger", p_trip=trip)
        return {e["expense_id"]: e for e in body["expenses"]}, body

    led, raw_ledger = ledger()
    check("ledger shows the server proposal for JPY expenses", led[ids["est"]]["fx_proposal"]["krw"] == 12746
          and led[ids["est"]]["fx_proposal"]["rate_date"] == d(2))
    check("member sees the same proposal (read only)", ledger(member)[0][ids["est"]]["fx_proposal"] == led[ids["est"]]["fx_proposal"])
    check("non-JPY and KRW expenses have no proposal", led[ids["usd"]]["fx_proposal"] is None and led[ids["krw"]]["fx_proposal"] is None)
    check("not-yet-determined date is labelled undetermined", led[ids["undet"]]["fx_proposal"]["status"] == "undetermined")
    st, code, _ = outsider.rpc("get_room_ledger", p_trip=trip)
    check("outsider cannot read proposals", st == 404 and code == "trip_not_found")

    def review(client, key, **kw):
        e = ledger()[0][ids[key]]
        params = dict(p_expense=e["expense_id"], p_expected_version=e["version"], p_request_id=str(uuid.uuid4()),
                      p_decision="include", p_payer=host.uid)
        params.update(kw)
        return client.rpc("review_expense", **params)

    def pair(krw):
        split = sc_pair(krw)
        return [{"user_id": host.uid, "krw": split[0]}, {"user_id": member.uid, "krw": split[1]}]

    def sc_pair(krw):
        half = krw // 2
        return [half, half] if krw % 2 == 0 else [half + 1, half]  # 결제자(방장)가 1원 더(ADR-0007)

    q_est = led[ids["est"]]["fx_proposal"]["quote_id"]
    est = dict(p_krw_basis="reference_rate_estimate", p_fx_quote_id=q_est)
    st, code, _ = member.rpc("review_expense", p_expense=ids["est"], p_expected_version=1, p_request_id=str(uuid.uuid4()),
                             p_decision="include", p_payer=host.uid, p_krw_amount=12746, p_shares=pair(12746), **est)
    check("member cannot approve an estimate -> host_only", st == 403 and code == "host_only", status=st, code=code)
    st, code, _ = outsider.rpc("review_expense", p_expense=ids["est"], p_expected_version=1, p_request_id=str(uuid.uuid4()),
                               p_decision="include", p_payer=host.uid, p_krw_amount=12746, p_shares=pair(12746), **est)
    check("outsider cannot approve -> trip_not_found", st == 404 and code == "trip_not_found", status=st, code=code)
    for label, kw, want in [
        ("estimate with a different KRW than the server computes", dict(p_krw_amount=12745, p_shares=pair(12745), **est), "krw_mismatch"),
        ("estimate without the quote the host saw", dict(p_krw_amount=12746, p_shares=pair(12746), p_krw_basis="reference_rate_estimate"), "basis_invalid"),
        ("estimate with an unknown quote id", dict(p_krw_amount=12746, p_shares=pair(12746), p_krw_basis="reference_rate_estimate",
                                                 p_fx_quote_id=str(uuid.uuid4())), "stale_quote"),
        ("estimate mixed with acquisition inputs", dict(p_krw_amount=12746, p_shares=pair(12746), p_acq_krw=95000,
                                                       p_acq_foreign_minor=10000, **est), "basis_invalid"),
        ("unknown basis", dict(p_krw_amount=12746, p_shares=pair(12746), p_krw_basis="guess"), "basis_invalid"),
        ("shares not summing to the estimate", dict(p_krw_amount=12746, p_shares=pair(12745), **est), "shares_mismatch"),
    ]:
        st, code, _ = review(host, "est", **kw)
        check(f"{label} -> {want}", st >= 400 and code == want, status=st, code=code)
    st, code, _ = review(host, "undet", p_krw_amount=1, p_shares=pair(2), p_krw_basis="reference_rate_estimate",
                         p_fx_quote_id=q_est)
    check("estimate for an undetermined date -> stale_quote (no amount without a defensible quote)",
          st == 409 and code == "stale_quote", status=st, code=code)
    st, code, _ = review(host, "usd", p_krw_amount=1000, p_shares=pair(1000), p_krw_basis="reference_rate_estimate",
                         p_fx_quote_id=q_est)
    check("estimate for another currency -> basis_invalid (JPY only)", st == 400 and code == "basis_invalid", status=st, code=code)
    st, code, _ = review(host, "krw", p_shares=[{"user_id": host.uid, "krw": 38000}], p_krw_basis="acquisition_cost",
                         p_acq_krw=1, p_acq_foreign_minor=1)
    check("acquisition basis on a KRW expense -> basis_invalid", st == 400 and code == "basis_invalid", status=st, code=code)
    check("rejected approvals changed nothing", all(e["version"] == 1 and e["status"] == "pending" for e in ledger()[0].values()))

    st, body, _ = review(host, "est", p_krw_amount=12746, p_shares=pair(12746), **est)
    check("host approves the estimate shown", st == 200 and body["status"] == "included", status=st)
    e = ledger()[0][ids["est"]]
    check("approved estimate is pinned and labelled (never actual)",
          e["krw_basis"] == "reference_rate_estimate" and e["is_estimate"] is True and e["krw_amount"] == 12746
          and e["fx"]["rate"] == "905.25" and e["fx"]["rate_date"] == d(2) and e["fx"]["quote_unit"] == 100
          and e["fx"]["quote_id"] == q_est and e["fx"]["data_origin"] == "fixture" and e["fx"]["source"] == "bok_ecos"
          and e["amount_minor"] == 1408 and e["currency"] == "JPY" and e["expense_date"] == d(3) and e["acquisition"] is None
          and e["fx_superseded"] is False, e=e)

    # 견적 갱신 충돌: 방장이 본 고시값 뒤에 같은 날짜 값이 새로 들어오면(정정) 옛 값으로는 승인할 수 없다.
    q_old = ledger()[0][ids["upd"]]["fx_proposal"]
    ok, run2 = fx.ingest_fixture(fx.ecos_shape(vals(d9="911.50")), datetime.date.fromisoformat(d(5)),
                                 datetime.date.fromisoformat(d(12)))
    q_new = ledger()[0][ids["upd"]]["fx_proposal"]
    check("re-ingested date with a corrected value becomes the current proposal",
          ok and q_old["rate"] == "910.00" and q_new["rate"] == "911.50" and q_new["krw"] == 9115 and q_new["quote_id"] != q_old["quote_id"])
    st, code, raw = host.rpc("review_expense", p_expense=ids["upd"], p_expected_version=1, p_request_id=str(uuid.uuid4()),
                             p_decision="include", p_payer=host.uid, p_krw_amount=9100, p_shares=pair(9100),
                             p_krw_basis="reference_rate_estimate", p_fx_quote_id=q_old["quote_id"])
    check("approval of the superseded preview -> stale_quote", st == 409 and code == "stale_quote", status=st, code=code)
    st, body, _ = review(host, "upd", p_krw_amount=9115, p_shares=pair(9115), p_krw_basis="reference_rate_estimate",
                         p_fx_quote_id=q_new["quote_id"])
    e = ledger()[0][ids["upd"]]
    check("approval of the current quote succeeds; odd estimate splits with payer +1 (ADR-0007)",
          st == 200 and e["krw_amount"] == 9115 and {s["user_id"]: s["krw"] for s in e["shares"]} == {host.uid: 4558, member.uid: 4557})
    # 같은 값의 다시 받기: 본 고시값과 값이 같으면 승인한다(받기 기록만 새것).
    q_same_old = ledger()[0][ids["same"]]["fx_proposal"]
    fx.ingest_fixture(fx.ecos_shape(vals(d2="905.25")), datetime.date.fromisoformat(d(1)), datetime.date.fromisoformat(d(2)))
    q_same_new = ledger()[0][ids["same"]]["fx_proposal"]
    st, body, _ = review(host, "same", p_krw_amount=1811, p_shares=[{"user_id": member.uid, "krw": 1811}],
                         p_krw_basis="reference_rate_estimate", p_fx_quote_id=q_same_old["quote_id"])
    check("re-fetch with identical values: the quote the host saw is still accepted",
          q_same_new["quote_id"] != q_same_old["quote_id"] and q_same_new["rate"] == q_same_old["rate"] and st == 200)

    # 외화 취득 원가(우선순위 2).
    for label, kw, want in [("acquired yen zero", dict(p_acq_krw=95000, p_acq_foreign_minor=0, p_krw_amount=1), "krw_unverified"),
                            ("paid KRW too large", dict(p_acq_krw=10000000000, p_acq_foreign_minor=1, p_krw_amount=1), "krw_unverified"),
                            ("missing acquired yen", dict(p_acq_krw=95000, p_krw_amount=13376), "krw_unverified"),
                            ("app KRW differs from server", dict(p_acq_krw=95000, p_acq_foreign_minor=10000, p_krw_amount=13377), "krw_mismatch"),
                            ("acquisition with a quote id", dict(p_acq_krw=95000, p_acq_foreign_minor=10000, p_krw_amount=13376,
                                                                p_fx_quote_id=q_est), "basis_invalid")]:
        st, code, _ = review(host, "acq", p_krw_basis="acquisition_cost", p_shares=pair(13376), **kw)
        check(f"acquisition {label} -> {want}", st == 400 and code == want, status=st, code=code)
    st, body, _ = review(host, "acq", p_krw_basis="acquisition_cost", p_acq_krw=95000, p_acq_foreign_minor=10000,
                         p_krw_amount=13376, p_shares=pair(13376))
    e = ledger()[0][ids["acq"]]
    check("acquisition cost approved: 1408 JPY x 95,000/10,000 = 13,376 with provenance, not an estimate",
          st == 200 and e["krw_basis"] == "acquisition_cost" and e["krw_amount"] == 13376 and e["is_estimate"] is False
          and e["acquisition"] == {"krw_paid": 95000, "foreign_minor": 10000, "currency": "JPY"} and e["fx"] is None)

    # 실제 원화 청구액(우선순위 1): 예전 요청 모양 그대로 받고, 같은 요청 재시도는 예전처럼 수렴한다.
    req = str(uuid.uuid4())
    old_style = dict(p_expense=ids["actual"], p_expected_version=1, p_request_id=req, p_decision="include", p_payer=host.uid,
                     p_krw_amount=12000, p_shares=pair(12000))
    st, body, _ = host.rpc("review_expense", **old_style)
    st2, body2, _ = host.rpc("review_expense", **old_style)
    e = ledger()[0][ids["actual"]]
    check("old-style review (no basis) is still a verified actual charge and replays", st == 200 and st2 == 200
          and body2["replayed"] and e["krw_basis"] == "verified_krw_charge" and e["is_estimate"] is False and e["fx"] is None)
    st, code, _ = host.rpc("review_expense", **old_style, p_krw_basis="reference_rate_estimate", p_fx_quote_id=q_est)
    check("same request key with a different basis -> idempotency_conflict", st == 409 and code == "idempotency_conflict")

    # 예상액 포함 뒤 그 지출일 값이 늦게 들어오면(고시 없던 날): 포함 금액은 그대로, 장부만 더 새 값이 있다고 알린다.
    st, prev_before, _ = host.rpc("preview_settlement", p_trip=trip)
    fx.ingest_fixture(fx.ecos_shape(vals(d3="904.00")), datetime.date.fromisoformat(d(3)), datetime.date.fromisoformat(d(3)))
    e = ledger()[0][ids["est"]]
    st, prev_after, _ = host.rpc("preview_settlement", p_trip=trip)
    check("late quote: approved estimate keeps its pinned quote and amount, ledger flags fx_superseded",
          e["krw_amount"] == 12746 and e["fx"]["rate"] == "905.25" and e["fx_superseded"] is True
          and e["fx_proposal"]["rate_date"] == d(3))
    check("late quote does not change preview totals or transfers", prev_before["transfers"] == prev_after["transfers"]
          and prev_before["included_total_krw"] == prev_after["included_total_krw"]
          and prev_after["estimated_total_krw"] == 12746 + 9115 + 1811)

    # 보류: 기준을 정할 수 없는 지출.
    st, body, _ = host.rpc("review_expense", p_expense=ids["undet"], p_expected_version=1, p_request_id=str(uuid.uuid4()),
                           p_decision="hold", p_hold_reason="원화 청구액 확인 대기")
    st, body, _ = review(host, "usd", p_krw_amount=1450, p_shares=[{"user_id": member.uid, "krw": 1450}])
    st, body, _ = review(host, "krw", p_shares=pair(38000))
    # 정정된 예상액은 방장 결정 전에는 확정을 막는다(ADR-0009). 여기서는 고정 금액 유지를 고른다(자세한 검사는 fx-correction-contract.py).
    st, prev, _ = host.rpc("preview_settlement", p_trip=trip)
    check("superseded estimates (both pinned to the d2 quote for d3) block the preview until the host decides (ADR-0009)",
          not prev["ready"] and sorted(prev["fx_correction_expense_ids"]) == sorted([ids["est"], ids["same"]]),
          blocking=prev.get("fx_correction_expense_ids"))
    for key in ("est", "same"):
        e = ledger()[0][ids[key]]
        st, body, _ = host.rpc("keep_fx_estimate", p_expense=ids[key], p_expected_version=e["version"],
                               p_request_id=str(uuid.uuid4()), p_replacement_quote_id=e["fx_proposal"]["quote_id"])
        check(f"host keeps the pinned estimate ({key})", st == 200 and ledger()[0][ids[key]]["fx_correction"] == "kept",
              status=st)
    st, prev, _ = host.rpc("preview_settlement", p_trip=trip)
    check("preview is ready and lists the held expense as excluded", prev["ready"]
          and [x["expense_id"] for x in prev["excluded"] if x["kind"] == "held"] == [ids["undet"]])

    # ------------------------------------------------------------ 확정: 입력·기준·결과 고정과 재현
    st, body, _ = host.rpc("finalize_settlement", p_trip=trip, p_expected_revision=prev["revision"], p_request_id=str(uuid.uuid4()))
    check("finalize with approved estimates", st == 200, status=st)
    st, f1, _ = member.rpc("get_finalized_settlement", p_trip=trip)
    snap = f1["snapshot"]
    check("rule version v2", f1["rule_version"] == "explicit-krw-shares-v2" and snap["rule_version"] == "explicit-krw-shares-v2")
    by = {x["expense_id"]: x for x in snap["inputs"]["expenses"]}
    check("snapshot freezes source inputs, dates, units, rates and provenance",
          by[ids["est"]]["fx"]["rate"] == "905.25" and by[ids["est"]]["fx"]["rate_date"] == d(2)
          and by[ids["est"]]["fx"]["quote_unit"] == 100 and by[ids["est"]]["fx"]["data_origin"] == "fixture"
          and by[ids["est"]]["is_estimate"] is True and by[ids["est"]]["amount_minor"] == 1408
          and by[ids["est"]]["expense_date"] == d(3) and by[ids["acq"]]["acquisition"]["krw_paid"] == 95000
          and by[ids["actual"]]["krw_basis"] == "verified_krw_charge" and by[ids["actual"]]["is_estimate"] is False
          and "fx_proposal" not in by[ids["est"]] and "fx_superseded" not in by[ids["est"]])
    check("snapshot outputs carry the estimated part of the total",
          snap["outputs"]["estimated_total_krw"] == 12746 + 9115 + 1811)

    # 독립 재현: 스냅숏 입력만으로 원화(기준별), 합계, 잔액, 송금을 다시 계산한다.
    def replay(s):
        net = {m["user_id"]: 0 for m in s["inputs"]["members"]}
        total = estimated = 0
        for x in s["inputs"]["expenses"]:
            if x["krw_basis"] == "reference_rate_estimate":
                assert x["krw_amount"] == half_up(Fraction(x["amount_minor"]) * Fraction(x["fx"]["rate"]) / x["fx"]["quote_unit"])
                assert x["fx"]["rate_date"] <= x["expense_date"] and x["currency"] == "JPY"
            if x["krw_basis"] == "acquisition_cost":
                a = x["acquisition"]
                assert x["krw_amount"] == half_up(Fraction(x["amount_minor"] * a["krw_paid"], a["foreign_minor"]))
            if x["kind"] == "shared":
                total += x["krw_amount"]
                estimated += x["krw_amount"] if x.get("is_estimate") else 0
                net[x["payer_id"]] += x["krw_amount"]
                for sh in x["shares"]:
                    net[sh["user_id"]] -= sh["krw"]
                assert sum(sh["krw"] for sh in x["shares"]) == x["krw_amount"]
        bal = dict(net)
        transfers = []
        while True:
            debt = sorted((v, k) for k, v in bal.items() if v < 0)
            cred = sorted(((-v, k) for k, v in bal.items() if v > 0))
            if not debt or not cred:
                break
            (dv, dk), (cv, ck) = debt[0], cred[0]
            amt = min(-dv, -cv)
            transfers.append({"from": dk, "to": ck, "krw": amt})
            bal[dk] += amt
            bal[ck] -= amt
        return total, estimated, net, transfers

    try:
        total, estimated, net, transfers = replay(snap)
        ok = (total == snap["outputs"]["included_total_krw"] and estimated == snap["outputs"]["estimated_total_krw"]
              and net == {b["user_id"]: b["net_krw"] for b in snap["outputs"]["balances"]} and transfers == snap["outputs"]["transfers"])
    except AssertionError:
        ok = False
    check("deterministic replay from frozen inputs reproduces every KRW amount and the outputs", ok)
    ok = sc.lb.rows(f"select (encode(sha256(convert_to(snapshot::text, 'UTF8')), 'hex') = snapshot_sha256) as ok "
                    f"from public.finalizations where trip_id = '{trip}'", "fx-contract-hash")[0]["ok"] is True
    check("snapshot hash matches", ok)
    fx.ingest_fixture(fx.ecos_shape(vals(d2="999.99", d9="1.00")), datetime.date.fromisoformat(d(0)),
                      datetime.date.fromisoformat(d(19)))
    st, f2, _ = member.rpc("get_finalized_settlement", p_trip=trip)
    check("quote updates after finalize do not change the frozen settlement", f2 == f1)
    led_final, raw_final = ledger()
    check("finalized ledger shows no live proposal or superseded flag",
          all(x["fx_proposal"] is None and x["fx_superseded"] is False for x in led_final.values()))
    st, code, _ = review(host, "est", p_krw_amount=12746, p_shares=pair(12746), **est)
    check("no estimate approval after finalize -> trip_finalized", st == 409 and code == "trip_finalized")

    failed = [c for c in sc.checks if not c["ok"]]
    summary = {"passed": len(sc.checks) - len(failed), "total": len(sc.checks), "year": year, "checks": sc.checks}
    if out:
        out.write_text(json.dumps(summary, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"{summary['passed']}/{summary['total']} passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
