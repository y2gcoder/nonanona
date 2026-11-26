# 비밀값 템플릿: 값이 아니라 1Password 참조(op://)만 담아 커밋한다.
# 원본은 개인 1Password 계정의 `nonanona` vault다.
# 실행: op run --env-file=.env.tpl -- <명령>
#
# 웹·앱 번들에 들어가는 공개 값(NEXT_PUBLIC_*, 공개 프로젝트 토큰, API 기본 URL)은 여기가 아니라 각 앱 설정에 둔다.
# 아직 1Password 항목이 없는 키는 주석으로 둔다(없는 항목을 참조하면 op run이 실패한다).

# EXAMPLE_API_KEY=op://nonanona/<항목 이름>/credential

# 한국은행 ECOS Open API 인증키(scripts/ecos-fx.py, mise run fx:ingest). 키는 요청 URL 경로에 들어가므로 출력·기록하지 않는다.
# 1Password nonanona vault에 항목을 만든 뒤 주석을 푼다. 공개 시험 키 `sample`(한 번에 10건)은 비밀값이 아니다.
# ECOS_API_KEY=op://nonanona/ECOS Open API/credential
