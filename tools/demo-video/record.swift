import ScreenCaptureKit
import AVFoundation
import AppKit
// Records a region of the main display, leaving out the Claude app's windows (its control overlay).
// usage: record <out.mov> <seconds> x y w h   (points, top-left origin)
let a = CommandLine.arguments
let out = URL(fileURLWithPath: a[1]); let seconds = Double(a[2])!
let rect = CGRect(x: Double(a[3])!, y: Double(a[4])!, width: Double(a[5])!, height: Double(a[6])!)
final class Delegate: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
  func recordingOutputDidStartRecording(_ r: SCRecordingOutput) { print("recording started"); fflush(stdout) }
  func recordingOutput(_ r: SCRecordingOutput, didFailWithError e: Error) { print("record failed", e); exit(1) }
  func recordingOutputDidFinishRecording(_ r: SCRecordingOutput) { print("recording finished"); exit(0) }
  func stream(_ s: SCStream, didStopWithError e: Error) { print("stream stopped", e) }
}
let delegate = Delegate()
Task {
  do {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    let display = content.displays.first { $0.displayID == CGMainDisplayID() }!
    let excluded = content.applications.filter { $0.bundleIdentifier.hasPrefix("com.anthropic.") }
    print("excluding", excluded.map(\.bundleIdentifier))
    let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
    let config = SCStreamConfiguration()
    config.sourceRect = rect
    config.width = Int(rect.width * 2); config.height = Int(rect.height * 2)
    config.showsCursor = false
    config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    config.capturesAudio = false
    let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
    let rc = SCRecordingOutputConfiguration()
    rc.outputURL = out; rc.outputFileType = .mov; rc.videoCodecType = .h264
    let rec = SCRecordingOutput(configuration: rc, delegate: delegate)
    try stream.addRecordingOutput(rec)
    try await stream.startCapture()
    try await Task.sleep(for: .seconds(seconds))
    try stream.removeRecordingOutput(rec)
    try await stream.stopCapture()
    try await Task.sleep(for: .seconds(3))
    print("stopped without finish callback"); exit(0)
  } catch { print("error", error); exit(1) }
}
NSApplication.shared.setActivationPolicy(.accessory); NSApplication.shared.run()
