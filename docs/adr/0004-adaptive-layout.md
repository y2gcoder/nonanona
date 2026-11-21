# 창 크기와 접기에 맞춘 모바일 화면 배치

상태: accepted (2026-11-21)

두 앱은 기기 모델이 아니라 지금 창의 크기 종류, 창 크기, 시스템이 알려 주는 접힘(예약 영역·hinge)으로 배치를 정한다. 접히는 폰(iPhone Duo, Android 폴더블), 가로, 분할 화면에서 같은 화면 상태가 이어져야 하고, 나중의 영수증 목록·상세(가림 편집 포함)가 접힘 위에 놓이면 안 되기 때문이다. 근거 문서: [Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo), [Preparing your app for iPhone Duo](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo), [Use window size classes](https://developer.android.com/develop/ui/compose/layouts/adaptive/use-window-size-classes) (확인일 2026-11-21).

## 결정

- **시스템 목록·상세 컨테이너를 쓴다.** iOS는 `NavigationSplitView`(`.balanced`), Android는 Navigation 3의 `ListDetailSceneStrategy`(material3-adaptive)다. 홈이 목록, 초안·초대·여행방이 상세다. 공용 배치 프레임워크나 기기별 배치는 만들지 않는다.
- **두 칸이 되는 기준은 플랫폼 기본값을 따른다.** iOS는 가로 크기 종류가 regular일 때(iPhone Duo 안쪽 화면, Pro Max 가로), Android는 창 폭 840dp(expanded) 이상일 때다. 같은 크기의 창이 두 플랫폼에서 다르게 보일 수 있다(예: 600~840dp는 Android 한 칸). 플랫폼 지침에서 벗어나지 않는 쪽을 골랐다.
- **접힘 위에 내용·버튼을 두지 않는다.** iOS는 목록을 숨기는 버튼을 없애(`.toolbar(removing: .sidebarToggle)`) 상세가 창 전체(접힘 포함)를 쓰는 일이 없게 하고, 열 폭은 시스템이 접힘에 맞춘다. 그래서 넓은 창에서 목록을 숨길 수 없다. Android는 세로 separating hinge가 창을 나누면 폭이 좁아도 두 칸으로 바꿔 두 칸을 접힘 양쪽에 둔다. 시스템이 옮겨 주지 않는 Android 시트·대화상자는 두 앱이 같은 규칙(`ContentMargins.fitting`)으로 넓은 쪽에 둔다. 넓은 창의 글 위주 화면은 640(pt·dp) 폭으로 제한한다.
- **화면 상태는 모델에 안정 ID로 둔다.** iOS `AppModel.selection`, Android `AppViewModel.backStack`(`Route`)과 처리기·올리기 상태가 창 크기 변경, 접기, 회전, Activity 다시 만들기를 지나도 남는다. 처리기를 새로 만들지 않으므로 OCR·올리기가 다시 시작되지 않는다.
- **창(시트·확인)은 화면 맨 위에서 한 번만 띄운다.** 로그인 시트와 올릴 곳·장수 최종 확인은 상태를 모델에 두고 `RootView`·`NonanonaApp`에서 띄운다. iOS 최종 확인은 행 안 버튼의 확인 시트(넓은 창에서 팝오버)에서 가운데 알림으로 바꿨다. 팝오버가 열린 채 회전해 크기 종류가 바뀌면 다시 뜨지 못하고 멈추는 것을 시뮬레이터에서 재현했다.

## 나중 디자인에 주는 제약

- 영수증 목록·상세(가림 편집)를 붙일 때도 위 컨테이너 안에서 상세 쪽에 둔다. 상세 안에서 두 영역(사진·편집)을 더 나누면 iOS는 예약 영역(`ReservedRegion` division)을, Android는 `WindowAdaptiveInfo.windowPosture`의 hinge를 보고 접힘을 피한다. iOS `ArrangementView`는 Xcode 27.2 SDK에 없어 쓰지 않았다(문서에는 있음, UIKit `UIArrangementViewController`만 있음).
- 넓은 창에서 목록 숨기기가 필요해지면 그 화면이 예약 영역을 직접 피하는지 먼저 확인하고 이 결정을 다시 쓴다.
