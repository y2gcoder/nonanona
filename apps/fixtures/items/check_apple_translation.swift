// macOS 호스트에서 Apple Translation(기기 안) 일본어→한국어를 앱과 같은 API로 확인한다(시뮬레이터는 번역하지 않는다).
// 가상 품목 이름만 넣는다. 사용: swift apps/fixtures/items/check_apple_translation.swift
import Foundation
import Translation

let names = ["枝豆", "鶏の唐揚げ", "生ビール 2杯", "ウーロン茶", "だし巻き玉子", "おにぎり鮭", "緑茶ボトル", "サンドイッチ"]
let ja = Locale.Language(identifier: "ja")
let ko = Locale.Language(identifier: "ko")
let status = await LanguageAvailability().status(from: ja, to: ko)
print("LanguageAvailability ja→ko:", status)
for (label, strategy) in [("highFidelity", TranslationSession.Strategy.highFidelity), ("lowLatency", .lowLatency)] {
  let session = TranslationSession(installedSource: ja, target: ko, preferredStrategy: strategy)
  do {
    let responses = try await session.translations(from: names.map { TranslationSession.Request(sourceText: $0) })
    for (name, r) in zip(names, responses) { print("\(label): \(name) → \(r.targetText)") }
  } catch {
    print("\(label): error \(error)")
  }
}
