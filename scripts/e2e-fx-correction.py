#!/usr/bin/env python3
"""확정 전 기준환율 정정 E2E(ADR-0009, 로컬 Supabase 모드, 방장 기기 하나: iOS 시뮬레이터 또는 Android 에뮬레이터, 표준 라이브러리만).

가상 회원이 시드 여행방(가상 후쿠오카 정산)에 엔화 직접 입력 3건을 올리고, 가상 방장 계정이 같은 RPC로 셋 다 기준환율 예상으로
포함한다(예상 포함 화면 자체는 e2e-fx.py가 확인한다): 2,000엔(10-20, 909.35 → 18,187원), 1,500엔(11-04, 903.60 → 13,554원),
1,000엔(11-06, 904.40 → 9,044원). 그 뒤 방장 기기에서:
  X1 미리보기: 결정할 지출 없음, 확정 가능 → 스크립트가 보는 사이 세 날짜를 정정(11-04 904.20, 11-06 904.90, 10-19~20 고시 없음)
  X2 본 미리보기로 확정 → 거절(fx_correction_required), 결정 필요 3건 → 1,500엔 비교(고정 13,554 / 새 13,563 / +9) → 고정 금액 유지
     → 스크립트가 11-04를 같은 값으로 다시 받음(유지 그대로)
  X3 장부에 유지 표시 → 1,000엔 새 예상 금액 적용(9,049원, 결제자 +1) → 스크립트가 11-04를 다시 정정(904.50)
  X4 1,500엔이 다시 결정 필요(새 13,568 / +14) → 다시 유지
  X5 2,000엔: 쓸 고시값 없음, 유지·적용 없음 → 보류
  X6 미리보기 → 확정 → 유지한 13,554원은 고정 고시값(903.60) 그대로 예상 금액으로 확정본에 남는다.
단계마다 서버 행(상태·기준·원화·고정 고시값·정정 상태·유지 결정 수)을 확인한다. 기준환율은 가상 시험값(data_origin=fixture)뿐이다.

사전 조건: mise run local:up. iOS는 부팅한 시뮬레이터, Android는 실행 중인 에뮬레이터 하나(adb 기기 하나).
사용: python3 -I scripts/e2e-fx-correction.py ios <시뮬레이터 UDID> [증거 폴더]
      python3 -I scripts/e2e-fx-correction.py android [증거 폴더]
"""

import datetime
import importlib.util
import json
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
           else tempfile.mkdtemp(prefix="nonanona-fxc-e2e-"))


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


s = load("e2e_settlement", "e2e-settlement.py", [str(ROOT / "scripts" / "e2e-settlement.py"), UDID, HOST, str(OUT)])
fx = load("ecos_fx", "ecos-fx.py")
lb, u, log, until, reach = s.lb, s.u, s.log, s.until, s.reach
TRIP = s.TRIP
EXPENSES = [("2026-10-20", 2000, "가상 공항버스"), ("2026-11-04", 1500, "가상 라멘"), ("2026-11-06", 1000, "가상 택시")]


def token(account):
    env = lb.status()
    accounts = json.loads((lb.RUN / "accounts.json").read_text())
    st, raw = lb.http(env, "POST", "/auth/v1/token?grant_type=password",
                      {"email": accounts[account][0], "password": accounts[account][1]})
    body = json.loads(raw)
    return env, body["access_token"], body["user"]["id"]


def rpc(env, tok, name, **params):
    st, raw = lb.http(env, "POST", f"/rest/v1/rpc/{name}", params, token=tok)
    assert st == 200, (name, st, lb.code_of(raw))
    return json.loads(raw)


def setup():
    env, member_tok, member_id = token("member")
    _, host_tok, host_id = token("host")
    trip = lb.rows(f"select id from public.trips where name = '{TRIP}'", "fxc-e2e-trip")[0]["id"]
    for day, amount, merchant in EXPENSES:
        rpc(env, member_tok, "submit_manual_expense", p_trip=trip, p_request_id=str(uuid.uuid4()), p_expense_date=day,
            p_amount_minor=amount, p_currency="JPY", p_merchant=merchant)
    for e in rpc(env, host_tok, "get_room_ledger", p_trip=trip)["expenses"]:
        p = e["fx_proposal"]
        half = p["krw"] // 2
        rpc(env, host_tok, "review_expense", p_expense=e["expense_id"], p_expected_version=e["version"],
            p_request_id=str(uuid.uuid4()), p_decision="include", p_payer=host_id, p_krw_amount=p["krw"],
            p_krw_basis="reference_rate_estimate", p_fx_quote_id=p["quote_id"],
            p_shares=[{"user_id": host_id, "krw": p["krw"] - half}, {"user_id": member_id, "krw": half}])
    log("member submitted 3 JPY manual expenses; host account included them as estimates via the same RPCs")


