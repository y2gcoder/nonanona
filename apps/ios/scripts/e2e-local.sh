#!/usr/bin/env bash
# iOS 시뮬레이터 E2E(로컬 Supabase 모드): 사진 앱 공유 → 초대 링크 → 로컬 가상 계정 로그인 → 실제 accept_invite
#   → 같은 초대 반복 수락 → 만료·취소된 초대 → API 게이트웨이 정지 중 참여(연결 실패) → 재시작 후 다시 시도
#   → 서버 세션 삭제 + 토큰 만료 대기 → 세션 만료 → 초안·초대 유지 확인 → 다시 로그인 → 참여.
# 사전 조건: 저장소 루트에서 `mise run local:up`(또는 local:reset)으로 Config/Local.xcconfig가 있어야 한다.
# 사용: apps/ios/scripts/e2e-local.sh <simulator-udid> [증거 폴더]
set -euo pipefail
UDID="$1"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${2:-$(mktemp -d)}"
WORK="${WORK:-$(mktemp -d)}"
mkdir -p "$WORK" "$OUT/screens"
FIXTURE="$HERE/../fixtures/synthetic-receipt-r01.png"
APP_ID=app.nonanona
GROUP=group.app.nonanona
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$OUT/ios-e2e-local.log"; }
: > "$OUT/ios-e2e-local.log"
backend() { python3 -I "$ROOT/scripts/local-backend.py" "$@" | tee -a "$OUT/ios-e2e-local.log"; }
[[ -f "$HERE/Config/Local.xcconfig" ]] || { log "Config/Local.xcconfig 없음: mise run local:up"; exit 1; }
cd "$HERE"

log "reset local backend (fresh synthetic accounts and invites)"
backend reset
log "build-for-testing (Debug, local backend mode)"
xcodebuild build-for-testing -project Nonanona.xcodeproj -scheme Nonanona \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$WORK/dd" > "$WORK/build.log" 2>&1
APP="$WORK/dd/Build/Products/Debug-iphonesimulator/Nonanona.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :NonanonaBackend' "$APP/Info.plist")" == local ]] || { log "app is not in local mode"; exit 1; }
xcrun simctl uninstall "$UDID" "$APP_ID" || true
xcrun simctl install "$UDID" "$APP"
xcrun simctl addmedia "$UDID" "$FIXTURE"
# 설치 직후에는 공유 확장이 공유 메뉴에 바로 등록되지 않을 수 있어 등록될 때까지 기다린다.
for _ in $(seq 1 30); do
  xcrun simctl spawn "$UDID" pluginkit -mA -p com.apple.share-services 2>/dev/null | grep -q "$APP_ID.share" && break
  sleep 1
done

run_test() {
  log "test $1"
  rm -rf "$WORK/$1.xcresult" "$WORK/attachments/$1" && mkdir -p "$WORK/attachments/$1"
  TEST_RUNNER_EXPECT_LOCAL_BACKEND=1 xcodebuild test-without-building -project Nonanona.xcodeproj -scheme Nonanona \
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$WORK/dd" \
    -resultBundlePath "$WORK/$1.xcresult" -only-testing:"NonanonaUITests/LocalBackendUITests/$1" \
    > "$WORK/$1.log" 2>&1 || { grep -E "error:|Test Case" "$WORK/$1.log" | tail -20; exit 1; }
  grep -E "Test Case .*(passed|failed)" "$WORK/$1.log" | tee -a "$OUT/ios-e2e-local.log"
  xcrun xcresulttool export attachments --path "$WORK/$1.xcresult" --output-path "$WORK/attachments/$1" > /dev/null
}

app_state() {  # 앱 컨테이너의 초안·보관한 초대·세션 파일 유무(내용은 읽지 않는다)
  local data group
  data="$(xcrun simctl get_app_container "$UDID" "$APP_ID" data)"
  group="$(xcrun simctl get_app_container "$UDID" "$APP_ID" "$GROUP")"
  {
    echo "# $1"
    echo "drafts=$(find "$group/receipt-import/drafts" -name draft.json 2>/dev/null | wc -l | tr -d ' ')"
    echo "pending_invite=$([[ -f "$data/Library/Application Support/account/pending-invite.json" ]] && echo yes || echo no)"
    echo "local_session=$([[ -f "$data/Library/Application Support/local-auth/session.json" ]] && echo yes || echo no)"
    echo "test_session=$([[ -f "$data/Library/Application Support/test-auth/session.json" ]] && echo yes || echo no)"
  } | tee "$OUT/ios-local-state-$1.txt" | tee -a "$OUT/ios-e2e-local.log"
}

run_test testL1_AcceptRepeatExpiredAndInvalidInvites
backend report
backend api-stop
run_test testL2_JoinWhileServerUnreachableShowsRetry
app_state while-server-unreachable
grep -q "pending_invite=yes" "$OUT/ios-local-state-while-server-unreachable.txt"
backend api-start
run_test testL3_RetryAfterServerIsBackJoins
backend revoke-sessions
log "wait 35s so the stored access token reaches its 30s expiry and the app must refresh"
sleep 35
run_test testL4_ExpiredServerSessionReauthKeepsDraftAndInvite
app_state after-reauth
grep -q "drafts=1" "$OUT/ios-local-state-after-reauth.txt"
grep -q "pending_invite=no" "$OUT/ios-local-state-after-reauth.txt"
grep -q "local_session=yes" "$OUT/ios-local-state-after-reauth.txt"
grep -q "test_session=no" "$OUT/ios-local-state-after-reauth.txt"
backend report | tee "$OUT/ios-local-server-report.json"
grep -q '"member_trips": 3' "$OUT/ios-local-server-report.json"
grep -q '"used_invites": 3' "$OUT/ios-local-server-report.json"

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
