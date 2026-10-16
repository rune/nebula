// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "NebulaKit",
	platforms: [.macOS(.v15)],
	products: [
		.library(name: "NebulaApp", targets: ["NebulaApp"]),
		.library(name: "NebulaCore", targets: ["NebulaCore"]),
	],
	dependencies: [
		.package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.0"),
	],
	targets: [
		.target(name: "NebulaCore"),
		.target(name: "NebulaDesign", resources: [.process("Resources")]),
		.target(name: "NebulaPolish", dependencies: ["NebulaCore"]),
		.target(name: "NebulaCapture", dependencies: ["NebulaCore"]),
		.target(name: "NebulaAudio", dependencies: ["NebulaCore"]),
		.target(name: "NebulaRender", dependencies: ["NebulaCore", "NebulaPolish", "NebulaAudio"]),
		.target(
			name: "NebulaCaptions",
			dependencies: ["NebulaCore", .product(name: "WhisperKit", package: "WhisperKit")]
		),
		.target(name: "NebulaMCP", dependencies: ["NebulaCore"]),
		.target(
			name: "NebulaApp",
			dependencies: [
				"NebulaCore", "NebulaDesign", "NebulaPolish", "NebulaCapture", "NebulaAudio",
				"NebulaRender", "NebulaCaptions", "NebulaMCP",
			]
		),
		.testTarget(name: "NebulaCoreTests", dependencies: ["NebulaCore"]),
		.testTarget(name: "NebulaPolishTests", dependencies: ["NebulaPolish"]),
		.testTarget(name: "NebulaRenderTests", dependencies: ["NebulaRender"]),
		.testTarget(name: "NebulaAudioTests", dependencies: ["NebulaAudio"]),
		.testTarget(name: "NebulaMCPTests", dependencies: ["NebulaMCP"]),
	]
)
