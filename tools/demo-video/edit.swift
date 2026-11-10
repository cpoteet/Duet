import AVFoundation
import AppKit
import CoreImage
// usage: edit in.mov out.mp4 spec.json
// A screen recording cut into a short, looping demo. One segment table drives the cut; everything
// else (camera, overlays, cues) is keyed to source times and mapped through it, then eased in output time.
// spec: width, height, fps, bitrate,
//   segments [[srcStart, srcEnd, speed], ...], holdEnd (seconds the last frame is held)
//   intro {hold, out, icon, title, subtitle}   card animates in, holds, then lifts away as the scene rises in
//   outro {in, hold, out, icon, title, subtitle} scene settles back as the card animates in, holds, lifts away
//   fonts [paths], fadeColor [r, g, b] (backdrop, raw 0-255)
//   chip {src, lead, hold, centerY}            key chip for the shortcut
//   lift {from, to, rect [x,y,w,h], radius, scale, dim, blur, ease, easeOut}   raise a window out of the frame
//   camera [[src, cx, cy, zoom], ...]          virtual camera, output pixels (top-left origin)
//   cursor {keys [[src, x, y], ...], press src, fadeIn, hide src}   synthetic arrow cursor gliding between keys
//   clicks [[src, x, y], ...]                  press ripple
//   xfade {src, dur}                           crossfade into the segment that starts at src (holds the outgoing frame)
//   cues {name: src}                           printed as output times, for the page's step labels
let a = CommandLine.arguments
let spec = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: a[3]))) as! [String: Any]
func num(_ v: Any?) -> Double { (v as! NSNumber).doubleValue }
let W = Int(num(spec["width"])), H = Int(num(spec["height"])), fps = num(spec["fps"]), bitrate = Int(num(spec["bitrate"]))
let Wd = Double(W), Hd = Double(H)
let segs = (spec["segments"] as! [[Any]]).map { (num($0[0]), num($0[1]), num($0[2])) }
let holdEnd = spec["holdEnd"].map(num) ?? 0
let intro = spec["intro"] as? [String: Any], outro = spec["outro"] as? [String: Any]
let pre = intro.map { num($0["hold"]) } ?? 0
var segOut: [Double] = []
var acc = 0.0
for s in segs { segOut.append(acc); acc += (s.1 - s.0) / s.2 }
let playDur = acc
let sceneEnd = pre + playDur + holdEnd
let total = sceneEnd + (outro.map { num($0["hold"]) + num($0["out"]) } ?? 0)
func srcTime(_ t: Double) -> Double {   // t is output time
  let st = t - pre
  for (i, s) in segs.enumerated() { let d = (s.1 - s.0) / s.2; if st < segOut[i] + d { return s.0 + max(0, st - segOut[i]) * s.2 } }
  return segs.last!.1
}
func outTime(_ src: Double) -> Double {
  for (i, s) in segs.enumerated() { if src < s.0 { return pre + segOut[i] }; if src <= s.1 { return pre + segOut[i] + (src - s.0) / s.2 } }
  return pre + playDur
}
func clamp01(_ x: Double) -> Double { max(0, min(1, x)) }
func ease(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
func easeIn(_ x: Double) -> Double { x * x * x }
func easeOutBack(_ x: Double) -> Double { let c1 = 1.70158, c3 = c1 + 1; return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2) }
let fadeRGB = ((spec["fadeColor"] as? [Any]) ?? [21, 33, 62]).map { CGFloat(num($0) / 255) }
for f in (spec["fonts"] as? [String]) ?? [] { CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: f) as CFURL, .process, nil) }

func bitmap(_ w: Int, _ h: Int, _ draw: () -> Void) -> CGImage {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  draw()
  NSGraphicsContext.restoreGraphicsState()
  return rep.cgImage!
}
// The backdrop colour. Replaced by a corner of the first source frame once it is read, so the cards'
// background takes exactly the footage's path and the two match.
var navyCI = CIImage(color: CIColor(red: fadeRGB[0], green: fadeRGB[1], blue: fadeRGB[2])).cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
func alpha(_ img: CIImage, _ a: CGFloat) -> CIImage {
  // CIColorMatrix works on unpremultiplied colour, so scaling alpha alone is a plain fade.
  img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: a)])
}
func scaled(_ img: CIImage, _ s: CGFloat, about c: CGPoint = CGPoint(x: Wd / 2, y: Hd / 2)) -> CIImage {
  img.transformed(by: CGAffineTransform(translationX: -c.x, y: -c.y).concatenating(CGAffineTransform(scaleX: s, y: s)).concatenating(CGAffineTransform(translationX: c.x, y: c.y)))
}
let frame = CGRect(x: 0, y: 0, width: W, height: H)

