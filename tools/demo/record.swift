import Foundation
import ScreenCaptureKit
import AVFoundation
import AppKit

final class Recorder: NSObject, SCRecordingOutputDelegate {
    var finished = false
    var failure: Error?
    func recordingOutputDidStartRecording(_ output: SCRecordingOutput) { print("RECORDING_STARTED"); fflush(stdout) }
    func recordingOutputDidFinishRecording(_ output: SCRecordingOutput) { finished = true }
    func recordingOutput(_ output: SCRecordingOutput, didFailWithError error: Error) { failure = error; finished = true }
}
@main struct Main {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        guard CommandLine.arguments.count >= 4 else { fatalError("Usage: record output.mp4 seconds app-pid") }
        let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let seconds = Double(CommandLine.arguments[2])!
        let pid = Int32(CommandLine.arguments[3])!
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let window = content.windows.filter({ $0.owningApplication?.processID == pid && $0.frame.width > 500 }).max(by: { $0.frame.width < $1.frame.width }) else { fatalError("App window not found") }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width) * 2
        config.height = Int(window.frame.height) * 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = false
        config.sampleRate = 48000
        config.channelCount = 2
        config.showsCursor = false
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let recordingConfig = SCRecordingOutputConfiguration()
        recordingConfig.outputURL = outputURL
        recordingConfig.videoCodecType = .h264
        recordingConfig.outputFileType = .mp4
        let delegate = Recorder()
        let output = SCRecordingOutput(configuration: recordingConfig, delegate: delegate)
        try stream.addRecordingOutput(output)
        try await stream.startCapture()
        for _ in 0..<Int(seconds * 10) {
            if CommandLine.arguments.count > 4 && FileManager.default.fileExists(atPath: CommandLine.arguments[4]) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await stream.stopCapture()
        for _ in 0..<100 where !delegate.finished { try await Task.sleep(for: .milliseconds(100)) }
        if let error = delegate.failure { throw error }
        guard delegate.finished else { fatalError("Recording did not finalize") }
        print("RECORDING_SAVED \(outputURL.path)")
    }
}
