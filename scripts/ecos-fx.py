#!/usr/bin/env python3
"""한국은행 ECOS 기준환율(원/일본엔, 100엔당 원) 받기 어댑터와 가상 시험값 넣기. Python 표준 라이브러리만 쓴다(ADR-0008).

사용(저장소 루트, local:up 뒤):
  python3 -I scripts/ecos-fx.py series
      ECOS 통계표·세부항목 목록에서 731Y001/0000002의 이름·단위·주기·출처를 확인한다(키 필요).
  python3 -I scripts/ecos-fx.py ingest <시작 YYYY-MM-DD> [<끝 YYYY-MM-DD>]
      ECOS StatisticSearch 응답을 받아 그대로 로컬 서버의 ingest_ecos_jpy_rates(service_role 전용)에 넣는다.
      끝을 빼거나 오늘(KST) 이후로 주면 어제로 줄인다(서버는 KST로 끝난 날까지만 받는다). data_origin=ecos_live.
  python3 -I scripts/ecos-fx.py fixture [파일]
      가상 시험값(시장 환율 아님, 기본 supabase/fixtures/fx-jpy-synthetic.json)을 DB 소유자 권한으로 넣는다.
      data_origin=fixture. 이 길은 API로 열려 있지 않다.

키는 환경 변수 ECOS_API_KEY로만 받는다. 1Password nonanona vault에 항목을 만든 뒤 .env.tpl의 ECOS_API_KEY 줄 주석을 풀고
`op run --env-file=.env.tpl -- python3 -I scripts/ecos-fx.py ingest ...`로 주입한다. ECOS는 키를 URL 경로에 넣으므로
요청 URL·키·응답 원문은 어디에도 출력하지 않는다(받은 건수·날짜·ECOS 결과 코드만). ECOS가 공개한 시험 키 `sample`은
한 번에 10건까지만 주므로 14일씩 나눠 받는다.
"""

import datetime
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
import tomllib
import urllib.error
import urllib.request
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "supabase" / "fixtures" / "fx-jpy-synthetic.json"
KST = ZoneInfo("Asia/Seoul")

# ECOS 개발 명세: https://ecos.bok.or.kr/api/#/DevGuide/DevSpeciflcation (확인일 2026-11-24)
# 731Y001 "3.1.1.1. 주요국 통화의 대원화환율"(출처 서울외국환중개, 주기 D), 0000002 "원/일본엔(100엔)", 단위 "원".
ECOS_BASE = "https://ecos.bok.or.kr/api"
STAT_CODE, ITEM_CODE, ITEM_NAME, UNIT_NAME = "731Y001", "0000002", "원/일본엔(100엔)", "원"
ROW_KEYS = ["STAT_CODE", "STAT_NAME", "ITEM_CODE1", "ITEM_NAME1", "ITEM_CODE2", "ITEM_NAME2", "ITEM_CODE3", "ITEM_NAME3",
            "ITEM_CODE4", "ITEM_NAME4", "UNIT_NAME", "WGT", "TIME", "DATA_VALUE"]


def log(msg):
    print(f"[ecos-fx] {msg}", flush=True)


def today_kst():
    return datetime.datetime.now(KST).date()


def ecos_key():
    key = os.environ.get("ECOS_API_KEY", "")
    if not key:
        sys.exit("[ecos-fx] ECOS_API_KEY가 없습니다. op run --env-file=.env.tpl -- ... 로 주입하세요(값은 출력하지 않습니다).")
    # 경로에 들어가므로 영숫자만 받는다(경로 조작 방지).
    if not re.fullmatch(r"[A-Za-z0-9]{1,64}", key):
        sys.exit(f"[ecos-fx] ECOS_API_KEY 형식이 맞지 않습니다(길이 {len(key)}).")
    return key


