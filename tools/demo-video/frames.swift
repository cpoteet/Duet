import AVFoundation
import AppKit
// usage: frames in out-dir step [start end] [maxWidth]  -> jpgs named by time; also prints change vs previous sample
let a = CommandLine.arguments
let asset = AVURLAsset(url: URL(fileURLWithPath: a[1])); let out = a[2]; let step = Double(a[3])!
let dur = CMTimeGetSeconds(asset.duration)
let start = a.count > 4 ? Double(a[4])! : 0, end = a.count > 5 ? min(Double(a[5])!, dur) : dur
let maxW = a.count > 6 ? Double(a[6])! : 640
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let gen = AVAssetImageGenerator(asset: asset)
gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
gen.maximumSize = CGSize(width: maxW, height: maxW)
print("duration", dur)
var prev: [UInt8]? = nil
var t = start
while t < end {
  if let cg = try? gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) {
    let rep = NSBitmapImageRep(cgImage: cg)
    try! rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])!.write(to: URL(fileURLWithPath: String(format: "%@/t%05.1f.jpg", out, t)))
    // change metric on a 64x40 thumbnail
    let w = 64, h = 40
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    if let p = prev { var d = 0; for i in 0..<buf.count { d += abs(Int(buf[i]) - Int(p[i])) }; print(String(format: "%5.1f  %6.2f", t, Double(d) / Double(buf.count))) }
    prev = buf
  }
  t += step
}
