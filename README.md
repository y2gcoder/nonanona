# 노나노나 (nonanona)

> 같이 쓴 돈, 쉽게 노나노나.

여행이 끝난 뒤 영수증 사진과 결제 화면 캡처를 올리면 지출을 정리하고, 일행끼리 누가 누구에게 얼마를 보낼지 원화로 계산하는 서비스입니다.

현재 기획 단계입니다. 제품 범위는 [docs/00-brief.md](docs/00-brief.md), 결정 기록은 [docs/adr/](docs/adr/)를 보세요.

## 개발 시작

필요한 것: [mise](https://mise.jdx.dev), 1Password 데스크톱 앱과 `op` CLI(비밀값이 필요한 작업에만).

```sh
mise run setup                                 # 도구 설치와 커밋 전 gitleaks 훅
cp mise.local.toml.example mise.local.toml     # 선택: 비밀값이 필요하면 개인 1Password 계정 고정
mise run doctor                                # 도구·훅·1Password 점검
```

비밀값은 1Password의 `nonanona` vault에 두고, 저장소에는 `op://` 참조만 담은 [`.env.tpl`](.env.tpl)을 둡니다. 비밀값이 필요한 명령만 `op run --env-file=.env.tpl -- <명령>`으로 실행합니다.

## 라이선스

코드는 [AGPL-3.0](LICENSE)입니다.
