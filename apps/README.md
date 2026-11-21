# 모바일 앱 (첫 로컬 슬라이스)

iOS(SwiftUI)와 Android(Kotlin, Compose) 네이티브 앱의 뼈대다. 이번 슬라이스는 다음 흐름만 기기 안에서 끝낸다.

> 사진 앱·파일 앱에서 영수증 공유 → 로그인하지 않은 채 기기에 초안 저장 → 초대 링크 열기 → 로그인 → 열었던 초대의 여행방으로 돌아오기

로그인 도중 앱 프로세스가 끝나도 초안과 열었던 초대는 남고, 다시 열면 그 초대 화면으로 돌아온다([ADR-0002](../docs/adr/0002-authentication-and-device-transfer.md)). 실제 소셜 로그인, 서버, 클라우드 호출, 운영 자격 증명은 없다. 화면 기준은 [모바일 디자인 기준](../docs/design/mobile-foundations.md)에 있다.

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

- 경계 구현체는 앱 시작 지점에서 빌드 종류에 따라 연결한다. debug는 가상 계정(가나)과 가상 여행방(가상 도쿄 여행)을 돌려주는 테스트 구현체, release는 아무것도 성공시키지 않는 `Unavailable*` 구현체다.
- 테스트 구현체는 iOS `Nonanona/Testing/`(`#if DEBUG`), Android `src/debug/`에만 있어 release 바이너리에 들어가지 않는다. debug 로그인 시트에는 "테스트 로그인 · 실제 계정에 연결하지 않아요" 라벨이 붙는다.
- release 앱에서 로그인 시트를 열면 "지금은 로그인할 수 없어요."만 보이고 로그인 버튼이 없다. iOS는 `mise run ios:release-check`로, Android는 release APK를 로컬 디버그 키로 서명해 설치하고 같은 화면을 확인했다.
- Android 앱은 INTERNET 권한을 요청하지 않는다.

## 명령

저장소 루트에서 `mise run setup`, `mise run doctor`. Android SDK 위치는 `ANDROID_HOME` 또는 `apps/android/local.properties`(`sdk.dir=…`, gitignore)로 정한다.

```sh
mise run lint            # swift-format(Xcode 포함판) + ktlint + Android lint(debug, release)
mise run test            # ReceiptImport 패키지(macOS) + iOS 앱 단위 테스트(시뮬레이터) + Android JVM 단위 테스트
mise run ios:build       # 앱·공유 확장 Debug/Release (시뮬레이터)
mise run android:build   # debug APK, 서명하지 않은 release APK
mise run ios:release-check
mise run ios:e2e -- <시뮬레이터 UDID> [증거 폴더]
mise run android:e2e -- [증거 폴더]      # 실행 중인 에뮬레이터 하나
```

iOS 단위 테스트와 release 확인은 `IOS_DESTINATION`(기본 `platform=iOS Simulator,name=iPhone 18 Pro`)으로 시뮬레이터를 고른다. 커밋할 때 lefthook이 바뀐 Swift·Kotlin 파일에 swift-format과 ktlint를 돌린다.

### E2E가 확인하는 것

두 스크립트 모두 앱을 새로 설치하고 [가상 영수증](fixtures/README.md) 한 장으로 같은 순서를 밟는다.

1. 앱이 꺼진 상태에서 사진 앱(iOS)·파일 앱(Android)의 시스템 공유 메뉴로 보낸다. 로그인하지 않은 상태로 초안 1장이 생긴다.
2. 시스템 링크 열기로 `nonanona://invite/SYNTHINVITE01`을 연다. 초대 화면에서 "로그인하고 참여하기" → 로그인 시트.
3. 로그인 시트가 열린 채로 앱 프로세스를 SIGKILL로 끝낸다. 디스크에 초안 1장·사진 1장·보관한 초대가 있고 세션은 없는지 확인한다.
4. 홈 화면 아이콘(iOS)·런처 인텐트(Android)로 다시 연다. 초대 화면으로 돌아오고, 홈에 초안과 초대 카드가 그대로 있다. 이 화면을 라이트·다크·큰 글자로 찍는다.
5. 테스트 로그인 → "가상 도쿄 여행" 여행방(참여함, 일행 2명). 보관한 초대는 지워지고 초안은 남는다.

## 버전

정확한 버전으로 고정했고, 모두 게시 후 7일이 지난 안정판이다(확인일 2026-11-21). Android 전이 의존성은 `apps/android/app/gradle.lockfile`에 고정한다(갱신: `./gradlew :app:dependencies --write-locks`).

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
| compileSdk / targetSdk / minSdk | 37.1 / 36 / 26 | Compose 1.12·lifecycle 2.11이 compileSdk 37 이상을 요구한다. AGP 9.3.1이 검증한 상한인 37.1을 쓰고, 실행 동작은 targetSdk 36(앞선 실험과 같음)으로 둔다 |

게시일은 Google Maven의 POM `Last-Modified`와 공식 릴리스 노트로 확인했다. 앞선 실험(native-batch-import, local-collaboration)과 같은 Kotlin·AGP·Gradle 조합을 이어 쓰고, Compose 의존성만 새로 더했다.

## 남은 일과 알려진 공백

- 실제 로그인(Apple, Google, 이메일 일회용 코드), 세션 Keychain·암호화 저장, 서버 연결(Supabase 구현체), 여행방 목록과 다시 열기, 초안을 여행방에 올리기는 다음 슬라이스다.
- 초대 링크는 사용자 지정 스킴(`nonanona://`)이다. 운영 도메인의 Universal Links·App Links는 서버 준비와 함께 붙인다.
- 번들 ID·applicationId(`app.nonanona`), App Group(`group.app.nonanona`), 앱 아이콘은 임시다. 실기기 서명과 스토어 등록 때 정한다.
- 시뮬레이터·에뮬레이터만 확인했다. 실기기, Google 포토 앱의 공유(에뮬레이터는 계정 없이 쓸 수 없어 파일 앱으로 대신), 앱 안 사진 선택기의 E2E, 공유 확장 메모리 한도, 큰 HEIC는 확인하지 않았다.
- 10장 묶음 처리, OCR, 가림, 정산은 이번 범위가 아니다(앞선 실험에서 따로 검증했다).
