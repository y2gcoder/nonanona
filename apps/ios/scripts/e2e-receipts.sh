#!/usr/bin/env bash
# iOS 시뮬레이터 E2E(영수증 처리): 사진 앱에서 가상 영수증 10장 공유 → 기기 안 OCR(동시 2장)
#   → 처리 도중 SIGKILL → 디스크 상태 확인 → 다시 열어 이어서 처리 → 실패한 사진만 다시 읽기
#   → 개발용 확인으로 가림 사본 → 호스트에서 가림 픽셀·메타데이터 검사.
# 사용: apps/ios/scripts/e2e-receipts.sh <simulator-udid> [증거 폴더]
set -euo pipefail
UDID="$1"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="$HERE/../fixtures/receipts"
OUT="${2:-$(mktemp -d)}"
WORK="${WORK:-$(mktemp -d)}"
mkdir -p "$WORK" "$OUT/screens"
APP_ID=app.nonanona
GROUP=group.app.nonanona
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$OUT/ios-e2e-receipts.log"; }
: > "$OUT/ios-e2e-receipts.log"
cd "$HERE"

log "build-for-testing (Debug, test backend)"
xcodebuild build-for-testing -project Nonanona.xcodeproj -scheme Nonanona \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$WORK/dd" NONANONA_BACKEND=test > "$WORK/build.log" 2>&1
xcrun simctl uninstall "$UDID" "$APP_ID" || true
xcrun simctl install "$UDID" "$WORK/dd/Build/Products/Debug-iphonesimulator/Nonanona.app"
xcrun simctl addmedia "$UDID" "$FIXTURES"/receipt-r*.png
for _ in $(seq 1 30); do
  xcrun simctl spawn "$UDID" pluginkit -mA -p com.apple.share-services 2>/dev/null | grep -q "$APP_ID.share" && break
  sleep 1
done

run_test() {
  log "test $1"
  rm -rf "$WORK/$1.xcresult" "$WORK/attachments/$1" && mkdir -p "$WORK/attachments/$1"
  xcodebuild test-without-building -project Nonanona.xcodeproj -scheme Nonanona \
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$WORK/dd" \
    -resultBundlePath "$WORK/$1.xcresult" -only-testing:"NonanonaUITests/ReceiptProcessingUITests/$1" \
    > "$WORK/$1.log" 2>&1 || { grep -E "error:|Test Case" "$WORK/$1.log" | tail -20; exit 1; }
  grep -E "Test Case .*(passed|failed)" "$WORK/$1.log" | tee -a "$OUT/ios-e2e-receipts.log"
  xcrun xcresulttool export attachments --path "$WORK/$1.xcresult" --output-path "$WORK/attachments/$1" > /dev/null
}

app_pid() {
  local list
  list="$(xcrun simctl spawn "$UDID" launchctl list)"
  awk '/UIKitApplication:app\.nonanona\[/ && $1 ~ /^[0-9]+$/ {print $1}' <<< "$list" | sed -n 1p
}

draft_dir() { ls -d "$(xcrun simctl get_app_container "$UDID" "$APP_ID" "$GROUP")"/receipt-import/drafts/*/ | head -1; }

states() {  # $1 = label. processing.json의 상태·시도 횟수만 요약한다(OCR 내용은 읽지 않는다).
  python3 -I - "$(draft_dir)processing.json" "$1" <<'PY' | tee "$OUT/ios-receipts-state-$1.json" | tee -a "$OUT/ios-e2e-receipts.log"
import collections, json, sys
m = json.load(open(sys.argv[1]))
items = sorted(m["items"], key=lambda i: i["position"])
print(json.dumps({
    "label": sys.argv[2],
    "states": dict(collections.Counter(i["state"] for i in items)),
    "attempts": [i["attempts"] for i in items],
    "failures": {i["position"]: i.get("failure") for i in items if i.get("failure")},
    "recoveredCount": m["recoveredCount"],
}, ensure_ascii=False))
PY
}

run_test testR1_ShareTenPhotos
# 처리를 늦추고 4번째 사진의 첫 시도를 실패시킨다(debug 빌드만 읽는 실행 환경 변수).
log "launch app with processing delay 2500ms and a first-attempt failure at position 4"
SIMCTL_CHILD_NONANONA_PROCESSING_DELAY_MS=2500 SIMCTL_CHILD_NONANONA_FAIL_FIRST_ATTEMPT_POSITION=4 \
  xcrun simctl launch --terminate-running-process "$UDID" "$APP_ID" > /dev/null
for _ in $(seq 1 300); do
  n="$(python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1])); print(sum(i["state"] in ("ready","failed","confirmed") for i in m["items"]))' "$(draft_dir)processing.json" 2>/dev/null || echo 0)"
  (( n >= 4 )) && break
  sleep 0.3
done
(( n >= 4 && n <= 6 )) || { log "processed=$n is outside 4..6 at kill time"; exit 1; }
pid="$(app_pid)"
[[ -n $pid ]] || { log "app is not running mid-processing"; exit 1; }
kill -9 "$pid"
log "SIGKILL app pid $pid with $n/10 processed"
for _ in $(seq 1 20); do [[ -z "$(app_pid)" ]] && break; sleep 0.5; done
states at-kill

run_test testR2_ReopenResumesThenRetryOnlyFailedAndConfirm
states final
DIR="$(draft_dir)"
python3 -I - "$DIR" "$WORK/artifact-pair" <<'PY'
import json, pathlib, shutil, sys
d, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
m = json.load(open(d / "processing.json"))
item = next(i for i in m["items"] if i["state"] == "confirmed")
shutil.copy(d / item["photoFileName"], str(out) + "-original")
shutil.copy(d / "confirmed" / item["confirmed"]["artifactFileName"], str(out) + "-artifact")
PY
python3 -I "$HERE/../fixtures/check_artifact.py" "$WORK/artifact-pair-original" "$WORK/artifact-pair-artifact" \
  | tee "$OUT/ios-receipts-artifact-check.json" | tee -a "$OUT/ios-e2e-receipts.log"
log "proposals kept local: $(ls "$DIR"proposals | wc -l | tr -d ' ') files in the app container only"

python3 -I - "$WORK/attachments" "$OUT/screens" <<'PY'
import json, pathlib, subprocess, sys
src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
for manifest in src.glob("*/manifest.json"):
    for test in json.loads(manifest.read_text()):
        for a in test.get("attachments", []):
            f = manifest.parent / a["exportedFileName"]
            name = a.get("suggestedHumanReadableName", f.stem).split("_0_")[0]
            if f.suffix == ".png":
                subprocess.run(["sips", "-Z", "1000", str(f), "--out", str(dst / f"{name}.png")], check=True, capture_output=True)
PY
log "PASS"
