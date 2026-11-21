# 모바일 디자인 기준

iOS(SwiftUI)와 Android(Compose)를 따로 만들면서 두 앱이 같은 서비스로 보이게 하는 최소 기준이다. 두 앱은 같은 **역할 이름, 문구, 화면 상태**를 쓰고, 생김새는 각 플랫폼의 시스템 스타일을 따른다. 공유 UI 코드, 토큰 생성기, Figma, 디자인 시스템 라이브러리는 두지 않는다. 브랜드 색은 아직 정하지 않았다. 아래 값은 모두 임시이며 각 플랫폼의 테마 파일 하나에서 바꾼다.

| 플랫폼 | 역할을 연결한 파일 |
| --- | --- |
| iOS | `apps/ios/Nonanona/Design/Theme.swift` |
| Android | `apps/android/app/src/main/java/app/nonanona/design/Theme.kt`, `StatusLabel.kt` |

## 맞추는 것과 플랫폼에 맡기는 것

| 맞춘다 | 플랫폼에 맡긴다 |
| --- | --- |
| 역할 이름(색·글자·간격·상태 라벨) | 탐색: iOS `NavigationStack`, Android Navigation 3 + 시스템 뒤로 가기(예측 뒤로 포함) |
| 한국어 문구와 말투(해요체, 짧은 문장) | 시트: iOS `.sheet`(detents), Android `ModalBottomSheet` |
| 화면과 상태의 종류, 상태를 바꾸는 동작 | 사진 고르기: iOS `PhotosPicker`, Android 시스템 사진 선택기(`PickMultipleVisualMedia`), 둘 다 권한 요청 없음 |
| 상태는 글자 라벨로 표시(색은 보조) | 공유로 받기: iOS 공유 확장(시트 안에서 "초안에 담기"), Android 공유 대상 Activity(바로 담고 스낵바) |
| 간격 값 | 제목: iOS 큰 제목, Android 상단 앱 바 / 주 동작: iOS 하단 막대, Android 확장 FAB |
| 글자 크기는 시스템 설정을 따름 | 로그인 버튼 모양(아래 "로그인 버튼") |
| 창 크기별 배치 규칙과 읽기 폭 640(아래 "창 크기와 접기") | 목록·상세: iOS `NavigationSplitView`, Android `ListDetailSceneStrategy` / 두 칸 기준: iOS 가로 regular, Android 840dp |

## 색 역할 (임시 중립 팔레트)

브랜드 색이 없으므로 무채색만 쓴다. Android는 동적 색(Material You)을 끈다. 두 앱의 화면을 같은 기준으로 비교하기 위해서다.

| 역할 | 뜻 | SwiftUI | Compose Material 3 |
| --- | --- | --- | --- |
| background | 화면 바탕 | 시스템 그룹 배경(목록 기본값) | `background`/`surface` 라이트 #F9F9F9, 다크 #131313 |
| container | 카드·목록 행 | 목록 셀 배경 | `surfaceContainerHigh` |
| content | 본문 글자 | `.primary` | `onSurface` |
| contentSecondary | 보조 글자 | `.secondary` | `onSurfaceVariant` |
| accent | 주 동작·강조, 앱 tint | `.primary`(라이트 검정, 다크 흰색) | `primary` 라이트 #303030, 다크 #E2E2E2 |
| onAccent | accent 위 글자 | `systemBackground` | `onPrimary` |
| error | 실패 문구 | `.red` | `error`(M3 기본값) |

## 글자 역할

크기를 직접 정하지 않는다. iOS는 Dynamic Type 텍스트 스타일, Android는 M3 기본 타입 스케일(sp)을 써서 시스템 글자 크기 설정을 그대로 따른다.

| 역할 | 쓰는 곳 | SwiftUI | Compose M3 |
| --- | --- | --- | --- |
| screenTitle | 화면 제목 | 내비게이션 큰 제목 / inline | `TopAppBar` 제목 |
| heading | 화면 안 큰 문장(초대 화면) | `.title2.bold()` | `headlineSmall` |
| sectionTitle | 섹션 머리말, 카드 제목 | `.headline` | `titleMedium` |
| body | 본문 | `.body` | `bodyLarge` |
| supporting | 설명·날짜 | `.subheadline` | `bodyMedium` |
| status | 상태 라벨 | `.caption.weight(.semibold)` | `labelMedium` |

