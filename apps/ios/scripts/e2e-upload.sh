#!/usr/bin/env bash
# iOS 시뮬레이터 E2E(로컬 Supabase 모드, 영수증 올리기). 사전 조건: mise run local:up
# 가상 영수증 2장 공유 → 1장만 확인 → 초대로 여행방 참여 → 올릴 곳·장수 최종 확인 창(아직 서버에 아무것도 없음)
# → 오프라인 실패 → 구성원이 아닌 여행방(실패, 아무것도 안 생김) → 세션 만료 → 다시 로그인 → 사본만 올라가고 끊김
# → 다시 시도로 지출 1건 → 반복은 같은 지출 → 앱을 다시 열어 올려도 같은 지출 → 서버 사본·필드·비구성원 접근 검사.
# 사용: apps/ios/scripts/e2e-upload.sh <simulator-udid> [증거 폴더]
set -euo pipefail
UDID="$1"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${2:-$(mktemp -d)}"
WORK="$(mktemp -d)"  # 실행마다 새 작업 폴더
mkdir -p "$OUT/screens"
APP_ID=app.nonanona
GROUP=group.app.nonanona
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$OUT/ios-e2e-upload.log"; }
: > "$OUT/ios-e2e-upload.log"
backend() { python3 -I "$ROOT/scripts/local-backend.py" "$@" | tee -a "$OUT/ios-e2e-upload.log"; }
report() {
  log "server: $(python3 -I "$ROOT/scripts/local-backend.py" upload-report | python3 -I -c 'import json,sys; r=json.load(sys.stdin); print(json.dumps({k: r[k] for k in ("objects","expenses","objects_without_expense","expenses_without_object")}))')"
}
expect_report() { report; tail -1 "$OUT/ios-e2e-upload.log" | grep -q "$1" || { log "expected $1"; exit 1; }; }
[[ -f "$HERE/Config/Local.xcconfig" ]] || { log "Config/Local.xcconfig 없음: mise run local:up"; exit 1; }
cd "$HERE"

backend reset
log "build-for-testing (Debug, local backend mode)"
xcodebuild build-for-testing -project Nonanona.xcodeproj -scheme Nonanona \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$WORK/dd" > "$WORK/build.log" 2>&1
xcrun simctl uninstall "$UDID" "$APP_ID" || true
xcrun simctl install "$UDID" "$WORK/dd/Build/Products/Debug-iphonesimulator/Nonanona.app"
xcrun simctl addmedia "$UDID" "$HERE/../fixtures/receipts/receipt-r01.png" "$HERE/../fixtures/receipts/receipt-r02.png"
for _ in $(seq 1 30); do
  xcrun simctl spawn "$UDID" pluginkit -mA -p com.apple.share-services 2>/dev/null | grep -q "$APP_ID.share" && break
  sleep 1
done

# 결과 번들과 첨부는 단계마다 새로 만든 빈 폴더에 둔다. 아무것도 지우거나 덮어쓰지 않는다.
mkdir "$WORK/attachments"
run_test() {
  local name="${1:?}" dir
  dir="$(mktemp -d "$WORK/attachments/$name.XXXXXX")"
  log "test $name"
  TEST_RUNNER_EXPECT_LOCAL_BACKEND=1 xcodebuild test-without-building -project Nonanona.xcodeproj -scheme Nonanona \
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$WORK/dd" \
    -resultBundlePath "$dir/result.xcresult" -only-testing:"NonanonaUITests/ReceiptUploadUITests/$name" \
    > "$dir/test.log" 2>&1 || { grep -E "error:|Test Case" "$dir/test.log" | tail -20; exit 1; }
  grep -E "Test Case .*(passed|failed)" "$dir/test.log" | tee -a "$OUT/ios-e2e-upload.log"
  mkdir "$dir/export"
  xcrun xcresulttool export attachments --path "$dir/result.xcresult" --output-path "$dir/export" > /dev/null
}
app_pid() {
  local list
  list="$(xcrun simctl spawn "$UDID" launchctl list)"
  awk '/UIKitApplication:app\.nonanona\[/ && $1 ~ /^[0-9]+$/ {print $1}' <<< "$list" | sed -n 1p
}
launch() {
  SIMCTL_CHILD_NONANONA_UPLOAD_FAIL_AFTER_STORAGE_ONCE="${1:-0}" xcrun simctl launch --terminate-running-process "$UDID" "$APP_ID" > /dev/null
  sleep 2
}

