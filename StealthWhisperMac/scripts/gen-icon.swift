// Generates AppIcon.png (1024x1024) for Stealth Whisper:
// dark blue-black gradient squircle with a white waveform symbol.
// Run: swift scripts/gen-icon.swift <output.png>
import AppKit

let size = CGFloat(1024)
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// Background: rounded rect (Apple icon grid uses ~22.5% corner radius)
let inset = size * 0.05
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.225, yRadius: size * 0.225)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.20, alpha: 1),
    NSColor(calibratedRed: 0.02, green: 0.03, blue: 0.07, alpha: 1),
])!
gradient.draw(in: path, angle: -90)

// Accent ring, echoing the "stealth" circle of the menu bar icon
let ring = NSBezierPath(ovalIn: rect.insetBy(dx: size * 0.09, dy: size * 0.09))
ring.lineWidth = size * 0.018
NSColor(calibratedRed: 0.25, green: 0.55, blue: 1.0, alpha: 0.85).setStroke()
ring.stroke()

// Waveform bars
let barCount = 9
let heights: [CGFloat] = [0.16, 0.30, 0.48, 0.68, 0.54, 0.68, 0.42, 0.28, 0.14]
let barWidth = size * 0.042
let gap = size * 0.028
let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap
var x = (size - totalWidth) / 2
NSColor.white.setFill()
for h in heights {
    let barHeight = size * h * 0.62
    let barRect = NSRect(x: x, y: (size - barHeight) / 2, width: barWidth, height: barHeight)
    NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    x += barWidth + gap
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("Failed to render icon")
}
try! png.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