한국어 줄바꿈: iOS는 기본으로 어절 단위로 끊는다. Android는 글자 로캘을 `ko-KR`로 두고 `LineBreak.WordBreak.Phrase`를 써서 같은 결과를 낸다(API 33 이상).

## 간격 역할

`xs 4`, `s 8`, `m 16`(화면 좌우 여백, 카드 안 여백), `l 24`, `xl 32`. 단위는 pt와 dp로 같은 숫자다. 목록 행 높이와 안쪽 여백은 시스템 목록 기본값을 따른다.

## 상태 라벨

상태는 항상 글자로 보여 준다. 색만으로 구분하지 않는다.

| 역할 | 예 | SwiftUI | Compose M3 |
| --- | --- | --- | --- |
| neutral | 기기에만 저장됨, 로그인 안 됨, 방장, 나 | `.secondary` / `tertiarySystemFill` | `onSurfaceVariant` / `surfaceContainerHighest` |
| attention | 초대 대기 중 | `systemBackground` / `.primary`(반전) | `onPrimary` / `primary` |
| positive | 로그인됨 · 이름, 참여함 | `.primary` / `secondarySystemFill` | `onSecondaryContainer` / `secondaryContainer` |
| error | (실패 상태 라벨용 예약) | `.red` / 옅은 빨강 | `onErrorContainer` / `errorContainer` |

## 화면과 상태

| 화면 | 상태 | 주요 문구 |
| --- | --- | --- |
| 홈 | 초안 없음 / 초안 있음 / 초대 대기 카드 / 로그인 안 됨·로그인됨 | 노나노나 · 영수증 초안 · 아직 초안이 없어요 · 사진 N장 · 기기에만 저장됨 · 사진 고르기 |
| 공유로 받기 | 담기 전 / 담는 중 / 실패 | 영수증 초안에 담기 · 사진 N장을 이 기기의 초안에 저장해요. 로그인하지 않아도 돼요. · 사진 N장을 초안에 담았어요 |
| 초안 | 사진 목록 | 초안 · 로그인하지 않아도 이 기기에 보관돼요. |
| 초대 | 로그인 필요 / 참여 가능 / 참여 중 / 실패 | 여행방 초대 · 여행방에 초대받았어요 · 로그인하고 참여하기 · 참여하기 · 참여하지 못했어요. 다시 시도해 주세요. |
| 로그인 시트 | 고르기 / 로그인 중 / 실패 / 사용 불가 | 로그인 · 여행방을 만들거나 초대를 수락하려면 로그인해요. · 지금은 로그인할 수 없어요. |
| 여행방 | 참여함 | 일행 · 방장 · 나 · 영수증 초안 N장은 아직 이 기기에만 있어요. |
| 목록 옆 안내(넓은 창) | 아무것도 고르지 않음 | 초안을 골라 주세요 · 목록에서 초안을 고르면 여기에 보여요. |

debug 빌드의 테스트 로그인은 시트에 **테스트 로그인 · 실제 계정에 연결하지 않아요** 라벨을 붙인다. 이 문구와 테스트 구현체는 release 빌드에 들어가지 않는다.

## 로그인 버튼

- iOS: Apple(검정 바탕 흰 글자, 다크에서는 반전, Apple 로고 SF Symbol)과 Google(테두리 버튼). Android: Google만(테두리 버튼). [ADR-0002](../adr/0002-authentication-and-device-transfer.md)의 제공자 구성이다.
- 실제 로그인을 연결할 때 iOS는 `SignInWithAppleButton`, Google은 브랜드 지침의 공식 버튼(로고 포함)으로 바꾼다. 지금 버튼은 같은 자리와 문구만 맞춘 임시 버튼이다.

## 창 크기와 접기

배치는 기기 모델이나 세로 고정이 아니라 **지금 창**의 크기 종류·크기, 안전 영역, 시스템이 알려 주는 접힘·가림 영역으로 정한다([ADR-0004](../adr/0004-adaptive-layout.md)). 화면의 생김새(문구, 역할, 상태 라벨)는 그대로이고 놓이는 자리만 바뀐다. 이 절은 배치의 바탕만 정한다. 영수증 검토·가림 편집 화면의 시각 흐름(A/B)은 여기서 고르지 않는다.

