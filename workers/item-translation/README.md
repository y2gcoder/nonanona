# 영수증 품목 한 줄 재번역

GitHub 이슈 [#7](https://github.com/y2gcoder/nonanona/issues/7)의 Worker다. 기존 Supabase 로그인 토큰을 검증한 뒤 AI Gateway를 경유해 Workers AI Gemma 4를 호출한다.

- 요청은 `POST /v1/item-translation`이다. `Authorization: Bearer <Supabase 사용자 액세스 토큰>`과 `Content-Type: application/json`을 사용한다. 본문 예시는 `{"text":"冷や奴"}`다. 한 줄 최대 유니코드 스칼라 120개, 본문 최대 1,024바이트다.
- 성공은 `{"translation":"차가운 두부"}`다. 뜻이 불확실하면 `{"translation":null}`을 반환한다. 오류 응답에는 `error` 코드만 담긴다.
- Cloudflare 배포 설정에는 `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `AI_GATEWAY_ID`가 필요하다. 별도로 만든 Gateway를 지정하며, 같은 계정에 Rate Limit 바인딩의 네임스페이스가 이미 쓰이는지 확인한다. 사용자별 초기 제한은 Cloudflare 위치당 분당 10회다. Gateway의 제한은 배포 시 따로 설정한다.
- AI 바인딩 요청에서는 Gateway 캐시와 요청 로그 수집을 끈다. Worker 로그는 모델 요청의 상태 코드와 경과 시간만 기록한다. 출시 전 실제 Gateway에서 요청·응답 본문이 보관되지 않는지 확인한다.

로컬 계약 시험은 이 디렉터리에서 mise가 고정한 Node로 실행한다. Supabase Auth, 사용자별 제한, AI 바인딩은 시험용 구현이며 외부 서비스에 요청하지 않는다.

```sh
mise exec -- node --test index.test.mjs
```

두 앱의 재번역 확인 화면은 debug 빌드의 미리보기로 검증할 수 있다. iOS는 `NONANONA_ITEM_RETRANSLATION=preview`, Android는 `files/debug-processing.properties`의 `itemRetranslation=preview`로 켠다. 두 경우 가상 품목 사전의 응답을 사용한다. 품목별 나누기 화면에서 ‘여러 품목 다시 번역’을 열어 최대 32개를 고른다. 제안은 품목별로 적용하고, 제안을 받지 못한 줄에는 원문이 표시된다.

확인 화면이 닫히는 조건과 요청·결과를 기기에 남기는 방식은 [apps/README.md](../../apps/README.md)의 ‘품목명 다시 번역’ 항목에 있다.

## 여러 품목 재번역 시험

로컬 시험에서 `ENABLE_BATCH_TRANSLATION=true`인 경우 `POST /v1/item-translations`를 사용할 수 있다. 인증 방식은 한 줄 API와 같다. 요청 예시는 `{"items":[{"id":"r01","text":"冷や奴"},{"id":"r02","text":"生中"}]}`다. ID는 이 요청에서만 쓰는 `r`과 숫자 두 자리이며 중복 없이 지정한다. 시험 상한은 32줄이며 본문 상한은 16KiB다.

응답은 요청 순서대로 `items`의 각 `id`와 `translation`을 돌려준다. 모델 응답의 ID가 누락되거나 중복되면 전체 요청을 실패로 처리한다. ID가 모두 일치하면 번역을 보류했거나 형식이 잘못된 줄은 `translation: null`로 돌려주고, 다른 줄의 번역은 반환한다.
