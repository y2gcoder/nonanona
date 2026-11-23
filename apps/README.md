# 모바일 앱 (첫 로컬 슬라이스)

iOS(SwiftUI)와 Android(Kotlin, Compose) 네이티브 앱의 뼈대다. 이번 슬라이스는 다음 흐름만 기기 안에서 끝낸다.

> 사진 앱·파일 앱에서 영수증 공유 → 로그인하지 않은 채 기기에 초안 저장 → 초대 링크 열기 → 로그인 → 열었던 초대의 여행방으로 돌아오기

로그인 도중 앱 프로세스가 끝나도 초안과 열었던 초대는 남고, 다시 열면 그 초대 화면으로 돌아온다([ADR-0002](../docs/adr/0002-authentication-and-device-transfer.md)). debug 빌드는 같은 흐름을 **테스트 구현체**(기기 안, 기본값) 또는 **로컬 Supabase 모드**(Docker로 띄운 로컬 Auth + Postgres에 실제 HTTP로 로그인·초대 수락, 아래 절)로 돌린다. 실제 소셜 로그인, 클라우드 프로젝트, 운영 자격 증명은 없다. 화면 기준은 [모바일 디자인 기준](../docs/design/mobile-foundations.md)에 있다. 두 앱은 첫 슬라이스부터 창 크기·회전·접히는 기기에 맞춰 배치한다(아래 "창 크기와 접기").

## 구성

기능별 폴더로 나누고([ADR-0003](../docs/adr/0003-mobile-architecture.md)), 기능끼리는 서로 참조하지 않는다. 앱 계층이 순서를 잇는다.

| 책임 | iOS (`apps/ios`) | Android (`apps/android/app/src`) |
| --- | --- | --- |
| 영수증 가져오기: 공유·사진 선택으로 받은 사진(1~10장)을 초안 폴더에 원자적으로 저장, 사진별 기기 안 OCR 처리와 가림 확인(아래 "영수증 처리") | `Packages/ReceiptImport`(앱과 공유 확장이 함께 쓰는 Swift 패키지), `NonanonaShare/`(공유 확장), `Nonanona/Features/ReceiptImport/` | `main/.../feature/receiptimport/` |
| 계정: 인증 경계 `AuthGateway`, 로그인 시트 | `Nonanona/Features/Account/` | `main/.../feature/account/` |
| 여행방: 여행방 경계 `TripGateway`(초대 수락), 초대·여행방 화면 | `Nonanona/Features/Trip/` | `main/.../feature/trip/` |
| 앱: 보관한 초대(`PendingInviteStore`), 로그인→초대 수락 순서(`JoinFlow`), 화면 상태와 이동, 구현체 연결 | `Nonanona/App/`(`AppModel`, `AppGraph`) | `main/.../`(`AppViewModel`, `AppGraph`) |
| 디자인 역할 | `Nonanona/Design/Theme.swift` | `main/.../design/` |

화면 상태는 iOS `@Observable` 모델, Android `ViewModel`이 맡는다. 저장과 경계 호출은 저장소·`JoinFlow`에 있고 화면 코드에서 부르지 않는다.

### 테스트 구현체와 release 빌드

- 경계 구현체는 앱 시작 지점에서 빌드 종류에 따라 연결한다. debug는 가상 계정(가나)과 가상 여행방(가상 도쿄 여행)을 돌려주는 테스트 구현체(기본) 또는 로컬 Supabase 구현체, release는 아무것도 성공시키지 않는 `Unavailable*` 구현체다.
- 테스트·로컬 구현체는 iOS `Nonanona/Testing/`·`Nonanona/LocalBackend/`(`#if DEBUG`), Android `src/debug/`에만 있어 release 바이너리에 들어가지 않는다. debug 로그인 시트에는 "테스트 로그인 · 실제 계정에 연결하지 않아요" 또는 "로컬 테스트 계정 · 실제 소셜 로그인이 아니에요" 라벨이 붙는다.
- release 앱에서 로그인 시트를 열면 "지금은 로그인할 수 없어요."만 보이고 로그인 버튼이 없다. iOS는 `mise run ios:release-check`로, Android는 release APK를 로컬 디버그 키로 서명해 설치하고 같은 화면을 확인했다.
- release 빌드에는 INTERNET 권한, 평문 HTTP 허용, 로컬 설정 값이 없다. Android debug 빌드만 로컬 모드를 위해 INTERNET과 `10.0.2.2` 평문 HTTP를 허용한다(`src/debug/AndroidManifest.xml`). 확인 방법은 아래 "release 확인"에 있다.

### 실패 처리

경계 구현체는 실패를 기능이 가진 작은 타입으로만 알린다. 화면 문구와 다음 동작은 이 값으로 정하고, 제공자·서버의 원문이나 코드는 화면에 보이지 않는다. 작업 취소는 실패로 바꾸지 않고 그대로 전한다(상태만 되돌리고 아무것도 지우지 않는다).

| 기능 | 값 | 앱 동작 |
| --- | --- | --- |
| 계정 `SignInFailure` | `cancelled` | 오류로 보이지 않고 로그인 시트의 고르기 상태로 돌아간다 |
| | `network`, `unavailable`, `unknown` | 시트에 문구를 보이고 같은 제공자 버튼으로 다시 시도한다 |
| 여행방 `InviteAcceptFailure` | `sessionExpired` | 기기의 세션만 지운다. 초대는 남고 "다시 로그인하기" 후 같은 초대로 참여한다 |
| | `inviteExpired` | 보관한 초대를 지우고 새 링크를 요청하라고 안내한다("초대 만료됨"). 다시 시도 버튼은 없다 |
| | `inviteInvalid` | 이미 다른 사람이 썼거나 방장이 취소했거나 없는 링크. 동작은 `inviteExpired`와 같고 문구만 다르다("쓸 수 없는 초대") |
| | `network`, `unavailable`, `unknown` | 초대를 남기고 "다시 시도"로 같은 요청을 보낸다 |

어떤 실패도 기기에 저장한 초안을 건드리지 않는다. 판단은 두 앱의 `JoinFlow`에 있고 단위 테스트가 가짜 경계로 각 실패의 발생과 복구를 확인한다. debug 테스트 구현체는 가상 초대 코드 `SYNTHOFFLINE01`(첫 시도 연결 실패), `SYNTHEXPIRED01`(초대 만료), `SYNTHSESSION01`(첫 시도 세션 만료)로 같은 흐름을 기기에서 재현하고, 두 E2E가 정상 흐름 뒤에 이 세 경우를 확인한다.

## 영수증 처리 (기기 안, 로컬 전용)

native-batch-import 실험에서 검증한 처리 코어를 영수증 가져오기 기능 안으로 옮겼다(두 플랫폼 같은 모델). 실험의 화면, 기록 서버, 공유 payload는 옮기지 않았다. 검토·확인 화면은 아래 "영수증 검토(목록 먼저)", 올리기는 아래 "영수증 올리기"(로컬 Supabase 모드, debug 화면)에 있다.

- **처리 상태**: 초안마다 `processing.json`에 사진별 상태(`queued → processing → ready | failed → confirmed`), 시도 횟수, 실패 이유를 둔다. 상태는 화면에 알리기 전에 원자적으로 디스크에 먼저 쓴다. 처리기를 만들 때 `processing`으로 남은 사진(처리 중 앱 종료)을 `queued`로 되돌리고 `recoveredCount`를 늘린다. 끝난 사진은 다시 읽지 않는다.
- **OCR**: 동시에 최대 2장. iOS는 Apple Vision(`ja-JP`), Android는 ML Kit 번들 일본어 모델(`text-recognition-japanese` 16.0.1). 사진에서 날짜·합계·가게와 가림 후보(전화·카드·회원·예약번호 줄)를 고른다. 실패는 문자열이 아니라 `ProcessingFailure`(`unreadable`, `missingTotal`, `missingDate`, `invalidImage`, `recognitionError`)로 남기고, 그 사진 하나만 "다시 읽기"로 대기열에 되돌린다.
- **타입 분리**: 원본 사진(초안 폴더), `OCRProposal`(OCR 전문 포함, 기기 안 `proposals/`에만), `AllowedReceiptFields`(날짜·금액·통화·가게), `MaskedArtifact`(가림을 구운 새 PNG. 굽기 함수만 만들 수 있다), `ConfirmedReceipt`(허용 필드 + 가림 사본 이름·해시)는 서로 다른 타입이다.
- **확인**: `confirm(item, fields, maskLineIDs)`만 가림을 픽셀에 굽는다(새 비트맵에 검은 띠, PNG 재인코딩 후 `IHDR/PLTE/tRNS/sRGB/IDAT/IEND` 외 청크 제거). 날짜 형식·금액·통화가 맞지 않거나 `ready`가 아니면 거절한다.
- **기기 경계(fail closed)**: 기기 밖으로 보낼 수 있는 것은 `outboundReceipts()` 하나뿐이다. 확인한 영수증만 돌려주고, 그 전에 가림 사본이 있는지, 해시가 확인 당시와 같은지, 허용 청크만 있는지, 원본과 다른 바이트인지 다시 본다. 하나라도 어긋나면 아무것도 돌려주지 않는다. 돌려주는 값은 검사한 바이트 그대로다(검사 뒤 파일을 다시 읽지 않는다). 올리기는 이것만 쓴다.
- **저장 정책**: iOS는 App Group 컨테이너의 초안 폴더(백업 제외, `completeFileProtectionUntilFirstUserAuthentication`), Android는 앱 전용 `filesDir`(백업·기기 이전 제외 규칙). 임시 파일은 같은 폴더 안 숨김 파일로 쓰고 이름을 바꿔 공개한다.
- **release 앱**: 네트워크 권한이 없다. ML Kit이 병합하는 `INTERNET`·`ACCESS_NETWORK_STATE`를 main 매니페스트에서 지웠다(debug는 로컬 Supabase 모드 때문에 `INTERNET`만 다시 받는다).
- **화면**: 초안 화면이 영수증 목록이다(아래 "영수증 검토(목록 먼저)"). debug 빌드에만 "확인(개발용)"(제안값과 가림 후보를 그대로 확인, 예전 E2E가 쓴다)과 처리 늦추기·첫 시도 실패 주입·가림 제안 비우기(iOS 실행 환경 변수 `NONANONA_PROCESSING_DELAY_MS`·`NONANONA_FAIL_FIRST_ATTEMPT_POSITION`·`NONANONA_DROP_SUGGESTIONS_POSITION`, Android `files/debug-processing.properties`의 `delayMillisPerItem`·`failFirstAttemptAtPosition`·`dropSuggestionsAtPosition`)이 있다.

### 확인한 것 (2026-11-21, 가상 영수증 10장)

| 확인 | iOS | Android |
| --- | --- | --- |
| 단위 테스트 | `swift test`(macOS, 실제 Vision): 9장 날짜·합계가 정답과 같고 민감한 줄마다 가림 후보가 있음, r10 실패. 동시 처리 최대 2. 4장 완료·2장 처리 중 상태를 복사해 다시 열면 복구 2건, 6장만 다시 읽고 시도 횟수 `[1,1,1,1,2,2,1,1,1,1]`. 실패 1장 다시 읽기 뒤 나머지 9장 그대로. 가림 픽셀·메타데이터, 경계(확인 전 빈 목록, 사본을 원본으로 바꾸면 거절), 잘못된 값·상태 거절 | JVM(정답 줄 위치로 만든 OCR 대역, ImageIO 굽기): 같은 항목 4개 |
| 기기 E2E: 진입 | 사진 앱에서 10장 선택 → 공유 → 노나노나 → 홈 화면처럼 앱 실행 | 파일 앱에서 10장 선택 → 시스템 공유 → 노나노나(콜드 스타트) |
| 처리 도중 SIGKILL | 4/10 처리 시점: ready 2, failed 2(주입 1 + 사진 앱 순서로 1번에 온 r10), processing 2, queued 4 | 4/10: ready 3, failed 1(주입), processing 2, queued 4 |
| 다시 열기 | 이어서 읽은 사진 2장, 10/10 처리 | 같음 |
| 실패만 다시 읽기 | 주입 실패 사진 → 확인 필요, r10 → 다시 실패(`unreadable`), 다른 8장 라벨 그대로 | 같음 |
| 최종 상태 | ready 8, confirmed 1, failed 1(r10), 시도 `[2,1,1,2,2,2,1,1,1,1]` | ready 8, confirmed 1, failed 1(r10), 시도 `[1,1,1,2,2,2,1,1,1,2]` |
| 실제 OCR | Vision이 읽을 수 있는 9장 모두 날짜·합계를 읽음 | ML Kit이 읽을 수 있는 9장 모두 날짜·합계를 읽음 |
| 가림 사본 호스트 검사 | r09: 민감한 줄 글자 픽셀 3,017개 모두 검정, 가림 띠 밖 표본 42,960개 변화 0, 청크 `IHDR/sRGB/IDAT/IEND`, 원본 표지 문자열 없음, 원본과 다른 바이트 | r01: 2,730개 모두 검정, 변화 0, 같은 청크, 표지 없음 |
| OCR 전문 | 기기 안 `proposals/` 9개 파일에만 있음 | 같음 |
| release | 개발용 버튼 문구·처리 훅 변수·테스트/로컬 구현체 0 | 개발용 문구 리소스·처리 훅 파일 이름·테스트/로컬 클래스 0, 네트워크 권한 없음 |
| 기존 흐름 회귀 | 테스트 모드 E2E 4단계, 로컬 Supabase 모드 E2E 4단계 통과(서버 보고 참여 3·사용된 초대 3) | 같음 |

