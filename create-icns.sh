#!/bin/bash
# Convert SVG to icns using built-in macOS tools

set -e

# Create iconset directory
rm -rf AppIcon.iconset
mkdir AppIcon.iconset

# Use sips to convert (need PNG first)
# Since we have SVG, use qlmanage or convert via Preview export
# Fallback: create simple PNG with built-in tools

# Check if we have rsvg-convert (from librsvg)
if command -v rsvg-convert &> /dev/null; then
    echo "Using rsvg-convert..."
    for size in 16 32 64 128 256 512; do
        rsvg-convert -w $size -h $size icon.svg -o "AppIcon.iconset/icon_${size}x${size}.png"
        rsvg-convert -w $((size*2)) -h $((size*2)) icon.svg -o "AppIcon.iconset/icon_${size}x${size}@2x.png"
    done
elif command -v convert &> /dev/null; then
    echo "Using ImageMagick..."
    for size in 16 32 64 128 256 512; do
        convert -background none -resize ${size}x${size} icon.svg "AppIcon.iconset/icon_${size}x${size}.png"
        convert -background none -resize $((size*2))x$((size*2)) icon.svg "AppIcon.iconset/icon_${size}x${size}@2x.png"
    done
else
    echo "No SVG converter found. Creating icon programmatically..."
    
    # Use Swift to create icon
    swift - << 'SWIFT'
import AppKit

let sizes = [16, 32, 64, 128, 256, 512]
let iconsetPath = "AppIcon.iconset"

for size in sizes {
    for scale in [1, 2] {
        let pixelSize = size * scale
        let image = NSImage(size: NSSize(width: pixelSize, height: pixelSize))
        
        image.lockFocus()
        
        // Background
        let bgPath = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize), 
                                   xRadius: CGFloat(pixelSize) * 0.18, 
                                   yRadius: CGFloat(pixelSize) * 0.18)
        NSColor(red: 0.23, green: 0.51, blue: 0.96, alpha: 1).setFill()
        bgPath.fill()
        
        // Hard drive
        let driveRect = NSRect(x: CGFloat(pixelSize) * 0.19, y: CGFloat(pixelSize) * 0.31,
                               width: CGFloat(pixelSize) * 0.62, height: CGFloat(pixelSize) * 0.38)
        let drivePath = NSBezierPath(roundedRect: driveRect, xRadius: 8, yRadius: 8)
        NSColor(white: 0.92, alpha: 1).setFill()
        drivePath.fill()
        NSColor(white: 0.7, alpha: 1).setStroke()
        drivePath.lineWidth = CGFloat(pixelSize) * 0.01
        drivePath.stroke()
        
        // LED
        let ledCenter = NSPoint(x: CGFloat(pixelSize) * 0.78, y: CGFloat(pixelSize) * 0.58)
        let ledPath = NSBezierPath(ovalIn: NSRect(x: ledCenter.x - CGFloat(pixelSize) * 0.03,
                                                   y: ledCenter.y - CGFloat(pixelSize) * 0.03,
                                                   width: CGFloat(pixelSize) * 0.06,
                                                   height: CGFloat(pixelSize) * 0.06))
        NSColor(red: 0.13, green: 0.77, blue: 0.37, alpha: 1).setFill()
        ledPath.fill()
        
        // Heartbeat circle
        let heartCenter = NSPoint(x: CGFloat(pixelSize) * 0.5, y: CGFloat(pixelSize) * 0.22)
        let heartPath = NSBezierPath(ovalIn: NSRect(x: heartCenter.x - CGFloat(pixelSize) * 0.11,
                                                     y: heartCenter.y - CGFloat(pixelSize) * 0.11,
                                                     width: CGFloat(pixelSize) * 0.22,
                                                     height: CGFloat(pixelSize) * 0.22))
        NSColor(red: 0.94, green: 0.27, blue: 0.27, alpha: 1).setFill()
        heartPath.fill()
        
        // Heartbeat line
        let pulse = NSBezierPath()
        let py = heartCenter.y
        let px = heartCenter.x
        let s = CGFloat(pixelSize) * 0.055
        pulse.move(to: NSPoint(x: px - s*4, y: py))
        pulse.line(to: NSPoint(x: px - s*2, y: py))
        pulse.line(to: NSPoint(x: px - s, y: py + s*2.5))
        pulse.line(to: NSPoint(x: px, y: py - s*3))
        pulse.line(to: NSPoint(x: px + s, y: py + s*1.5))
        pulse.line(to: NSPoint(x: px + s*2, y: py))
        pulse.line(to: NSPoint(x: px + s*4, y: py))
        NSColor.white.setStroke()
        pulse.lineWidth = CGFloat(pixelSize) * 0.015
        pulse.lineCapStyle = .round
        pulse.lineJoinStyle = .round
        pulse.stroke()
        
        image.unlockFocus()
        
        // Save
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { continue }
        
        let suffix = scale == 2 ? "@2x" : ""
        let filename = "\(iconsetPath)/icon_\(size)x\(size)\(suffix).png"
        try? png.write(to: URL(fileURLWithPath: filename))
        print("Created \(filename)")
    }
}
SWIFT
fi

# Create icns
iconutil -c icns AppIcon.iconset -o AppIcon.icns

echo "✅ Created AppIcon.icns"

# Cleanup
rm -rf AppIcon.iconset
