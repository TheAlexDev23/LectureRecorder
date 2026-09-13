// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "LectureRecorder", platforms: [.macOS(.v15)], products: [.executable(name: "LectureRecorder", targets: ["LectureRecorder"])], targets: [.executableTarget(name: "LectureRecorder"), .testTarget(name: "LectureRecorderTests", dependencies: ["LectureRecorder"])], swiftLanguageModes: [.v5])