// Title card: icon, title, subtitle. kIn and kOut are seconds into the in and out phases;
// each element staggers in (icon springs, text rises) and lifts away on the way out.
let serif = NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: "Source Serif 4", .traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.semibold]]), size: 92) ?? NSFont.systemFont(ofSize: 92, weight: .semibold)
let sans = NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: "Geist"]), size: 34) ?? NSFont.systemFont(ofSize: 34)
var iconCache: [String: NSImage] = [:]
func cardImage(_ c: [String: Any], kIn: Double, kOut: Double) -> CGImage {
  bitmap(W, H) {
    func phase(_ i: Int) -> (p: Double, q: Double) { (clamp01((kIn - 0.13 * Double(i)) / 0.7), clamp01((kOut - 0.07 * Double(i)) / 0.5)) }
    let path = c["icon"] as! String
    let icon = iconCache[path] ?? NSImage(contentsOfFile: path)!; iconCache[path] = icon
    let cy = CGFloat(Hd / 2 + 84)
    // icon
    let (p0, q0) = phase(0)
    let ia = CGFloat(easeOut(clamp01(p0 * 1.6)) * (1 - easeIn(q0)))
    let isz = CGFloat(200 * (0.55 + 0.45 * easeOutBack(p0)) * (1 - 0.08 * easeIn(q0)))
    let iyOff = CGFloat(-34 * easeIn(q0))
    let r = NSRect(x: CGFloat(Wd / 2) - isz / 2, y: cy - isz / 2 - iyOff, width: isz, height: isz)
    if ia > 0 {
      NSGraphicsContext.saveGraphicsState()
      let sh = NSShadow(); sh.shadowColor = NSColor(white: 0, alpha: 0.45 * ia); sh.shadowBlurRadius = 34; sh.shadowOffset = NSSize(width: 0, height: -14); sh.set()
      NSColor(white: 1, alpha: ia).setFill(); NSBezierPath(roundedRect: r, xRadius: isz * 0.225, yRadius: isz * 0.225).fill()
      NSGraphicsContext.restoreGraphicsState()
      NSGraphicsContext.saveGraphicsState()
      NSBezierPath(roundedRect: r, xRadius: isz * 0.225, yRadius: isz * 0.225).addClip()
      icon.draw(in: r, from: .zero, operation: .sourceOver, fraction: ia)
      NSGraphicsContext.restoreGraphicsState()
    }
    // text rows
    var y = cy - 100 - 44
    for (i, (str, font, color, kern)) in [(c["title"] as! String, serif, NSColor(deviceRed: 0.93, green: 0.95, blue: 0.98, alpha: 1), -1.2), (c["subtitle"] as! String, sans, NSColor(deviceRed: 0.70, green: 0.74, blue: 0.84, alpha: 1), 0.0)].enumerated() {
      let (p, q) = phase(i + 1)
      let al = CGFloat(easeOut(p) * (1 - easeIn(q)))
      let dy = CGFloat(-26 * (1 - easeOut(p)) + 34 * easeIn(q))
      let s = NSAttributedString(string: str, attributes: [.font: font, .kern: kern, .foregroundColor: color.withAlphaComponent(al)])
      let sz = s.size()
      y -= sz.height
      if al > 0 { s.draw(at: NSPoint(x: (CGFloat(Wd) - sz.width) / 2, y: y + dy)) }
      y -= 14
    }
  }
}

