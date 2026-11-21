# 모바일 앱 (첫 로컬 슬라이스)

iOS(SwiftUI)와 Android(Kotlin, Compose) 네이티브 앱의 뼈대다. 이번 슬라이스는 다음 흐름만 기기 안에서 끝낸다.

> 사진 앱·파일 앱에서 영수증 공유 → 로그인하지 않은 채 기기에 초안 저장 → 초대 링크 열기 → 로그인 → 열었던 초대의 여행방으로 돌아오기

로그인 도중 앱 프로세스가 끝나도 초안과 열었던 초대는 남고, 다시 열면 그 초대 화면으로 돌아온다([ADR-0002](../docs/adr/0002-authentication-and-device-transfer.md)). debug 빌드는 같은 흐름을 **테스트 구현체**(기기 안, 기본값) 또는 **로컬 Supabase 모드**(Docker로 띄운 로컬 Auth + Postgres에 실제 HTTP로 로그인·초대 수락, 아래 절)로 돌린다. 실제 소셜 로그인, 클라우드 프로젝트, 운영 자격 증명은 없다. 화면 기준은 [모바일 디자인 기준](../docs/design/mobile-foundations.md)에 있다.

## 구성

기능별 폴더로 나누고([ADR-0003](../docs/adr/0003-mobile-architecture.md)), 기능끼리는 서로 참조하지 않는다. 앱 계층이 순서를 잇는다.

| 책임 | iOS (`apps/ios`) | Android (`apps/android/app/src`) |
| --- | --- | --- |
| 영수증 가져오기: 공유·사진 선택으로 받은 사진을 초안 폴더에 원자적으로 저장 | `Packages/ReceiptImport`(앱과 공유 확장이 함께 쓰는 Swift 패키지), `NonanonaShare/`(공유 확장), `Nonanona/Features/ReceiptImport/` | `main/.../feature/receiptimport/` |
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

정확한 버전으로 고정했고, 모두 게시 후 7일이 지난 안정판이다(확인일 2026-11-21). Android 전이 의존성은 `apps/android/app/gradle.lockfile`(앱 304개), 플러그인 클래스패스는 `apps/android/buildscript-gradle.lockfile`(113개)에 고정한다(갱신: `./gradlew buildEnvironment :app:dependencies --write-locks`). 두 잠금 파일의 모든 항목이 게시 후 7일이 지났음을 Google Maven·Maven Central의 POM `Last-Modified`로 확인했다(가장 최근: navigation3 1.2.1, 2026-11-04). Dependabot은 `apps/android`의 Gradle 생태계를 7일 cooldown으로 본다. iOS는 원격 Swift 패키지가 없어 Dependabot 대상이 아니다.

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
| JUnit | 4.13.2 | 2021-02-13 (단위 테스트만) |
| Supabase CLI (`mise.toml`) | 3.1.0 | 2026-11-09. 3.2.0(2026-11-16)은 7일 전이라 쓰지 않는다. 로컬 스택 이미지는 CLI가 고정한 태그를 쓴다 |
| compileSdk / targetSdk / minSdk | 37.1 / 36 / 26 | Compose 1.12·lifecycle 2.11이 compileSdk 37 이상을 요구한다. AGP 9.3.1이 검증한 상한인 37.1을 쓰고, 실행 동작은 targetSdk 36(앞선 실험과 같음)으로 둔다 |

게시일은 Google Maven의 POM `Last-Modified`와 공식 릴리스 노트로 확인했다. 앞선 실험(native-batch-import, local-collaboration)과 같은 Kotlin·AGP·Gradle 조합을 이어 쓰고, Compose 의존성만 새로 더했다.

## 남은 일과 알려진 공백

- 실제 로그인(Apple, Google, 이메일 일회용 코드)은 연결하지 않았다. 로컬 모드의 Apple·Google 버튼은 가상 계정 비밀번호 로그인이며, 실제 소셜 로그인을 검증한 것이 아니다. Apple·Google 앱 등록, Supabase 클라우드 프로젝트, 운영 도메인, Sentry는 이후 일이다.
- release 빌드용 실제 구현체는 아직 없다(release는 계속 `Unavailable*`). 로컬 구현체는 debug 전용이며 세션을 앱 전용 파일에 둔다. 실제 구현체는 Keychain·암호화 저장소를 쓴다.
- 서버 오류 매핑은 로컬 스택(Auth, PostgREST, 이 저장소의 RPC 코드)에서 실제로 받은 값에 맞췄다. 클라우드 프로젝트의 응답, 실제 OAuth 오류, 속도 제한은 로컬에서 재현하지 않았다(429·5xx 매핑은 단위 테스트만).
- 세션 만료는 서버에서 세션을 지우고 토큰 만료를 기다려 재현했다. 장기간 미사용, 다른 기기 로그아웃, 계정 정지는 확인하지 않았다.
- 여행방 목록과 다시 열기, 초안을 여행방에 올리기는 다음 슬라이스다.
- 초대 링크는 사용자 지정 스킴(`nonanona://`)이다. 운영 도메인의 Universal Links·App Links는 서버 준비와 함께 붙인다.
- 번들 ID·applicationId(`app.nonanona`), App Group(`group.app.nonanona`), 앱 아이콘은 임시다. 실기기 서명과 스토어 등록 때 정한다.
- 시뮬레이터·에뮬레이터만 확인했다. 실기기, Google 포토 앱의 공유(에뮬레이터는 계정 없이 쓸 수 없어 파일 앱으로 대신), 앱 안 사진 선택기의 E2E, 공유 확장 메모리 한도, 큰 HEIC는 확인하지 않았다.
- 10장 묶음 처리, OCR, 가림, 정산은 이번 범위가 아니다(앞선 실험에서 따로 검증했다).
