#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# 인자 없는 mise install은 사용자 전역 도구까지 설치한다.
project_tools=$(mise ls --project --no-header)
if [[ -z $project_tools ]]; then
  printf '설치할 프로젝트 도구를 찾지 못했습니다.\n' >&2
  exit 1
fi
tools=()
while read -r tool _; do
  tools+=("$tool")
done <<< "$project_tools"

# mise는 이미 설치된 같은 버전의 아카이브 체크섬을 다시 확인하지 않는다.
if mise where python >/dev/null 2>&1; then
  mise install --locked --force python
fi
mise install --locked "${tools[@]}"
lefthook=$(mise which lefthook)
"$lefthook" install
