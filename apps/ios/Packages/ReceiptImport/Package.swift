// swift-tools-version: 6.0
// 앱과 공유 확장이 함께 쓰는 영수증 가져오기 코드(ADR-0003). 외부 의존성 없음.
import PackageDescription

let package = Package(
  name: "ReceiptImport",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [.library(name: "ReceiptImport", targets: ["ReceiptImport"])],
  targets: [
    .target(name: "ReceiptImport"),
    .testTarget(name: "ReceiptImportTests", dependencies: ["ReceiptImport"]),
  ]
)
