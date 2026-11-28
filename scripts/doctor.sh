#!/usr/bin/env bash
# 개발 환경 점검: mise run doctor
# 비밀값은 출력하지 않는다. 실패 항목이 하나라도 있으면 종료 코드 1.
# 저장소에 맞는 점검(Docker, 언어 런타임 버전 등)은 아래 "저장소별 점검"에 추가한다.
set -u
cd "$(dirname "$0")/.."
vault=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")   # 1Password vault 이름 = 저장소 이름

failures=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; failures=$((failures + 1)); }

echo "도구"
if ! missing=$(mise ls --project --missing --no-header); then
  bad "프로젝트 도구 목록을 확인할 수 없습니다"
elif [[ -n $missing ]]; then
  bad "설치 안 된 도구가 있습니다: 'mise run setup' ($(awk '{print $1}' <<< "$missing" | paste -sd ' ' -))"
else
  ok "mise.toml의 도구가 모두 설치됨"
fi
for t in gitleaks lefthook; do
  want=$(mise which "$t" 2>/dev/null); got=$(command -v "$t" 2>/dev/null)
  if [[ -z $got ]]; then bad "$t: 실행할 수 없습니다 ('mise run setup' 후 셸에서 mise activate 필요)"
  elif [[ -n $want && $got != "$want" && $got != *"/mise/shims/$t" ]]; then bad "$t: mise가 고정한 버전이 아닌 $got 이 실행됩니다"
  else ok "$t $("$t" version 2>/dev/null | head -1)"; fi
done

if python=$(mise which --tool python python3 2>/dev/null); then
  # Python 패치 버전이 같아도 python-build-standalone 빌드 날짜가 달라질 수 있다.
  if builds=$("$python" -I - <<'PY'
from datetime import datetime, timedelta
import platform
import re
import tomllib

with open("mise.lock", "rb") as lockfile:
    [python] = tomllib.load(lockfile)["tools"]["python"]
[tag] = {
    re.search(r"/releases/download/(\d{8})/", entry["url"])[1]
    for key, entry in python.items() if key.startswith("platforms.")
}
expected = datetime.strptime(tag, "%Y%m%d").date()
installed = datetime.strptime(platform.python_build()[1], "%b %d %Y %H:%M:%S").date()
# 상류 빌드가 자정을 넘기면 바이너리에는 태그 다음 날 날짜가 기록된다.
matches = expected <= installed <= expected + timedelta(days=1)
print(tag, installed.strftime("%Y%m%d"), int(matches))
PY
  ); then
    read -r expected installed matches <<< "$builds"
    if [[ $matches == 1 ]]; then ok "Python 빌드 $expected (컴파일 날짜 $installed)"
    else warn "Python 컴파일 날짜 $installed (mise.lock 빌드: $expected). 'mise run setup'으로 다시 설치하세요"; fi
  else
    warn "Python 빌드 날짜를 확인할 수 없습니다. 'mise run setup'으로 다시 설치하세요"
  fi
fi

echo "비밀값 보호"
hooks_dir=$(git rev-parse --git-common-dir 2>/dev/null)/hooks
if [[ -f $hooks_dir/pre-commit ]]; then ok "git pre-commit 훅 설치됨"; else warn "pre-commit 훅이 없습니다: mise run hooks:install"; fi
[[ -f .gitleaks.toml ]] && ok ".gitleaks.toml 있음" || bad ".gitleaks.toml이 없습니다"
git check-ignore -q mise.local.toml && ok "mise.local.toml은 gitignore 대상" || bad "mise.local.toml이 gitignore에 없습니다"

echo "1Password (선택; 비밀값이 필요한 작업에서만 사용)"
if [[ -n ${OP_SERVICE_ACCOUNT_TOKEN:-} ]]; then
  warn "OP_SERVICE_ACCOUNT_TOKEN이 설정돼 있습니다. op가 개인 로그인이 아니라 그 서비스 계정(회사 토큰일 수 있음)으로 동작합니다. mise.local.toml에서 해제하세요"
else
  ok "OP_SERVICE_ACCOUNT_TOKEN 없음"
fi
if ! command -v op >/dev/null 2>&1; then
  warn "op(1Password CLI)가 없습니다"
elif [[ -z ${OP_ACCOUNT:-} ]]; then
  warn "OP_ACCOUNT가 비어 있습니다. mise.local.toml.example을 mise.local.toml로 복사해 개인 계정을 지정하세요"
else
  ok "OP_ACCOUNT 지정됨 (값은 출력하지 않음)"
  if who=$(op whoami --format json 2>&1); then
    url=$(printf '%s' "$who" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("url",""))' 2>/dev/null)
    uuid=$(printf '%s' "$who" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("account_uuid",""))' 2>/dev/null)
    if [[ $OP_ACCOUNT == "$url" || $OP_ACCOUNT == "$uuid" ]]; then ok "op whoami: 로그인 계정이 OP_ACCOUNT와 같습니다"
    else warn "op whoami의 계정이 OP_ACCOUNT와 다릅니다. 다른 계정으로 로그인돼 있을 수 있습니다"; fi
    if op vault get "$vault" >/dev/null 2>&1; then ok "vault '$vault' 접근 가능"
    else warn "vault '$vault'에 접근할 수 없습니다(아직 없거나, 개인 계정이 아니거나, 앱 연동이 꺼져 있음)"; fi
  else
    warn "op whoami 실패: 1Password 데스크톱 앱을 잠금 해제하고 CLI 연동을 켜세요"
  fi
fi

echo "모바일 앱 (apps/)"
want_xcode="Xcode 27.2"   # iOS 빌드·swift-format을 이 버전으로 맞췄다. 바꾸면 apps/README.md도 고친다.
got_xcode=$(xcodebuild -version 2>/dev/null | head -1)
if [[ $got_xcode == "$want_xcode" ]]; then ok "$got_xcode"
elif [[ -n $got_xcode ]]; then warn "$got_xcode (기준: $want_xcode)"
else warn "Xcode가 없습니다(iOS 작업에만 필요)"; fi
sdk=${ANDROID_HOME:-}
[[ -z $sdk && -f apps/android/local.properties ]] && sdk=$(sed -n 's/^sdk.dir=//p' apps/android/local.properties)
if [[ -z $sdk ]]; then warn "Android SDK 위치가 없습니다: ANDROID_HOME 또는 apps/android/local.properties(sdk.dir)"
elif [[ -d $sdk/platforms/android-37.1 ]]; then ok "Android SDK Platform 37.1 설치됨"
else warn "Android SDK Platform 37.1이 없습니다: sdkmanager \"platforms;android-37.1\""; fi

echo
if (( failures )); then printf '\033[31m%d개 항목이 실패했습니다.\033[0m\n' "$failures"; exit 1; fi
printf '\033[32m모두 통과했습니다.\033[0m\n'
