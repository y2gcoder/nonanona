#!/usr/bin/env bash
# iOS iPhone Duo 시뮬레이터 E2E(자세 변경, 테스트 구현체): 바깥 화면(접음)에서 초안 둘 공유 → 처리를 늦춘 채 앱 실행
#   → 읽는 중 book → flat → folded(같은 초안·처리 상태, 안쪽 화면은 목록·초안 나란히, book에서 요약·상태가 division 밖)
#   → 사진별 시도 횟수 1 → 최종 확인 창을 연 채 book → flat → folded(같은 문장, book에서 division 밖) → 한 번만 올림.
# 자세 이름은 Device Hub가 그리는 기기 모양이다(버튼에 접근성 이름이 없음): folded(바깥 화면), book(두 번째 버튼,
#   안쪽 화면이 접힘에서 꺾임), flat(세 번째 버튼, 평평함). 앱 DEBUG 로그로 division 예약 영역을 함께 남긴다.
# 자세는 simctl·XCTest로 바꿀 수 없어 Device Hub 아래쪽 자세 버튼을 Orca Computer Use(`orca computer`)로 누른다.
# 사전 조건: Device Hub 창(1100×800pt)에 이 시뮬레이터가 열려 있고 접은 자세, `orca computer permissions`에서
#   손쉬운 사용·화면 기록 허용. 누를 때 Device Hub를 앞으로 가져온다(--restore-window).
# 사용: apps/ios/scripts/e2e-posture.sh <iPhone Duo simulator-udid> [증거 폴더]
set -euo pipefail
UDID="$1"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="$HERE/../fixtures/receipts"
OUT="${2:-$(mktemp -d)}"
WORK="$(mktemp -d)"
SIGNAL="$WORK/posture"
mkdir -p "$OUT/screens" "$OUT/device-hub" "$SIGNAL"
APP_ID=app.nonanona
GROUP=group.app.nonanona
HUB=com.apple.dt.Devices
DEVICE="$(xcrun simctl list devices -j | python3 -I -c 'import json,sys; d=json.load(sys.stdin)["devices"]; print(next(x["name"] for v in d.values() for x in v if x["udid"]==sys.argv[1]))' "$UDID")"
LOG="$OUT/ios-e2e-posture.log"
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
: > "$LOG"
cd "$HERE"
log "device: $DEVICE ($UDID)"

# Device Hub 창이 이 시뮬레이터를 보여 주는지, 버튼 좌표를 정한 창 크기인지 확인한다.
hub_window() {
  orca computer get-app-state --app "$HUB" --no-screenshot --max-elements 1 --restore-window --json |
    python3 -I -c 'import json,sys; w=json.load(sys.stdin)["result"]["snapshot"]["window"]; print(w["title"], w["width"], w["height"])'
}
read -r HUB_TITLE <<< "$(hub_window)"
case "$HUB_TITLE" in
  "$DEVICE – "*" 1100 800") ;;
  *) log "Device Hub must show '$DEVICE' in a 1100x800 window (got: $HUB_TITLE)"; exit 1 ;;
esac

# 아래쪽 자세 버튼(창 좌표, 1100×800 창): folded · book · flat. 접근성 이름이 없어 좌표로 누른다.
posture_x() { case "$1" in folded) echo 712 ;; book) echo 746 ;; flat) echo 780 ;; esac; }

displays() {  # 시뮬레이터 화면 ID(바깥·안쪽). 화면이 둘이면 simctl이 고르지 못하고 ID를 알려 준다.
  rm -f "$WORK/probe.png"
  xcrun simctl io "$UDID" screenshot "$WORK/probe.png" 2>&1 | sed -nE 's/.*--display=([0-9]+).*/\1/p' || true
}

capture() {  # Device Hub 창과 시뮬레이터 각 화면
  local name="$1" shot
  shot="$(orca computer get-app-state --app "$HUB" --json | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["result"].get("screenshot",{}).get("path",""))' || true)"
  [ -n "$shot" ] && sips -Z 1000 "$shot" --out "$OUT/device-hub/$name.png" > /dev/null
  local ids
  ids="$(displays)"
  [ -z "$ids" ] && [ -s "$WORK/probe.png" ] && sips -Z 1000 "$WORK/probe.png" --out "$OUT/device-hub/$name-display.png" > /dev/null
  for d in $ids; do
    xcrun simctl io "$UDID" screenshot --display="$d" "$WORK/$name-display$d.png" > /dev/null 2>&1 &&
      sips -Z 1000 "$WORK/$name-display$d.png" --out "$OUT/device-hub/$name-display$d.png" > /dev/null || true
  done
}