```sh
mise run ios:e2e-receipts -- <시뮬레이터 UDID> [증거 폴더]
mise run android:e2e-receipts -- [증거 폴더]
```

## 영수증 올리기 (로컬 Supabase 모드, debug 화면)

확인한 영수증을 참여한 여행방에 올리는 좁은 세로 구간이다. 결제자·부담자·원화 환산·검토 같은 정산 흐름은 넣지 않았다.

- **앱**: 초안 화면의 debug 전용 "여행방에 올리기(개발용)" 구역이 올릴 곳(참여한 여행방 이름)과 확인한 영수증 장수를 보여 주고, "‘여행방’에 영수증 N장을 올릴까요?" 최종 확인을 받은 뒤에만 올린다. 확인하지 않은 사진은 올리지 않는다. 보내는 것은 `outboundReceipts()`가 돌려준 가림 사본 바이트와 허용 필드(날짜·금액·통화·가게)뿐이다. 경계는 `TripGateway.submitReceipt` 하나이고(여행방 기능), 실패는 `ReceiptUploadFailure`(`sessionExpired`, `destinationUnavailable`, `network`, `unavailable`, `unknown`)로만 알린다. 세션 만료면 세션만 지우고, 초안·사본은 그대로 둔 채 다시 로그인 후 같은 요청 키로 다시 올린다. 화면 문구와 버튼은 iOS `#if DEBUG`, Android `src/debug`에만 있다.
- **요청 키**: `(여행방, 사본 SHA-256)`으로 만든 결정적 UUID(두 플랫폼이 같은 값, 단위 테스트로 고정). 재시도·반복·앱을 다시 연 뒤 올리기가 모두 같은 키를 쓴다.
- **서버**(`supabase/migrations/…_receipt_expenses.sql`): 비공개 버킷 `receipts`(PNG만, 2 MiB). 객체 이름은 `<trip>/<올린 사람>/<요청 키>.png`이고, 올리기 정책은 그 방 구성원이 자기 폴더에만, 읽기는 그 방 구성원만이다. 덮어쓰기·삭제 정책은 없다. `submit_receipt_expense` RPC(`private` 스키마 definer 본문)는 구성원인지(아니면 `trip_not_found`), 그 이름의 객체가 호출자 소유 PNG로 있는지(`artifact_missing`) 본 뒤 `expenses` 행을 만든다. `(trip, 요청 키)` 고유 제약과 요청 지문으로 같은 요청은 같은 행(`replayed`), 다른 내용은 `idempotency_conflict`. 지출 행 열: `id, trip_id, client_request_id, request_fingerprint, uploaded_by, expense_date, amount_minor, currency, merchant, artifact_path, artifact_sha256, created_at`. 구성원만 SELECT, 쓰기 권한 없음.
- **원자성 없음**: Storage와 DB는 한 트랜잭션이 아니다. 사본만 올라가고 끊기면 행 없는 객체가 남는다. 지출은 행으로만 보이므로 반쯤 보이는 지출은 없고, 같은 키로 다시 시도하면 업로드는 "이미 있음"(`KeyAlreadyExists`)으로 넘어가고 행이 생긴다. 행 없는 객체를 지우는 작업은 아직 없다.
- **실패 구분**: Storage는 잘못된 토큰과 권한 없음을 같은 `AccessDenied`로 알린다(로컬에서 확인). 앱은 이때 Auth(`/auth/v1/user`)로 세션이 유효한지 확인해, 무효면 `sessionExpired`, 유효면 `destinationUnavailable`로 닫는다.

### 확인한 것 (2026-11-21, 가상 영수증 2장 중 1장만 확인)

두 플랫폼 E2E가 같은 순서를 밟고, 단계마다 서버의 객체·지출 수를 본다(`scripts/local-backend.py upload-report`).

| 단계 | iOS | Android | 서버(객체/지출) |
| --- | --- | --- | --- |
| 1장 확인, 초대로 참여, 최종 확인 창(올릴 곳·장수 표시) | 통과 | 통과 | 0 / 0 (확인 전 업로드 없음) |
| API 게이트웨이 정지 중 최종 확인 | "인터넷에 연결할 수 없어요" | 같음 | 0 / 0 |
| 서버에서 구성원 빼기 → 올리기 | "이 여행방에 올릴 수 없어요" | 같음 | 0 / 0 |
| 서버 세션 삭제 + 토큰 만료 → 올리기 | "로그인이 만료됐어요" → 다시 로그인 | 같음 | 따로 재지 않음(다음 줄의 1 / 0에 포함) |
| 다시 올리기(debug: 사본 저장 직후 첫 실패 주입) | 연결 실패로 보임 | 같음 | 1 / 0 (행 없는 객체, 지출로 안 보임) |
| 다시 시도 | "올림 1장(이미 올린 0장 포함)" | 같음 | 1 / 1 |
| 같은 영수증 다시 올리기 | "올림 1장(이미 올린 1장 포함)" | 같음 | 1 / 1 |
| SIGKILL → 다시 열기 → 초대로 다시 들어가 올리기 | "이미 올린 1장" | 같음 | 1 / 1 |
| 서버가 받은 사본 | 확인한 사본과 같은 해시, 기기의 어떤 원본과도 다름. r02: 민감한 줄 글자 픽셀 1,869개 모두 검정, 띠 밖 변화 0, 청크 `IHDR/sRGB/IDAT/IEND`, 원본 표지 없음 | r01: 2,730개 모두 검정, 변화 0, 같은 청크, 표지 없음 | 확인하지 않은 사진은 올라가지 않음(객체 1) |
| 서버 지출 필드 | 2026-11-03 · 1,276 JPY · みなと珈琲(기기에서 확인한 값과 같음) | 2026-11-03 · 1,408 JPY · さくら食堂(같음) | 허용 열만 |
| 비구성원 가상 계정 | 지출·여행방 0행, 방 폴더 목록 0, 구성원 객체 내려받기 `NoSuchKey`, 방 폴더에 올리기 `AccessDenied`, 제출 RPC `trip_not_found`, 익명 지출 조회 401 | 같음 | |

```sh
mise run local:up
mise run ios:e2e-upload -- <시뮬레이터 UDID> [증거 폴더]
mise run android:e2e-upload -- [증거 폴더]
mise run local:down
```

## 영수증 검토(목록 먼저)

