#!/usr/bin/env bash
# iOS 시뮬레이터 E2E(적응형 화면, 테스트 구현체): 초안 둘 공유 → 처리를 늦춘 채 앱 실행 → 읽는 중 가로·세로 회전
#   (같은 초안·처리 상태, 넓은 가로 창이면 목록과 초안이 나란히) → 사진별 시도 횟수 1(중복 OCR 없음)
#   → 올릴 곳·장수 최종 확인 창을 연 채 회전(같은 문장) → 한 번만 올림 → 큰 글자 + 가로에서 스크롤로 모든 버튼에 닿기.
# 사용: apps/ios/scripts/e2e-adaptive.sh <simulator-udid> [증거 폴더]
#   EXPECT_WIDE_LANDSCAPE=1: 가로로 돌리면 가로 크기 종류가 regular가 되는 기기(예: iPhone 18 Pro Max).
set -euo pipefail
UDID="$1"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="$HERE/../fixtures/receipts"
OUT="${2:-$(mktemp -d)}"
WORK="$(mktemp -d)"  # 실행마다 새 작업 폴더
mkdir -p "$OUT/screens"
APP_ID=app.nonanona
GROUP=group.app.nonanona
DEVICE="$(xcrun simctl list devices -j | python3 -I -c 'import json,sys; d=json.load(sys.stdin)["devices"]; print(next(x["name"] for v in d.values() for x in v if x["udid"]==sys.argv[1]))' "$UDID")"
TAG="$(tr ' ' '-' <<< "$DEVICE" | tr -cd 'A-Za-z0-9-' | tr 'A-Z' 'a-z')"
LOG="$OUT/ios-e2e-adaptive-$TAG.log"
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
: > "$LOG"
cd "$HERE"
log "device: $DEVICE ($UDID), expect wide landscape: ${EXPECT_WIDE_LANDSCAPE:-0}"

log "build-for-testing (Debug, test backend)"
xcodebuild build-for-testing -project Nonanona.xcodeproj -scheme Nonanona \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$WORK/dd" NONANONA_BACKEND=test > "$WORK/build.log" 2>&1
xcrun simctl uninstall "$UDID" "$APP_ID" || true
xcrun simctl install "$UDID" "$WORK/dd/Build/Products/Debug-iphonesimulator/Nonanona.app"
xcrun simctl addmedia "$UDID" "$FIXTURES"/receipt-r0{1,2,3}.png
for _ in $(seq 1 30); do
  xcrun simctl spawn "$UDID" pluginkit -mA -p com.apple.share-services 2>/dev/null | grep -q "$APP_ID.share" && break
  sleep 1
done
TEXT_SIZE="$(xcrun simctl ui "$UDID" content_size)"
restore() { xcrun simctl ui "$UDID" content_size "$TEXT_SIZE" > /dev/null 2>&1 || true; }
trap restore EXIT
xcrun simctl ui "$UDID" content_size large

mkdir "$WORK/attachments"
run_test() {
  local name="${1:?}" dir
  dir="$(mktemp -d "$WORK/attachments/$name.XXXXXX")"
  log "test $name"
  TEST_RUNNER_EXPECT_WIDE_LANDSCAPE="${EXPECT_WIDE_LANDSCAPE:-0}" xcodebuild test-without-building -project Nonanona.xcodeproj \
    -scheme Nonanona -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$WORK/dd" \
    -resultBundlePath "$dir/result.xcresult" -only-testing:"NonanonaUITests/AdaptiveLayoutUITests/$name" \
    > "$dir/test.log" 2>&1 || { grep -E "error:|Test Case" "$dir/test.log" | tail -20 | tee -a "$LOG"; exit 1; }
  grep -E "Test Case .*(passed|failed)" "$dir/test.log" | tee -a "$LOG"
  mkdir "$dir/export"
  xcrun xcresulttool export attachments --path "$dir/result.xcresult" --output-path "$dir/export" > /dev/null
}

# 사진별 시도 횟수: 회전·장면 다시 활성화로 같은 사진을 다시 읽었다면 1보다 크다.
attempts() {
  python3 -I - "$(xcrun simctl get_app_container "$UDID" "$APP_ID" "$GROUP")/receipt-import/drafts" "$1" <<'PY' | tee -a "$LOG"
import json, pathlib, sys
root, label = pathlib.Path(sys.argv[1]), sys.argv[2]
drafts = {}
for m in sorted(root.glob("*/processing.json")):
    items = sorted(json.load(open(m))["items"], key=lambda i: i["position"])
    drafts[len(items)] = {"attempts": [i["attempts"] for i in items], "states": [i["state"] for i in items]}
print(json.dumps({"label": label, "drafts_by_photo_count": drafts}, ensure_ascii=False))
assert sorted(drafts) == [1, 2], "two drafts (1 and 2 photos)"
assert all(a == 1 for d in drafts.values() for a in d["attempts"]), "every photo read exactly once"
PY
}

run_test testA1_ShareTwoDrafts
log "launch app with processing delay 8000ms per photo"
SIMCTL_CHILD_NONANONA_PROCESSING_DELAY_MS=8000 xcrun simctl launch --terminate-running-process "$UDID" "$APP_ID" > /dev/null
run_test testA2_RotateWhileReadingKeepsDraftAndProgress
attempts after-rotation-while-reading
run_test testA3_UploadConfirmationSurvivesRotation
xcrun simctl ui "$UDID" content_size accessibility-extra-large
log "text size accessibility-extra-large"
run_test testA4_LargeTextLandscapeScrollsToEveryControl
attempts final

python3 -I - "$WORK/attachments" "$OUT/screens" "$TAG" <<'PY'
import json, pathlib, subprocess, sys
src, dst, tag = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
for manifest in src.glob("*/export/manifest.json"):
    for test in json.loads(manifest.read_text()):
        for a in test.get("attachments", []):
            f = manifest.parent / a["exportedFileName"]
            name = a.get("suggestedHumanReadableName", f.stem).split("_0_")[0]
            if f.suffix == ".png" and name.startswith("ios-adaptive"):
                subprocess.run(["sips", "-Z", "1000", str(f), "--out", str(dst / f"{name}-{tag}.png")], check=True, capture_output=True)
PY
log "PASS"