def ecos_get(key, *parts):
    """ECOS 호출. URL에 키가 들어가므로 실패해도 URL·예외 원문을 내지 않고 종류만 알린다."""
    url = "/".join([ECOS_BASE, parts[0], key, "json", "kr", *parts[1:]])
    req = urllib.request.Request(url, headers={"Accept": "application/json", "User-Agent": "nonanona-fx-adapter"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        sys.exit(f"[ecos-fx] ECOS HTTP {e.code}")
    except (urllib.error.URLError, TimeoutError, OSError):
        sys.exit("[ecos-fx] ECOS에 연결하지 못했습니다")
    except ValueError:
        sys.exit("[ecos-fx] ECOS 응답이 JSON이 아닙니다")


def result_code(body):
    r = body.get("RESULT") if isinstance(body, dict) else None
    return r.get("CODE") if isinstance(r, dict) else None


def ymd(d):
    return d.strftime("%Y%m%d")


def windows(start, end, days):
    cur = start
    while cur <= end:
        stop = min(end, cur + datetime.timedelta(days=days - 1))
        yield cur, stop
        cur = stop + datetime.timedelta(days=1)


# ---------------------------------------------------------------- 서버에 넣기
def local_backend():
    spec = importlib.util.spec_from_file_location("local_backend", ROOT / "scripts" / "local-backend.py")
    lb = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(lb)
    return lb


def ingest_live(response, start, end):
    """service_role RPC(로컬 API). 서버가 응답 원문을 검사한다. 상태 코드와 서버 코드만 돌려준다."""
    lb = local_backend()
    env = lb.status()
    st, raw = lb.http(env, "POST", "/rest/v1/rpc/ingest_ecos_jpy_rates",
                      {"p_response": response, "p_start": start.isoformat(), "p_end": end.isoformat()},
                      token=env["SECRET_KEY"], key=env["SECRET_KEY"])
    return st, (json.loads(raw) if st < 300 else lb.code_of(raw))


def psql(sql):
    with (ROOT / "supabase" / "config.toml").open("rb") as config:
        project_id = tomllib.load(config)["project_id"]
    r = subprocess.run(["docker", "exec", "-i", f"supabase_db_{project_id}", "psql", "-U", "postgres", "-tAq", "-v", "ON_ERROR_STOP=1"],
                       input=sql, capture_output=True, text=True)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def ingest_fixture(response, start, end):
    """가상 시험값: DB 소유자로 private.ingest_fx_response(..., 'fixture'). (성공 여부, 결과 JSON 또는 서버 코드)."""
    text = json.dumps(response, ensure_ascii=False)
    tag = "$fx" + hashlib.sha256(text.encode()).hexdigest()[:12] + "$"
    assert tag not in text
    code, out, err = psql(f"select private.ingest_fx_response({tag}{text}{tag}::jsonb, '{start.isoformat()}', "
                          f"'{end.isoformat()}', 'fixture');")
    if code != 0:
        m = re.search(r"ERROR:\s+([a-z_]+)", err)
        return False, (m.group(1) if m else "error")
    return True, json.loads(out)


def ecos_shape(values):
    """ECOS StatisticSearch 응답 모양(실제 응답의 키 그대로)으로 감싼다. values: {날짜: '고시값'}."""
    if not values:
        return {"RESULT": {"CODE": "INFO-200", "MESSAGE": "해당하는 데이터가 없습니다."}}
    rows = []
    for day in sorted(values):
        row = dict.fromkeys(ROW_KEYS)
        row.update({"STAT_CODE": STAT_CODE, "STAT_NAME": "3.1.1.1. 주요국 통화의 대원화환율", "ITEM_CODE1": ITEM_CODE,
                    "ITEM_NAME1": ITEM_NAME, "UNIT_NAME": UNIT_NAME, "TIME": day.replace("-", ""), "DATA_VALUE": values[day]})
        rows.append(row)
    return {"StatisticSearch": {"list_total_count": len(rows), "row": rows}}


# ---------------------------------------------------------------- 명령
def cmd_series():
    key = ecos_key()
    table = ecos_get(key, "StatisticTableList", "1", "10", STAT_CODE)
    # sample 키는 10건까지만 준다(0000002는 목록 앞쪽에 있다).
    items = ecos_get(key, "StatisticItemList", "1", "10" if key == "sample" else "100", STAT_CODE)
    t = next((r for r in (table.get("StatisticTableList") or {}).get("row", []) if r.get("STAT_CODE") == STAT_CODE), None)
    i = next((r for r in (items.get("StatisticItemList") or {}).get("row", []) if r.get("ITEM_CODE") == ITEM_CODE), None)
    if not t or not i:
        sys.exit(f"[ecos-fx] 통계표 또는 항목을 찾지 못했습니다(결과 코드 {result_code(table) or result_code(items)})")
    report = {"stat_code": t["STAT_CODE"], "stat_name": t["STAT_NAME"], "org": t["ORG_NAME"], "cycle": t["CYCLE"],
              "item_code": i["ITEM_CODE"], "item_name": i["ITEM_NAME"], "unit": i["UNIT_NAME"],
              "start": i["START_TIME"], "end": i["END_TIME"]}
    print(json.dumps(report, ensure_ascii=False, indent=1))
    ok = (i["ITEM_NAME"] == ITEM_NAME and i["UNIT_NAME"] == UNIT_NAME and i["CYCLE"] == "D" and t["CYCLE"] == "D")
    log("항목 이름·단위·주기가 서버 검사와 같습니다" if ok else "항목 메타데이터가 바뀌었습니다: 서버 검사(마이그레이션)를 다시 보세요")
    sys.exit(0 if ok else 1)


def cmd_ingest(args):
    if not args:
        sys.exit("사용: ecos-fx.py ingest <시작 YYYY-MM-DD> [<끝 YYYY-MM-DD>]")
    start = datetime.date.fromisoformat(args[0])
    yesterday = today_kst() - datetime.timedelta(days=1)
    end = datetime.date.fromisoformat(args[1]) if len(args) > 1 else yesterday
    if end > yesterday:
        log(f"끝 날짜를 어제(KST) {yesterday.isoformat()}로 줄입니다(오늘 값은 아직 받지 않습니다)")
        end = yesterday
    if start > end:
        sys.exit("[ecos-fx] 시작이 끝보다 늦습니다")
    key = ecos_key()
    sample = key == "sample"
    # sample 키는 한 번에 10건까지: 14일(영업일 최대 10일)씩. 그 밖에는 1000건, 180일씩(서버는 한 번에 366일까지).
    size, span = (10, 14) if sample else (1000, 180)
    total = 0
    for a, b in windows(start, end, span):
        body = ecos_get(key, "StatisticSearch", "1", str(size), STAT_CODE, "D", ymd(a), ymd(b), ITEM_CODE)
        code = result_code(body)
        if code is not None and code != "INFO-200":
            sys.exit(f"[ecos-fx] ECOS 결과 코드 {code} ({a}~{b}): 넣지 않았습니다")
        st, res = ingest_live(body, a, b)
        if st >= 300:
            sys.exit(f"[ecos-fx] 서버가 거절했습니다 ({a}~{b}): HTTP {st} {res}")
        total += res["rows"]
        log(f"{a}~{b}: {res['rows']}건 넣음 (받기 기록 {res['ingestion_id'][:8]}, data_origin={res['data_origin']})")
    log(f"합계 {total}건")


def cmd_fixture(args):
    path = Path(args[0]) if args else FIXTURE
    data = json.loads(path.read_text(encoding="utf-8"))
    for run in data["runs"]:
        a, b = datetime.date.fromisoformat(run["start"]), datetime.date.fromisoformat(run["end"])
        ok, res = ingest_fixture(ecos_shape(run["values"]), a, b)
        if not ok:
            sys.exit(f"[ecos-fx] 가상 시험값을 넣지 못했습니다({run['label']}): {res}")
        log(f"가상 시험값(시장 환율 아님) {run['label']}: {a}~{b} {res['rows']}건 (data_origin=fixture)")


def main():
    cmd, args = (sys.argv[1], sys.argv[2:]) if len(sys.argv) > 1 else ("", [])
    if cmd == "series":
        cmd_series()
    elif cmd == "ingest":
        cmd_ingest(args)
    elif cmd == "fixture":
        cmd_fixture(args)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
