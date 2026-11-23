#!/usr/bin/env python3
"""검토 E2E(iOS·Android)가 기기에서 꺼낸 초안 폴더와 서버가 받은 사본을 검사한다. Python 표준 라이브러리만 쓴다.

사용: python3 -I apps/fixtures/review_e2e_check.py <명령> --draft <초안 폴더> --fixtures <receipts 폴더> [옵션]
  order                     사진 번호 ↔ 가상 영수증(원본 바이트로 찾음). 셸 변수 FAILED_POSITION(r10), MISSED_POSITION(r01), ORDER
  manual [--merchant M]     r10이 사본 없이 직접 입력으로 확인됐는지(2026-11-08 · 1760 JPY · 가게), 검토 입력이 지워졌는지
  plan --missed N           EDIT_POSITION(지금 열린 다음 사진), 놓친 가림을 고칠 OCR 줄 ID(MASK_LINE_IDS)와 가림 영역(BAND_TOP/HEIGHT)
  edited --position N [--suffix S]  고친 값(금액 +10, 가게 끝 "(수정)")으로 확인했는지
  masked --position N       그 사진의 가린 사본이 정답의 민감한 줄을 모두 가렸는지(check_artifact.py)
  typed                     확인하지 않은 입력(금액 999)이 남은 사진 번호 TYPED_POSITION
  states --label L          사진별 상태·시도 횟수·직접 입력 여부·검토 입력 파일 유무(내용은 내지 않음)
  received --received D --report R --checker C   서버가 받은 사본·지출 필드가 확인한 것과 같고 원본·직접 입력은 없는지
OCR 전문과 원본 내용은 출력하지 않는다(줄 ID·위치·해시·판정만).
"""
import argparse
import hashlib
import json
import math
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_artifact  # noqa: E402  (같은 폴더의 PNG 디코더)

SENSITIVE_KEYS = ("TEL", "カード", "会員", "承認", "予約")
ALLOWED_CURRENCIES = {"JPY", "KRW", "USD", "EUR"}
EXPENSE_COLUMNS = ["id", "trip_id", "client_request_id", "request_fingerprint", "uploaded_by", "expense_date", "amount_minor",
                   "currency", "merchant", "artifact_path", "artifact_sha256", "created_at"]


def norm(o):
    """두 플랫폼의 키 이름 차이(artifactSHA256/artifactSha256, Confirmed/confirmed)를 맞춘다."""
    if isinstance(o, dict):
        return {k.lower(): norm(v) for k, v in o.items()}
    if isinstance(o, list):
        return [norm(v) for v in o]
    return o


def load(args):
    d = Path(args.draft)
    if (d / "processing.json").exists():
        m = norm(json.loads((d / "processing.json").read_text()))
    else:  # 앱이 아직 처리를 시작하지 않았다(공유 확장이 초안만 만든 상태). 초안 목록 파일의 사진 순서를 쓴다.
        if (d / "draft.json").exists():
            names = json.loads((d / "draft.json").read_text())["photoFileNames"]
        else:
            props = dict(l.split("=", 1) for l in (d / "draft.properties").read_text().splitlines() if "=" in l and not l.startswith("#"))
            names = props["photos"].split(",")
        m = {"items": [{"id": Path(n).stem, "position": k + 1, "photofilename": n, "state": "queued", "attempts": 0}
                       for k, n in enumerate(names)], "recoveredcount": 0}
    items = sorted(m["items"], key=lambda i: i["position"])
    for i in items:
        i["state"] = i["state"].lower()
    truths = json.loads((Path(args.fixtures) / "ground-truth.json").read_text())
    by_bytes = {(Path(args.fixtures) / t["file"]).read_bytes(): t for t in truths}
    for i in items:
        i["truth"] = by_bytes.get((d / i["photofilename"]).read_bytes())
    return d, m, items


def item_at(items, position):
    return next(i for i in items if i["position"] == position)


def proposal(d, item):
    p = norm(json.loads((d / "proposals" / f"{item['id']}.json").read_text()))
    ocr = p.get("ocr", p)  # iOS는 ocr 아래, Android는 평평하다
    return p, ocr


