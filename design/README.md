# 디자인 토큰

기준 원본은 [ADR-0014](../docs/adr/0014-unified-design-system.md)에서 정한 비공개 Claude Design System 아티팩트 **노나노나 디자인 시스템**이다. 디자인이 바뀌면 아티팩트에서 `tokens.json`을 내려받아 [저장소 사본](tokens.json)을 교체한다.

```sh
mise run design:tokens
mise run design:check
```

`design:tokens`는 다음 두 파일을 만든다. 생성 파일은 손으로 고치지 않는다. JSON과 생성 파일을 함께 커밋한다.

- [iOS DesignTokens.swift](../apps/ios/Nonanona/Design/DesignTokens.swift)는 시스템 라이트·다크를 따르는 SwiftUI 색을 제공한다. 간격·둥글기·크기와 글자 크기·줄높이는 pt이고, 굵기는 숫자, 자간은 글자 크기에 대한 비율(em)이다.
- [Android DesignTokens.kt](../apps/android/app/src/main/java/app/nonanona/design/DesignTokens.kt)는 라이트·다크 색 묶음을 제공한다. 간격·둥글기·크기는 dp, 글자 크기·줄높이는 sp, 자간은 em이고, 굵기는 Compose `FontWeight`다.

`design:check`는 생성기 테스트를 실행하고, 임시로 생성한 결과를 현재 파일과 비교한다. 값이 다르면 차이와 갱신 명령을 출력한다. 모든 PR과 main 푸시에서 CI가 이 작업을 실행한다.

그림자는 두 플랫폼에서 오프셋과 흐림을 적용하는 방식이 달라, 시트와 하단 막대에 적용할 때 각 플랫폼에서 해석한다. 원본 값은 JSON에 있다.
