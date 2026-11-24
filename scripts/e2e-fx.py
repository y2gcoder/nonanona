#!/usr/bin/env python3
"""엔화 원화 기준 E2E(로컬 Supabase 모드, 방장 기기 하나: iOS 시뮬레이터 또는 Android 에뮬레이터, 표준 라이브러리만).

가상 회원 계정이 시드 여행방(가상 후쿠오카 정산)에 엔화 직접 입력 4건을 앱과 같은 RPC로 올리고, 방장 기기에서:
  1,276엔(11-03, 그날 고시 없음) → 기준환율 예상 11,551원(11-02 값, 가상 시험 환율 표시) 포함
  1,500엔(11-04) → 예상 13,554원을 보는 사이 스크립트가 11-04 값을 정정 → 저장이 거절되고 새 예상 13,563원으로 다시 저장
  8,000엔 → 환전 원가 95,000원/10,000엔 = 76,000원 포함
  2,000엔(12-01, 아직 덮지 않은 날) → 예상 금액 없음, 포함 불가 → 보류
→ 미리보기(예상 금액 합계·원화 환산 근거) → 확정 → 스크립트가 고시값을 다시 바꾸고 앱을 SIGKILL → 다시 열어도 같은 확정본.
단계마다 서버 행을 확인한다. 기준환율은 가상 시험값(data_origin=fixture)뿐이다.

사전 조건: mise run local:up. iOS는 부팅한 시뮬레이터, Android는 실행 중인 에뮬레이터 하나(adb 기기 하나).
사용: python3 -I scripts/e2e-fx.py ios <시뮬레이터 UDID> [증거 폴더]
      python3 -I scripts/e2e-fx.py android [증거 폴더]
"""

import datetime
import importlib.util
import json
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HOST = sys.argv[1] if len(sys.argv) > 1 else ""
if HOST not in ("ios", "android"):
    sys.exit(__doc__)
UDID = sys.argv[2] if HOST == "ios" else "none"
OUT = Path((sys.argv[3] if HOST == "ios" else sys.argv[2]) if len(sys.argv) > (3 if HOST == "ios" else 2)
           else tempfile.mkdtemp(prefix="nonanona-fx-e2e-"))


def load(name, file, argv=None):
    saved = sys.argv
    if argv:
        sys.argv = argv
    try:
        spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / file)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    finally:
        sys.argv = saved


# 두 기기 정산 E2E의 기기 도우미(빌드·설치·XCUITest 실행·adb 화면 조작)를 그대로 쓴다.
s = load("e2e_settlement", "e2e-settlement.py", [str(ROOT / "scripts" / "e2e-settlement.py"), UDID, HOST, str(OUT)])
fx = load("ecos_fx", "ecos-fx.py")
lb, u, log, until, reach = s.lb, s.u, s.log, s.until, s.reach
TRIP = s.TRIP
EXPENSES = [("2026-11-03", 1276, "가상 커피"), ("2026-11-04", 1500, "가상 도시락"), ("2026-11-05", 8000, "가상 현금 공동 지출"),
            ("2026-12-01", 2000, "가상 미래 날짜")]


def member_submits():
    env = lb.status()
    accounts = json.loads((lb.RUN / "accounts.json").read_text())
    st, raw = lb.http(env, "POST", "/auth/v1/token?grant_type=password",
                      {"email": accounts["member"][0], "password": accounts["member"][1]})
    token = json.loads(raw)["access_token"]
    trip = lb.rows(f"select id from public.trips where name = '{TRIP}'", "fx-e2e-trip")[0]["id"]
    for day, amount, merchant in EXPENSES:
        st, raw = lb.http(env, "POST", "/rest/v1/rpc/submit_manual_expense",
                          {"p_trip": trip, "p_request_id": str(uuid.uuid4()), "p_expense_date": day, "p_amount_minor": amount,
                           "p_currency": "JPY", "p_merchant": merchant}, token=token)
        assert st == 200, (st, lb.code_of(raw))
    log(f"member account submitted {len(EXPENSES)} JPY manual expenses via the same RPC")