// Key chip: a dark pill whose keys land one after another, redrawn per frame while it shows.
// k is time since the chip started; each key fades and drops in 70 ms after the previous one.
func chipImage(_ k: Double) -> CGImage {
  let keys = ["⌃", "⌥", "Space"]
  let keyH: CGFloat = 50, pad: CGFloat = 14, gap: CGFloat = 10
  let font = NSFont.systemFont(ofSize: 24, weight: .semibold)
  let widths = keys.map { max(keyH, ($0 as NSString).size(withAttributes: [.font: font]).width + 32) }
  let w = widths.reduce(0, +) + gap * CGFloat(keys.count - 1) + pad * 2, h = keyH + pad * 2
  let shadow: CGFloat = 24
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w + shadow * 2), pixelsHigh: Int(h + shadow * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let body = NSRect(x: shadow, y: shadow, width: w, height: h)
  let sh = NSShadow(); sh.shadowColor = NSColor(white: 0, alpha: 0.35); sh.shadowBlurRadius = 18; sh.shadowOffset = NSSize(width: 0, height: -6)
  NSGraphicsContext.saveGraphicsState(); sh.set()
  NSColor(srgbRed: 0.075, green: 0.11, blue: 0.21, alpha: 0.96).setFill()
  NSBezierPath(roundedRect: body, xRadius: 20, yRadius: 20).fill()
  NSGraphicsContext.restoreGraphicsState()
  NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10).setStroke()
  let outline = NSBezierPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5), xRadius: 20, yRadius: 20); outline.lineWidth = 1; outline.stroke()
  var x = shadow + pad
  for (i, key) in keys.enumerated() {
    let p = max(0, min(1, (k - 0.05 - Double(i) * 0.07) / 0.16)), e = CGFloat(1 - pow(1 - p, 3))
    let r = NSRect(x: x, y: shadow + pad + (1 - e) * 8, width: widths[i], height: keyH)
    let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: 10, yRadius: 10)
    NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14 * e).setFill(); path.fill()
    NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.32 * e).setStroke(); path.lineWidth = 1.5; path.stroke()
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(srgbRed: 0.95, green: 0.96, blue: 1, alpha: e)]
    let sz = (key as NSString).size(withAttributes: attrs)
    (key as NSString).draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2), withAttributes: attrs)
    x += widths[i] + gap
  }
  NSGraphicsContext.restoreGraphicsState()
  return rep.cgImage!
}
// Click ripple: a ring that grows and fades, k = time since the click.
func rippleImage(_ k: Double) -> CGImage {
  let size = 120, rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let p = min(1, k / 0.5), e = 1 - pow(1 - p, 3), c = CGFloat(size) / 2
  let r = CGFloat(10 + 40 * e)
  let dotA = CGFloat(max(0, 1 - k / 0.3)) * 0.7
  NSColor(white: 1, alpha: dotA).setFill()
  NSBezierPath(ovalIn: NSRect(x: c - 13, y: c - 13, width: 26, height: 26)).fill()
  NSColor(srgbRed: 0.06, green: 0.2, blue: 0.6, alpha: CGFloat(0.9 * (1 - p))).setStroke()
  let ring = NSBezierPath(ovalIn: NSRect(x: c - r, y: c - r, width: r * 2, height: r * 2)); ring.lineWidth = 3.5; ring.stroke()
  NSGraphicsContext.restoreGraphicsState()
  return rep.cgImage!
}
// Cursor: the system arrow, drawn at screen size times the camera zoom.
_ = NSApplication.shared
let arrow = NSCursor.arrow
let arrowPts = arrow.image.size, arrowHot = arrow.hotSpot
let arrowCG = bitmap(Int(arrowPts.width * 4), Int(arrowPts.height * 4)) { arrow.image.draw(in: NSRect(x: 0, y: 0, width: arrowPts.width * 4, height: arrowPts.height * 4)) }
let ptToOut = spec["pointScale"].map(num) ?? 1.2529
let cursorSpec = spec["cursor"] as? [String: Any]
let cursorKeys: [(Double, Double, Double)] = ((cursorSpec?["keys"] as? [[Any]]) ?? []).map { (outTime(num($0[0])), num($0[1]), num($0[2])) }
let cursorPress = cursorSpec.map { outTime(num($0["press"])) } ?? -1
let cursorHide = cursorSpec?["hide"].map { outTime(num($0)) } ?? .infinity
func cursorAt(_ t: Double) -> (Double, Double, Double)? {   // x, y, alpha
  guard let f = cursorKeys.first, let l = cursorKeys.last else { return nil }
  let fadeIn = cursorSpec?["fadeIn"].map(num) ?? 0.25
  if t < f.0 - fadeIn || t >= cursorHide { return nil }
  let al = clamp01((t - (f.0 - fadeIn)) / fadeIn)
  if t <= f.0 { return (f.1, f.2, al) }
  for i in 1..<cursorKeys.count where t < cursorKeys[i].0 {
    let p = cursorKeys[i - 1], q = cursorKeys[i], k = ease((t - p.0) / max(1e-6, q.0 - p.0))
    return (p.1 + (q.1 - p.1) * k, p.2 + (q.2 - p.2) * k, al)
  }
  return (l.1, l.2, al)
}
let clicks: [(Double, Double, Double)] = ((spec["clicks"] as? [[Any]]) ?? []).map { (outTime(num($0[0])), num($0[1]), num($0[2])) }

