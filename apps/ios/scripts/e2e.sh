#!/usr/bin/env bash
# iOS 시뮬레이터 E2E: 사진 앱 공유 → 로그인 전 초안 → 초대 링크 → 로그인 화면에서 강제 종료
#   → 홈 화면 아이콘으로 다시 열기 → 초안·초대 유지 확인 → 테스트 로그인 → 초대받은 여행방.
# 사용: apps/ios/scripts/e2e.sh <simulator-udid> [증거 폴더]
# 빌드 산출물과 결과 번들은 임시 폴더에만 둔다. 앱 데이터는 매번 새로 설치해 지운다.
set -euo pipefail
UDID="$1"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${2:-$(mktemp -d)}"
WORK="${WORK:-$(mktemp -d)}"
mkdir -p "$WORK"
FIXTURE="$HERE/../fixtures/synthetic-receipt-r01.png"
APP_ID=app.nonanona
GROUP=group.app.nonanona
mkdir -p "$OUT/screens"
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$OUT/ios-e2e.log"; }
: > "$OUT/ios-e2e.log"
cd "$HERE"

log "build-for-testing (Debug)"
# 로컬 Supabase 설정(Config/Local.xcconfig)이 있어도 이 E2E는 테스트 구현체로 빌드한다.
xcodebuild build-for-testing -project Nonanona.xcodeproj -scheme Nonanona \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$WORK/dd" NONANONA_BACKEND=test > "$WORK/build.log" 2>&1
log "fresh install, synthetic receipt into Photos"
xcrun simctl uninstall "$UDID" "$APP_ID" || true
xcrun simctl install "$UDID" "$WORK/dd/Build/Products/Debug-iphonesimulator/Nonanona.app"
xcrun simctl addmedia "$UDID" "$FIXTURE"
# 설치 직후에는 공유 확장이 공유 메뉴에 바로 등록되지 않을 수 있어 등록될 때까지 기다린다.
for _ in $(seq 1 30); do
  xcrun simctl spawn "$UDID" pluginkit -mA -p com.apple.share-services 2>/dev/null | grep -q "$APP_ID.share" && break
  sleep 1
done

run_test() {
  log "test $1"
  rm -rf "$WORK/$1.xcresult"
  xcodebuild test-without-building -project Nonanona.xcodeproj -scheme Nonanona \
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$WORK/dd" \
    -resultBundlePath "$WORK/$1.xcresult" -only-testing:"NonanonaUITests/FirstSliceUITests/$1" \
    > "$WORK/$1.log" 2>&1 || { tail -40 "$WORK/$1.log"; exit 1; }
  grep -E "Test Case .*(passed|failed)" "$WORK/$1.log" | tee -a "$OUT/ios-e2e.log"
  rm -rf "$WORK/attachments/$1" && mkdir -p "$WORK/attachments/$1"
  xcrun xcresulttool export attachments --path "$WORK/$1.xcresult" --output-path "$WORK/attachments/$1" > /dev/null
}

state() {  # $1 = label. 앱 컨테이너에서 초안·보관한 초대·세션 파일을 확인한다.
  local data group
  data="$(xcrun simctl get_app_container "$UDID" "$APP_ID" data)"
  group="$(xcrun simctl get_app_container "$UDID" "$APP_ID" "$GROUP")"
  {
    echo "# $1"
    echo "app_pid=$(app_pid || true)"
    echo "drafts=$(find "$group/receipt-import/drafts" -name draft.json 2>/dev/null | wc -l | tr -d ' ')"
    echo "draft_photos=$(find "$group/receipt-import/drafts" -name 'photo-*' 2>/dev/null | wc -l | tr -d ' ')"
    local invite="$data/Library/Application Support/account/pending-invite.json"
    if [[ -f $invite ]]; then echo "pending_invite=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["code"]["value"])' "$invite")"; else echo "pending_invite=none"; fi
    echo "test_session=$([[ -f "$data/Library/Application Support/test-auth/session.json" ]] && echo yes || echo no)"
  } | tee "$OUT/ios-state-$1.txt" | tee -a "$OUT/ios-e2e.log"
}

app_pid() {  # 앱이 떠 있으면 pid를, 아니면 빈 문자열을 낸다(파이프를 일찍 닫지 않는다).
  local list
  list="$(xcrun simctl spawn "$UDID" launchctl list)"
  awk '/UIKitApplication:app\.nonanona\[/ && $1 ~ /^[0-9]+$/ {print $1}' <<< "$list" | sed -n 1p
}

run_test test1_ShareFromPhotosSignedOutThenOpenInviteAndStartLogin
pid="$(app_pid)"
[[ -n $pid ]] || { log "app is not running at the login sheet"; exit 1; }
log "SIGKILL app pid $pid while the login sheet is open (sign-in not completed)"
kill -9 "$pid"
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -z "$(app_pid)" ]] && break; sleep 0.5; done
state after-kill-before-sign-in
grep -q "app_pid=$" "$OUT/ios-state-after-kill-before-sign-in.txt"
grep -q "drafts=1" "$OUT/ios-state-after-kill-before-sign-in.txt"
grep -q "pending_invite=SYNTHINVITE01" "$OUT/ios-state-after-kill-before-sign-in.txt"
grep -q "test_session=no" "$OUT/ios-state-after-kill-before-sign-in.txt"

run_test test2_RelaunchFromHomeScreenKeepsDraftAndInvite
log "capture core screen (home: draft + pending invite) in light, dark, accessibility-large"
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularMode notSupported
capture() { sleep 2; xcrun simctl io "$UDID" screenshot "$WORK/$1.png" > /dev/null 2>&1; sips -Z 1000 "$WORK/$1.png" --out "$OUT/screens/$1.png" > /dev/null; }
capture ios-home-light
xcrun simctl ui "$UDID" appearance dark; capture ios-home-dark
xcrun simctl ui "$UDID" appearance light
xcrun simctl ui "$UDID" content_size accessibility-large; capture ios-home-large-text
xcrun simctl ui "$UDID" content_size large
xcrun simctl status_bar "$UDID" clear
run_test test3_SignInReturnsToInvitedRoom
state after-sign-in-and-join
grep -q "drafts=1" "$OUT/ios-state-after-sign-in-and-join.txt"
grep -q "pending_invite=none" "$OUT/ios-state-after-sign-in-and-join.txt"
grep -q "test_session=yes" "$OUT/ios-state-after-sign-in-and-join.txt"

run_test test4_InviteFailuresRecoverWithoutLosingDraft
state after-invite-failures
grep -q "drafts=1" "$OUT/ios-state-after-invite-failures.txt"
grep -q "pending_invite=none" "$OUT/ios-state-after-invite-failures.txt"
grep -q "test_session=yes" "$OUT/ios-state-after-invite-failures.txt"

log "collect screenshots"
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
log "PASS (work dir: $WORK)"