### 크기별 배치

| 창 | iOS | Android | 배치 |
| --- | --- | --- | --- |
| 좁은 창: 폰 세로, iPhone Duo 바깥 화면, 폴더블 바깥 화면, 분할 화면의 좁은 쪽 | 가로 compact | 폭 600dp 미만(compact) | 한 화면씩 쌓는다. 시스템 뒤로 가기·스와이프 |
| 낮은 창: 폰 가로, 큰 글자 | 세로 compact | 높이 480dp 미만 | 같은 한 화면(iOS Pro Max 가로는 아래 넓은 창). 모든 화면·시트는 스크롤로 마지막 버튼까지 닿는다 |
| 중간 폭: 600~840dp | regular면 넓은 창 | 한 칸(Material 기본) | 한 칸, 글 위주 내용은 읽기 폭 |
| 넓은 창: iPhone Duo 안쪽 화면, Pro Max 가로, 펼친 폴더블(840dp 이상) | 가로 regular | 폭 840dp 이상(expanded) | 목록(홈) 옆에 고른 화면(초안·초대·여행방). 아무것도 안 골랐으면 "초안을 골라 주세요" 안내 |
| 반쯤 접은 폴더블(책 자세) | 시스템 분할 보기가 접힘에 맞춰 열 폭을 정한다 | 세로 separating hinge가 있으면 폭과 상관없이 두 칸, 두 칸은 접힘 양쪽 | 내용·버튼은 접힘 위에 놓이지 않는다 |

- 목록·상세: iOS `NavigationSplitView`(`.balanced`, 목록 숨기기 버튼 없음), Android Navigation 3 `ListDetailSceneStrategy`(material3-adaptive). 상세는 넓은 창에서 뒤로 가기 화살표 없이 목록 옆에 있고, 고른 초안은 목록에서 고른 상태(iOS 선택 강조, Android 행 바탕색)로 보인다. 스낵바는 맨 위 화면 하나만 띄운다.
- 읽기 폭: 글 위주 목록·화면·시트는 넓은 창에서 **640**(pt·dp, M3 바텀 시트 최대 폭과 같음)보다 넓어지지 않고 가운데에 둔다. 좁은 창에서는 아무것도 바꾸지 않는다.
- 접힘·가림: 안전 영역은 시스템 컨테이너가 지킨다. iOS는 목록·시트의 스크롤 여백(`adaptiveContentMargins`)이 `ReservedRegion`(division) 세로 접힘을 피해 넓은 쪽에 내용을 둔다(iOS 27.1 이상, 시스템 분할 보기 안에서는 보통 0). Android는 시트·대화상자를 hinge 넓은 쪽에 옮긴다. 두 앱이 같은 규칙(`ContentMargins.fitting`)을 쓴다.
- 막대: iPhone Duo 바깥 화면에서는 시스템이 상태 막대·도구 막대·뒤로 버튼을 옆(세로)에 둔다. 글자만 있는 하단 동작 "사진 고르기"는 시스템 규칙대로 가로 막대에 남는다(아이콘으로 바꾸는 것은 디자인 결정으로 남긴다).
- 창(시트·확인): 로그인 시트와 올릴 곳·장수 최종 확인은 화면 맨 위에서 한 번만 띄운다. iOS 최종 확인은 가운데 알림이다(Android AlertDialog와 같음). 예전의 행 안 확인 시트는 넓은 창에서 팝오버가 되어, 열린 채 회전하면 다시 뜨지 못하고 멈췄다.

### 바뀌어도 남는 것

창 크기 변경, 접기·펴기, 회전, 분할 화면, Android의 Activity 다시 만들기를 지나도 다음이 그대로다. 모두 화면이 아니라 모델(iOS `AppModel`, Android `AppViewModel`)에 있다.

