// Renders the Nebula app icon (1024 px) and writes every size the asset catalog needs.
// Usage: swift scripts/make-icon.swift <AppIcon.appiconset folder> [preview.png]
import AppKit
import CoreGraphics

let size: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
	CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
	CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
}

func render() -> CGImage {
	let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

	// Body: the macOS icon grid (824 pt squircle inside 1024).
	let body = CGRect(x: 100, y: 100, width: 824, height: 824)
	let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
	ctx.saveGState()
	ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.45))
	ctx.addPath(bodyPath)
	ctx.setFillColor(color(0x050507))
	ctx.fillPath()
	ctx.restoreGState()

	ctx.saveGState()
	ctx.addPath(bodyPath)
	ctx.clip()
	ctx.drawLinearGradient(gradient([color(0x17131F), color(0x060608)]), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

	let center = CGPoint(x: 500, y: 512)
	let radius: CGFloat = 214
	let ring = CGRect(x: center.x - 330, y: center.y - 104, width: 660, height: 208)
	let tilt = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: 0.36).translatedBy(x: -center.x, y: -center.y)

	func strokeRing(front: Bool) {
		ctx.saveGState()
		ctx.concatenate(tilt)
		// Back half above the centre line, front half below it.
		ctx.clip(to: front
			? CGRect(x: 0, y: 0, width: size, height: center.y)
			: CGRect(x: 0, y: center.y, width: size, height: size - center.y))
		ctx.addEllipse(in: ring)
		ctx.setStrokeColor(color(0xB089F0))
		ctx.setLineWidth(18)
		ctx.strokePath()
		ctx.restoreGState()
	}

	strokeRing(front: false)

	// The orb.
	ctx.saveGState()
	ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
	ctx.clip()
	ctx.drawLinearGradient(gradient([color(0xC45CFF), color(0x8C28FF), color(0x4F1BC9)]),
		start: CGPoint(x: center.x - radius, y: center.y + radius), end: CGPoint(x: center.x + radius, y: center.y - radius), options: [])
	// Soft shading on the lower right (not a glow: stays inside the orb).
	ctx.drawRadialGradient(gradient([color(0x1B0036, 0), color(0x1B0036, 0.55)]),
		startCenter: CGPoint(x: center.x - 70, y: center.y + 80), startRadius: radius * 0.4,
		endCenter: CGPoint(x: center.x - 70, y: center.y + 80), endRadius: radius * 1.5, options: [])
	ctx.restoreGState()

	strokeRing(front: true)

	// A small star riding the ring.
	let star = CGPoint(x: ring.maxX - 22, y: center.y + 18).applying(tilt)
	ctx.setFillColor(color(0xFFFFFF))
	ctx.fillEllipse(in: CGRect(x: star.x - 30, y: star.y - 30, width: 60, height: 60))

	// Hairline edge.
	ctx.restoreGState()
	ctx.addPath(bodyPath)
	ctx.setStrokeColor(color(0xFFFFFF, 0.08))
	ctx.setLineWidth(3)
	ctx.strokePath()
	return ctx.makeImage()!
}

func write(_ image: CGImage, pixels: Int, to url: URL) {
	let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
	ctx.interpolationQuality = .high
	ctx.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
	let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
	try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let icon = render()
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
	for scale in [1, 2] {
		let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
		write(icon, pixels: points * scale, to: folder.appending(path: name))
		images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
	}
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: folder.appending(path: "Contents.json"))
if CommandLine.arguments.count > 2 { write(icon, pixels: 1024, to: URL(fileURLWithPath: CommandLine.arguments[2])) }
print("Wrote icon to \(folder.path)")