def rows(label):
    r = lb.rows(f"""select coalesce(json_agg(json_build_object('amount', e.amount_minor, 'status', e.status, 'version', e.version,
          'krw', e.krw_amount, 'basis', e.krw_basis, 'rate', e.fx_rate::text, 'rate_date', e.fx_rate_date,
          'correction', case when t.status = 'open' then private.fx_correction(e) end,
          'keeps', (select count(*) from public.fx_keep_decisions k where k.expense_id = e.id),
          'shares', (select json_agg(s.krw order by s.krw desc) from public.expense_shares s where s.expense_id = e.id))
          order by e.expense_date), '[]') as expenses,
          (select status from public.trips where name = '{TRIP}') as trip_status,
          (select string_agg(f.snapshot_sha256, ',') from public.finalizations f join public.trips t2 on t2.id = f.trip_id
             where t2.name = '{TRIP}') as snapshots
        from public.expenses e join public.trips t on t.id = e.trip_id where t.name = '{TRIP}'""", "fxc-e2e-rows")[0]
    (OUT / f"server-{label}.json").write_text(json.dumps(r, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    log(f"server {label}: " + ", ".join(
        f"{e['amount']}JPY {e['status']} {e['krw']} @{e['rate']} {e['correction']} keeps={e['keeps']}" for e in r["expenses"]))
    return {e["amount"]: e for e in r["expenses"]}, r


def ingest(values, start, end, what):
    ok, res = fx.ingest_fixture(fx.ecos_shape(values), datetime.date.fromisoformat(start), datetime.date.fromisoformat(end))
    assert ok, res
    log(f"synthetic quotes ingested (fixture): {what}")


# ---------------------------------------------------------------- Android 방장 단계
def a_text_is(screen, id_, want):
    got = reach(screen, id=id_).text
    assert got == want, (id_, got)


def a_compare(pinned, pinned_date, new, new_date, diff):
    a_text_is("expense_review_screen", "review_fx_pinned_krw", pinned)
    assert reach("expense_review_screen", id="review_fx_pinned_quote").text.endswith(pinned_date)
    a_text_is("expense_review_screen", "review_fx_new_krw", new)
    assert reach("expense_review_screen", id="review_fx_new_quote").text.endswith(new_date)
    a_text_is("expense_review_screen", "review_fx_diff", diff)


def a_corrections_label(want):
    """장부 머리의 "환율 정정 결정 필요 N건"(목록이 아래로 넘어가 있을 수 있어 화면 안으로 가져온다)."""
    def seen():
        try:
            return reach("room_screen", id="room_fx_correction") and s.a_texts("room_fx_correction") == want
        except TimeoutError:
            return False
    until(seen, 20, want)


def a_open(line):
    """장부에서 "날짜 · 원래 금액" 줄을 화면 안으로 가져와 그 지출 검토를 연다(지출 줄이 길어 반쯤 보이는 줄도 있다)."""
    u.tap(reach("room_screen", text=line))
    u.wait(id="expense_review_screen", timeout=10)


def a_back_to_room():
    until(lambda: not u.find(id="expense_review_screen"), 15, "review closes")
    u.wait(id="room_screen", timeout=10)


def a_x1():
    s.a_login("다라")
    s.a_open_trip()
    s.a_refresh()
    assert not u.find(id="room_fx_correction")
    u.tap(reach("room_screen", id="open_settlement"))
    until(lambda: u.find(id="transfer_1"), 15, "preview")
    assert not u.find(id="settlement_fx_blocked")
    assert reach("settlement_screen", id="settlement_finalize").enabled
    s.a_shot("android-fxc-preview-before")


def a_x2():
    u.tap(reach("settlement_screen", id="settlement_finalize"))
    u.tap(u.wait(id="finalize_confirm", timeout=10))
    until(lambda: u.find(id="settlement_fx_1"), 20, "blocked list")
    a_text_is("settlement_screen", "settlement_failure",
              "기준환율이 정정된 예상 금액이 있어 확정하지 않았어요. 지출마다 고정 금액 유지나 새 예상 금액 적용을 골라 주세요.")
    a_text_is("settlement_screen", "settlement_fx_blocked", "기준환율이 정정된 예상 금액 3건이 있어 확정할 수 없어요.")
    reach("settlement_screen", id="settlement_fx_1")
    assert "고정 18,187원 · 쓸 고시값 없음" in s.a_texts("settlement_fx_1")
    reach("settlement_screen", id="settlement_fx_2")
    second = s.a_texts("settlement_fx_2")
    assert "1,500 JPY" in second and "고정 13,554원 → 새 13,563원" in second, second
    reach("settlement_screen", id="settlement_fx_3")
    assert "고정 9,044원 → 새 9,049원" in s.a_texts("settlement_fx_3")
    assert not reach("settlement_screen", id="settlement_finalize").enabled
    s.a_shot("android-fxc-blocked")
    u.tap(reach("settlement_screen", id="settlement_fx_2"))
    u.wait(id="expense_review_screen", timeout=10)
    a_compare("13,554원", "2026-11-04 고시 · 100엔당 903.60원", "새 예상 금액 13,563원", "2026-11-04 고시 · 100엔당 904.20원",
              "차이 +9원")
    a_text_is("expense_review_screen", "review_fx_state", "확정하려면 둘 중 하나를 골라 주세요. 고르기 전에는 포함한 금액이 바뀌지 않아요.")
    s.a_shot("android-fxc-compare")
    u.tap(reach("expense_review_screen", id="review_fx_keep"))
    a_back_to_room()


def a_x3():
    s.a_refresh()
    a_corrections_label("환율 정정 결정 필요 2건")
    reach("room_screen", text="기준환율이 정정됐지만 고정 금액 유지를 골랐어요. 예상 금액 그대로예요.")
    i = s.a_expense_index("1,500 JPY")
    row = " ".join(u.texts_within(f"expense_{i}"))
    assert "고정 금액 유지를 골랐어요" in row and "예상 금액 13,554원" in row, row
    a_open("2026-11-06 · 1,000 JPY")
    a_compare("9,044원", "2026-11-06 고시 · 100엔당 904.40원", "새 예상 금액 9,049원", "2026-11-06 고시 · 100엔당 904.90원",
              "차이 +5원")
    a_text_is("expense_review_screen", "review_even_summary", "다라 4,525원 · 가나 4,524원 · 합계 9,049원. 남는 1원은 결제자(다라)가 더 부담해요.")
    s.a_shot("android-fxc-apply")
    u.tap(reach("expense_review_screen", id="review_fx_apply"))
    a_back_to_room()


def a_x4():
    s.a_refresh()
    a_corrections_label("환율 정정 결정 필요 2건")
    a_open("2026-11-04 · 1,500 JPY")
    a_compare("13,554원", "2026-11-04 고시 · 100엔당 903.60원", "새 예상 금액 13,568원", "2026-11-04 고시 · 100엔당 904.50원",
              "차이 +14원")
    s.a_shot("android-fxc-repeat")
    u.tap(reach("expense_review_screen", id="review_fx_keep"))
    a_back_to_room()


def a_x5():
    a_open("2026-10-20 · 2,000 JPY")
    a_text_is("expense_review_screen", "review_fx_pinned_krw", "18,187원")
    a_text_is("expense_review_screen", "review_fx_new_none", "쓸 수 있는 기준환율 고시값이 없어요.")
    assert reach("expense_review_screen", id="review_fx_state").text.startswith("정정 뒤 이 날짜에 쓸 수 있는 기준환율이 없어")
    assert not u.find(id="review_fx_keep") and not u.find(id="review_fx_apply")
    s.a_shot("android-fxc-unavailable")
    u.tap(reach("expense_review_screen", id="review_hold"))
    u.tap(u.wait(id="hold_reason_1", timeout=10))
    a_back_to_room()
    assert not u.find(id="room_fx_correction")


def a_block(id_):
    reach("settlement_screen", id=id_)
    return " ".join(u.texts_within(id_))


def a_x6():
    u.tap(reach("room_screen", id="open_settlement"))
    until(lambda: u.texts_within("transfer_1") == ["가나 → 다라", "11,301원"], 15, "transfer 1")
    assert not u.find(id="settlement_fx_blocked")
    assert u.texts_within("settlement_estimated") == ["이 중 예상 금액(기준환율)", "22,603원"], u.texts_within("settlement_estimated")
    first = a_block("converted_1")
    assert "예상 금액 13,554원" in first and "100엔당 903.60원" in first, first
    second = a_block("converted_2")
    assert "예상 금액 9,049원" in second and "100엔당 904.90원" in second, second
    u.tap(reach("settlement_screen", id="settlement_finalize"))
    u.tap(u.wait(id="finalize_confirm", timeout=10))
    until(lambda: u.texts_within("settlement_status") == ["정산 확정됨"], 20, "finalized")
    final = a_block("converted_1")
    assert "예상 금액 13,554원" in final and "실제 청구액이 아니에요" in final, final
    s.a_shot("android-fxc-final")


# ---------------------------------------------------------------- 흐름
def main():
    log(f"FX correction E2E host={HOST} evidence={OUT}")
    s.backend("reset")
    setup()
    if HOST == "ios":
        s.ios_build()
        s.ios_launch()
        step = {k: (lambda name: (lambda: s.ios_test(name)))(v) for k, v in {
            "X1": "testX1_PreviewReadyBeforeCorrection", "X2": "testX2_FinalizeBlockedThenKeepPinned",
            "X3": "testX3_RefetchKeepsDecisionThenApplyNew", "X4": "testX4_AnotherCorrectionNeedsANewDecision",
            "X5": "testX5_UnavailableQuoteHolds", "X6": "testX6_FinalizeKeepsPinnedEstimate"}.items()}
    else:
        s.a_install()
        step = {"X1": a_x1, "X2": a_x2, "X3": a_x3, "X4": a_x4, "X5": a_x5, "X6": a_x6}

    by, _ = rows("included")
    assert [(by[a]["krw"], by[a]["rate"], by[a]["correction"]) for a in (2000, 1500, 1000)] == \
        [(18187, "909.35", None), (13554, "903.60", None), (9044, "904.40", None)], by
    step["X1"]()
    rev = lb.rows(f"select revision from public.trips where name = '{TRIP}'", "fxc-e2e-rev")[0]["revision"]
    ingest({"2026-11-04": "904.20", "2026-11-06": "904.90"}, "2026-11-04", "2026-11-06", "11-04 904.20, 11-06 904.90")
    ingest({}, "2026-10-19", "2026-10-20", "10-19..10-20 no quotes")
    by, _ = rows("corrected")
    assert [by[a]["correction"] for a in (2000, 1500, 1000)] == ["unavailable", "required", "required"], by
    assert lb.rows(f"select revision from public.trips where name = '{TRIP}'", "fxc-e2e-rev")[0]["revision"] == rev, \
        "a correction alone does not bump the revision (the app's finalize uses the revision it saw)"

    step["X2"]()
    by, r = rows("after-keep")
    assert r["trip_status"] == "open" and not r["snapshots"], "finalize was refused"
    assert (by[1500]["correction"], by[1500]["keeps"], by[1500]["krw"], by[1500]["rate"]) == ("kept", 1, 13554, "903.60"), by[1500]
    ingest({"2026-11-04": "904.20"}, "2026-11-04", "2026-11-04", "identical refetch of 11-04 904.20")
    by, _ = rows("after-refetch")
    assert by[1500]["correction"] == "kept", by[1500]

    step["X3"]()
    by, _ = rows("after-apply")
    assert (by[1000]["krw"], by[1000]["rate"], by[1000]["correction"], by[1000]["shares"]) == (9049, "904.90", None, [4525, 4524]), \
        by[1000]
    ingest({"2026-11-04": "904.50"}, "2026-11-04", "2026-11-04", "another correction of 11-04 -> 904.50")
    by, _ = rows("after-second-correction")
    assert by[1500]["correction"] == "required", by[1500]

    step["X4"]()
    by, _ = rows("after-second-keep")
    assert (by[1500]["correction"], by[1500]["keeps"], by[1500]["krw"]) == ("kept", 2, 13554), by[1500]

    step["X5"]()
    by, _ = rows("after-hold")
    assert by[2000]["status"] == "held" and by[2000]["correction"] is None, by[2000]

    step["X6"]()
    by, r = rows("finalized")
    assert r["trip_status"] == "finalized" and r["snapshots"], r
    snap = lb.rows(f"select f.snapshot from public.finalizations f join public.trips t on t.id = f.trip_id "
                   f"where t.name = '{TRIP}'", "fxc-e2e-snap")[0]["snapshot"]
    x = {e["amount_minor"]: e for e in snap["inputs"]["expenses"]}
    assert (x[1500]["krw_amount"], x[1500]["fx"]["rate"], x[1500]["is_estimate"]) == (13554, "903.60", True), x[1500]
    assert (x[1000]["krw_amount"], x[1000]["fx"]["rate"]) == (9049, "904.90"), x[1000]
    assert snap["outputs"]["estimated_total_krw"] == 22603 and snap["outputs"]["transfers"][0]["krw"] == 11301, snap["outputs"]
    log("PASS")


if __name__ == "__main__":
    main()