| 상태 | 어디에 | 확인 |
| --- | --- | --- |
| 지금 화면(고른 초안은 안정 ID) | iOS `selection: Route?`, Android `backStack: [Route]` | 두 E2E, iOS 단위 테스트(분할 보기 접기·펴기) |
| 처리 상태와 처리기 | 초안 ID별 처리기·manifest | 읽는 중 회전·접기 뒤 사진별 시도 횟수 1(중복 OCR 없음), 장면 다시 활성화 5번에도 OCR 2번(단위 테스트) |
| 최종 확인의 올릴 곳·장수 | `uploadConfirmation`(초안 ID, 여행방 ID·이름, 장수) | 열린 채 회전·접기·펴기 뒤 같은 문장, 한 번만 올림. 그사이 올릴 곳이 바뀌면 예전 확인으로는 올리지 않음(단위 테스트) |
| 로그인 시트·참여 상태 | `login`, `join` | 반쯤 접은 채·가로 큰 글자에서 시트 사용 |
| 아직 보내지 않은 입력 | 지금은 입력 칸이 없다 | 검토 화면에서 입력 칸이 생기면 같은 규칙(모델 또는 `rememberSaveable`/`@SceneStorage`)으로 둔다 |

### 나중의 영수증 목록·상세

영수증 목록(사진)과 상세(값 고치기·가림 편집)는 위 목록·상세의 **상세 쪽**에 붙인다. 상세 안을 다시 둘로 나누면 iOS는 `ReservedRegion`, Android는 `WindowAdaptiveInfo.windowPosture`의 hinge를 보고 가림 편집 영역이 접힘에 걸치지 않게 한다. 고른 영수증도 안정 ID로 모델에 둔다.

### 확인한 기기와 구성 (2026-11-21, 가상 자료)

| 구성 | iOS (`mise run ios:e2e-adaptive`) | Android (`mise run android:e2e-adaptive`) |
| --- | --- | --- |
| 좁은 창(바깥 화면) | iPhone Duo 시뮬레이터 바깥 화면(466×678pt, 세로·가로) | Pixel 9 Pro Fold 프로필 에뮬레이터를 실제로 접어(`emu fold`) 바깥 화면(1080×2424px) |
| 넓은 창 | iPhone 18 Pro Max 가로(가로 regular, 목록 옆 초안) | 펼친 안쪽 화면(2076×2152px, 약 852dp) |
| 접기·펴기 이벤트 | **확인하지 못함**(아래 공백) | 읽는 중 펼침 → 접기 → 펴기 → 반쯤 접기(`emu posture 2`) |
| 반쯤 접기 | **확인하지 못함** | 두 칸이 hinge(x=1038px) 양쪽(목록 0–1038, 상세 1097–2076), 로그인 시트·최종 확인이 hinge 한쪽 |
| 낮은 창·회전 | Duo 바깥 화면·Pro Max·18 Pro 세로↔가로(읽는 중, 최종 확인을 연 채) | 안쪽 화면 가로 |
| 큰 글자 | `accessibility-extra-large` + 가로 | `font_scale 2.0` + 가로 |
| 분할·크기 바꾸기 | 단위 테스트: 실제 창에 띄운 분할 보기를 669×951 regular → 466×678 compact → 951×669 regular → 320×951 compact로 바꿈 | `wm size 1300x1000`(533×410dp, compact 폭·높이) |
| 스크롤·키보드 | 가로 큰 글자에서 초안 마지막 행·로그인 시트 버튼까지 스크롤 | 같음 |

| | iOS | Android |
| --- | --- | --- |
| 넓은 창 | ![](screens/ios-adaptive-wide-landscape.png) | ![](screens/android-adaptive-unfolded.png) |
| 좁은 창(바깥 화면). iOS는 최종 확인, 세로 뒤로 버튼 | ![](screens/ios-adaptive-duo-outer.png) | ![](screens/android-adaptive-folded.png) |
| 반쯤 접기 + 최종 확인 | (확인하지 못함) | ![](screens/android-adaptive-half-opened-confirmation.png) |
| 큰 글자 + 가로 | ![](screens/ios-adaptive-large-text-landscape-login.png) | ![](screens/android-adaptive-landscape-large-text.png) |

