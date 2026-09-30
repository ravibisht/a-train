// render-background.swift — draws the Installer window background: A-Train logo bottom-left with the
// tagline beneath it, on a transparent canvas. Usage:
//   swift render-background.swift <logo.png> <out.png> <light|dark> <scale>
import AppKit

let args = CommandLine.arguments
guard args.count >= 5, let logo = NSImage(contentsOfFile: args[1]), let scale = Double(args[4]) else {
    FileHandle.standardError.write("usage: render-background.swift <logo.png> <out.png> <light|dark> <scale>\n".data(using: .utf8)!)
    exit(1)
}
let dark = args[3] == "dark"
let tagline = "Made out of frustration, so you don’t have to be."
let w = 620.0, h = 418.0                                  // Installer pane size in points
let px = Int(w * scale), py = Int(h * scale)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: py, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: w, height: h)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: w, height: h).fill()

// Installer's sidebar is only ~175 pt wide (the text pane covers the rest): logo 112 pt, text wrapped to fit
let logoSize = 112.0, left = 30.0, bottom = 34.0
let textColor = dark ? NSColor(white: 0.92, alpha: 1) : NSColor(white: 0.20, alpha: 1)
let subColor  = dark ? NSColor(white: 0.70, alpha: 1) : NSColor(white: 0.45, alpha: 1)
let tagAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: textColor]
let subAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: subColor]
let line1 = NSAttributedString(string: "Made out of frustration,", attributes: tagAttrs)
let line2 = NSAttributedString(string: "so you don’t have to be.", attributes: tagAttrs)
let sub = NSAttributedString(string: "Split tunnel for the Check Point VPN", attributes: subAttrs)
sub.draw(at: NSPoint(x: left, y: bottom))
line2.draw(at: NSPoint(x: left, y: bottom + 16))
line1.draw(at: NSPoint(x: left, y: bottom + 31))
logo.draw(in: NSRect(x: left - 4, y: bottom + 52, width: logoSize, height: logoSize), from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(2) }
try! png.write(to: URL(fileURLWithPath: args[2]))