// Virtual camera
let camKeys: [(Double, Double, Double, Double)] = ((spec["camera"] as? [[Any]]) ?? []).map { (outTime(num($0[0])), num($0[1]), num($0[2]), num($0[3])) }
func camAt(_ t: Double) -> (Double, Double, Double) {
  guard let first = camKeys.first else { return (Wd / 2, Hd / 2, 1) }
  if t <= first.0 { return (first.1, first.2, first.3) }
  for i in 1..<max(1, camKeys.count) where t < camKeys[i].0 {
    let a = camKeys[i - 1], b = camKeys[i], k = ease((t - a.0) / max(1e-6, b.0 - a.0))
    return (a.1 + (b.1 - a.1) * k, a.2 + (b.2 - a.2) * k, exp(log(a.3) + (log(b.3) - log(a.3)) * k))
  }
  let l = camKeys.last!; return (l.1, l.2, l.3)
}
// Lift
let liftSpec = spec["lift"] as? [String: Any]
func liftAmount(_ t: Double) -> Double {
  guard let l = liftSpec else { return 0 }
  let a = outTime(num(l["from"])), b = outTime(num(l["to"])), e = l["ease"].map(num) ?? 0.35, eo = l["easeOut"].map(num) ?? e
  if t <= a || t >= b { return 0 }
  return ease(min(1, (t - a) / e, (b - t) / max(1e-3, eo)))
}
let xfade = spec["xfade"] as? [String: Any]
let xfadeAt = xfade.map { outTime(num($0["src"])) } ?? -1, xfadeDur = xfade.map { num($0["dur"]) } ?? 0

var chipCI: CIImage? = nil, chipStart = 0.0, chipEnd = 0.0, chipCY = 0.0
if let c = spec["chip"] as? [String: Any] {
  chipCI = CIImage(cgImage: chipImage(1))
  chipStart = max(0, outTime(num(c["src"])) - num(c["lead"])); chipEnd = chipStart + num(c["hold"])
  chipCY = Hd - num(c["centerY"])
}
var report: [String: Any] = ["duration": total, "sceneStart": pre, "sceneEnd": sceneEnd]
if let cues = spec["cues"] as? [String: Any] { report["cues"] = cues.mapValues { (outTime(num($0)) * 100).rounded() / 100 } }

