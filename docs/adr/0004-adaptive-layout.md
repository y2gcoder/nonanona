# 창 크기와 접기에 맞춘 모바일 화면 배치

상태: accepted (2026-11-21)

두 앱은 기기 모델이 아니라 지금 창의 크기 종류, 창 크기, 시스템이 알려 주는 접힘(예약 영역·hinge)으로 배치를 정한다. 접히는 폰(iPhone Duo, Android 폴더블), 가로, 분할 화면에서 같은 화면 상태가 이어져야 하고, 나중의 영수증 목록·상세(가림 편집 포함)가 접힘 위에 놓이면 안 되기 때문이다. 근거 문서: [Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo), [Preparing your app for iPhone Duo](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo), [Use window size classes](https://developer.android.com/develop/ui/compose/layouts/adaptive/use-window-size-classes) (확인일 2026-11-21).

## 결정

- **시스템 목록·상세 컨테이너를 쓴다.** iOS는 `NavigationSplitView`(`.balanced`), Android는 Navigation 3의 `ListDetailSceneStrategy`(material3-adaptive)다. 홈이 목록, 초안·초대·여행방이 상세다. 공용 배치 프레임워크나 기기별 배치는 만들지 않는다.
- **두 칸이 되는 기준은 플랫폼 기본값을 따른다.** iOS는 가로 크기 종류가 regular일 때(iPhone Duo 안쪽 화면, Pro Max 가로), Android는 창 폭 840dp(expanded) 이상일 때다. 같은 크기의 창이 두 플랫폼에서 다르게 보일 수 있다(예: 600~840dp는 Android 한 칸). 플랫폼 지침에서 벗어나지 않는 쪽을 골랐다.
- **접힘 위에 내용·버튼을 두지 않는다.** iOS는 목록을 숨기는 버튼을 없애(`.toolbar(removing: .sidebarToggle)`) 상세가 창 전체(접힘 포함)를 쓰는 일이 없게 하고, 열 폭은 시스템이 접힘에 맞춘다. 그래서 넓은 창에서 목록을 숨길 수 없다. Android는 세로 separating hinge가 창을 나누면 폭이 좁아도 두 칸으로 바꿔 두 칸을 접힘 양쪽에 둔다. 시스템이 옮겨 주지 않는 Android 시트·대화상자는 두 앱이 같은 규칙(`ContentMargins.fitting`)으로 넓은 쪽에 둔다. 넓은 창의 글 위주 화면은 640(pt·dp) 폭으로 제한한다.
- **화면 상태는 모델에 안정 ID로 둔다.** iOS `AppModel.selection`, Android `AppViewModel.backStack`(`Route`)과 처리기·올리기 상태가 창 크기 변경, 접기, 회전, Activity 다시 만들기를 지나도 남는다. 처리기를 새로 만들지 않으므로 OCR·올리기가 다시 시작되지 않는다.
- **창(시트·확인)은 화면 맨 위에서 한 번만 띄운다.** 로그인 시트와 올릴 곳·장수 최종 확인은 상태를 모델에 두고 `RootView`·`NonanonaApp`에서 띄운다. iOS 최종 확인은 행 안 버튼의 확인 시트(넓은 창에서 팝오버)에서 가운데 알림으로 바꿨다. 팝오버가 열린 채 회전해 크기 종류가 바뀌면 다시 뜨지 못하고 멈추는 것을 시뮬레이터에서 재현했다.

## 확인한 것 (2026-11-23, iPhone Duo 시뮬레이터)

Device Hub 자세 버튼으로 실제 자세를 바꿔 봤다(`ios:e2e-posture`, 자세 이름과 좌표는 [apps/README](../../apps/README.md#iphone-duo-자세-2026-11-23-시뮬레이터)). 결정은 바꾸지 않는다.

- 안쪽 화면이 접힘에서 꺾인 자세(book, 시스템 hinge `partiallyOpen` 133.8°)에서는 시스템이 활성 세로 division(951pt 창의 455.5–495.5)을 알리고, 분할 보기 열과 가운데 알림을 그 밖에 둔다. 앱이 직접 피하지 않아도 내용·버튼이 접힘 위에 오지 않았다. "시스템 컨테이너에 맡긴다"가 이 자세에서 맞았다.
- 평평한 자세(flat, hinge `fullyOpen` 180°)에서는 같은 자리의 division이 안정된 뒤 비활성(`isActive == false`)이고, 열이 기본 폭(목록 320)으로 돌아가며 가운데 알림과 초안 내용이 그 자리에 걸친다. Apple 문서는 접힘 division이 반쯤 열렸을 때만 활성이고 완전히 열리면 비활성이라고 한다([ReservedRegion](https://developer.apple.com/documentation/swiftui/reservedregion), 확인일 2026-11-23). 그래서 정상 동작으로 보고, 앱 여백은 지금처럼 활성 division만 피한다(비활성 영역까지 미리 비우지 않는다).
- 자세가 바뀌어도 고른 초안, 처리 상태(중복 OCR 없음), 열린 최종 확인이 남고 한 번만 올라갔다.

## 나중 디자인에 주는 제약

- 영수증 목록·상세(가림 편집)를 붙일 때도 위 컨테이너 안에서 상세 쪽에 둔다. 상세 안에서 두 영역(사진·편집)을 더 나누면 iOS는 예약 영역(`ReservedRegion` division)을, Android는 `WindowAdaptiveInfo.windowPosture`의 hinge를 보고 접힘을 피한다. 두 영역을 접힘 양쪽에 두는 일은 iOS `ArrangementView`(SwiftUI, iOS 27.1+)를 먼저 검토한다. 정정(2026-11-23): 예전에 "Xcode 27.2 SDK에 없다"고 적었으나 SwiftUICore 인터페이스에 공개돼 있고 iOS 27.2 시뮬레이터 대상으로 타입 검사를 통과한다. 지금 화면에는 두 영역 나누기가 없어 쓰지 않는다.
- 넓은 창에서 목록 숨기기가 필요해지면 그 화면이 예약 영역을 직접 피하는지 먼저 확인하고 이 결정을 다시 쓴다.
