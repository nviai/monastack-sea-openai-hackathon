import Foundation
import ScreenCaptureKit
import AVFoundation
import AppKit

// Capture app-only pixels/audio with ScreenCaptureKit. Encode video in software
// to avoid unavailable VideoToolbox/ReplayKit encoders on the host.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "office.demo.capture")
    let encoder = Process()
    let pipe = Pipe()
    let url: URL
    let videoURL: URL
    let audioURL: URL
    let width: Int
    let height: Int
    var start: CMTime?
    var audioStart: CMTime?
    var previous: Data?
    var seen = 0
    var frames = 0
    var audioSamples = 0
    var audioFile: AVAudioFile?
    var failure: Error?

    init(url: URL, width: Int, height: Int) throws {
        self.url = url; self.width = width; self.height = height
        videoURL = url.deletingPathExtension().appendingPathExtension("video.mp4")
        audioURL = url.deletingPathExtension().appendingPathExtension("audio.wav")
        super.init()
        encoder.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        encoder.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-f", "rawvideo", "-pixel_format", "bgra", "-video_size", "\(width)x\(height)", "-framerate", "30", "-i", "pipe:0", "-an", "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p", videoURL.path]
        encoder.standardInput = pipe
        try encoder.run()
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { failure = error }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        if seen < 5 { print("SAMPLE type=\(type.rawValue) valid=\(sample.isValid) image=\(sample.imageBuffer != nil) attachments=\(String(describing: CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)))"); fflush(stdout); seen += 1 }
        guard sample.isValid, failure == nil else { return }
        let time = sample.presentationTimeStamp
        do {
            switch type {
            case .screen:
                guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                      let status = attachments.first?[.status] as? Int,
                      status == SCFrameStatus.complete.rawValue,
                      let pixel = sample.imageBuffer else { return }
                if start == nil { start = time }
                let target = Int((time - start!).seconds * 30)
                if let previous {
                    while frames < target { try pipe.fileHandleForWriting.write(contentsOf: previous); frames += 1 }
                }
                CVPixelBufferLockBaseAddress(pixel, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
                guard let base = CVPixelBufferGetBaseAddress(pixel) else { return }
                let stride = CVPixelBufferGetBytesPerRow(pixel)
                var pixels = Data(capacity: width * height * 4)
                for row in 0..<height { pixels.append(base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self), count: width * 4) }
                previous = pixels
                if frames <= target {
                    try pipe.fileHandleForWriting.write(contentsOf: pixels); frames += 1
                    if frames == 1 { print("RECORDING_STARTED"); fflush(stdout) }
                }
            case .audio:
                guard let start, time >= start, let description = sample.formatDescription else { return }
                let format = AVAudioFormat(cmAudioFormatDescription: description)
                let count = AVAudioFrameCount(sample.numSamples)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return }
                buffer.frameLength = count
                let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count), into: buffer.mutableAudioBufferList)
                guard status == noErr else { return }
                if audioFile == nil {
                    audioStart = time
                    audioFile = try AVAudioFile(forWriting: audioURL, settings: format.settings)
                }
                try audioFile!.write(from: buffer); audioSamples += 1
            default: break
            }
        } catch { failure = error }
    }
    func finish() async throws {
        queue.sync { audioFile = nil; try? pipe.fileHandleForWriting.close() }
        encoder.waitUntilExit()
        if let failure { throw failure }
        guard encoder.terminationStatus == 0, frames > 0, audioSamples > 0 else {
            throw NSError(domain: "DemoRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing captured video or audio"])
        }
        let mux = Process(); mux.executableURL = encoder.executableURL
        let offset = max(0, (audioStart! - start!).seconds)
        mux.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-i", videoURL.path, "-itsoffset", "\(offset)", "-i", audioURL.path, "-af", "apad", "-shortest", "-c:v", "copy", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", url.path]
        try mux.run(); mux.waitUntilExit()
        guard mux.terminationStatus == 0 else { throw NSError(domain: "DemoRecorder", code: 2) }
        print("CAPTURED frames=\(frames) audioSamples=\(audioSamples)")
    }
}
@main struct Main {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        guard CommandLine.arguments.count >= 4 else { fatalError("Usage: record output.mp4 seconds app-pid [stop-file]") }
        let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let seconds = Double(CommandLine.arguments[2])!
        let pid = Int32(CommandLine.arguments[3])!
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let window = content.windows.filter({ $0.owningApplication?.processID == pid && $0.frame.width > 500 }).max(by: { $0.frame.width < $1.frame.width }) else { fatalError("App window not found") }
        let config = SCStreamConfiguration()
        let scale = min(1480 / window.frame.width, 928 / window.frame.height)
        config.width = Int(window.frame.width * scale) / 2 * 2
        config.height = Int(window.frame.height * scale) / 2 * 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = false
        config.sampleRate = 48000
        config.channelCount = 2
        config.showsCursor = false
        let recorder = try Recorder(url: outputURL, width: config.width, height: config.height)
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: recorder)
        try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.queue)
        try stream.addStreamOutput(recorder, type: .audio, sampleHandlerQueue: recorder.queue)
        try await stream.startCapture()
        for _ in 0..<Int(seconds * 10) {
            if CommandLine.arguments.count > 4 && FileManager.default.fileExists(atPath: CommandLine.arguments[4]) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await stream.stopCapture()
        try await recorder.finish()
        print("RECORDING_SAVED \(outputURL.path)")
    }
}
