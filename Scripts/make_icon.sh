#!/usr/bin/env bash
#
# make_icon.sh — generate the Process Explorer app icon.
#
# Draws a base 1024x1024 PNG (a Sysinternals-style dark rounded tile with a
# green CPU bar-graph / activity pulse motif) using a tiny AppKit Swift program,
# then downsamples it with `sips` into every size the macOS asset catalog needs
# and writes the matching Contents.json. Also emits a standalone AppIcon.icns
# via `iconutil` for convenience / About-box use.
#
# Idempotent: re-running regenerates everything from scratch.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSET_DIR="$REPO_ROOT/App/Assets.xcassets/AppIcon.appiconset"
BUILD_DIR="$REPO_ROOT/build"
BASE_PNG="$BUILD_DIR/AppIcon-1024.png"

mkdir -p "$ASSET_DIR" "$BUILD_DIR"

# ---------------------------------------------------------------------------
# 1. Draw the base 1024x1024 PNG with AppKit / CoreGraphics.
# ---------------------------------------------------------------------------
DRAW_SWIFT="$(mktemp -t procexp_icon).swift"
trap 'rm -f "$DRAW_SWIFT"' EXIT

cat > "$DRAW_SWIFT" <<'SWIFT'
import AppKit
import Foundation

let side = 1024.0
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(side), pixelsHigh: Int(side),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
    NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a)
}

// Transparent canvas.
ctx.clear(CGRect(x: 0, y: 0, width: side, height: side))

// Rounded "app tile" with padding (macOS icon grid leaves a margin).
let pad = 100.0
let tile = CGRect(x: pad, y: pad, width: side - 2*pad, height: side - 2*pad)
let radius = 185.0
let tilePath = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

// Vertical gradient background: deep navy -> near-black.
ctx.saveGState()
tilePath.addClip()
let bg = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [rgb(27, 42, 74).cgColor, rgb(14, 22, 38).cgColor] as CFArray,
    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: side), end: CGPoint(x: 0, y: 0), options: [])

// Subtle top sheen.
let sheen = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [rgb(255, 255, 255, 0.10).cgColor, rgb(255, 255, 255, 0).cgColor] as CFArray,
    locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: side - pad),
                       end: CGPoint(x: 0, y: side * 0.6), options: [])
ctx.restoreGState()

// CPU history bar graph: bars of varying height in a green gradient,
// evoking a live activity monitor.
let heights: [Double] = [0.30, 0.48, 0.38, 0.62, 0.52, 0.78, 0.66, 0.92, 0.72, 0.58]
let plotPad = 210.0
let plot = CGRect(x: plotPad, y: plotPad,
                  width: side - 2*plotPad, height: side - 2*plotPad)
let n = Double(heights.count)
let gap = plot.width * 0.028
let barW = (plot.width - gap * (n - 1)) / n

let greenTop = rgb(61, 220, 132)     // #3DDC84
let greenBot = rgb(37, 160, 96)      // deeper green

for (i, h) in heights.enumerated() {
    let x = plot.minX + Double(i) * (barW + gap)
    let barH = max(plot.height * h, barW)
    let bar = CGRect(x: x, y: plot.minY, width: barW, height: barH)
    let barPath = NSBezierPath(roundedRect: bar,
                               xRadius: barW * 0.22, yRadius: barW * 0.22)
    ctx.saveGState()
    barPath.addClip()
    let grad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [greenTop.cgColor, greenBot.cgColor] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: bar.maxY),
                           end: CGPoint(x: 0, y: bar.minY), options: [])
    ctx.restoreGState()
}

// A "pulse" line tracing the bar tops for a signal/telemetry feel.
let pulse = NSBezierPath()
pulse.lineWidth = 14
pulse.lineJoinStyle = .round
pulse.lineCapStyle = .round
for (i, h) in heights.enumerated() {
    let x = plot.minX + Double(i) * (barW + gap) + barW / 2
    let y = plot.minY + max(plot.height * h, barW) + 26
    let pt = CGPoint(x: x, y: min(y, plot.maxY))
    if i == 0 { pulse.move(to: pt) } else { pulse.line(to: pt) }
}
rgb(180, 255, 210, 0.85).setStroke()
pulse.stroke()

NSGraphicsContext.restoreGraphicsState()

let outPath = CommandLine.arguments[1]
guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("failed to encode PNG\n".utf8))
    exit(1)
}
try data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
SWIFT

echo "Drawing base icon…"
swift "$DRAW_SWIFT" "$BASE_PNG"

# ---------------------------------------------------------------------------
# 2. Downsample into every appiconset size.
# ---------------------------------------------------------------------------
gen() { # <pixels> <output-filename>
    sips -s format png -z "$1" "$1" "$BASE_PNG" --out "$ASSET_DIR/$2" >/dev/null
}

echo "Generating icon sizes into $ASSET_DIR …"
gen 16   icon_16x16.png
gen 32   icon_16x16@2x.png
gen 32   icon_32x32.png
gen 64   icon_32x32@2x.png
gen 128  icon_128x128.png
gen 256  icon_128x128@2x.png
gen 256  icon_256x256.png
gen 512  icon_256x256@2x.png
gen 512  icon_512x512.png
gen 1024 icon_512x512@2x.png

# ---------------------------------------------------------------------------
# 3. Write the asset catalog Contents.json.
# ---------------------------------------------------------------------------
cat > "$ASSET_DIR/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16",   "filename" : "icon_16x16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16",   "filename" : "icon_16x16@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32",   "filename" : "icon_32x32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32",   "filename" : "icon_32x32@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon_128x128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon_128x128@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon_256x256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon_256x256@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon_512x512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon_512x512@2x.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

# ---------------------------------------------------------------------------
# 4. Also emit a standalone AppIcon.icns (handy outside the asset catalog).
# ---------------------------------------------------------------------------
ICONSET="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for spec in \
    "16 icon_16x16.png" "32 icon_16x16@2x.png" \
    "32 icon_32x32.png" "64 icon_32x32@2x.png" \
    "128 icon_128x128.png" "256 icon_128x128@2x.png" \
    "256 icon_256x256.png" "512 icon_256x256@2x.png" \
    "512 icon_512x512.png" "1024 icon_512x512@2x.png"; do
    set -- $spec
    sips -z "$1" "$1" "$BASE_PNG" --out "$ICONSET/$2" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$BUILD_DIR/AppIcon.icns"
echo "Wrote $BUILD_DIR/AppIcon.icns"

echo "Icon generation complete."