run_test testU1_ShareTwoReceipts
log "launch app (debug hook: first successful storage upload is interrupted before the expense row)"
launch 1
run_test testU2_ConfirmOneJoinTripAndStopAtFinalConfirmation
expect_report '"objects": 0, "expenses": 0'
log "before final confirmation: nothing on the server"

backend api-stop
run_test testU3_FinalConfirmWhileOfflineFails
backend api-start
expect_report '"objects": 0, "expenses": 0'

backend membership-remove
run_test testU4_InvalidDestinationFailsClosed
expect_report '"objects": 0, "expenses": 0'
backend membership-restore

backend revoke-sessions
log "wait 35s for the stored access token to expire"
sleep 35
run_test testU5_SessionLossReloginThenPartialFailure
expect_report '"objects": 1, "expenses": 0, "objects_without_expense": 1'
log "partial failure: object stored, no expense row (not visible as an expense)"

run_test testU6_RetryCreatesOneExpenseThenRepeatReplays
expect_report '"objects": 1, "expenses": 1, "objects_without_expense": 0'

pid="$(app_pid)"
kill -9 "$pid"
log "SIGKILL app pid $pid, reopen"
launch 0
run_test testU7_ReopenAndUploadAgainReplays
expect_report '"objects": 1, "expenses": 1, "objects_without_expense": 0'

log "what the server actually received"
python3 -I "$ROOT/scripts/local-backend.py" upload-report | tee "$OUT/ios-upload-server-report.json" | tee -a "$OUT/ios-e2e-upload.log"
backend fetch-artifact "$WORK/received.png"
DIR="$(ls -d "$(xcrun simctl get_app_container "$UDID" "$APP_ID" "$GROUP")"/receipt-import/drafts/*/ | head -1)"
python3 -I - "$DIR" "$WORK/received.png" "$WORK/device-original" "$OUT/ios-upload-fields.json" <<'PY' | tee -a "$OUT/ios-e2e-upload.log"
import hashlib, json, pathlib, shutil, sys
d, received, original_out, fields_out = map(pathlib.Path, sys.argv[1:5])
m = json.load(open(d / "processing.json"))
confirmed = [i for i in m["items"] if i["state"] == "confirmed"]
assert len(confirmed) == 1, "exactly one confirmed photo"
item = confirmed[0]
local = (d / "confirmed" / item["confirmed"]["artifactFileName"]).read_bytes()
data = received.read_bytes()
shutil.copy(d / item["photoFileName"], original_out)
print(json.dumps({"received_equals_confirmed_artifact": hashlib.sha256(data).hexdigest() == item["confirmed"]["artifactSHA256"] == hashlib.sha256(local).hexdigest(),
                  "received_equals_any_original": any((d / i["photoFileName"]).read_bytes() == data for i in m["items"])}))
fields_out.write_text(json.dumps(item["confirmed"]["fields"], ensure_ascii=False) + "\n")
PY
python3 -I "$HERE/../fixtures/check_artifact.py" "$WORK/device-original" "$WORK/received.png" | tee "$OUT/ios-upload-artifact-check.json" | tee -a "$OUT/ios-e2e-upload.log"
backend outsider-check | tee "$OUT/ios-upload-outsider.json"

python3 -I - "$WORK/attachments" "$OUT/screens" <<'PY'
import json, pathlib, subprocess, sys
src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
for manifest in src.glob("*/export/manifest.json"):
    for test in json.loads(manifest.read_text()):
        for a in test.get("attachments", []):
            f = manifest.parent / a["exportedFileName"]
            name = a.get("suggestedHumanReadableName", f.stem).split("_0_")[0]
            if f.suffix == ".png":
                subprocess.run(["sips", "-Z", "1000", str(f), "--out", str(dst / f"{name}.png")], check=True, capture_output=True)
PY
log "PASS"