def rows(label):
    r = lb.rows(f"""select coalesce(json_agg(json_build_object('amount', e.amount_minor, 'status', e.status,
          'krw', e.krw_amount, 'basis', e.krw_basis, 'rate', e.fx_rate::text, 'rate_date', e.fx_rate_date,
          'acq', e.acq_krw, 'acq_foreign', e.acq_foreign_minor) order by e.expense_date), '[]') as expenses,
          (select status from public.trips where name = '{TRIP}') as trip_status,
          (select string_agg(f.snapshot_sha256, ',') from public.finalizations f join public.trips t on t.id = f.trip_id
             where t.name = '{TRIP}') as snapshots
        from public.expenses e join public.trips t on t.id = e.trip_id where t.name = '{TRIP}'""", "fx-e2e-rows")[0]
    (OUT / f"server-{label}.json").write_text(json.dumps(r, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    log(f"server {label}: " + ", ".join(f"{e['amount']}JPY {e['status']} {e['basis']} {e['krw']}" for e in r["expenses"]))
    return r


def by_amount(r):
    return {e["amount"]: e for e in r["expenses"]}


def correct_quote():
    ok, res = fx.ingest_fixture(fx.ecos_shape({"2026-11-04": "904.20"}), datetime.date(2026, 11, 4), datetime.date(2026, 11, 4))
    assert ok, res
    log("synthetic quote correction ingested: 2026-11-04 903.60 -> 904.20 (fixture)")


def change_quotes_after_finalize():
    ok, res = fx.ingest_fixture(fx.ecos_shape({"2026-11-02": "999.99", "2026-11-04": "1.00"}), datetime.date(2026, 11, 1),
                                datetime.date(2026, 11, 5))
    assert ok, res
    log("synthetic quotes changed again after finalize (fixture)")


# ---------------------------------------------------------------- Android 방장 단계
def a_source(name):
    u.tap(reach("expense_review_screen", id=f"review_source_{name}"))


def a_text_is(id_, want):
    got = reach("expense_review_screen", id=id_).text
    assert got == want, (id_, got)


def a_include():
    u.tap(reach("expense_review_screen", id="review_include"))
    until(lambda: not u.find(id="expense_review_screen"), 15, "review closes")
    u.wait(id="room_screen", timeout=10)


def a_f1():
    s.a_login("다라")
    s.a_open_trip()
    s.a_refresh()
    until(lambda: s.a_texts("room_pending") == "확인 필요 4건", 15, "4 pending")
    s.a_open_expense("1,276 JPY")
    reach("expense_review_screen", id="review_payer_1")
    s.a_pick_member("review_payer", "다라")
    a_source("estimate")
    a_text_is("review_estimate_krw", "예상 금액 11,551원")
    a_text_is("review_estimate_quote", "한국은행 ECOS 원/일본엔(100엔) · 2026-11-02 고시 · 100엔당 905.25원")
    a_text_is("review_estimate_fallback", "지출일(2026-11-03)에 고시가 없어 그 전 가장 최근 고시일 값이에요.")
    a_text_is("review_estimate_synthetic", "가상 시험 환율 · 시장 환율 아님")
    a_text_is("review_even_summary", "다라 5,776원 · 가나 5,775원 · 합계 11,551원. 남는 1원은 결제자(다라)가 더 부담해요.")
    s.a_shot("android-fx-review-estimate")
    a_include()


def a_f2a():
    s.a_open_expense("1,500 JPY")
    reach("expense_review_screen", id="review_payer_1")
    s.a_pick_member("review_payer", "다라")
    a_source("estimate")
    a_text_is("review_estimate_krw", "예상 금액 13,554원")
    assert reach("expense_review_screen", id="review_estimate_quote").text.endswith("2026-11-04 고시 · 100엔당 903.60원")
    assert not u.find(id="review_estimate_fallback")
    s.a_shot("android-fx-review-before-correction")


def a_f2b():
    u.tap(reach("expense_review_screen", id="review_include"))
    until(lambda: u.find(id="review_failure"), 15, "quote changed message")
    a_text_is("review_failure", "기준환율 고시값이 새로 들어와 예상 금액이 바뀌었어요. 새 금액을 확인하고 다시 저장해 주세요.")
    a_text_is("review_estimate_krw", "예상 금액 13,563원")
    assert reach("expense_review_screen", id="review_estimate_quote").text.endswith("2026-11-04 고시 · 100엔당 904.20원")
    a_text_is("review_even_summary", "다라 6,782원 · 가나 6,781원 · 합계 13,563원. 남는 1원은 결제자(다라)가 더 부담해요.")
    s.a_shot("android-fx-review-quote-changed")
    a_include()


def a_f3():
    s.a_open_expense("8,000 JPY")
    reach("expense_review_screen", id="review_payer_1")
    s.a_pick_member("review_payer", "다라")
    a_source("acquisition")
    s.type_into("expense_review_screen", "review_acq_krw", "95000")
    s.type_into("expense_review_screen", "review_acq_foreign", "10000")
    s.hide_keyboard()
    a_text_is("review_acq_result", "8,000 JPY × 95,000원 ÷ 10,000 JPY = 76,000원 (원 단위 반올림)")
    a_text_is("review_even_summary", "한 사람 38,000원 · 합계 76,000원")
    s.a_shot("android-fx-review-acquisition")
    a_include()


def a_f4():
    s.a_open_expense("2,000 JPY")
    reach("expense_review_screen", id="review_payer_1")
    s.a_pick_member("review_payer", "다라")
    a_source("estimate")
    a_text_is("review_estimate_none", "이 날짜의 기준환율을 아직 확인하지 못했어요. 실제 청구액·환전 원가를 쓰거나 보류해 주세요.")
    a_text_is("review_share_problem", "쓸 수 있는 기준환율이 없어요. 다른 기준을 고르거나 보류해 주세요.")
    assert not reach("expense_review_screen", id="review_include").enabled
    s.a_shot("android-fx-review-undetermined")
    u.tap(reach("expense_review_screen", id="review_hold"))
    u.tap(u.wait(id="hold_reason_1", timeout=10))
    until(lambda: not u.find(id="expense_review_screen"), 15, "review closes")
    assert not u.find(id="room_pending")
    i = s.a_expense_index("1,276 JPY")
    row = " ".join(u.texts_within(f"expense_{i}"))
    assert "예상 금액 11,551원" in row and "가상 시험 환율 · 시장 환율 아님" in row, row
    s.a_shot("android-fx-ledger")


def a_totals():
    until(lambda: u.texts_within("transfer_1") == ["가나 → 다라", "50,556원"], 15, "transfer 1")
    assert u.texts_within("settlement_total") == ["함께 쓴 돈", "101,114원"], u.texts_within("settlement_total")
    assert u.texts_within("settlement_estimated") == ["이 중 예상 금액(기준환율)", "25,114원"]
    first = a_block("converted_1")
    assert "예상 금액 11,551원" in first and "2026-11-02 고시 · 100엔당 905.25원" in first and "가상 시험 환율" in first, first
    second = a_block("converted_2")
    assert "예상 금액 13,563원" in second and "100엔당 904.20원" in second, second
    third = a_block("converted_3")
    assert "환전 원가 76,000원" in third and "95,000원에 10,000 JPY" in third, third
    assert "보류: 원화 청구액 확인 대기" in a_block("excluded_1")


def a_block(id_):
    """송금표의 한 줄을 화면 안으로 가져와 그 안의 글자를 이어 붙인다."""
    reach("settlement_screen", id=id_)
    return " ".join(u.texts_within(id_))


def a_f5():
    u.tap(reach("room_screen", id="open_settlement"))
    a_totals()
    s.a_shot("android-fx-preview")
    u.tap(reach("settlement_screen", id="settlement_finalize"))
    u.tap(u.wait(id="finalize_confirm", timeout=10))
    until(lambda: u.texts_within("settlement_status") == ["정산 확정됨"], 20, "finalized")


def a_f6(prefix):
    s.a_open_trip()
    s.a_refresh()
    u.wait(id="room_finalized", timeout=20)
    u.tap(reach("room_screen", id="open_settlement"))
    node = u.wait(id="settlement_final_id", timeout=20)
    assert node.text.startswith(f"확정 번호 {prefix}"), node.text
    reach("settlement_screen", id="transfer_1")
    a_totals()
    assert not u.find(id="settlement_finalize")
    s.a_shot("android-fx-final")


# ---------------------------------------------------------------- 흐름
def main():
    log(f"FX E2E host={HOST} evidence={OUT}")
    s.backend("reset")
    member_submits()
    if HOST == "ios":
        s.ios_build()
        s.ios_launch()
        step = {"F1": lambda: s.ios_test("testF1_EstimateWithFallbackAndSyntheticLabel"),
                "F2a": lambda: s.ios_test("testF2a_OpenEstimateBeforeQuoteCorrection"),
                "F2b": lambda: s.ios_test("testF2b_IncludeAfterCorrectionShowsNewEstimate"),
                "F3": lambda: s.ios_test("testF3_AcquisitionCost"),
                "F4": lambda: s.ios_test("testF4_UndeterminedDateHolds"),
                "F5": lambda: s.ios_test("testF5_PreviewShowsEstimatedPartThenFinalize")}
    else:
        s.a_install()
        step = {"F1": a_f1, "F2a": a_f2a, "F2b": a_f2b, "F3": a_f3, "F4": a_f4, "F5": a_f5}

    step["F1"]()
    e = by_amount(rows("after-estimate"))[1276]
    assert (e["status"], e["basis"], e["krw"], e["rate"], e["rate_date"]) == \
        ("included", "reference_rate_estimate", 11551, "905.25", "2026-11-02"), e
    step["F2a"]()
    correct_quote()
    step["F2b"]()
    e = by_amount(rows("after-quote-change"))[1500]
    assert (e["basis"], e["krw"], e["rate"], e["rate_date"]) == ("reference_rate_estimate", 13563, "904.20", "2026-11-04"), e
    step["F3"]()
    e = by_amount(rows("after-acquisition"))[8000]
    assert (e["basis"], e["krw"], e["acq"], e["acq_foreign"]) == ("acquisition_cost", 76000, 95000, 10000), e
    step["F4"]()
    r = rows("after-hold")
    e = by_amount(r)[2000]
    assert e["status"] == "held" and e["basis"] is None and e["krw"] is None, e
    step["F5"]()
    final = rows("finalized")
    assert final["trip_status"] == "finalized" and final["snapshots"], final
    fid = lb.rows(f"select f.id::text as id from public.finalizations f join public.trips t on t.id = f.trip_id "
                  f"where t.name = '{TRIP}'", "fx-e2e-final")[0]["id"]
    change_quotes_after_finalize()
    if HOST == "ios":
        s.ios_kill()
        s.ios_launch()
        s.ios_test("testF6_FinalKeepsFrozenEstimates", FINAL_ID_PREFIX=fid[:8])
    else:
        u.sh(f"am force-stop {s.PKG}")
        s.a_launch()
        a_f6(fid[:8])
    after = rows("after-relaunch")
    assert after["snapshots"] == final["snapshots"] and after["expenses"] == final["expenses"], "frozen settlement changed"
    log("PASS")


if __name__ == "__main__":
    main()
