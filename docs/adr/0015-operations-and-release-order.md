# 운영 환경과 출시 순서

상태: accepted (2026-11-28, 사용자 합의). [ADR-0003](0003-mobile-architecture.md)을 유지한다(자체 서버 앱 없음). [ADR-0002](0002-authentication-and-device-transfer.md)의 "발송 서비스는 출시 준비에서 결정한다"를 정한다.

지금은 로컬 Supabase와 debug 빌드만 있다. 출시에 필요한 운영 환경, 인증 메일, 스토어 계정, 관측 도구를 한 번에 정한다.

## 결정

- **자체 서버 앱은 두지 않는다.** 서버 쪽 코드는 Supabase(인증·DB·저장소·RPC)와 품목 재번역 Worker(`workers/item-translation`)뿐이다.
- **운영 Supabase는 클라우드 서울 리전이고, 출시 직전에 만든다.** 스키마와 설정은 저장소의 `supabase/migrations`와 `supabase/config.toml`이 기준이고 CI가 반영한다. 대시보드에서 직접 고치지 않는다. 운영 상태가 저장소와 어긋나지 않게 하고, 바꾼 이력을 PR로 남기기 위해서다.
- **인증 메일은 Supabase 사용자 지정 SMTP에 Resend를 연결해 보낸다.** 기기 이전과 계정 복구 코드([ADR-0002](0002-authentication-and-device-transfer.md))다. 보내는 주소용 도메인을 사고, 같은 도메인을 초대 링크의 Universal Links·App Links에도 쓴다.
- **Android를 먼저 출시한다.** Google Play 개인 계정의 비공개 테스트(12명·14일)를 참가자 시험과 겹쳐 진행한다. Apple Developer는 iPhone 사용자를 시험에 넣어야 할 때 가입한다. iOS 코드는 계속 함께 맞춘다.
- **관측은 크래시에 Sentry, 사용 흐름에 PostHog를 쓴다.** PostHog는 기존 조직에 노나노나 프로젝트를 만들고 종량제에 청구 상한을 건다. 화면 녹화는 끈다. 이벤트와 크래시에는 금액, 가게 이름, OCR 글자, 사진을 넣지 않는다. 이 규칙은 두 도구를 붙일 때 시험으로 고정한다.

## 정하지 않은 것

- **스테이징 Supabase를 둘지**는 운영 기반 작업을 시작할 때 정한다. 두자는 이유: 모바일 앱은 바로 되돌릴 수 없고 옛 판 앱이 운영 DB를 계속 쓰므로 마이그레이션을 운영 전에 옛 앱과 함께 시험해야 하고, Apple·Google OAuth 설정도 운영 전에 시험해야 한다. 대가는 프로젝트 하나의 비용과 관리다.

## 대가

- 서버 동작이 Supabase가 제공하는 범위(RPC, 정책, 저장소)에 묶인다. 넘어서는 일이 생기면 [ADR-0003](0003-mobile-architecture.md)의 HTTP 구현체 전환을 따른다.
- 대시보드에서 급히 고칠 수 없다. 운영 장애도 PR과 CI를 거친다.
- 도메인, Resend, Google Play, Sentry, PostHog 계정을 따로 관리하고 비용이 생긴다.
- iPhone 사용자는 Android보다 늦게 받는다.
