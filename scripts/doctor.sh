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
missing=$(mise ls --no-global --current --missing 2>/dev/null)
if [[ -z $missing ]]; then ok "mise.toml의 도구가 모두 설치됨"; else bad "설치 안 된 도구가 있습니다: 'mise install' ($(echo "$missing" | awk '{print $1}' | tr '\n' ' '))"; fi
for t in gitleaks lefthook; do
  want=$(mise which "$t" 2>/dev/null); got=$(command -v "$t" 2>/dev/null)
  if [[ -z $got ]]; then bad "$t: 실행할 수 없습니다 (mise install 후 셸에서 mise activate 필요)"
  elif [[ -n $want && $got != "$want" && $got != *"/mise/shims/$t" ]]; then bad "$t: mise가 고정한 버전이 아닌 $got 이 실행됩니다"
  else ok "$t $("$t" version 2>/dev/null | head -1)"; fi
done

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

# echo "저장소별 점검"
# 예: if docker info >/dev/null 2>&1; then ok "Docker 실행 중"; else bad "Docker를 실행하세요"; fi

echo
if (( failures )); then printf '\033[31m%d개 항목이 실패했습니다.\033[0m\n' "$failures"; exit 1; fi
printf '\033[32m모두 통과했습니다.\033[0m\n'