받은 영수증을 모두 목록에서 먼저 보이고, 한 장씩 기기 안 원본과 비교해 값과 가림을 고친 뒤 "확인하고 다음"으로 확인한다. 결정은 [ADR-0005](../docs/adr/0005-receipt-review-and-mask-correction.md), 화면·문구는 [디자인 기준](../docs/design/mobile-foundations.md#영수증-목록과-검토목록-먼저). release 빌드에서도 검토·확인을 할 수 있다(올리기만 debug 전용).

- **목록(초안 화면)**: 읽음·확인 수, 상태별 개수(읽는 중과 대기를 나눔), 읽지 못한 사진 안내("사진 N 열기"), "확인할 영수증 검토 (N)". 행은 사진 번호 순서이고 상태 라벨·한 줄 요약(가게 · 날짜 · 금액 · 가림 N곳, 고치던 값 반영)·실패 행의 "다시 읽기"·"직접 입력"이 있다.
- **검토 화면**: 원본/가린 사본 전환, 가림(OCR 줄 스위치, 직접 더한 가로 띠를 버튼·화면 읽기 조절로 옮기고 크기 바꾸기), 값(가게·날짜·금액·통화 JPY/KRW/USD/EUR), 하단 "확인하고 다음"과 왜 누를 수 없는지 한 줄. 읽지 못한 사진은 "이 사진만 다시 읽기"와 직접 입력. iOS는 숫자 자판 위 "완료"와 목록 끌기로 자판을 닫는다.
- **저장**: 고치던 입력은 사진마다 `reviews/<사진>.json`에 고칠 때마다 원자적으로 쓰고, 확인하면 지운다(값이 비면 OCR 제안). 확인(`confirm`)은 가림 줄 + 띠를 구운 사본과 허용 필드를 디스크에 쓴 뒤 다음 "확인 필요" 사진(목록 순서, 뒤에 없으면 앞쪽)을 열고, 없으면 목록으로 돌아가 남은 것을 보인다. 직접 입력(`confirmManual`)은 사본 없이 값만 남기고 기기 밖으로 나가지 않는다(경계 `outboundReceipts()`가 건너뛴다).
- **미리보기**: 확인과 같은 굽기 함수(`preview`)로 만들고 디스크에 쓰지 않는다. 화면 읽기에는 "가린 사본 미리보기, 가림 N곳…"만 읽힌다.
- **올리기 연결**: 기존 debug 올리기 구역과 같은 경로(올릴 곳 = 참여한 여행방, 최종 확인 창, 같은 요청 키)다. 올릴 장수는 사본이 있는 확인 영수증만 세고, 직접 입력은 "직접 입력 N건은 사진이 없어 이번에는 올리지 않아요"로 알린다.
- **검증용 훅(debug)**: 가림 제안 비우기(iOS `NONANONA_DROP_SUGGESTIONS_POSITION`, Android `dropSuggestionsAtPosition`)로 제안이 민감한 줄을 놓친 경우를 재현한다.

### 확인한 것 (2026-11-23, 가상 영수증 10장, 로컬 Supabase)

두 E2E가 같은 순서를 밟고, 단계마다 기기 디스크(`apps/fixtures/review_e2e_check.py`, 두 플랫폼 공용)와 서버(`local-backend.py upload-report`, `fetch-artifacts`)를 본다.

| 단계 | iOS (`ios:e2e-review`, iPhone 18 Pro Max 시뮬레이터 iOS 27.2) | Android (`android:e2e-review`, Pixel 9 Pro Fold 프로필 에뮬레이터 API 36, 접은 바깥 화면에서 시작) |
| --- | --- | --- |
| 공유 → 목록 | 사진 앱 10장, 순서 r02,r06,r10,r01,r05,r09,r04,r08,r03,r07 | 파일 앱 10장, 순서 r01…r10 |
| 처리 중 목록 | "읽는 중 2 · 대기 …"(읽는 중과 대기를 나눔, 화면 기록) | "읽는 중 2 · 대기 2 · 확인 필요 6" |
| 다 읽은 뒤 | "확인 필요 9 · 읽지 못함 1", 실패 안내 "사진 3 열기", "확인할 영수증 검토 (9)" | 같음("사진 10 열기") |
| 읽지 못한 사진(r10) | 값 없으면 확인 버튼 꺼짐·이유 보임 → 가게·금액 입력 → 이 사진만 다시 읽기(시도 2, 다시 실패) → 입력 그대로 → 날짜 입력 → 확인하고 다음 → 다음 확인 필요 사진이 열림. 디스크: 확인함, 사본 없음, 검토 입력 파일 지워짐 | 같음 |
| 값 고치기 | r05 금액 6,050 → 6,060, 가게 끝 "(수정)" → 다음 사진, 확인 2/10, 디스크 값 = 고친 값 | 금액 +10, 가게 끝 " edit"(adb는 ASCII만 입력) → 같음 |
| 놓친 가림 고치기(r01, 제안 비움) | "가림 0곳"에서 시작 → TEL 줄 스위치 + 가림 영역(47%에서 아래로 옮겨 79–85%) → "가림 2곳" → 가린 사본 미리보기(이름에 가린 글자 없음) → 확인 | 같음. 두 플랫폼 사본: 민감한 줄 글자 픽셀 2,730개 모두 검정, 띠 밖 표본 42,960개 변화 0, 청크 `IHDR/sRGB/IDAT/IEND` |
| 입력 중 SIGKILL → 다시 열기 | 확인 3/10 유지, "확인할 영수증 검토 (7)", 입력만 한 사진은 "확인 필요"·금액 999 그대로 | 같음(행 요약에도 999) |
| 배치 바꾸기 | 세로 → 가로(넓은 창: 홈 목록 옆 검토 화면) → 세로: 같은 사진·같은 입력 | 펴기(두 칸: 영수증 목록은 왼쪽, 검토 칸 x 1198–2076, 확인 버튼이 hinge 한쪽) → 접기: 같은 사진·같은 입력 |
| 큰 글자 | `accessibility-extra-extra-extra-large`: 같은 사진, "가림 영역 더하기"·"확인하고 다음"까지 스크롤로 닿음, 이름 있음 | `font_scale 2.0`: 같음 |
| 검토 화면을 나가기 | 확인 3/10 그대로(나가기는 확인이 아님) | 같음 |
| 올릴 곳 없음 | 안내만, 올리기 버튼 없음 | 같음 |
| 참여 후 최종 확인 창 | "‘가상 오사카 여행’에 영수증 2장을 올릴까요?", 직접 입력 제외 안내. 서버 0 / 0 | 같음 |
| 최종 확인 취소 | 서버 0 / 0 | 같음 |
| 구성원 아님 | "이 여행방에 올릴 수 없어요…", 서버 0 / 0 | 같음 |
| 올리기 → 반복 | "올림 2장(이미 올린 0장 포함)" → "올림 2장(이미 올린 2장 포함)", 서버 2 / 2 | 같음 |
| 서버가 받은 것 | 사본 2개(r01·r05) = 기기의 확인 사본 해시, 어떤 원본과도 다름, 민감한 줄 모두 검정(2,730·3,070), 띠 밖 변화 0. 지출 필드 = 기기 확인 값(고친 6,060 JPY·かもめ寿司(수정) 포함), 직접 입력(1,760 JPY)은 없음. 비구성원 7개 접근 모두 거절 | 사본 2개 = 기기의 확인 사본 해시, 어떤 원본과도 다름, r01·r02 민감한 줄 모두 검정(2,730·1,869), 띠 밖 변화 0. 지출 필드 = 기기 확인 값(고친 값 포함), 직접 입력(1,760 JPY)은 없음. 비구성원 7개 접근 모두 거절 |

```sh
mise run local:up
mise run ios:e2e-review -- <새 시뮬레이터 UDID> [증거 폴더]   # EXPECT_WIDE_LANDSCAPE=1 (Pro Max 등)
mise run android:e2e-review -- [증거 폴더]                   # 접은 접히는 기기 에뮬레이터
mise run local:down
```

단위 테스트: 두 플랫폼이 같은 경우를 본다(입력 검사·띠 픽셀·다음 사진 고르기, 놓친 가림을 줄+띠로 고친 사본 = 미리보기, 직접 입력이 다시 읽기를 지나도 남고 경계를 넘지 않음, 검토 입력이 처리기를 다시 만들어도 남음). iOS는 실제 창의 분할 보기를 접고 펴는 동안 고른 영수증·입력이 남고 확인하고 다음이 순서대로 가는지도 본다.

**회귀와 release**: 바뀐 목록 화면·올릴 장수로 기존 `ios:e2e-upload`(iPhone 18 Pro)·`android:e2e-upload`(폰 에뮬레이터) 통과. 단위 테스트 iOS 패키지 16·앱 24, Android 36 통과. swift-format·ktlint 통과, Android lint 오류 0. `ios:release-check` 통과, iOS Release 실행 파일에 검토 화면 문구는 있고 개발용 문구·테스트/로컬 경계·개발용 올리기 기호는 0. Android release APK에 검토 화면 클래스는 있고 `localbackend`·`testing`·`DebugUploadSection` 0, INTERNET 권한 없음, 개발용 문구 0. 기존 `*-e2e-receipts`·`*-e2e-adaptive`·`ios:e2e-posture`·테스트 모드 `*:e2e`는 이번에 다시 돌리지 않았다(같은 식별자·개발용 확인 버튼을 그대로 두었다).

**찾아 고친 것**: iOS에서 검토 화면을 `navigationDestination` 클로저 안에서 모델 값으로 만들었더니, 클로저가 모델 변화에 다시 불리지 않아 화면이 예전 값에 머물고 자판을 닫을 때 입력 칸이 빈 값을 다시 써 버렸다(시뮬레이터에서 재현). 모델을 자기 body에서 읽는 목적지 뷰로 바꿨다. iOS 숫자 자판에는 닫기 키가 없어 "완료"를 더했다. iOS 가림 영역의 다섯 버튼이 한 목록 행에 스타일 없이 있어 한 번 누르면 모두("삭제"까지) 동작했다. 버튼마다 따로 눌리도록 `.bordered` 스타일을 줬다.

**증거 공백**: 시뮬레이터·에뮬레이터만 확인했다. VoiceOver·TalkBack으로 실제로 읽고 조절 동작(위·아래로 쓸기, 사용자 지정 동작)으로 띠를 옮기는 것은 E2E가 하지 않았다(이름·값·조작 크기만 확인). iPhone Duo 자세, 반쯤 접기, 다크 모드, 실제 사용자 영수증, 긴 영수증·기울어진 사진, 사진 확대(핀치)는 확인하지 않았다. 직접 입력한 값은 서버로 올리지 않는다(ADR-0005). 확인한 사진은 다시 고칠 수 없다. 개발용 "확인(개발용)" 바로 확인 버튼은 예전 E2E 때문에 debug에 남아 있다.

### 리뷰 반영 (2026-11-23, 008d3c3 독립 리뷰)

결정은 [ADR-0005 "리뷰 뒤 보강"](../docs/adr/0005-receipt-review-and-mask-correction.md#리뷰-뒤-보강-2026-11-23). 직접 입력은 이번에도 기기에만 둔다.

| 항목 | 바꾼 것 | 확인 |
| --- | --- | --- |
| 확인의 내구성 | 확인·직접 입력은 처리 상태를 디스크에 먼저 쓰고, 성공한 뒤에만 확인 상태를 알리고 다음 사진으로 가고 검토 입력을 지운다. 실패하면 사본을 지우고 확인 전으로 둔 채 "확인을 저장하지 못했어요…" | 두 플랫폼 단위 테스트(쓰기 실패 주입 → 알림 없음·확인 전·검토 입력 유지·사본 없음·경계 빈 목록 → 처리기 다시 만들기(재시작) → 확인 전 → 쓰기 복구 뒤 확인). iOS 모델 테스트(선택·입력 유지, 다음 사진으로 가지 않음, 재시작 뒤 마지막 입력). 두 E2E: `debug-fail-writes`에 `processing.json`을 적고 "확인하고 다음" → 오류, 같은 사진, 확인 3/10 그대로 |
| 입력 저장 실패 | 쓰지 못하면 "입력을 기기에 저장하지 못했어요" + "다시 저장", 화면·메모리 입력 유지, 디스크는 마지막 입력. 저장에 순번을 붙여 늦게 끝난 오래된 저장이 덮지 않음 | 단위 테스트(실패 시 디스크 값 유지, 순번 3이 4를 덮지 않음). 두 E2E: `reviews/`를 적고 금액 888 → 오류·화면 888 → SIGKILL·다시 열기 → 디스크의 999 |
| 최종 확인 동의 | 확인 창에 여행방 ID와 영수증별 사진 ID·사본 해시·확인 값(날짜·금액·통화·가게)을 담고, 보내기 직전 경계를 지난 목록과 하나라도 다르면 아무것도 보내지 않음("올릴 영수증이 바뀌어 아무것도 올리지 않았어요") | iOS 모델 테스트: 1장으로 확인 창을 연 뒤 다른 영수증을 확인 → 보내기 0건, 다시 열면 2장으로 묻고 보냄. Android JVM: 영수증 더함·사본·금액·통화·사진이 바뀌면 거절 |
| 받은 쪽 검사 | E2E 서버 검사가 사본 해시로 지출 행을 짝지어 날짜·금액·**통화**·가게를 비교하고, 통화가 허용 목록(JPY·KRW·USD·EUR)인지, 지출 열이 정해진 12개 그대로인지 본다(`upload-report`에 행별 사본 해시를 더함) | 두 E2E 통과 |
| 날짜·금액 입력 | 유니코드 10진 숫자·줄표·빗금 변형을 ASCII로 맞춘 뒤 ASCII 형식만 받음. 날짜는 숫자 8자리·`2026/11/8`도 받아 `2026-11-08`로. iOS는 예전에 `\d`가 유니코드 숫자를 통과시키고 `Int()`가 실패해 `parts[2]`에서 멈출 수 있었다 | 두 플랫폼 단위 테스트(전각·아랍-인도 숫자 붙여넣기, 잘린 날짜·섞인 글자 거절). iOS E2E는 직접 입력 날짜를 전각 `２０２６－１１－０８`로 쳐서 디스크 `2026-11-08`. Android E2E는 직접 입력(가게·금액·날짜 `20261108`)을 화면 자판(Gboard) 키를 눌러 쳐서 디스크 `2026-11-08` |
| Android EXIF 방향 | OCR·굽기·검토 화면 원본/가림 표시·목록 미리보기가 같은 디코딩(EXIF 방향 8가지)을 씀. 예전에는 화면만 방향을 무시했다 | E2E: 가상 JPEG(r01을 반시계 90°로 저장 + Orientation 6, `apps/fixtures/make_exif_rotated.py`) 공유 → 원본 칸 비율 0.965(똑바른 r01과 같음), 화면 기록의 줄별 글자 분포와 똑바른 r01의 상관 0.841(옆으로 누운 그림은 0.13) → 확인한 사본 720×746, 민감한 줄 2,730개 모두 검정, 띠 밖 평균 차이 1.19(JPEG 손실) |

회귀: 두 검토 E2E(위 항목 포함) 다시 통과(iPhone 18 Pro Max 시뮬레이터, Pixel 9 Pro Fold 프로필 에뮬레이터), 기존 `ios:e2e-upload`(iPhone 18 Pro)·`android:e2e-upload`(폰 에뮬레이터) 통과(iOS는 첫 실행에서 공유 메뉴에 노나노나가 늦게 떠 실패, 새 시뮬레이터에서 다시 통과). 단위 테스트 iOS 패키지 19·앱 26, Android 40 통과. swift-format·ktlint 통과, Android lint 오류 0, `ios:release-check` 통과, Android release APK에 디버그·로컬 코드(저장 실패 주입 포함)와 INTERNET 권한 없음.

**처리기 하나(후속 리뷰 P1, 2026-11-23)**: Android `AppViewModel`이 "처리기가 없으면 만들고 넣기" 사이에 멈춰(디스크 읽기), 앱 시작 읽기와 공유로 받은 초안 읽기가 겹치면 같은 초안에 처리기가 둘 생길 수 있었다. 둘은 각자 manifest를 들고 `processing.json`을 번갈아 덮어쓰고, 둘째는 만들 때 첫째가 읽던 사진을 대기열로 되돌려 같은 사진을 다시 읽는다. `DraftProcessors`가 찾기·만들기를 한 잠금 안에서 하고 만든 뒤에만 넣는다(취소·실패하면 넣지 않아 다음 요청이 새로 만든다). 초안 목록도 읽기·게시를 한 잠금 안에서 해 먼저 읽은 오래된 목록이 새 목록을 덮지 않고, 처리기를 확보한 뒤의 첫 상태는 그사이 처리기가 알린 더 새 상태를 덮지 않는다. 올리기 반복은 `ConsentedUpload`로 옮겨 ViewModel이 그대로 쓴다. 확인: JVM 테스트(게이트로 순서를 정한 겹친 요청 → 처리기 1개·같은 객체·사진마다 OCR 1번, 만들기 취소·실패 뒤 다음 요청 성공, 겹친 목록 읽기의 게시 순서, 처리기 하나로 확인·직접 입력 → 새 레지스트리·새 처리기(재시작)에서 같은 확인·디스크 manifest와 같음, 동의 스냅샷이 다르거나 여행방이 다르면 게이트웨이 호출 0번). 겹친 요청 테스트는 예전 모양(잠금 없이 만들고 넣기)으로 되돌리면 실패하는 것을 확인했다. 에뮬레이터(2026-11-24): `android:e2e-review`(Pixel 9 Pro Fold 프로필, 콜드 스타트 공유로 시작 읽기와 가져오기가 겹침) 통과, 마지막 디스크 상태의 사진별 OCR 시도 `[1,1,1,1,1,1,1,1,1,2]`(r10의 2는 "이 사진만 다시 읽기"), 이어서 읽은 사진 0. `android:e2e-upload`(폰 에뮬레이터, 세션 만료·부분 실패·반복 수렴 포함) 통과. JVM 테스트 46개 통과.

증거 폴더(커밋하지 않음): 실행마다 `android-review-*.json`·`ios-review-*.json`과 화면 기록(`android-review-save-failed`, `android-review-confirm-failed`, `android-review-exif-original`, `ios-review-save-failed`, `ios-review-confirm-failed`).

**남은 공백**: 저장 실패는 debug 주입(경로 조각으로 쓰기 실패)으로만 재현했다. 실제 저장 공간 부족·파일 보호 잠금은 확인하지 않았다. 최종 확인 뒤 내용이 바뀌는 경우는 단위 테스트로만 확인했다(iOS 모델 테스트, Android는 ViewModel이 쓰는 `ConsentedUpload` 테스트로 게이트웨이 호출 0번. E2E에서는 확인 창이 떠 있는 동안 다른 영수증을 확인할 화면 경로가 없다). iOS EXIF 방향 E2E는 하지 않았다(처음부터 ImageIO 변환 하나를 씀). 날짜 고르기(달력)는 넣지 않았다(숫자 8자리 입력으로 해결). 서버 RPC의 통화 제한(지금은 `^[A-Z]{3}$`)은 바꾸지 않았다(받은 쪽 검사는 E2E 호스트 검사를 강화했다).

## 여행방 정산 (로컬 Supabase 모드)

결정과 아직 정하지 않은 것은 [ADR-0006](../docs/adr/0006-room-settlement.md)에 있다. 서버가 계산·확정하고, 두 앱은 서버 값을 그린다.

- **홈**: 로그인하면 참여한 여행방 목록이 보인다. 로그인하지 않았으면 "로그인" 버튼이 있다(초대 없이도 시드 여행방을 열 수 있게). 여행방을 열면 그 방이 올릴 곳이 된다.
- **장부**(상세 칸): 일행과 지출. 지출마다 원래 금액, 올린 사람, 증빙(가린 사본 또는 직접 입력), 상태(확인 필요·포함·보류), 포함이면 결제자·원화·사람별 몫, 보류면 사유. 방장만 지출을 눌러 검토한다.
- **지출 검토**(세 번째 칸, 방장): 결제자, 원화(KRW는 그대로, 외화는 실제 원화 청구액을 적는다 — 환율로 계산하지 않는다), 부담(한 사람 · 둘이 반씩 · 직접 나누기), 포함하기 또는 보류하기(사유 3개 중 하나). 반으로 나누면 원이 남으면 반씩을 막고 직접 나누게 한다. 다른 변경이 먼저 저장되면 최신 값으로 다시 열고 알린다.
- **송금표**(세 번째 칸): 확정 전에는 서버 미리보기(송금, 함께 쓴 돈, 제외된 지출, 확인 필요 건수), 방장만 "정산 확정"(확인 창). 미리보기 뒤 바뀐 것이 있으면 확정하지 않고 새 미리보기를 보인다. 확정 뒤에는 확정본(판, 기기 시간대의 확정 시각, 확정 번호·기록 해시 앞 8자리)을 그린다.
- **직접 입력 올리기**(초안 화면, debug): 읽지 못한 사진에 값만 확인한 항목은 사본 올리기와 따로 "직접 입력 올리기"로 최종 확인을 받고 허용 필드만 올린다.
- 로컬 debug 계정: 기본은 가상 회원(가나). iOS는 실행 환경 변수 `NONANONA_LOCAL_ACCOUNT=host`, Android는 `files/debug-processing.properties`의 `localAccount=host`이면 가상 방장(다라)으로 로그인한다. 두 계정 모두 `local:reset`이 만든 시드 여행방 "가상 후쿠오카 정산"의 구성원이다.

```sh
mise run local:up
mise run local:contract                                   # 서버 계약 시험(실제 HTTP)
mise run e2e:settlement -- <시뮬레이터 UDID> android [증거 폴더]   # Android 방장, iOS 회원
mise run e2e:settlement -- <시뮬레이터 UDID> ios [증거 폴더]       # iOS 방장, Android 회원
```

### 확인한 것 (2026-11-24, iPhone 18 Pro 시뮬레이터 iOS 27.2 + Android 에뮬레이터 API 36, 가상 계정·가상 영수증)

`scripts/e2e-settlement.py`를 방장 기기를 바꿔 두 번 돌렸고 둘 다 통과했다(A: Android 방장·iOS 회원, B: iOS 방장·Android 회원). 단계마다 서버 행(지출·몫·확정)을 읽어 확인한다.

1. 회원 기기: 가상 영수증 3장(r01·r02·r10) 공유 → 읽은 2장은 제안 그대로 확인, 읽지 못한 r10은 값만 직접 입력(`ticket`, 38,000 KRW, 2026-11-08). 홈의 "로그인" → 시드 여행방을 열어 올릴 곳으로 정함(지출 없음) → 사본 2장 최종 확인 뒤 올림 → 직접 입력 1건은 따로 "직접 입력 1건을 올릴까요?" 확인 뒤 올림 → 다시 올리면 "이미 올린 1건 포함"(서버 지출 그대로 3건). 서버: 객체 2, 지출 3(사본 2·직접 입력 1, 모두 확인 필요, 올린 사람 가나, 결제자 없음), 직접 입력 행에 사본 없음.
2. 회원 기기: 같은 지출 3건이 보이지만 지출을 눌러도 검토가 열리지 않고, 미리보기에 확정 버튼이 없다.
3. 방장 기기: 로그인 → 확인 필요 3건 → r01(1,408 JPY): 결제자 다라, 실제 원화 13,377원 → "둘이 반씩"은 "1원이 남아요"로 막힘 → 직접 나누기(6,688 + 6,688이면 "1원이 남았어요", iOS는 한 칸만 채워 "6,689원이 남았어요") → 6,688/6,689로 포함. r02: "원화 청구액 확인 대기"로 보류. 직접 입력: 원화 그대로 38,000원, 반씩 19,000원 포함. 서버: r01 `verified_krw_charge` 13,377원·몫 6,688/6,689, r02 보류 사유, 입장권 `krw_original` 19,000/19,000.
4. 방장 기기 미리보기: "가나 → 다라 25,689원", 함께 쓴 돈 51,377원, 제외 r02(보류). 스크립트가 회원 계정으로 지출 1건(5,000 KRW)을 더한 뒤 확정 → 오래된 revision으로 거절, 새 미리보기에 확인 필요 1건·확정 버튼 꺼짐 → 그 지출을 "결제 여부 불명확"으로 보류 → 송금은 그대로 25,689원 → 확인 창 → 확정.
5. 서버: 방 `finalized`, 확정 행 1개, 스냅숏 결과 함께 쓴 돈 51,377·송금 [25,689]·제외 2건(사유 2개). 두 기기 모두 같은 확정 번호(앞 8자리), 같은 송금 한 줄·합계·제외 2건, 확정·검토 동작 없음.
6. 두 앱을 SIGKILL하고 다시 연 뒤에도 5와 같고, 서버 revision·확정 행이 그대로다(다시 열기는 아무것도 쓰지 않는다). 기존 비구성원 검사(`outsider-check`)도 통과.

서버 계약 시험(`mise run local:contract`, 실제 HTTP, 실행마다 새 가상 여행방): 75개(검토 동시 실행에서 뒤에 보낸 요청이 이기면 다시 검토하는 검사 1개가 더해져 76개) 모두 통과. 비구성원의 모든 정산 RPC·6개 테이블 거부, 테이블 직접 쓰기 거부, 회원의 검토·확정 `host_only`, 외화 원화 없음 `krw_unverified`, 1원 남는 몫 `shares_mismatch`, 잘못된 몫 6종 `shares_invalid`, 같은 버전 동시 검토는 하나만 반영, 검토·직접 입력·확정 재시도 수렴과 다른 내용 거절, 미리보기 뒤 지출 추가 시 `stale_revision`(새 변경 목록 포함), 확인 필요 `pending_review`, 서로 다른 확정 요청 동시 실행은 하나만 커밋, 스냅숏 해시·독립 재계산 일치, 확정 뒤 쓰기 거절과 기존 요청 재시도 수렴, 확정 행 소유자 수정 불가, 기존 사본 올리기 RPC의 비구성원·확정 방 거절. `supabase db advisors`: 보안 경고 없음(정보성: 쓰이지 않은 색인, 의도적으로 정책 없는 `trip_invites`·`settlement_requests`).

기존 흐름 회귀(같은 날, 이 슬라이스의 코드로): `ios:e2e-upload`(새 시뮬레이터)·`android:e2e-upload` 통과, `ios:e2e-local`·`android:e2e-local` 통과(시드 정산 방 때문에 `local-backend.py report`는 초대로 참여한 방만 센다). `ios:e2e-review`는 UI 단계 14개가 모두 통과했고, 마지막 서버 수신 검사만 지출 열 허용 목록이 새 정산 열을 몰라 실패해 목록을 고친 뒤 같은 실행의 서버 사본·보고로 다시 검사해 통과했다(처음부터 다시 돌리지는 않았다). `android:e2e-review`(접히는 기기)는 처음 네 번 통과시키지 못했고(그중 셋은 펼친 채 시작한 설정 실수), 원인을 따로 조사해 앱을 고친 뒤 통과했다(아래 "Android 검토 화면: 자판이 입력 칸을 가림").

단위 테스트: iOS(공통 예제 몫 제안, 원화·몫 검사, 실패 매핑, 직접 입력 요청 키가 Android와 같은 값), Android(같은 항목), 가져오기 패키지(직접 입력은 사본 경계로 나가지 않고 허용 필드만 따로 나간다). 화면: `docs/design/screens/*-settlement-*.png`.

### Android 검토 화면: 자판이 입력 칸을 가림 (2026-11-24 조사·수정)

- **증상**: 접은 바깥 화면(1080×2424)에서 검토 화면의 아래쪽 입력 칸(가게·금액)을 누르면, 자판이 올라오면서 위로 함께 올라간 "확인하고 다음" 막대 뒤에 그 칸이 가려진 채 남았다. 사용자는 치는 글자를 볼 수 없고, UI Automator는 가려진 칸을 트리에서 빼서 `android:e2e-review`의 글자 입력 단계가 간헐적으로(누르기 전 칸의 위치에 따라) 멈췄다.
- **원인(앱)**: 확인 막대는 `imePadding`으로 자판 위에 붙고 Scaffold가 그 높이를 아래 여백으로 넘기는데, 목록은 그것을 `contentPadding`(안쪽 여백)으로만 써서 보이는 영역 크기가 그대로였다. 스크롤 컨테이너는 자기 영역이 줄 때 포커스된 칸을 보이는 곳으로 옮기므로, 안쪽 여백만 늘어나는 경우에는 옮기지 않는다.
- **판정 근거**: 실패 순간의 상태를 남겼다(바깥 화면 캡처: Gboard가 떠 있고 제안 줄에 직전 입력이 보이며 칸은 막대 뒤, `dumpsys input_method` `mInputShown=true`, 포커스 창은 앱, 기기 자세 CLOSED, 트리에 `review_merchant` 없음). 같은 기기 상태에서 알려진 기준 f0f2cad 빌드(격리한 Orca 워크트리에서 빌드)도 같은 순서(SIGKILL → 런처로 다시 열기 → 목록에서 사진 열기 → 가게 이름 입력)의 첫 반복에서 똑같이 가려져 실패했다. 이 슬라이스의 회귀가 아니라 원래 있던 배치 결함이고, 하네스·자판 문제가 아니다.
- **수정**: 검토 목록이 Scaffold의 아래 여백을 보이는 영역 자체의 여백(`Modifier.padding`)으로 쓴다(`ReceiptReviewUi.kt`). 자판이 올라오면 영역이 줄고 포커스된 칸이 막대 위로 옮겨진다. 하네스와 단언은 바꾸지 않았다.
- **확인**: 같은 반복 순서 10회 모두 통과(수정 전 HEAD는 2회째, f0f2cad는 1회째 실패). 수정 뒤 `android:e2e-review` 전체(새로 설치, 접은 채 시작, 서버 수신 사본·필드·가림 검사 포함) 통과.

### 독립 검토 반영 (2026-11-24)

- 확정된 방에 처음 참여하는 초대 수락을 거절한다(`trip_finalized`, 잠금 뒤 쓰기 전). 계약 시험에 순차(거절, 재시도도 같음, 확정 전에 참여한 계정의 재시도 수렴)와 잠금으로 순서를 정한 두 순서(확정 먼저 → 참여 거절·확정본에 참여자 없음, 참여 먼저 → 확정 `stale_revision`·방 열림)를 더했다: 85/85, 가드를 빼면 5개 실패. 앱은 `roomFinalized`로 보인다(매핑·JoinFlow 단위 테스트, 기기 화면은 확인하지 않음).
- 검토 입력을 연 지출 버전에 묶었다(위 ADR-0006). 두 플랫폼 단위 테스트(편집 중 새 버전 도착, 서버만 새 버전, 다시 열기, 연결 실패 재시도의 같은 요청 키). 예전 동작으로 되돌리면 실패한다.
- Android 로컬 구현체가 검토 성공 응답의 본문이 깨졌거나 객체가 아니면 `Unknown`으로 옮기고, 검토 상태는 같은 요청 키로 다시 보낼 수 있는 실패로 남는다(루프백 HTTP 단위 테스트).
- 다시 돌린 것: 단위 테스트 iOS 37·Android 58, 정산 E2E 두 방향(새 시뮬레이터 + 폰 에뮬레이터, 둘 다 통과), `ios:e2e-local`·`android:e2e-local` 통과, ktlint·swift-format·Android lint(기존 경고만)·두 앱 release 빌드. 정산 E2E는 화면 캡처가 디스플레이를 고르지 않아 접히는 기기 에뮬레이터에서는 돌지 않는다(폰 에뮬레이터용).

### 저장 중 다시 열기 (2026-11-24, 후속 검토 P2)

- **문제**: 검토 저장이 응답을 기다리는 동안 뒤로 갔다가(장부를 새로 읽은 뒤) 같은 지출을 다시 열면, 다시 열기가 저장 중 상태와 보낸 요청을 지우고 입력을 새 버전으로 다시 채워 두 번째 저장을 보낼 수 있었다. 그 뒤 늦게 온 첫 응답이 새 입력을 지우고 화면을 닫을 수 있었다.
- **수정**(iOS `RoomModel`, Android `RoomController`): 지출마다 응답을 기다리는 작업 하나(바뀌지 않는 요청 + 작업 ID)를 둔다. 작업이 있는 동안 다시 열기는 같은 작업에 붙어 저장 중 상태·입력을 그대로 보이고, 새로고침은 그 입력을 다시 채우지 않으며, 고치기·보내기는 막힌다. 응답은 작업 ID가 같을 때만 반영하고, 보낸 버전에서 연 입력만 지우며, 그 지출의 화면만 닫는다. 연결 실패 뒤 다시 보내기는 같은 요청 키·연 버전이고, 다른 기기 변경으로 거절되면(`stale`) 입력을 최신 버전으로 다시 채우고 알리는 동작은 그대로다.
- **확인**: 두 앱에 게이트웨이를 멈춰 두는 같은 시나리오 5개(저장 → 뒤로 → 새 장부 → 다시 열기 → 두 번째 요청 없음 → 응답 → 닫힘·요청 1번 / 다른 지출을 고치는 중 앞 응답 → 그 화면·입력 그대로 / 두 지출 응답을 거꾸로 / 새로고침 뒤 연결 실패 → 같은 키로 다시 보내기 / 다시 연 뒤 stale → 다시 채우고 알림). iOS 42·Android 63 단위 테스트 통과. 고치기 전 코드로 되돌리면 두 앱 모두 첫 시나리오가 실패한다(iOS는 두 번째 요청이 풀리지 않아 시간 제한까지 기다림). 나머지 넷은 고치기 전에도 통과하던 동작을 지키는 검사다. 기기 E2E로는 확인하지 않았다(화면에서 응답을 멈춰 두는 방법이 없다).

### 방장 검토 화면에서 가린 사본 보기 (2026-11-24)

결정은 [ADR-0006](../docs/adr/0006-room-settlement.md)의 "방장은 검토 화면에서 공유한 가림 사본만 본다".

- 검토 화면의 "증빙" 칸: 사본으로 올린 지출은 "가린 사본 보기"를 눌러 연다(자동으로 받지 않는다). 받은 사본, "올린 사본과 같아요 · 확인 <해시 앞 8자리>", "사본 닫기". 직접 입력은 "증빙 없음 · 직접 입력이라 사진이 없어요." 실패는 권한 없음·찾을 수 없음(저장소가 둘을 구분하지 않음)·받은 사본이 다름·연결·일시 장애로 나눠 보이고 모두 "다시 시도"가 있다. 사본 칸은 결제자·원화·부담 입력과 따로 돌아 검토를 막지 않는다.
- 경계: `TripGateway.maskedReceipt(ReceiptArtifactRef, in: TripID)`(장부가 준 경로·해시). 로컬 구현체는 경로가 지금 여행방의 `<여행방>/<올린 사람>/<요청 키>.png`인지 먼저 보고, 비공개 버킷을 인증 다운로드(`/storage/v1/object/authenticated/receipts/…`)로 받은 뒤 PNG 서명과 SHA-256이 장부와 같을 때만 돌려준다. iOS는 임시 세션에 로컬 캐시 무시, Android는 `useCaches = false`. 받은 바이트는 화면 상태(메모리)에만 있고, 검토 화면을 떠나거나(다른 지출 포함) 세션이 끝나거나 연 여행방이 바뀌면 지운다. 받는 중에 지우면 늦게 온 응답을 버린다.
- 서버: 새 마이그레이션 `20261124120000_ledger_receipt_artifact.sql`이 장부 응답에만 `artifact_path`·`artifact_sha256`을 더한다(구성원은 이미 RLS로 읽던 값). 확정본 스냅숏 모양, 올리기·정산 규칙, Storage 정책은 그대로다.

확인한 것:
- 정산 E2E 두 방향 통과(A: Android 방장·폰 에뮬레이터 API 36, iOS 회원·iPhone 18 Pro / B: iOS 방장·iPhone 18 Pro Max, Android 회원). 방장 검토 뒤 스크립트가 관리 키로 Storage의 실제 객체를 받아 해시를 구하고 장부 해시와 같음을 확인한다(A `b36a5e8e…` 66,131바이트, B `915e7e33…` 67,942바이트, `receipt-artifact.json`). 방장 기기 화면의 확인 문구가 그 해시 앞 8자리와 같고(앱이 받은 바이트의 해시), 사본 이미지 접근성 이름은 "가린 영수증 사본"이다. 뒤로 갔다 다시 열면 사본이 없고 다시 눌러야 받는다. 직접 입력은 증빙 없음. API 게이트웨이를 멈추면 연결 실패와 "다시 시도"가 보이고 결제자 고르기는 그대로 된다. 다시 켜고 다시 시도하면 같은 사본. 큰 글자(iOS 접근성 최대, Android 글꼴 2.0)와 가로(iOS Pro Max는 목록 옆 상세, Android 폰은 장부 옆 검토 두 칸)에서도 같은 확인 문구. 사본 보기 전후 방 revision이 같다(아무것도 쓰지 않음). 이어서 기존 미리보기·확정·다시 열기 단계와 비구성원 검사(`outsider-check`)도 통과.
- 서버 계약 시험 96/96: 장부의 경로가 그 여행방 경로이고 해시가 올린 바이트와 같음, 방장 인증 다운로드가 올린 바이트와 정확히 같음, 비구성원·익명·공개 URL은 거절, 직접 입력은 경로·해시 없음.
- 단위 테스트 iOS 50·Android 70: 경로 범위(다른 여행방·`..`·확장자·덧붙인 경로 거절), PNG·해시 검사, Storage 실패 매핑, 받기·닫기, 직접 입력은 요청 없음, 화면을 떠나면 지우고 늦은 응답은 버림, 세션·여행방 바뀜에 모두 지움, 실패 뒤 다시 시도와 검토 입력 그대로.
- 기존 E2E의 iOS H1 단계는 새 "증빙" 칸 때문에 아래로 밀린 검토 조작을 스크롤해 찾도록 고쳤다(단언은 같음). 넓은 창에서 목록이 둘일 때 검토 목록을 넘기게 했다.

확인하지 않은 것: 권한 거절 화면은 기기에서 재현하지 않았다(방장은 언제나 구성원이다). 비구성원 거절은 계약 시험과 `outsider-check`, 토큰이 유효한 `AccessDenied` → 권한 없음과 세션 복구는 HTTP 경계 시험(아래)으로만 확인했다. 해시가 다른 사본, 그림으로 풀리지 않는 사본, 받는 중 계정·여행방·세션이 바뀌는 경우는 단위 시험으로만 확인했다. 접히는 기기(정산 E2E가 두 디스플레이에서 화면을 찍지 못함), 다크 모드, 실기기는 보지 않았다. 회원은 이 화면이 없어 사본을 보지 못한다(검토 화면이 방장 전용).

#### 독립 검토 반영 (2026-11-24)

- **Storage 세션 복구(두 앱 같은 규칙)**: 로컬 Storage는 잘못된 토큰과 만료된 토큰을 정책 거절과 같은 400 `AccessDenied`로 알린다(로컬 스택에서 직접 확인: 만료 토큰 `"exp" claim timestamp check failed`, 같은 토큰에 Auth `/auth/v1/user`는 403 `bad_jwt`). 그래서 `AccessDenied`를 받으면 같은 연결로 Auth에 지금 토큰을 묻는다. Auth가 받으면 진짜 거절(권한 없음), 거절하면 한 번 갱신해 다시 받고, 닿지 않으면 연결 실패다. `InvalidJWT`는 묻지 않고 한 번 갱신해 다시 받는다. 갱신은 많아야 한 번이고, 갱신 뒤에도 토큰 거절이거나 갱신이 거절되면 세션 만료로 끝나 앱이 세션을 지운다(다시 로그인한 뒤 다시 시도). 공개·서명 URL로 대신 받지 않는다. 시험: iOS는 실제 URLSession 아래 URLProtocol, Android는 루프백 HTTP 서버로 같은 8가지(InvalidJWT 한 번 갱신 뒤 성공·두 번이면 만료, AccessDenied+Auth 200 → 권한 없음·갱신 없음, AccessDenied+Auth 403 → 갱신 한 번 뒤 성공, 갱신 거절 → 만료, 두 번 거절이면 갱신 한 번에서 멈춤, Auth 닿지 않음 → 연결 실패, NoSuchKey → 묻지도 갱신하지도 않음, 모든 Storage 요청이 인증 경로)를 본다.
- **그림으로 끝까지 풀리는 사본만 보인다**: 해시가 맞은 뒤에도 PNG 구조(서명, IHDR로 시작·IEND로 끝, 청크 길이·CRC, IDAT를 이어 풀었을 때 IHDR 크기와 정확히 같음)를 보고 플랫폼 디코더(iOS ImageIO, Android BitmapFactory)가 그림을 만들 때만 "보임"이 된다. 아니면 다시 시도할 수 있는 "사본 그림을 열 수 없어요". iOS ImageIO는 잘린 PNG도 그림을 만들어(로그만 남김) 구조 검사 없이 잘린 사본이 보였다는 것을 시험이 먼저 보여 줬다. 화면은 받은 바이트를 다시 풀지 않고 검사 때 만든 그림을 그린다. 바이트와 그림은 여전히 메모리에만 있다. 시험: 실제 가상 영수증 PNG(720×746)는 통과, 앞 절반만 남긴 PNG·서명+IHDR만·CRC가 틀린 PNG는 거절, 잘린 사본을 받으면 실패 뒤 다시 시도로 실제 사본. Android JVM 시험은 BitmapFactory 대신 JVM PNG 디코더(ImageIO)를 꽂는다. Android 기기의 BitmapFactory 경로는 정산 E2E로만 본다.
- **계정·여행방·세션에 묶기**: 사본은 받기 시작할 때 지금 로그인한 계정과 연 여행방이 그 지출의 여행방일 때만 받고, 응답이 오면 그 맥락이 그대로인지 다시 본다. 바뀌었으면 보이지 않고 받는 중 표시도 걷는다(지우기가 아직 돌지 않았어도). 앱은 다른 계정으로 로그인·세션 종료·다른 여행방 열기에 연 사본을 모두 지운다(iOS `session`·`room` 바뀜, Android 상태 흐름 수집). 시험: iOS는 실제 `AppModel`로 받는 중 다른 계정 로그인·다른 여행방 열기·세션 만료를 지나 늦게 온 응답이 보이지 않음, 두 앱 모델 단위로 맥락 셋(계정·여행방·로그아웃) 바뀜 뒤 늦은 응답, 맞지 않는 맥락이면 요청하지 않음. Android `AppViewModel`의 상태 흐름 수집 자체는 JVM에서 돌릴 수 없어 확인하지 않았다(맥락 재확인이 수집을 기다리지 않는다).
- **저장 뒤 장부 다시 읽기 경쟁**: 저장이 끝나면 장부를 다시 읽기 **전에** 그 지출의 검토 화면을 닫는다. 읽는 동안 같은 지출을 다시 열면 그 화면은 닫히지 않는다. 서버가 알려 준 새 버전을 기억해 장부가 그 버전으로 오면 입력을 조용히 새로 채우고(이 기기가 저장한 것이라 "다른 변경" 알림 없음), 다른 기기가 그 뒤 바꾼 버전이면 알린다. 시험(두 앱): 장부 요청을 멈춰 둔 채 저장 완료 → 화면이 닫힘 → 같은 지출 다시 열기 → 장부를 풀어도 화면이 남고 입력은 새 버전·알림 없음·요청 1번, 다른 지출을 연 경우 그 입력 그대로, 그 뒤 다른 변경(버전 3)은 알림.
- 각 수정을 되돌리면 새 시험이 실패한다(Android: 닫기를 새로고침 뒤로, 맥락 재확인 제거, Auth 묻기 제거, 저장 버전 알림 끄기 각각. iOS: 닫기를 새로고침 뒤로, Auth 묻기 제거).
- 정산 E2E 두 방향 다시 통과(새 시뮬레이터: B iOS 방장 iPhone 18 Pro Max가 Android가 만든 사본 `915e7e33…` 67,942바이트를, A Android 방장 폰 에뮬레이터가 iOS가 만든 사본 `b36a5e8e…` 66,131바이트를 구조 검사·플랫폼 디코더로 풀어 보임, 확인 해시 = 저장된 객체 해시, 다시 열면 지워짐, 연결 실패·다시 시도, 큰 글자·가로, 보기 전후 revision 같음, 이어서 확정·다시 열기·비구성원 검사). 실제 앱 사본이 구조 검사를 통과한다는 것은 이 두 실행으로만 확인했다. 세션 복구·맥락 전환·저장 뒤 경쟁은 기기에서 재현하지 않았다(위 시험으로만).

### 확인하지 않은 것

- 미리보기 뒤의 늦은 지출은 스크립트가 가상 회원 계정으로 앱과 같은 RPC(`submit_manual_expense`)를 불러 넣었다. 회원 기기 화면으로 넣은 것은 아니다.
- 화면으로 확인한 거절은 "오래된 revision으로 확정"뿐이다. 같은 지출을 두 방장 화면이 동시에 검토하는 경우(`stale_expense`), 두 확정 요청 동시 실행, 같은 키 재시도(`replayed`)·다른 내용(`idempotency_conflict`), 회원의 검토·확정 시도(`host_only`), 비구성원 접근은 서버 계약 시험(실제 HTTP)으로만 확인했다. 앱이 검토 거절 뒤 최신 값으로 다시 여는 화면, 응답을 못 받은 검토·확정을 같은 키로 다시 보내는 경로, 정산 중 세션 만료는 기기에서 재현하지 않았다.
- 새 화면(장부·검토·송금표)의 접히는 기기 두 칸·세 칸과 다크 모드는 확인하지 않았다. 가로·큰 글자는 검토 화면의 사본 칸만 확인했다(위 "가린 사본 보기").
여행방 화면에서 사진 없는 지출을 새로 적는 입력, 품목별 나누기, 세 명 이상의 "반씩", 실시간 갱신(새로고침·다시 열기만)은 없다.
- 확정 뒤 다시 열기는 두 앱 프로세스를 SIGKILL한 뒤 같은 세션으로 다시 연 경우만이다. 다른 기기 로그인, 재설치는 확인하지 않았다.
- 가게 이름은 기기 OCR 값 그대로 올라간다(Android ML Kit은 みなと珈琲를 みなと迦芽로 읽었다). 그래서 E2E는 지출을 금액으로 찾는다.
- 테스트 모드(로컬 설정 없는 debug)에는 장부가 없고, release는 계속 연결 전 구현체다.

## 창 크기와 접기 (적응형 화면)

기기 모델이 아니라 지금 창의 크기 종류·크기, 안전 영역, 시스템이 알려 주는 접힘으로 배치한다([ADR-0004](../docs/adr/0004-adaptive-layout.md), 크기별 기대치는 [디자인 기준](../docs/design/mobile-foundations.md#창-크기와-접기)). iOS는 세로·가로(양쪽)를 모두 지원한다(예전에는 세로 고정).

- **목록·상세**: 홈이 목록, 초안·초대·여행방이 상세다. iOS `NavigationSplitView`(`.balanced`, 목록 숨기기 버튼 없음)는 가로 크기 종류가 regular이면 두 열, 아니면 한 화면씩 쌓는다. Android는 `NavDisplay`에 `ListDetailSceneStrategy`(material3-adaptive 1.3.0)를 주어 폭 840dp 이상이면 두 칸, 아니면 한 칸이다. 세로 separating hinge가 창을 나누면 폭과 상관없이 두 칸이고, 두 칸은 hinge 양쪽에 놓인다(`rememberPaneDirective`). 넓은 창에서 목록에서 고르면 상세를 바꾸고(쌓지 않음), 상세에는 뒤로 가기 화살표가 없다.
- **읽기 폭·접힘 피하기**: 글 위주 목록·화면·시트는 넓은 창에서 640(pt·dp)으로 가운데에 둔다(iOS `adaptiveContentMargins`, Android `Modifier.readableWidth`). iOS 스크롤 여백은 `ReservedRegion` division 세로 접힘을 넓은 쪽으로 피하고, Android 로그인 시트·최종 확인은 hinge 넓은 쪽으로 옮긴다. 둘 다 같은 순수 함수 `ContentMargins.fitting`(두 앱 단위 테스트가 같은 경우를 본다)을 쓴다. 이 규칙은 `Design/Theme.swift`, `design/AdaptiveLayout.kt` 한 곳에 있다.
- **상태**: 지금 화면(안정 ID), 처리기·처리 상태, 올리기 상태, 최종 확인(초안·여행방 ID·이름·장수), 로그인·참여 상태는 모델(iOS `AppModel`, Android `AppViewModel`)에 있어 창이 바뀌어도 남는다. 처리기를 다시 만들지 않으므로 OCR·올리기가 다시 시작되지 않는다. 최종 확인은 사용자가 본 값으로 올리고, 그사이 올릴 곳이 바뀌었으면 올리지 않는다(초대 링크를 새로 열면 확인을 닫는다).
- **최종 확인 창**: 로그인 시트처럼 화면 맨 위(`RootView`, `NonanonaApp`)에서 한 번만 띄운다. iOS는 가운데 알림이다(예전의 행 안 확인 시트는 넓은 창에서 버튼을 가리키는 팝오버가 되어, 열린 채 회전하면 다시 뜨지 못하고 앱이 쉬지 못하는 상태로 멈췄다. Pro Max 시뮬레이터에서 재현).

### 확인한 것 (2026-11-21, 가상 영수증 r01–r03)

| 확인 | iOS | Android |
| --- | --- | --- |
| 단위 테스트 | `ContentMargins` 5건(좁은 창, 읽기 폭, 세로 접힘 한쪽·같으면 앞쪽, 창 밖 접힘, 가로 접힘). 처리 중 장면 다시 활성화 5번 → OCR 2번·시도 `[1,1]`·선택 유지. 최종 확인이 올릴 곳을 지키고 한 번만 올림, 올릴 곳이 바뀐 뒤의 예전 확인은 올리지 않음. 실제 창에 띄운 분할 보기를 669×951(regular) → 466×678(compact) → 951×669(regular) → 320×951(compact)로 바꿔도 접힘·펼침이 따라가고 선택 유지 | `ContentMargins` 6건(iOS와 같은 경우 + 폭 0인 hinge) |
| E2E 기기 | iPhone 18 Pro Max(가로 regular), iPhone Duo 바깥 화면(466×678pt, iPhone Duo 런타임 iOS 27.2 24B91016s), iPhone 18 Pro(iOS 27.2) 시뮬레이터. 세 기기 모두 A1–A4 통과. 새 iPhone Duo 시뮬레이터에서 `ios:e2e-posture`(A1, P2, P3) 통과 | Pixel 9 Pro Fold 프로필 에뮬레이터(API 36, 안쪽 2076×2152px·바깥 1080×2424px, hinge x=1038px) |
| 읽는 중 배치 바꾸기 | 세로 → 가로 → 세로: 같은 초안(사진 2장)·처리 상태. Pro Max 가로에서만 목록과 초안이 나란히. iPhone Duo 시뮬레이터 자세(아래 "iPhone Duo 자세"): folded(466×678, 한 화면, 읽음 0/2) → book(951×669, 목록 0–455.7·초안 495.7–) → flat(951×669, 목록 0–320·초안 320–) → folded: 같은 초안·읽음 0/2, 모두 읽은 뒤 확인 | 펼침(두 칸, 읽음 0/2) → 접기(바깥 화면 한 칸, 같은 초안 0/2) → 펴기(두 칸) → 반쯤 접기(목록 0–1038, 상세 1097–2076) |
| 중복 OCR | 디스크의 사진별 시도 `[1,1]`, `[1]`(회전, Duo 자세 변경 모두) | 같음 |
| 접힘 피하기 | Duo book(`partiallyOpen`): 시스템이 활성 division(455.5–495.5)을 알리고 분할 보기 열과 최종 확인 알림(97.7–371.7)을 그 밖에 둔다. 처리 요약·사진 상태도 밖. Duo flat(`fullyOpen`): division이 비활성이라 열·알림이 가운데에 걸치는 것이 정상(아래) | 반쯤 접은 채 로그인 시트 (0–1038), 최종 확인 제목·버튼 (577–920)이 hinge 한쪽 |
| 최종 확인 유지 | 열린 채 가로 → 세로: 같은 문장, 누를 수 있음 → 올림 1장(이미 올린 0장 포함). Duo 열린 채 folded → book → flat → folded: 같은 문장, 누를 수 있음 → 올림 1장(이미 올린 0장 포함) | 열린 채 접기 → 펴기: 같은 문장 → 올림 1장(이미 올린 0장 포함) |
| 큰 글자 + 가로 | `accessibility-extra-large`: 초안 마지막 행, 로그인 시트 버튼까지 스크롤로 닿고 다시 로그인 | `font_scale 2.0`: 같음 |
| 낮고 좁은 창 | 단위 테스트의 320×951 compact | `wm size 1300x1000`(533×410dp): 한 칸, 마지막 행까지 스크롤 |
| 기존 흐름 회귀(바뀐 내비게이션·최종 확인) | `ios:e2e`, `ios:e2e-upload`(로컬 Supabase, 서버 객체·지출 1/1, 가림 사본 검사, 비구성원 차단) 통과. 단위 테스트, `ios:build`, `ios:release-check` 통과 | `android:e2e`, `android:e2e-receipts`, `android:e2e-local`, `android:e2e-upload`(같은 서버 검사) 통과(폰 에뮬레이터). 단위 테스트, lint(오류 0), release APK에 INTERNET·로컬·테스트·개발용 올리기 클래스 0 |

```sh
mise run ios:e2e-adaptive -- <시뮬레이터 UDID> [증거 폴더]       # 가로가 regular인 기기는 EXPECT_WIDE_LANDSCAPE=1
mise run ios:e2e-posture -- <iPhone Duo 시뮬레이터 UDID> [증거 폴더]  # Device Hub 자세 버튼을 누른다(아래)
mise run android:e2e-adaptive -- [증거 폴더]                    # 접히는 기기 에뮬레이터(emu fold/unfold/posture)
```

접히는 기기 에뮬레이터는 설치된 시스템 이미지로 만든다: `avdmanager create avd -n Nonanona_Fold -k "system-images;android-36;google_apis;arm64-v8a" -d pixel_9_pro_fold`. iOS iPhone Duo 시뮬레이터는 iPhone Duo 전용 런타임으로 만든다: `xcrun simctl create "Nonanona Duo" com.apple.CoreSimulator.SimDeviceType.iPhone-Duo com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4`. 같은 시뮬레이터에서 E2E를 여러 번 돌리면 사진 앱에 가상 영수증이 겹쳐 쌓여 공유 단계가 흔들린다. 새 시뮬레이터에서 돌린다.

### iPhone Duo 자세 (2026-11-23, 시뮬레이터)

`ios:e2e-posture`는 Xcode Device Hub 아래쪽 자세 버튼을 Orca Computer Use(`orca computer click --restore-window`)로 누른다. 자세는 `simctl`·XCTest로 바꿀 수 없다. 테스트가 신호 파일로 자세 변경을 부탁하고 스크립트가 누른 뒤 다음 단계로 간다. 사전 조건: 새 Duo 시뮬레이터를 Device Hub 창(1100×800pt, 버튼 좌표가 이 크기에 맞음)에 접은 채 띄우고, `orca computer permissions`에서 손쉬운 사용·화면 기록 허용. 누를 때마다 Device Hub를 앞으로 가져오므로 그동안 다른 창을 쓰면 클릭이 `window_not_focused`로 거절된다(스크립트가 다섯 번까지 다시 누르고, 그래도 안 되면 테스트가 실패한다). 백그라운드 클릭(창을 앞으로 가져오지 않음)으로는 Device Hub의 시뮬레이터 목록 선택이 바뀌지 않아 앞으로 가져와 누른다.

자세 버튼은 접근성 이름이 없어 Device Hub가 그리는 기기 모양으로 부르고, 실제 자세는 앱이 받은 시스템 hinge 상태로 확인했다(DEBUG 빌드의 `UIHingeInteraction` 로그, `Testing/DebugPostureLog.swift`. Apple 문서대로 hinge 값은 배치에 쓰지 않는다): **folded**(첫 번째 버튼) = `closed` 0°, 바깥 화면 466×678pt. **book**(두 번째, 접힘에서 꺾인 그림) = `partiallyOpen` 133.8°. **flat**(세 번째, 평평한 그림) = `fullyOpen` 180°. 두 안쪽 자세 모두 창은 951×669pt(가로 regular)다. 같은 DEBUG 빌드가 화면마다 division 예약 영역을 비활성 것까지(`includeInactive`) 남기고, 스크립트가 자세마다 누른 뒤의 마지막 값(안정된 값)을 `ios-posture-settled.txt`로 모은다.

| 자세 | 안정된 division(누르고 약 1–4초 뒤, 다음 누름까지 그대로) | 배치(창 좌표 pt) |
| --- | --- | --- |
| folded | 없음 | 한 화면. 처리 요약 x 20–80, 최종 확인 올리기 버튼 195–335 |
| book | 세로 455.5–495.5(폭 40) **활성**. 목록 열이 알림, 초안 열(495.7–)은 겹치지 않아 알리지 않음 | 목록 0–455.7, 초안 495.7–. 처리 요약 515.7–575.7, 사진 상태 587.7–638.3. 최종 확인 알림은 왼쪽 칸(제목 97.7–357.7, 올리기 231.7–371.7). 모두 division 밖(테스트가 확인) |
| flat | 같은 자리 455.5–495.5 **비활성**(`active=false`). 전환 중 잠깐 활성으로 알린 뒤 비활성이 된다 | 열이 기본 폭: 목록 0–320, 초안 320–867. 사진 상태 412–463, 가운데 최종 확인 알림(제목 303.7–563.7, 올리기 437.7–577.7)이 그 자리에 걸침(기록만) |

**flat의 겹침은 정상 동작이다.** Apple 문서: "A division is active only when the device is partially open or closed. When iPhone Duo is fully open, the division is inactive"([ReservedRegion](https://developer.apple.com/documentation/swiftui/reservedregion)), "the fold of iPhone Duo is active when the device is partially open, and inactive when it's fully open"([isActive](https://developer.apple.com/documentation/swiftui/reservedregion/isactive)), HIG "When the device is partially open, the folding region divides the inner display"([Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo), 확인일 2026-11-23). flat은 시스템이 `fullyOpen`으로 알린 자세이고, division은 남은 값이 아니라 안정된 비활성 값이며, 시스템 분할 보기·알림도 피하지 않는다. 그래서 앱 여백(`ContentMargins`, 활성 division만 피함)과 E2E(book에서만 division 밖을 단정, flat은 기록)를 바꾸지 않았다.

증거는 실행마다 증거 폴더에 남는다: 테스트 로그(창·요소 좌표), `ios-layout-reserved.log`(hinge·division 원본), `ios-posture-settled.txt`, Device Hub 창과 두 화면의 `simctl io --display` 사진(`device-hub/`). XCTest 화면 기록(`XCUIScreen.main`, `app.screenshot()`)은 바깥 화면만 찍어 안쪽 자세에서는 검은 화면이므로 안쪽 화면 사진은 스크립트가 찍는다. 스크립트는 누를 때만 Device Hub를 앞으로 가져오고 1초 뒤 원래 앞에 있던 앱을 되돌린다.

**증거 공백**: 위 자세 결과는 시뮬레이터다(Device Hub 버튼 세 개의 고정 각도 0°·133.8°·180°). 실제 iPhone Duo 하드웨어의 hinge 센서, 그 사이 각도, 노트북처럼 가로로 접은 자세(가로 division)는 확인하지 않았다. 2026-11-22에는 Orca Computer Use가 Device Hub에 `permission_denied`를 받아 막혔고, 2026-11-23에 권한이 맞춰진 뒤 위처럼 확인했다(권한 설정은 이 작업에서 바꾸지 않았다). Duo 자세 E2E는 큰 글자·로그인 시트를 다루지 않는다(큰 글자 + 가로는 `ios:e2e-adaptive`). 실기기, 태블릿, Android 실제 두 앱 분할 화면, 데스크톱 창은 확인하지 않았다. 입력 칸은 아직 없어 키보드가 가리는 경우는 해당이 없다.

## 로컬 Supabase 모드 (debug 전용)

debug 앱의 정상 진입 경로(공유, 초대 링크, 로그인 시트)를 그대로 두고, 인증·여행방 경계만 로컬 Supabase 스택에 실제 HTTP로 붙인다. SDK 없이 플랫폼 HTTP(iOS `URLSession`, Android `HttpURLConnection`)만 쓴다.

- **서버**: 저장소 루트 `supabase/`. `config.toml`은 Auth + Postgres + Data API만 켜고(Studio·Realtime·Storage·Edge·분석 끔), 가입은 막고(`enable_signup = false`), 토큰 수명을 30초로 짧게 둬 갱신과 세션 만료가 실제로 일어나게 한다. `migrations/…_trip_invites.sql`은 local-collaboration 실험의 여행방·구성원·초대와 `accept_invite` RPC만 옮겼다(쓰기는 RPC로만, `SECURITY DEFINER` 본문은 노출되지 않는 `private` 스키마, `auth.uid()` 검사, 테이블은 구성원 SELECT만). `supabase db advisors`: 문제 없음.
- **가상 자료**: `scripts/local-backend.py`가 Auth 관리자 API로 가상 계정 둘(방장 다라, 회원 가나, `@example.com`)을 매번 새 무작위 비밀번호로 만들고 `supabase/fixtures/local-trip-invites.sql`로 여행방 셋과 초대 다섯(정상·반복 `SYNTHLOCAL0001`, 만료 `SYNTHLOCALEXPIRED`, 취소 `SYNTHLOCALREVOKED`, 다시 시도 `SYNTHLOCALRETRY`, 다시 로그인 `SYNTHLOCALRELOG`)을 넣는다. 초대는 해시만 저장한다.
- **앱 설정**: 같은 스크립트가 gitignore된 `apps/android/local-backend.properties`, `apps/ios/Config/Local.xcconfig`를 권한 600으로 쓴다(로컬 주소, 로컬 publishable key, 가상 회원 계정). 이 파일이 있으면 debug 빌드가 로컬 모드가 되고, 지우면(`mise run local:down`) 테스트 구현체로 돌아간다. 테스트 모드 E2E는 파일이 있어도 `NONANONA_BACKEND=test`(iOS), `-Pnonanona.backend=test`(Android)로 테스트 구현체를 강제한다. 앱은 루프백 주소(iOS `127.0.0.1`, Android 에뮬레이터의 `10.0.2.2`)만 받아들이고 경로는 고정이다.
- **로그인**: 로그인 시트의 Apple·Google 버튼이 실제 소셜 로그인 대신 가상 회원 계정으로 비밀번호 로그인한다(`/auth/v1/token?grant_type=password`). 세션은 앱 전용 파일에 두고 만료 5초 전부터 갱신한다(`grant_type=refresh_token`, 회전). Data API가 JWT를 거절하면(`PGRST301`·`PGRST303`) 한 번 갱신하고 다시 부른다.
- **키와 비밀번호**: 화면·로그·보고에 내지 않는다. CLI 출력은 `supabase/.run/`(gitignore, 권한 700)에만 쌓고, 스크립트는 키 이름만 확인한다. CLI 사용 통계는 `mise.toml`의 `SUPABASE_TELEMETRY_DISABLED=1`로 이 저장소에서 끈다.

서버 결과 → 기능 실패(서버가 정한 코드와 정확히 같을 때만 옮기고 나머지는 `unknown`. 사람이 읽는 메시지는 보지 않는다):

| 서버 결과(로컬 스택에서 실제로 받은 값) | 실패 |
| --- | --- |
| Data API `PT410` + `invite_expired` | `inviteExpired` |
| `PT410` + `invite_revoked`·`invite_used`, `PT404` + `invite_invalid` | `inviteInvalid` |
| 갱신 거절 Auth `error_code`(`refresh_token_not_found`, `refresh_token_already_used`, `session_not_found`, `session_expired`, `user_not_found`, `user_banned`), 갱신 뒤에도 401, `not_authenticated` | `sessionExpired` |
| 429, 5xx | `unavailable` |
| 연결 실패·시간 초과 | `network` |
| 로그인 429·`over_request_rate_limit`·5xx / 연결 실패 / 그 밖(`invalid_credentials` 등) | `unavailable` / `network` / `unknown` |

같은 계정이 같은 초대를 다시 수락하면 서버가 초대를 새로 소비하지 않고 같은 여행방을 돌려준다(`replayed`).

### 실행 (사전 조건: Docker 실행 중, `mise install`로 Supabase CLI 3.1.0)

```sh
mise run local:up                                   # 스택 시작 → 가상 계정·여행방·초대 → 앱 설정 파일
mise run ios:e2e-local -- <시뮬레이터 UDID> [증거 폴더]  # 매번 local:reset부터 한다
mise run android:e2e-local -- [증거 폴더]             # local:reset → 로컬 모드 debug 빌드 → E2E
mise run local:down                                 # 스택 정지, 앱 설정 파일 삭제
```

두 E2E는 같은 순서를 밟는다: 공유로 초안 → 초대 링크 → 로컬 가상 계정 로그인 → 실제 수락("가상 오사카 여행", 방장 다라 + 나 가나) → 같은 초대 반복 수락 → 만료 초대(다시 시도 없음) → 취소된 초대("쓸 수 없는 초대") → API 게이트웨이 컨테이너를 멈춘 채 참여(연결 실패, 초대 유지) → 게이트웨이 재시작 뒤 "다시 시도"로 참여("가상 교토 여행") → 서버에서 회원 세션 삭제 + 35초 대기(액세스 토큰 만료) → 참여 시 갱신 거절 → "다시 로그인하기", 홈에 초안·초대 유지 → 다시 로그인 → 참여("가상 나라 여행"). 마지막에 서버에서 회원의 참여 3건·사용된 초대 3건을 확인한다.

### 결과 (2026-11-21, iPhone 18 Pro 시뮬레이터 iOS 27.2, Android 에뮬레이터 API 36)

| 확인 | iOS | Android |
| --- | --- | --- |
| 로컬 모드 E2E 4단계 | 통과(공유 → 수락·반복·만료·취소 → 연결 실패 → 다시 시도 → 세션 만료 → 다시 로그인) | 통과(같은 순서) |
| 연결 실패 중 기기 상태 | 초안 1, 보관한 초대 있음, 세션 있음 | 같음 |
| 세션 만료 직후 기기 상태 | (UI로 확인: 로그인 안 됨, 초안·초대 카드 유지) | 초안 1, 보관한 초대 있음, 로컬 세션 없음 |
| 다시 로그인 뒤 | 초안 1, 보관한 초대 없음, 로컬 세션 있음 | 같음 |
| 서버 보고 | 회원 참여 3, 사용된 초대 3 | 같음 |
| 테스트 모드 E2E(로컬 설정 파일이 있는 상태) | 통과 | 통과 |
| release 빌드 | 로컬·테스트 구현체 기호 0, 로컬 주소·키·문구 0, Info.plist에 로컬 키 없음, `ios:release-check` 통과 | `localbackend`·`testing` 클래스 0, 로컬 필드·키·`10.0.2.2` 0, INTERNET 권한 없음, 네트워크 보안 설정 없음 |

### release 확인

- iOS: `mise run ios:release-check`(UI 테스트) + Release 빌드의 `nm`으로 `Local*Gateway`·`Test*Gateway` 기호 0, 실행 파일에 로컬 주소·`sb_` 키·로컬 문구 0, Info.plist에 `Nonanona*` 로컬 키 없음.
- Android: `assembleRelease` APK의 dex에 `app/nonanona/localbackend`·`testing` 0, `LOCAL_*` 필드·`10.0.2.2` 0, `aapt2 dump permissions`에 INTERNET 없음, 매니페스트에 `networkSecurityConfig` 없음.

## 명령

저장소 루트에서 `mise run setup`, `mise run doctor`. Android SDK 위치는 `ANDROID_HOME` 또는 `apps/android/local.properties`(`sdk.dir=…`, gitignore)로 정한다.

```sh
mise run lint            # swift-format(Xcode 포함판) + ktlint + Android lint(debug, release)
mise run test            # ReceiptImport 패키지(macOS) + iOS 앱 단위 테스트(시뮬레이터) + Android JVM 단위 테스트
mise run ios:build       # 앱·공유 확장 Debug/Release (시뮬레이터)
mise run android:build   # debug APK, 서명하지 않은 release APK
mise run ios:release-check
mise run ios:e2e -- <시뮬레이터 UDID> [증거 폴더]   # 테스트 구현체
mise run android:e2e -- [증거 폴더]                 # 테스트 구현체, 실행 중인 에뮬레이터 하나
mise run ios:e2e-adaptive -- <시뮬레이터 UDID> [증거 폴더]   # 창 크기·회전·큰 글자(위 "창 크기와 접기")
mise run android:e2e-adaptive -- [증거 폴더]                 # 접히는 기기 에뮬레이터
# 로컬 Supabase 모드는 위 "로컬 Supabase 모드" 절
```

iOS 단위 테스트와 release 확인은 `IOS_DESTINATION`(기본 `platform=iOS Simulator,name=iPhone 18 Pro`)으로 시뮬레이터를 고른다. 커밋할 때 lefthook이 바뀐 Swift·Kotlin 파일에 swift-format과 ktlint를 돌린다.

### E2E가 확인하는 것

두 스크립트 모두 앱을 새로 설치하고 [가상 영수증](fixtures/README.md) 한 장으로 같은 순서를 밟는다.

1. 앱이 꺼진 상태에서 사진 앱(iOS)·파일 앱(Android)의 시스템 공유 메뉴로 보낸다. 로그인하지 않은 상태로 초안 1장이 생긴다.
2. 시스템 링크 열기로 `nonanona://invite/SYNTHINVITE01`을 연다. 초대 화면에서 "로그인하고 참여하기" → 로그인 시트.
3. 로그인 시트가 열린 채로 앱 프로세스를 SIGKILL로 끝낸다. 디스크에 초안 1장·사진 1장·보관한 초대가 있고 세션은 없는지 확인한다.
4. 홈 화면 아이콘(iOS)·런처 인텐트(Android)로 다시 연다. 초대 화면으로 돌아오고, 홈에 초안과 초대 카드가 그대로 있다. 이 화면을 라이트·다크·큰 글자로 찍는다.
5. 테스트 로그인 → "가상 도쿄 여행" 여행방(참여함, 일행 2명). 보관한 초대는 지워지고 초안은 남는다.
6. 가상 초대 코드로 연결 실패 → 다시 시도, 초대 만료(다시 시도 없음, 초대 카드 사라짐), 세션 만료 → 로그아웃 상태에서도 초안·초대 유지 → 다시 로그인 → 참여를 확인한다.

## 버전

정확한 버전으로 고정했고, 모두 게시 후 7일이 지난 안정판이다(확인일 2026-11-21). Android 전이 의존성은 `apps/android/app/gradle.lockfile`(앱 346개), 플러그인 클래스패스는 `apps/android/buildscript-gradle.lockfile`(113개)에 고정한다(갱신: `./gradlew buildEnvironment :app:dependencies --write-locks`). 두 잠금 파일의 모든 항목이 게시 후 7일이 지났음을 Google Maven·Maven Central의 POM `Last-Modified`로 확인했다(가장 최근: navigation3 1.2.1, 2026-11-04). Dependabot은 `apps/android`의 Gradle 생태계를 7일 cooldown으로 본다. iOS는 원격 Swift 패키지가 없어 Dependabot 대상이 아니다.

| 도구·의존성 | 버전 | 게시일과 근거 |
| --- | --- | --- |
| Xcode (Swift 6, swift-format 6.4.4 포함) | 27.2 | 기존 설치. `mise run doctor`가 버전을 확인한다 |
| iOS 최소 버전 | 17.0 | `@Observable`, `PhotosPicker` |
| JDK (`mise.toml`) | Temurin 21.0.9+10 | 2025-10. AGP 9.3은 JDK 17 이상 |
| ktlint (`mise.toml`) | 1.8.0 | 2025-11-14 |
| Gradle Wrapper | 9.7.0 | 2026-08-06. 배포본 SHA-256 고정, wrapper JAR은 공식 SHA-256과 일치 확인 |
| Android Gradle Plugin | 9.3.1 | 2026-07-23 |
| Kotlin(Compose 컴파일러 플러그인 포함) | 2.4.21 | 2026-10-08. [KGP 호환표](https://kotlinlang.org/docs/gradle-configure-project.html)의 AGP 상한이 9.3.1 |
| Compose BOM | 2026.09.00 | 2026-09-09 (ui 1.12.1, material3 1.4.0) |
| activity-compose | 1.13.0 | 2026-03-11 |
| lifecycle(viewmodel-compose, runtime-compose) | 2.11.0 | 2026-06-17 |
| Navigation 3 (navigation3-ui) | 1.2.1 | 2026-11-04 |
| material3-adaptive(adaptive, adaptive-layout, adaptive-navigation3) | 1.3.0 | 2026-08-12. Compose BOM 2026.09.00이 정하는 버전(따로 고정하지 않음). navigation3-ui 1.0.0 이상 요구. 함께 잠근 annotation-experimental 1.5.1(2025-07-16) |
| JUnit | 4.13.2 | 2021-02-13 (단위 테스트만) |
| ML Kit 일본어 텍스트 인식(번들 모델) | 16.0.1 | 2024-08-07(최신 안정판). Play Services 전이 의존성 포함 잠금 338개 모두 7일 경과 |
| org.json(JVM 단위 테스트 전용) | 20260814 | 2026-08-14. 앱은 플랫폼 org.json을 쓴다 |
| Supabase CLI (`mise.toml`) | 3.1.0 | 2026-11-09. 3.2.0(2026-11-16)은 7일 전이라 쓰지 않는다. 로컬 스택 이미지는 CLI가 고정한 태그를 쓴다 |
| compileSdk / targetSdk / minSdk | 37.1 / 36 / 26 | Compose 1.12·lifecycle 2.11이 compileSdk 37 이상을 요구한다. AGP 9.3.1이 검증한 상한인 37.1을 쓰고, 실행 동작은 targetSdk 36(앞선 실험과 같음)으로 둔다 |

게시일은 Google Maven의 POM `Last-Modified`와 공식 릴리스 노트로 확인했다. 앞선 실험(native-batch-import, local-collaboration)과 같은 Kotlin·AGP·Gradle 조합을 이어 쓰고, Compose 의존성만 새로 더했다.

## 남은 일과 알려진 공백

- 실제 로그인(Apple, Google, 이메일 일회용 코드)은 연결하지 않았다. 로컬 모드의 Apple·Google 버튼은 가상 계정 비밀번호 로그인이며, 실제 소셜 로그인을 검증한 것이 아니다. Apple·Google 앱 등록, Supabase 클라우드 프로젝트, 운영 도메인, Sentry는 이후 일이다.
- release 빌드용 실제 구현체는 아직 없다(release는 계속 `Unavailable*`). 로컬 구현체는 debug 전용이며 세션을 앱 전용 파일에 둔다. 실제 구현체는 Keychain·암호화 저장소를 쓴다.
- 서버 오류 매핑은 로컬 스택(Auth, PostgREST, 이 저장소의 RPC 코드)에서 실제로 받은 값에 맞췄다. 클라우드 프로젝트의 응답, 실제 OAuth 오류, 속도 제한은 로컬에서 재현하지 않았다(429·5xx 매핑은 단위 테스트만).
- 세션 만료는 서버에서 세션을 지우고 토큰 만료를 기다려 재현했다. 장기간 미사용, 다른 기기 로그아웃, 계정 정지는 확인하지 않았다.
- 참여한 여행방 목록은 로그인 뒤 서버에서 다시 읽는다(위 "여행방 정산"). 올릴 곳은 지금 연 여행방이다.
- 영수증 처리: release에서는 검토·확인까지 할 수 있고 올리기는 없다. 처리는 앱이 앞에 있을 때만 돈다(iOS 백그라운드 작업, Android WorkManager 없음). 실기기, 큰 HEIC·JPEG, EXIF 회전 사진, 저장 공간 부족, Google 포토 공유, 앱 안 사진 선택기로 10장 고르기는 확인하지 않았다. 가로 전체 띠 가림은 같은 행의 다른 정보도 덮는다. 공유 확장도 가져오기 패키지를 함께 링크해 OCR 코드가 들어 있다(쓰지는 않는다).
- debug 빌드는 로컬 모드 때문에 INTERNET 권한이 있어, ML Kit 라이브러리가 debug에서 사용 통계를 보낼 수 있는지는 확인하지 않았다(release는 권한이 없다).
- 초대 링크는 사용자 지정 스킴(`nonanona://`)이다. 운영 도메인의 Universal Links·App Links는 서버 준비와 함께 붙인다.
- 번들 ID·applicationId(`app.nonanona`), App Group(`group.app.nonanona`), 앱 아이콘은 임시다. 실기기 서명과 스토어 등록 때 정한다.
- 시뮬레이터·에뮬레이터만 확인했다. 실기기, Google 포토 앱의 공유(에뮬레이터는 계정 없이 쓸 수 없어 파일 앱으로 대신), 앱 안 사진 선택기의 E2E, 공유 확장 메모리 한도, 큰 HEIC는 확인하지 않았다.
- 정산은 로컬 슬라이스만 있다(위 "여행방 정산"과 ADR-0006). release는 계속 `Unavailable*`이다.
- 영수증 올리기: 행 없는 사본(부분 실패)을 지우는 정리 작업이 없다. 같은 사본을 다른 여행방에 올리면 다른 요청 키라 별개 지출이 된다. 한 번에 여러 장을 올리다 중간에 실패하면 앞의 장은 이미 올라간 상태로 남는다(같은 확인으로 다시 올리면 앞의 장은 같은 지출로 수렴). 서버가 사본 내용(가림이 실제로 개인정보를 가렸는지)을 검사하지 않는다. 파일 검사(청크·해시·픽셀)는 가림이 의미상 충분하다는 증명이 아니다. 실기기, 느린 망, 큰 사본, 여러 계정이 같은 방에 동시에 올리기는 확인하지 않았다.