let asset = AVURLAsset(url: URL(fileURLWithPath: a[1]))
let outURL = URL(fileURLWithPath: a[2]); try? FileManager.default.removeItem(at: outURL)
let sem = DispatchSemaphore(value: 0)
nonisolated(unsafe) var keep: [AnyObject] = []
Task {
  do {
    let track = try await asset.loadTracks(withMediaType: .video).first!
    let natural = try await track.load(.naturalSize)
    let reader = try AVAssetReader(asset: asset)
    let ro = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(ro)
    guard reader.startReading() else { print("reader failed", reader.error as Any); exit(1) }
    let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
    writer.shouldOptimizeForNetworkUse = true
    let wi = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
      AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel, AVVideoMaxKeyFrameIntervalKey: Int(fps * 2), AVVideoExpectedSourceFrameRateKey: Int(fps)],
      AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
    wi.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: wi, sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H])
    writer.add(wi); writer.startWriting(); writer.startSession(atSourceTime: .zero)
    keep = [reader, ro, writer, wi, adaptor]
    // No colour management: decoded values pass straight through so the backdrop keeps its colour.
    let ci = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    let sx = CGFloat(W) / natural.width, sy = CGFloat(H) / natural.height, f = Double(natural.width) / Wd
    var cur: CVPixelBuffer? = nil, next: (Double, CVPixelBuffer)? = nil, eof = false
    func pull() { if let sb = ro.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) { next = (CMSampleBufferGetPresentationTimeStamp(sb).seconds, pb) } else { next = nil; eof = true } }
    pull()
    if let first = next?.1 {
      navyCI = CIImage(cvPixelBuffer: first, options: [.colorSpace: NSNull()]).cropped(to: CGRect(x: 6, y: 6, width: 2, height: 2)).clampedToExtent().cropped(to: frame)
    }
    var frozenPB: CVPixelBuffer? = nil
    CVPixelBufferCreate(nil, W, H, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &frozenPB)
    let frames = Int((total * fps).rounded())

    func scene(_ t: Double, _ src: CVPixelBuffer) -> CIImage {
      var base = CIImage(cvPixelBuffer: src, options: [.colorSpace: NSNull()])
      let lk = liftAmount(t)
      if lk > 0, let l = liftSpec {
        let r = (l["rect"] as! [Any]).map(num)
        let rect = CGRect(x: r[0] * f, y: (Hd - r[1] - r[3]) * f, width: r[2] * f, height: r[3] * f)
        let k = CGFloat(lk), sc = CGFloat(1 + ((l["scale"].map(num) ?? 1.15) - 1) * lk), dim = 1 - CGFloat(l["dim"].map(num) ?? 0.5) * k
        let ext = base.extent
        let bg = base.clampedToExtent().applyingGaussianBlur(sigma: (l["blur"].map(num) ?? 10) * lk * f).cropped(to: ext)
          .applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: dim, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: dim, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: dim, w: 0)])
        let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: ["inputExtent": CIVector(cgRect: rect), "inputRadius": (l["radius"].map(num) ?? 20) * f, "inputColor": CIColor(red: 1, green: 1, blue: 1)])!.outputImage!
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: ext)
        let panel = base.applyingFilter("CIBlendWithAlphaMask", parameters: ["inputBackgroundImage": clear, "inputMaskImage": mask])
        let shadow = mask.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.55 * k)])
          .applyingGaussianBlur(sigma: 22 * f).transformed(by: CGAffineTransform(translationX: 0, y: -18 * f * k))
        let about = CGAffineTransform(translationX: -rect.midX, y: -rect.midY).concatenating(CGAffineTransform(scaleX: sc, y: sc)).concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY + 8 * f * k))
        base = panel.transformed(by: about).composited(over: shadow.transformed(by: about).composited(over: bg)).cropped(to: ext)
      }
      let (cx0, cy0, z0) = camAt(t)
      let z = max(1, z0), hw = Wd / (2 * z), hh = Hd / (2 * z)
      let cx = min(max(cx0, hw), Wd - hw), cyBL = min(max(Hd - cy0, hh), Hd - hh)
      func toFrame(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: (x - (cx - hw)) * z, y: ((Hd - y) - (cyBL - hh)) * z) }
      let cam = CGAffineTransform(scaleX: sx * CGFloat(z), y: sy * CGFloat(z)).concatenating(CGAffineTransform(translationX: CGFloat(-(cx - hw) * z), y: CGFloat(-(cyBL - hh) * z)))
      var img = base.transformed(by: cam, highQualityDownsample: true).cropped(to: frame)
      if chipCI != nil, t >= chipStart, t <= chipEnd {
        let fin = min(1, (t - chipStart) / 0.3), fout = min(1, (chipEnd - t) / 0.35)
        let s = CGFloat(0.92 + 0.08 * easeOutBack(fin)), rise = CGFloat(14 * (1 - easeOut(fin)))
        let chip = CIImage(cgImage: chipImage(t - chipStart)), e = chip.extent
        img = alpha(chip, CGFloat(min(easeOut(fin), easeOut(fout))))
          .transformed(by: CGAffineTransform(translationX: -e.width / 2, y: -e.height / 2))
          .transformed(by: CGAffineTransform(scaleX: s, y: s))
          .transformed(by: CGAffineTransform(translationX: CGFloat(Wd) / 2, y: CGFloat(chipCY) - rise))
          .composited(over: img)
      }
      for c in clicks where t >= c.0 && t < c.0 + 0.5 {
        let p = toFrame(c.1, c.2), rip = CIImage(cgImage: rippleImage(t - c.0))
        img = rip.transformed(by: CGAffineTransform(translationX: p.x - rip.extent.width / 2, y: p.y - rip.extent.height / 2)).composited(over: img)
      }
      if let (x, y, al) = cursorAt(t) {
        let press = (t >= cursorPress && t < cursorPress + 0.22) ? 1 - 0.14 * sin(.pi * (t - cursorPress) / 0.22) : 1
        let s = CGFloat(ptToOut * z * press) / CGFloat(arrowCG.width) * arrowPts.width
        let p = toFrame(x, y), cur = CIImage(cgImage: arrowCG)
        // hot spot is top-left based, in points
        let hx = arrowHot.x / arrowPts.width * CGFloat(arrowCG.width), hy = (1 - arrowHot.y / arrowPts.height) * CGFloat(arrowCG.height)
        img = alpha(cur, CGFloat(al)).transformed(by: CGAffineTransform(translationX: -hx, y: -hy).concatenating(CGAffineTransform(scaleX: s, y: s)).concatenating(CGAffineTransform(translationX: p.x, y: p.y))).composited(over: img)
      }
      return img
    }

    for n in 0..<frames {
      let t = Double(n) / fps
      var img = navyCI
      // the scene shows from the intro's lift-away until the outro has covered it
      let outroIn = outro.map { num($0["in"]) } ?? 0
      if t >= pre && t < sceneEnd {
        let st = srcTime(t)
        while !eof, let nx = next, nx.0 <= st + 0.0005 { cur = nx.1; pull() }
        if cur == nil, let nx = next { cur = nx.1 }
        guard let src = cur else { continue }
        var s = scene(t, src)
        // crossfade: hold the last outgoing frame, push it gently forward while the new scene settles in
        if xfadeDur > 0 {
          if t < xfadeAt && t + 1 / fps >= xfadeAt { ci.render(s, to: frozenPB!, bounds: frame, colorSpace: nil) }
          if t >= xfadeAt && t < xfadeAt + xfadeDur {
            let e = CGFloat(ease((t - xfadeAt) / xfadeDur))
            let held = scaled(CIImage(cvPixelBuffer: frozenPB!, options: [.colorSpace: NSNull()]), 1 + 0.05 * e)
            s = alpha(held, 1 - e).composited(over: scaled(s, 0.965 + 0.035 * e).composited(over: navyCI)).cropped(to: frame)
          }
        }
        // intro: the scene rises in from slightly small; outro: it settles back and fades
        var k: CGFloat = 1, sc: CGFloat = 1
        if let i = intro, t < pre + num(i["out"]) { let e = CGFloat(ease(clamp01((t - pre) / num(i["out"])))); k = e; sc = 0.93 + 0.07 * e }
        if outro != nil, t > sceneEnd - outroIn { let e = CGFloat(ease(clamp01((t - (sceneEnd - outroIn)) / outroIn))); k = min(k, 1 - e); sc = min(sc, 1 - 0.07 * e) }
        img = alpha(scaled(s, sc), k).composited(over: navyCI).cropped(to: frame)
      }
      if let i = intro, t < pre + num(i["out"]) {
        img = CIImage(cgImage: cardImage(i, kIn: t + 0.0, kOut: t - pre)).composited(over: img)
      }
      if let o = outro, t > sceneEnd - outroIn * 0.7 {
        img = CIImage(cgImage: cardImage(o, kIn: t - (sceneEnd - outroIn * 0.7), kOut: t - (sceneEnd + num(o["hold"])))).composited(over: img)
      }
      var out: CVPixelBuffer? = nil
      CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &out)
      ci.render(img.cropped(to: frame), to: out!, bounds: frame, colorSpace: nil)
      while !wi.isReadyForMoreMediaData { usleep(2000) }
      adaptor.append(out!, withPresentationTime: CMTime(value: CMTimeValue(n), timescale: CMTimeScale(fps)))
    }
    wi.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(fps)))
    await writer.finishWriting()
    if writer.status != .completed { print("writer failed", writer.error as Any); exit(1) }
    print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
  } catch { print("error", error); exit(1) }
  sem.signal()
}
sem.wait()