# 다른 앱이 앞으로 오면 클릭이 window_not_focused로 거절된다. 몇 번 다시 누른다.
click_posture() {
  local name="$1" step="$2"
  for attempt in 1 2 3 4 5; do
    log "posture $name: click Device Hub ($(posture_x "$step"), 774), attempt $attempt"
    orca computer click --app "$HUB" --x "$(posture_x "$step")" --y 774 --restore-window --no-screenshot --json \
      > "$WORK/click-$name.json" 2>&1 || true
    python3 -I -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("ok") else 1)' "$WORK/click-$name.json" &&
      return 0
    sleep 2
  done
  return 1
}

# 테스트가 want-<단계>를 쓰면 자세를 바꾸고 done-<단계>를 쓴다.
watch_postures() {
  while :; do
    for want in "$SIGNAL"/want-*; do
      [ -e "$want" ] || continue
      local name="${want##*/want-}"
      [ -e "$SIGNAL/done-$name" ] && continue
      local step="${name#*-}"
      if click_posture "$name" "$step"; then
        sleep 4
        capture "$name"
        : > "$SIGNAL/done-$name"
      else
        log "posture $name: Device Hub click failed: $(cat "$WORK/click-$name.json")"
        : > "$SIGNAL/failed-$name"
      fi
    done
    sleep 0.5
  done
}

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

watch_postures &
WATCHER=$!
# 앱이 남기는 division 예약 영역(DEBUG, Theme.swift)을 모은다.
xcrun simctl spawn "$UDID" log stream --level debug --style compact \
  --predicate 'subsystem == "app.nonanona" AND category == "layout"' > "$OUT/ios-layout-reserved.log" 2>&1 &
LOGGER=$!
trap 'kill $WATCHER $LOGGER 2> /dev/null || true' EXIT
capture start

mkdir "$WORK/attachments"
run_test() {
  local name="${1:?}" dir
  dir="$(mktemp -d "$WORK/attachments/$name.XXXXXX")"
  log "test $name"
  TEST_RUNNER_POSTURE_DIR="$SIGNAL" xcodebuild test-without-building -project Nonanona.xcodeproj \
    -scheme Nonanona -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$WORK/dd" \
    -resultBundlePath "$dir/result.xcresult" -only-testing:"NonanonaUITests/AdaptiveLayoutUITests/$name" \
    > "$dir/test.log" 2>&1 || { grep -E "error:|Test Case|POSTURE" "$dir/test.log" | tail -30 | tee -a "$LOG"; exit 1; }
  grep -E "POSTURE |Test Case .*(passed|failed)" "$dir/test.log" | tee -a "$LOG"
  mkdir "$dir/export"
  xcrun xcresulttool export attachments --path "$dir/result.xcresult" --output-path "$dir/export" > /dev/null
}

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
log "launch app with processing delay 90000ms per photo"
SIMCTL_CHILD_NONANONA_PROCESSING_DELAY_MS=90000 xcrun simctl launch --terminate-running-process "$UDID" "$APP_ID" > /dev/null
run_test testP2_PostureChangeWhileReadingKeepsDraftAndProgress
attempts after-posture-changes-while-reading
run_test testP3_UploadConfirmationSurvivesPostureChange
capture P3-uploaded
attempts final

python3 -I - "$WORK/attachments" "$OUT/screens" <<'PY'
import json, pathlib, subprocess, sys
src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
for manifest in src.glob("*/export/manifest.json"):
    for test in json.loads(manifest.read_text()):
        for a in test.get("attachments", []):
            f = manifest.parent / a["exportedFileName"]
            name = a.get("suggestedHumanReadableName", f.stem).split("_0_")[0]
            if f.suffix == ".png" and name.startswith("ios-"):
                subprocess.run(["sips", "-Z", "1000", str(f), "--out", str(dst / f"{name}.png")], check=True, capture_output=True)
PY
log "PASS"
