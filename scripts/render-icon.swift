// Renders build/AppIcon.icns: a macOS-style rounded square with an update arrow.
// Run via scripts/make-app.sh (needs only Command Line Tools).
import AppKit

let canvas: CGFloat = 1024
let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()

// macOS icon grid: rounded rect inset ~10% with ~22.5% corner radius.
let inset: CGFloat = canvas * 0.1
let rect = NSRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset)
let radius = rect.width * 0.225
let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

let gradient = NSGradient(
    starting: NSColor(calibratedRed: 0.16, green: 0.47, blue: 0.96, alpha: 1),
    ending: NSColor(calibratedRed: 0.42, green: 0.20, blue: 0.90, alpha: 1)
)!
gradient.draw(in: squircle, angle: -60)

// Circular "refresh" ring, broken at the top-right where the arrow head sits.
let center = NSPoint(x: canvas / 2, y: canvas / 2)
let ringRadius = rect.width * 0.27
let ring = NSBezierPath()
ring.appendArc(withCenter: center, radius: ringRadius, startAngle: 60, endAngle: 320)
ring.lineWidth = canvas * 0.055
ring.lineCapStyle = .round
NSColor.white.setStroke()
ring.stroke()

// Arrow head at the ring's open end (60°), pointing along the tangent.
let headAngle: CGFloat = 60 * .pi / 180
let tip = NSPoint(x: center.x + ringRadius * cos(headAngle),
                  y: center.y + ringRadius * sin(headAngle))
let tangent = headAngle + .pi / 2  // counter-clockwise travel direction
let headSize = canvas * 0.11
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: tip.x + headSize * cos(tangent),
                       y: tip.y + headSize * sin(tangent)))
arrow.line(to: NSPoint(x: tip.x + headSize * 0.7 * cos(headAngle),
                       y: tip.y + headSize * 0.7 * sin(headAngle)))
arrow.line(to: NSPoint(x: tip.x - headSize * 0.7 * cos(headAngle),
                       y: tip.y - headSize * 0.7 * sin(headAngle)))
arrow.close()
NSColor.white.setFill()
arrow.fill()

// Upward arrow in the middle: "updates available".
let shaft = NSBezierPath()
shaft.move(to: NSPoint(x: center.x, y: center.y - rect.width * 0.13))
shaft.line(to: NSPoint(x: center.x, y: center.y + rect.width * 0.10))
shaft.lineWidth = canvas * 0.05
shaft.lineCapStyle = .round
shaft.stroke()

let up = NSBezierPath()
let upTip = NSPoint(x: center.x, y: center.y + rect.width * 0.16)
let upSize = canvas * 0.085
up.move(to: upTip)
up.line(to: NSPoint(x: upTip.x - upSize, y: upTip.y - upSize))
up.line(to: NSPoint(x: upTip.x + upSize, y: upTip.y - upSize))
up.close()
up.fill()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
else {
    fatalError("Could not render icon PNG")
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "build/icon-1024.png")
try! FileManager.default.createDirectory(
    at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
try! png.write(to: out)
print("Wrote \(out.path)")
