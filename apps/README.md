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

native-batch-import 실험에서 검증한 처리 코어를 영수증 가져오기 기능 안으로 옮겼다(두 플랫폼 같은 모델). 실험의 화면, 기록 서버, 공유 payload는 옮기지 않았다. 검토·확인 화면은 디자인(A/B)과 함께 따로 붙인다. 올리기는 아래 "영수증 올리기"(로컬 Supabase 모드, debug 화면)에 있다.

- **처리 상태**: 초안마다 `processing.json`에 사진별 상태(`queued → processing → ready | failed → confirmed`), 시도 횟수, 실패 이유를 둔다. 상태는 화면에 알리기 전에 원자적으로 디스크에 먼저 쓴다. 처리기를 만들 때 `processing`으로 남은 사진(처리 중 앱 종료)을 `queued`로 되돌리고 `recoveredCount`를 늘린다. 끝난 사진은 다시 읽지 않는다.
- **OCR**: 동시에 최대 2장. iOS는 Apple Vision(`ja-JP`), Android는 ML Kit 번들 일본어 모델(`text-recognition-japanese` 16.0.1). 사진에서 날짜·합계·가게와 가림 후보(전화·카드·회원·예약번호 줄)를 고른다. 실패는 문자열이 아니라 `ProcessingFailure`(`unreadable`, `missingTotal`, `missingDate`, `invalidImage`, `recognitionError`)로 남기고, 그 사진 하나만 "다시 읽기"로 대기열에 되돌린다.
- **타입 분리**: 원본 사진(초안 폴더), `OCRProposal`(OCR 전문 포함, 기기 안 `proposals/`에만), `AllowedReceiptFields`(날짜·금액·통화·가게), `MaskedArtifact`(가림을 구운 새 PNG. 굽기 함수만 만들 수 있다), `ConfirmedReceipt`(허용 필드 + 가림 사본 이름·해시)는 서로 다른 타입이다.
- **확인**: `confirm(item, fields, maskLineIDs)`만 가림을 픽셀에 굽는다(새 비트맵에 검은 띠, PNG 재인코딩 후 `IHDR/PLTE/tRNS/sRGB/IDAT/IEND` 외 청크 제거). 날짜 형식·금액·통화가 맞지 않거나 `ready`가 아니면 거절한다.
- **기기 경계(fail closed)**: 기기 밖으로 보낼 수 있는 것은 `outboundReceipts()` 하나뿐이다. 확인한 영수증만 돌려주고, 그 전에 가림 사본이 있는지, 해시가 확인 당시와 같은지, 허용 청크만 있는지, 원본과 다른 바이트인지 다시 본다. 하나라도 어긋나면 아무것도 돌려주지 않는다. 돌려주는 값은 검사한 바이트 그대로다(검사 뒤 파일을 다시 읽지 않는다). 올리기는 이것만 쓴다.
- **저장 정책**: iOS는 App Group 컨테이너의 초안 폴더(백업 제외, `completeFileProtectionUntilFirstUserAuthentication`), Android는 앱 전용 `filesDir`(백업·기기 이전 제외 규칙). 임시 파일은 같은 폴더 안 숨김 파일로 쓰고 이름을 바꿔 공개한다.
- **release 앱**: 네트워크 권한이 없다. ML Kit이 병합하는 `INTERNET`·`ACCESS_NETWORK_STATE`를 main 매니페스트에서 지웠다(debug는 로컬 Supabase 모드 때문에 `INTERNET`만 다시 받는다).
- **화면(중립, 임시)**: 초안 화면에 "읽음 N/M", 이어서 읽은 사진 수, 사진별 상태 라벨(대기 중·읽는 중·확인 필요·읽지 못함·확인함)과 실패 이유, "다시 읽기"만 둔다. debug 빌드에만 "확인(개발용)"(제안값과 가림 후보를 그대로 확인)과 처리 늦추기·첫 시도 실패 주입(iOS 실행 환경 변수 `NONANONA_PROCESSING_DELAY_MS`·`NONANONA_FAIL_FIRST_ATTEMPT_POSITION`, Android `files/debug-processing.properties`)이 있다.

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
- 여행방 목록과 다시 열기는 다음 슬라이스다. 참여한 여행방은 앱 화면 상태에만 있어, 앱을 다시 열면 초대 링크로 다시 들어가야 올릴 곳이 생긴다.
- 영수증 처리: 검토·확인 화면(값 고치기, 가림 직접 고르기·그리기)과 직접 입력은 아직 없다. release에서는 처리 상태만 보이고 확인·올리기를 할 수 없다. 처리는 앱이 앞에 있을 때만 돈다(iOS 백그라운드 작업, Android WorkManager 없음). 실기기, 큰 HEIC·JPEG, EXIF 회전 사진, 저장 공간 부족, Google 포토 공유, 앱 안 사진 선택기로 10장 고르기는 확인하지 않았다. 가로 전체 띠 가림은 같은 행의 다른 정보도 덮는다. 공유 확장도 가져오기 패키지를 함께 링크해 OCR 코드가 들어 있다(쓰지는 않는다).
- debug 빌드는 로컬 모드 때문에 INTERNET 권한이 있어, ML Kit 라이브러리가 debug에서 사용 통계를 보낼 수 있는지는 확인하지 않았다(release는 권한이 없다).
- 초대 링크는 사용자 지정 스킴(`nonanona://`)이다. 운영 도메인의 Universal Links·App Links는 서버 준비와 함께 붙인다.
- 번들 ID·applicationId(`app.nonanona`), App Group(`group.app.nonanona`), 앱 아이콘은 임시다. 실기기 서명과 스토어 등록 때 정한다.
- 시뮬레이터·에뮬레이터만 확인했다. 실기기, Google 포토 앱의 공유(에뮬레이터는 계정 없이 쓸 수 없어 파일 앱으로 대신), 앱 안 사진 선택기의 E2E, 공유 확장 메모리 한도, 큰 HEIC는 확인하지 않았다.
- 정산(결제자·부담자·원화 환산·방장 검토·확정·송금표)은 아직 없다. 지출 행에는 허용 필드와 사본 위치만 있다.
- 영수증 올리기: 행 없는 사본(부분 실패)을 지우는 정리 작업이 없다. 같은 사본을 다른 여행방에 올리면 다른 요청 키라 별개 지출이 된다. 한 번에 여러 장을 올리다 중간에 실패하면 앞의 장은 이미 올라간 상태로 남는다(같은 확인으로 다시 올리면 앞의 장은 같은 지출로 수렴). 서버가 사본 내용(가림이 실제로 개인정보를 가렸는지)을 검사하지 않는다. 파일 검사(청크·해시·픽셀)는 가림이 의미상 충분하다는 증명이 아니다. 실기기, 느린 망, 큰 사본, 여러 계정이 같은 방에 동시에 올리기는 확인하지 않았다.
