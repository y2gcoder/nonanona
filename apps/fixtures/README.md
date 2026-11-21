# 가상 테스트 자료

`receipts/`의 영수증 10장(`receipt-r01.png`~`receipt-r10.png`)과 정답(`ground-truth.json`)은 native-batch-import 실험의 생성기로 만든 가상 일본어 영수증이다. 가게·주소·전화·카드·회원·예약 번호와 EXIF·GPS·설명 메타데이터가 모두 가상 값이며 `SYNTHETIC-ORIGINAL-METADATA rNN` 표지를 담고 있다. r10은 초점을 일부러 흐린 사진이라 실제 OCR이 읽지 못한다. 정답에는 날짜·합계·가게, 각 줄의 위치, 가려야 할 민감한 줄의 위치가 있다.

- 앱 번들에는 들어가지 않는다. 단위 테스트(iOS `ReceiptImport` 패키지, Android JVM)와 시뮬레이터·에뮬레이터 E2E만 쓴다.
- `check_artifact.py`: 기기에서 꺼낸 원본과 가림 사본을 정답과 비교한다(표준 라이브러리 PNG 디코더). 원본을 사본으로 넣으면 실패하는 것으로 검사기 자체를 확인했다.
