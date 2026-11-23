#!/usr/bin/env bash
# iOS 시뮬레이터 E2E(목록 먼저 영수증 검토, 로컬 Supabase 모드). 사전 조건: mise run local:up
# 가상 영수증 10장 공유 → 목록에서 읽는 중·대기·확인 필요·읽지 못함 → 읽지 못한 사진만 다시 읽기(입력 유지) → 직접 입력
# → 값 고쳐 확인하고 다음 → 제안이 놓친 가림을 OCR 줄·가림 영역으로 고치고 미리보기 → 입력 중 SIGKILL → 다시 열어 이어서
# → 회전(넓은 창)·가장 큰 글자 → 올릴 곳 없음 → 참여 → 최종 확인 전 0건 → 취소 0건 → 구성원 아님 0건 → 올리기 → 반복은 같은 지출
# → 서버가 받은 사본·필드와 기기 디스크를 검사한다.
# 사용: apps/ios/scripts/e2e-review.sh <simulator-udid> [증거 폴더]
#   가로가 regular 폭인 기기(iPhone 18 Pro Max 등)는 EXPECT_WIDE_LANDSCAPE=1로 넓은 창(목록 옆 검토 화면)도 확인한다.
set -euo pipefail
UDID="$1"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
FIXTURES="$HERE/../fixtures/receipts"
OUT="${2:-$(mktemp -d)}"
WORK="$(mktemp -d)"  # 실행마다 새 작업 폴더
mkdir -p "$OUT/screens"
APP_ID=app.nonanona
GROUP=group.app.nonanona
LOG="$OUT/ios-e2e-review.log"
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
: > "$LOG"
backend() { python3 -I "$ROOT/scripts/local-backend.py" "$@" | tee -a "$LOG"; }
expect_report() {
  local line
  line="$(python3 -I "$ROOT/scripts/local-backend.py" upload-report | python3 -I -c 'import json,sys; r=json.load(sys.stdin); print(json.dumps({k: r[k] for k in ("objects","expenses","objects_without_expense","expenses_without_object")}))')"
  log "server: $line"
  grep -q "$1" <<< "$line" || { log "expected $1"; exit 1; }
}
[[ -f "$HERE/Config/Local.xcconfig" ]] || { log "Config/Local.xcconfig 없음: mise run local:up"; exit 1; }
cd "$HERE"

backend reset
log "build-for-testing (Debug, local backend mode)"
xcodebuild build-for-testing -project Nonanona.xcodeproj -scheme Nonanona \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$WORK/dd" > "$WORK/build.log" 2>&1
xcrun simctl uninstall "$UDID" "$APP_ID" || true
xcrun simctl install "$UDID" "$WORK/dd/Build/Products/Debug-iphonesimulator/Nonanona.app"
xcrun simctl ui "$UDID" content_size large
xcrun simctl addmedia "$UDID" "$FIXTURES"/receipt-r*.png
for _ in $(seq 1 30); do
  xcrun simctl spawn "$UDID" pluginkit -mA -p com.apple.share-services 2>/dev/null | grep -q "$APP_ID.share" && break
  sleep 1
done