**증거 공백**: iPhone Duo의 접기·펴기·반쯤 접기는 Xcode Device Hub의 GUI(자세·hinge 막대)로만 바뀐다. `simctl`·XCTest에는 자세를 바꾸는 명령이 없고(화면 전원 끄기는 기기를 펴지 않는다), 이 세션의 GUI 자동화는 macOS 손쉬운 사용 권한이 없어 쓰지 못했다. 그래서 iOS에서는 실제 접기 이벤트와 접힘 예약 영역(`ReservedRegion` division)이 보이는 모습을 보지 못했고, 같은 신호(크기 종류·크기 변경, 장면 다시 활성화, division 영역 계산)를 단위 테스트로 주어 대신했다. 실기기, 태블릿, 데스크톱 창(ChromeOS·Mac의 iPhone 앱), Android 실제 분할 화면(두 앱 동시 실행)도 확인하지 않았다.

## 확인한 것 (2026-11-21, 가상 자료)

핵심 화면은 **로그인 전 홈(초안 1장 + 초대 대기)**이다. 아래 화면은 두 앱의 E2E 실행 중 같은 상태에서 찍었다(iPhone 18 Pro 시뮬레이터 iOS 27.2, Android 에뮬레이터 API 36).

| | iOS | Android |
| --- | --- | --- |
| 라이트 | ![](screens/ios-home-light.png) | ![](screens/android-home-light.png) |
| 다크 | ![](screens/ios-home-dark.png) | ![](screens/android-home-dark.png) |
| 큰 글자 | ![](screens/ios-home-large-text.png) | ![](screens/android-home-large-text.png) |
| 로그인 시트(debug) | ![](screens/ios-login-sheet.png) | ![](screens/android-login-sheet.png) |
| 로그인 시트(release) | ![](screens/ios-release-login-unavailable.png) | ![](screens/android-release-login-unavailable.png) |
| 여행방 | ![](screens/ios-room.png) | ![](screens/android-room.png) |

- 다크: 모든 글자·라벨이 바탕과 구분된다. 초대 대기 라벨은 반전 색, 주 동작은 라이트에서 검정, 다크에서 흰색이다. 하드코딩한 흰색·검정 글자는 없다.
- 큰 글자(iOS `accessibility-large`, Android `font_scale 2.0`): 글자가 잘리거나 겹치지 않고 줄이 늘어난다. 처음에 Android 초안 행의 상태 라벨을 행 끝에 두었더니 날짜가 좁은 칸에서 음절 단위로 끊겨, 라벨을 날짜 아래로 옮겨 iOS와 같은 배치로 맞췄다. 한국어 어절 줄바꿈도 이때 고쳤다.
- Android는 다크 전환과 글자 크기 변경(설정 변경으로 Activity를 다시 만듦) 뒤에도 같은 화면과 상태가 남는 것을 E2E에서 확인했다.
- 확인하지 않은 것: VoiceOver/TalkBack 읽기 순서, 명암비 수치 측정, 태블릿, 오른쪽에서 왼쪽 언어. 가로 화면·접히는 기기는 위 "창 크기와 접기"에서 확인했다.

## 참고한 플랫폼 문서

- Apple HIG: [Typography](https://developer.apple.com/design/human-interface-guidelines/typography), [Color](https://developer.apple.com/design/human-interface-guidelines/color), [Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode), [Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets), [Sign in with Apple](https://developer.apple.com/design/human-interface-guidelines/sign-in-with-apple)
- Material 3: [Color roles](https://m3.material.io/styles/color/roles), [Typography](https://m3.material.io/styles/typography/applying-type), [Bottom sheets](https://m3.material.io/components/bottom-sheets/guidelines)
- Android: [Photo picker](https://developer.android.com/training/data-storage/shared/photopicker), [Receive data from other apps](https://developer.android.com/training/sharing/receive), [Font scaling](https://developer.android.com/guide/topics/resources/runtime-changes)
- Google: [Sign in with Google branding guidelines](https://developers.google.com/identity/branding-guidelines)
- 창 크기와 접기(확인일 2026-11-21): Apple [Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo), [Preparing your app for iPhone Duo](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo), Android [Use window size classes](https://developer.android.com/develop/ui/compose/layouts/adaptive/use-window-size-classes). API는 Xcode 27.2 SDK의 SwiftUI 인터페이스와 material3-adaptive 1.3.0 소스에서 확인했다.
