import Foundation

/// Nebula's generated wallpapers. Each is a set of soft colour blobs on a dark base, drawn
/// at any resolution by the renderer, so they stay sharp at 4K and add nothing to the app size.
public struct WallpaperSpec: Hashable, Sendable, Identifiable {
	public struct Blob: Hashable, Sendable {
		public var center: NormPoint
		/// Radius as a fraction of the longer side.
		public var radius: Double
		public var color: ColorValue
	}

	public var id: String
	public var name: String
	public var base: ColorValue
	public var blobs: [Blob]
}

public enum BuiltInWallpapers {
	public static let all: [WallpaperSpec] = [
		spec("aurora", "Aurora", base: "#07050D", [
			(0.15, 0.20, 0.55, "#6828FF"), (0.85, 0.15, 0.45, "#B22EFF"), (0.55, 0.95, 0.60, "#2A0F6E"),
		]),
		spec("dusk", "Dusk", base: "#0C0614", [
			(0.10, 0.90, 0.60, "#8C28FF"), (0.90, 0.85, 0.40, "#FF5FA2"), (0.60, 0.05, 0.50, "#3B1D8F"),
		]),
		spec("lagoon", "Lagoon", base: "#04080F", [
			(0.20, 0.25, 0.55, "#1E5BFF"), (0.80, 0.70, 0.55, "#7A3CFF"), (0.50, 1.00, 0.40, "#00B3C7"),
		]),
		spec("ember", "Ember", base: "#0D0605", [
			(0.15, 0.85, 0.55, "#FF6A3D"), (0.85, 0.20, 0.50, "#B22EFF"), (0.55, 0.45, 0.35, "#5A1E8C"),
		]),
		spec("mist", "Mist", base: "#121018", [
			(0.25, 0.30, 0.60, "#B089F0"), (0.80, 0.80, 0.55, "#6E6A85"), (0.75, 0.10, 0.35, "#D8CCF5"),
		]),
		spec("orbit", "Orbit", base: "#020204", [
			(0.50, 0.50, 0.38, "#8C28FF"), (0.50, 0.50, 0.70, "#1B0D2E"),
		]),
		spec("meadow", "Meadow", base: "#050B08", [
			(0.20, 0.80, 0.55, "#1FAA6B"), (0.85, 0.25, 0.50, "#3E7BFA"), (0.50, 0.10, 0.35, "#A3E36B"),
		]),
		spec("sunrise", "Sunrise", base: "#120708", [
			(0.10, 0.10, 0.55, "#FFB547"), (0.90, 0.30, 0.55, "#FF4F7A"), (0.50, 0.95, 0.55, "#7B2CFF"),
		]),
	]

	public static var ids: [String] { all.map(\.id) }

	public static func spec(id: String) -> WallpaperSpec {
		all.first { $0.id == id } ?? all[0]
	}

	private static func spec(_ id: String, _ name: String, base: String, _ blobs: [(Double, Double, Double, String)]) -> WallpaperSpec {
		WallpaperSpec(
			id: id,
			name: name,
			base: ColorValue(hex: base) ?? .black,
			blobs: blobs.map { WallpaperSpec.Blob(center: NormPoint(x: $0.0, y: $0.1), radius: $0.2, color: ColorValue(hex: $0.3) ?? .violet) }
		)
	}
}