mkdir "$WORK/attachments"
run_test() {
  local name="${1:?}" dir
  shift
  dir="$(mktemp -d "$WORK/attachments/$name.XXXXXX")"
  log "test $name $*"
  env "$@" TEST_RUNNER_EXPECT_LOCAL_BACKEND=1 TEST_RUNNER_EXPECT_WIDE_LANDSCAPE="${EXPECT_WIDE_LANDSCAPE:-0}" \
    xcodebuild test-without-building -project Nonanona.xcodeproj -scheme Nonanona \
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$WORK/dd" \
    -resultBundlePath "$dir/result.xcresult" -only-testing:"NonanonaUITests/ReceiptReviewUITests/$name" \
    > "$dir/test.log" 2>&1 || { grep -E "error:|Test Case|XCTAssert|failed" "$dir/test.log" | tail -20 | tee -a "$LOG"; return 1; }
  grep -E "Test Case .*(passed|failed)" "$dir/test.log" | tee -a "$LOG"
  mkdir "$dir/export"
  xcrun xcresulttool export attachments --path "$dir/result.xcresult" --output-path "$dir/export" > /dev/null
}
app_pid() {
  local list
  list="$(xcrun simctl spawn "$UDID" launchctl list)"
  awk '/UIKitApplication:app\.nonanona\[/ && $1 ~ /^[0-9]+$/ {print $1}' <<< "$list" | sed -n 1p
}
draft_dir() { ls -d "$(xcrun simctl get_app_container "$UDID" "$APP_ID" "$GROUP")"/receipt-import/drafts/*/ | head -1; }
# 기기 디스크 검사(호스트 Python). 사진 번호 ↔ 가상 영수증은 원본 바이트로 찾는다. OCR 전문은 출력하지 않는다.
inspect() {
  local out
  out="$(python3 -I "$ROOT/apps/fixtures/review_e2e_check.py" "$@" --draft "$(draft_dir)" --fixtures "$FIXTURES")" || { echo "$out" | tee -a "$LOG"; log "check failed: $1"; exit 1; }
  echo "$out" | tee -a "$LOG"
}

# 사진 앱 격자를 누르는 단계는 가끔 사진이 아직 눌리지 않는 자리에 있어 실패한다. 사진 앱을 새로 띄워 한 번 더 한다.
run_test testV1_ShareTenPhotos || { log "share step failed once, retrying"; run_test testV1_ShareTenPhotos; }
eval "$(inspect order)"  # FAILED_POSITION, MISSED_POSITION(r01), ORDER
log "photo order: $ORDER; unreadable r10 at $FAILED_POSITION; suggestions dropped for r01 at $MISSED_POSITION"
log "launch app: processing delay 2500ms, mask suggestions dropped at position $MISSED_POSITION (debug hooks)"
SIMCTL_CHILD_NONANONA_PROCESSING_DELAY_MS=2500 SIMCTL_CHILD_NONANONA_DROP_SUGGESTIONS_POSITION="$MISSED_POSITION" \
  xcrun simctl launch --terminate-running-process "$UDID" "$APP_ID" > /dev/null
sleep 2

run_test testV2_QueueShowsActionableStates
run_test testV3_FailedPhotoRetryThenManualEntry
inspect manual
eval "$(inspect plan --missed "$MISSED_POSITION")"  # EDIT_POSITION, MASK_LINE_IDS, BAND_TOP, BAND_HEIGHT
log "edit position $EDIT_POSITION; missed mask fix: OCR lines [$MASK_LINE_IDS] + band ${BAND_TOP}% +${BAND_HEIGHT}%"
run_test testV4_EditValuesThenConfirmAndNext TEST_RUNNER_EDIT_POSITION="$EDIT_POSITION"
inspect edited --position "$EDIT_POSITION"
run_test testV5_CorrectMissedMaskWithPreview TEST_RUNNER_MISSED_POSITION="$MISSED_POSITION" \
  TEST_RUNNER_MASK_LINE_IDS="$MASK_LINE_IDS" TEST_RUNNER_BAND_TOP="$BAND_TOP" TEST_RUNNER_BAND_HEIGHT="$BAND_HEIGHT"
inspect masked --position "$MISSED_POSITION" --out "$OUT/ios-review-missed-mask-check.json"
run_test testV6_TypeWithoutConfirming
eval "$(inspect typed)"  # TYPED_POSITION
pid="$(app_pid)"
kill -9 "$pid"
log "SIGKILL app pid $pid while photo $TYPED_POSITION has unconfirmed input; reopen"
inspect states --label after-kill --out "$OUT/ios-review-state-after-kill.json"
xcrun simctl launch "$UDID" "$APP_ID" > /dev/null
sleep 2
run_test testV7_RecoverAfterRestartAndRotate TEST_RUNNER_TYPED_POSITION="$TYPED_POSITION"
xcrun simctl ui "$UDID" content_size accessibility-extra-extra-extra-large
log "content size: accessibility-extra-extra-extra-large"
run_test testV8_LargestTextStillReachable
xcrun simctl ui "$UDID" content_size large

run_test testV9_NoDestinationThenJoinAndStopAtFinalConfirmation
expect_report '"objects": 0, "expenses": 0'
log "final confirmation open: nothing on the server"
run_test testV10_CancelFinalConfirmationSendsNothing
expect_report '"objects": 0, "expenses": 0'
backend membership-remove
run_test testV11_UnauthorizedDestinationFailsClosed
expect_report '"objects": 0, "expenses": 0'
backend membership-restore
run_test testV12_UploadThenRepeatConverges
expect_report '"objects": 2, "expenses": 2, "objects_without_expense": 0, "expenses_without_object": 0'

log "what the server actually received"
python3 -I "$ROOT/scripts/local-backend.py" upload-report > "$OUT/ios-review-server-report.json"
backend fetch-artifacts "$WORK/received"
inspect received --received "$WORK/received" --report "$OUT/ios-review-server-report.json" \
  --checker "$ROOT/apps/fixtures/check_artifact.py" --out "$OUT/ios-review-received-check.json"
inspect states --label final --out "$OUT/ios-review-state-final.json"
backend outsider-check > "$OUT/ios-review-outsider.json"

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
