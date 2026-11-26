# 가상 테스트 자료

`receipts/`의 영수증 10장(`receipt-r01.png`~`receipt-r10.png`)과 정답(`ground-truth.json`)은 native-batch-import 실험의 생성기로 만든 가상 일본어 영수증이다. 가게·주소·전화·카드·회원·예약 번호와 EXIF·GPS·설명 메타데이터가 모두 가상 값이며 `SYNTHETIC-ORIGINAL-METADATA rNN` 표지를 담고 있다. r10은 초점을 일부러 흐린 사진이라 실제 OCR이 읽지 못한다. 정답에는 날짜·합계·가게, 각 줄의 위치, 가려야 할 민감한 줄의 위치가 있다.

- 앱 번들에는 들어가지 않는다. 단위 테스트(iOS `ReceiptImport` 패키지, Android JVM)와 시뮬레이터·에뮬레이터 E2E만 쓴다.
- `settlement/examples.json`: 정산 공통 예제(가상 값). `pair_splits`(둘이 반씩), `settlement`(계약 시험의 여행방), `krw_conversions`(엔화 환산: 취득 원가·기준환율 예상, 원 단위 반올림). 서버 계약 시험과 두 앱 단위 테스트가 같이 읽는다.
- `settlement/fx-responses/`: 로컬 서버에서 받은 실제 응답(장부·미리보기·v1·v2 확정본, 가상 계정·가상 시험 환율). `scripts/capture-fx-responses.py`로 다시 만든다. 정정 상태(ADR-0009)의 장부·미리보기·확정 거절 응답(`ledger-correction.json`·`preview-correction.json`·`finalize-correction-refused.json`)은 `scripts/capture-fx-correction-responses.py`로 다시 만든다. 계정 ID는 고정한 가상 UUID로 바꿨다. 두 앱의 응답 해석 시험이 읽는다.
- `settlement/proposal-responses/`: [ADR-0011](../../docs/adr/0011-cross-device-item-share-proposals.md)의 제안 보내기 응답과 방장·올린 회원·다른 회원의 장부 응답이다. 두 앱의 응답 해석 시험이 읽는다. `mise run local:up` 뒤 저장소 루트에서 `python3 -I scripts/capture-proposal-responses.py`를 실행하면 새 가상 여행방에서 응답을 받아 고정 파일을 다시 만든다. 계정 ID는 고정한 가상 UUID로 바꾼다.
- `check_artifact.py`: 기기에서 꺼낸 원본과 가림 사본을 정답과 비교한다(표준 라이브러리 PNG 디코더). 원본을 사본으로 넣으면 실패하는 것으로 검사기 자체를 확인했다.
- `items/`: 품목별 나누기 자료([ADR-0010](../../docs/adr/0010-on-device-item-split.md)). `receipt-i01.png`(가상 居酒屋, 품목 5개·내세 합계 3,500엔·수량 표시 1줄)와 `receipt-i02.png`(가상 マート, 품목 3개·할인 -50·소계 648·세금 51·합계 699엔)는 `make_item_receipts.swift`(macOS CoreText, Hiragino Sans)로 만든 가상 영수증이다. 사진 앱 설명에 `SYNTHETIC-ITEMS-METADATA iNN` 표지가 있다. `examples.json`은 두 앱이 같이 읽는 공통 예제다: `extraction`(OCR 줄 → 품목·요약·표시), `real_ocr`(실제 OCR로 읽은 두 장의 정답), `allocation`(사람마다 원 몫·남은 원·문제, 기대값은 손으로 계산). `check_apple_translation.swift`는 macOS 호스트에서 Apple Translation 기기 번역을 앱과 같은 API로 확인한다.