def next_ready(items, after):
    ready = [i for i in items if i["state"] == "ready" and i["position"] != after]
    return next((i for i in ready if i["position"] > after), ready[0] if ready else None)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("command")
    ap.add_argument("--draft", required=True)
    ap.add_argument("--fixtures", required=True)
    ap.add_argument("--missed", type=int)
    ap.add_argument("--position", type=int)
    ap.add_argument("--label")
    ap.add_argument("--out")
    ap.add_argument("--received")
    ap.add_argument("--report")
    ap.add_argument("--checker")
    ap.add_argument("--truth-file", default="receipt-r01.png")
    ap.add_argument("--screenshot")
    ap.add_argument("--bounds")
    ap.add_argument("--merchant", default="ゆきみ茶屋", help="직접 입력한 가게 이름(Android E2E는 adb로 ASCII만 칠 수 있다)")
    ap.add_argument("--suffix", default="(수정)", help="고친 가게 이름 끝에 붙인 글자")
    args = ap.parse_args()
    d, m, items = load(args)
    result = None

    if args.command == "order":
        refs = [i["truth"]["ref"] if i["truth"] else "?" for i in items]
        print(f"FAILED_POSITION={refs.index('r10') + 1}")
        print(f"MISSED_POSITION={refs.index('r01') + 1}")
        print(f"ORDER={','.join(refs)}")
        return

    if args.command == "manual":
        r10 = next(i for i in items if i["truth"]["ref"] == "r10")
        c = r10.get("confirmed") or {}
        result = {
            "check": "manual-entry",
            "position": r10["position"],
            "state": r10["state"],
            "attempts": r10["attempts"],
            "artifact": c.get("artifactfilename"),
            "fields": c.get("fields"),
            "review_file_left": (d / "reviews" / f"{r10['id']}.json").exists(),
            "artifact_file_exists": (d / "confirmed" / f"{r10['id']}.png").exists(),
        }
        ok = (r10["state"] == "confirmed" and r10["attempts"] >= 2 and c.get("artifactfilename") is None
              and c.get("fields") == {"date": "2026-11-08", "amountminor": 1760, "currency": "JPY", "merchant": args.merchant}
              and not result["review_file_left"] and not result["artifact_file_exists"])
        result["pass"] = ok

    elif args.command == "plan":
        failed = next(i for i in items if i["truth"]["ref"] == "r10")
        nxt = next_ready(items, failed["position"])
        edit = nxt if nxt["position"] != args.missed else next_ready(items, nxt["position"])
        missed = item_at(items, args.missed)
        p, ocr = proposal(d, missed)
        assert (p.get("suggestedmasklineids") or []) == [], "제안을 비운 사진이어야 한다"
        t = missed["truth"]
        h = ocr["pixelheight"]
        sens = sorted(t["sensitive"], key=lambda s: s["rect"][1])
        lines = []
        for s in sens[:-1]:
            mid = (s["rect"][1] + s["rect"][3]) / 2 / t["height"]
            hit = [l["id"] for l in ocr["lines"] if l["y"] <= mid <= l["y"] + l["height"]]
            assert hit, f"OCR line for sensitive row {s['rect']}"
            lines.extend(hit)
        y0, y1 = sens[-1]["rect"][1], sens[-1]["rect"][3]
        top = math.floor((y0 - 6) * 100 / h)
        if (top - 47) % 2:  # 가림 영역은 47%에서 2%씩 옮긴다
            top -= 1
        bottom = math.ceil((y1 + 6) * 100 / h)
        print(f"EDIT_POSITION={edit['position']}")
        print(f"MASK_LINE_IDS={','.join(str(x) for x in lines)}")
        print(f"BAND_TOP={top}")
        print(f"BAND_HEIGHT={bottom - top}")
        return

    elif args.command == "edited":
        it = item_at(items, args.position)
        p, _ = proposal(d, it)
        c = it.get("confirmed") or {}
        f = c.get("fields") or {}
        result = {"check": "edited", "position": args.position, "state": it["state"], "fields": f,
                  "proposal_amount": p["fields"]["amountminor"], "proposal_merchant": p["fields"].get("merchant")}
        result["pass"] = (it["state"] == "confirmed" and c.get("artifactfilename")
                          and f.get("amountminor") == p["fields"]["amountminor"] + 10
                          and f.get("merchant") == ((p["fields"].get("merchant") or "") + args.suffix).strip())

    elif args.command == "masked":
        it = item_at(items, args.position)
        c = it["confirmed"]
        r = subprocess.run([sys.executable, "-I", str(Path(__file__).with_name("check_artifact.py")),
                            str(d / it["photofilename"]), str(d / "confirmed" / c["artifactfilename"])],
                           capture_output=True, text=True)
        result = {"check": "missed-mask-corrected", "position": args.position, **json.loads(r.stdout)}

    elif args.command == "typed":
        hits = []
        for f in (d / "reviews").glob("*.json") if (d / "reviews").is_dir() else []:
            if norm(json.loads(f.read_text())).get("amount") == "999":
                hits.append(next(i["position"] for i in items if i["id"] == f.stem))
        assert len(hits) == 1, hits
        print(f"TYPED_POSITION={hits[0]}")
        return

    elif args.command == "states":
        result = {
            "label": args.label,
            "items": [{"position": i["position"], "fixture": i["truth"]["ref"], "state": i["state"],
                       "attempts": i["attempts"], "manual": bool(i.get("confirmed")) and i["confirmed"].get("artifactfilename") is None,
                       "review_file": (d / "reviews" / f"{i['id']}.json").exists()} for i in items],
            "recoveredCount": m["recoveredcount"],
        }
        result["pass"] = True

    elif args.command == "received":
        report = json.loads(Path(args.report).read_text())
        confirmed = {i["confirmed"]["artifactsha256"]: i for i in items
                     if i["state"] == "confirmed" and i["confirmed"].get("artifactfilename")}
        originals = [(d / i["photofilename"]).read_bytes() for i in items]
        checks = []
        for f in sorted(Path(args.received).glob("*.png")):
            data = f.read_bytes()
            sha = hashlib.sha256(data).hexdigest()
            it = confirmed.get(sha)
            entry = {"fixture": it["truth"]["ref"] if it else None, "equals_confirmed_artifact": bool(it) and sha == f.stem,
                     "equals_any_original": any(o == data for o in originals)}
            if it:
                r = subprocess.run([sys.executable, "-I", args.checker, str(d / it["photofilename"]), str(f)],
                                   capture_output=True, text=True)
                entry["artifact_check"] = json.loads(r.stdout)
            checks.append(entry)
        manual = [i["confirmed"]["fields"] for i in items if i["state"] == "confirmed" and not i["confirmed"].get("artifactfilename")]
        server_fields = report["expense_fields"] or []
        result = {
            "check": "server-received",
            "artifacts": checks,
            "server_expense_fields": server_fields,
            "server_expense_columns": report["expense_columns"],
            "device_confirmed_with_artifact": len(confirmed),
            "manual_entries_on_server": [f for f in manual if any(
                s["amount_minor"] == f["amountminor"] and s["date"] == f["date"] for s in server_fields)],
            # 사본 해시로 짝지어 날짜·금액·통화·가게가 기기에서 확인한 값과 정확히 같은지(통화 포함).
            "device_fields_match_server": {
                c["confirmed"]["artifactsha256"]: (c["confirmed"]["fields"]["date"], c["confirmed"]["fields"]["amountminor"],
                                                   c["confirmed"]["fields"]["currency"], c["confirmed"]["fields"]["merchant"])
                for c in confirmed.values()
            } == {s["artifact_sha256"]: (s["date"], s["amount_minor"], s["currency"], s["merchant"]) for s in server_fields},
            "server_currencies_allowed": all(s["currency"] in ALLOWED_CURRENCIES for s in server_fields),
            # 지출 행에는 허용한 열만 있다(OCR 전문·원본 위치·기기 정보 같은 열이 없다).
            "server_columns_are_allowlist": report["expense_columns"].split(",") == EXPENSE_COLUMNS,
        }
        result["pass"] = (len(checks) == len(confirmed) and all(c["equals_confirmed_artifact"] and not c["equals_any_original"]
                                                              and c["artifact_check"]["pass"] for c in checks)
                          and not result["manual_entries_on_server"] and result["device_fields_match_server"]
                          and result["server_currencies_allowed"] and result["server_columns_are_allowlist"])

    elif args.command == "rotated":
        # EXIF 방향이 붙은 사진을 확인한 사본: 똑바로 선 크기이고, 똑바른 정답(--truth-file)의 민감한 줄이 모두 검정이며,
        # 띠 밖은 똑바른 원본과 거의 같다(JPEG 손실만큼 허용).
        it = item_at(items, args.position)
        artifact = (d / "confirmed" / it["confirmed"]["artifactfilename"]).read_bytes()
        truth_file = Path(args.fixtures) / args.truth_file
        truth = next(t for t in json.loads((Path(args.fixtures) / "ground-truth.json").read_text()) if t["file"] == args.truth_file)
        tw, th, src = check_artifact.decode(truth_file.read_bytes())
        aw, ah, art = check_artifact.decode(artifact)
        ink = black = 0
        for sline in truth["sensitive"]:
            x0, y0, x1, y1 = sline["rect"]
            for y in range(y0, y1):
                for x in range(x0, x1):
                    if all(v < 128 for v in src(x, y)):
                        ink += 1
                        black += art(x, y) == (0, 0, 0)
        bands = [(s_["rect"][1] - 40, s_["rect"][3] + 40) for s_ in truth["sensitive"]]
        diffs = []
        if (aw, ah) == (tw, th):
            for y in range(0, th, 4):
                if any(a <= y <= b for a, b in bands):
                    continue
                for x in range(0, tw, 4):
                    diffs.append(max(abs(p - q) for p, q in zip(src(x, y), art(x, y))))
        mean = sum(diffs) / len(diffs) if diffs else 999
        result = {"check": "exif-rotated", "position": args.position, "upright_size": [aw, ah], "expected_size": [tw, th],
                  "sensitive_ink_pixels": ink, "sensitive_ink_pixels_black": black,
                  "outside_mean_abs_diff": round(mean, 2), "outside_samples": len(diffs),
                  "chunks": check_artifact.chunks_of(artifact)}
        result["pass"] = (aw, ah) == (tw, th) and ink > 0 and ink == black and mean < 12 and \
            set(result["chunks"]) <= check_artifact.ALLOWED

    elif args.command == "align":
        # 화면 기록에서 검토 화면 원본 그림 칸을 잘라, 줄마다 글자 픽셀 비율이 똑바른 정답 그림과 같은 모양인지 본다.
        # 옆으로 누운 그림이면 줄 모양이 달라 상관이 낮다(가림 띠는 반투명이라 글자 판정에 들지 않는다).
        x0, y0, x1, y1 = (int(v) for v in args.bounds.split(","))
        sw, sh_, shot = check_artifact.decode(Path(args.screenshot).read_bytes())
        tw, th, src = check_artifact.decode((Path(args.fixtures) / args.truth_file).read_bytes())

        def profile(w0, h0, w1, h1, px, bins=100):
            rows = []
            for b in range(bins):
                y = h0 + (h1 - h0) * b // bins
                xs = range(w0, w1, max(1, (w1 - w0) // 120))
                rows.append(sum(1 for x in xs if all(v < 90 for v in px(x, y)[:3])) / len(xs))
            return rows

        a = profile(x0, y0, x1, y1, shot)
        b = profile(0, 0, tw, th, src)
        ma, mb = sum(a) / len(a), sum(b) / len(b)
        cov = sum((p - ma) * (q - mb) for p, q in zip(a, b))
        var = (sum((p - ma) ** 2 for p in a) * sum((q - mb) ** 2 for q in b)) ** 0.5
        corr = cov / var if var else 0
        box_aspect = (x1 - x0) / (y1 - y0)
        result = {"check": "ui-alignment", "row_profile_correlation": round(corr, 3), "box_aspect": round(box_aspect, 3),
                  "upright_aspect": round(tw / th, 3)}
        result["pass"] = corr > 0.6 and abs(box_aspect - tw / th) < 0.02
    else:
        sys.exit(__doc__)

    text = json.dumps(result, ensure_ascii=False)
    if args.out:
        Path(args.out).write_text(text + "\n")
    print(text)
    if not result.get("pass"):
        sys.exit(1)


if __name__ == "__main__":
    main()
