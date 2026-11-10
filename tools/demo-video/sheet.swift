import AppKit
// usage: sheet out.jpg cols cellWidth files...
let a = CommandLine.arguments
let cols = Int(a[2])!, cw = CGFloat(Double(a[3])!)
let files = Array(a[4...])
let imgs = files.compactMap { NSImage(contentsOfFile: $0) }
let ch = cw * imgs[0].size.height / imgs[0].size.width
let rows = (imgs.count + cols - 1) / cols
let W = Int(cw) * cols, H = Int(ch + 18) * rows
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.white.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
for (i, img) in imgs.enumerated() {
  let x = CGFloat(i % cols) * cw, y = CGFloat(H) - CGFloat(i / cols + 1) * (ch + 18)
  img.draw(in: NSRect(x: x + 2, y: y + 2, width: cw - 4, height: ch - 4))
  (URL(fileURLWithPath: files[i]).lastPathComponent as NSString).draw(at: NSPoint(x: x + 4, y: y + ch), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
}
try! rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75])!.write(to: URL(fileURLWithPath: a[1]))
