// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "LectureRecorder", platforms: [.macOS(.v15)], products: [.executable(name: "LectureRecorder", targets: ["LectureRecorder"])], targets: [.target(name: "AudioTap"), .executableTarget(name: "LectureRecorder", dependencies: ["AudioTap"]), .testTarget(name: "LectureRecorderTests", dependencies: ["LectureRecorder", "AudioTap"])], swiftLanguageModes: [.v5])
