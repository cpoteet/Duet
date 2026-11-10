import AVFoundation
import AppKit
// rawframe in.mp4 t out.png : frame values as decoded, relabelled sRGB (no conversion), as browsers show the video
let a = CommandLine.arguments
let asset = AVURLAsset(url: URL(fileURLWithPath: a[1]))
let sem = DispatchSemaphore(value: 0)
Task {
  let track = try! await asset.loadTracks(withMediaType: .video).first!
  let reader = try! AVAssetReader(asset: asset)
  let ro = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
  reader.add(ro); reader.timeRange = CMTimeRange(start: CMTime(seconds: Double(a[2])!, preferredTimescale: 600), duration: CMTime(seconds: 0.2, preferredTimescale: 600))
  reader.startReading()
  let pb = CMSampleBufferGetImageBuffer(ro.copyNextSampleBuffer()!)!
  CVPixelBufferLockBaseAddress(pb, .readOnly)
  let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
  let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
  let img = ctx.makeImage()!
  try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[3]))
  sem.signal()
}
sem.wait()
