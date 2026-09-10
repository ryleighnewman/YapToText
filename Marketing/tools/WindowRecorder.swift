// Record ONE window to an mp4 with ScreenCaptureKit, even while it is behind other windows.
//
// This is what lets the video rig run in the background: it never fronts an app, never hides
// the user's windows, never touches the wallpaper, and never captures anything except the
// single window id it was given. `screencapture -v` cannot do this - it records a screen
// REGION, so whatever the user has on top would land in the footage.
//
// Usage: swift WindowRecorder.swift <windowID> <seconds> <output.mp4> [fps]
import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    private var started = false
    private(set) var frames = 0
    private(set) var statusCounts: [Int: Int] = [:]

    init(url: URL, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: width * height * 8,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid, input.isReadyForMoreMediaData else { return }
        // A frame whose status is not .complete carries no new pixels (SCK sends these while
        // the window is idle); writing them produces a file with duplicated timestamps.
        let attach = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        let raw = (attach?.first?[.status] as? Int) ?? -1
        statusCounts[raw, default: 0] += 1
        guard SCFrameStatus(rawValue: raw) == .complete else { return }
        if !started {
            writer.startWriting()
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sb))
            started = true
        }
        input.append(sb); frames += 1
    }

    func finish(_ completion: @escaping () -> Void) {
        guard started, writer.status == .writing else {
            FileHandle.standardError.write("no frames captured (status counts: \(statusCounts)) - is Screen Recording allowed for this process?\n".data(using: .utf8)!)
            completion(); return
        }
        input.markAsFinished()
        writer.finishWriting(completionHandler: completion)
    }
}

let args = CommandLine.arguments
guard args.count >= 4, let winID = UInt32(args[1]), let seconds = Double(args[2]) else {
    FileHandle.standardError.write("usage: WindowRecorder.swift <windowID> <seconds> <out.mp4> [fps]\n".data(using: .utf8)!)
    exit(2)
}
let outURL = URL(fileURLWithPath: args[3])
let fps = args.count > 4 ? (Int(args[4]) ?? 60) : 60

// A plain command-line tool has no CoreGraphics connection, and ScreenCaptureKit trips
// "CGS_REQUIRE_INIT" the moment it asks for shareable content. Touching NSApplication opens
// that connection, and the main thread has to keep pumping a run loop afterwards: blocking
// it on a semaphore starves the very callbacks the capture depends on.
_ = NSApplication.shared
var finished = false
Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == winID }) else {
            FileHandle.standardError.write("window \(winID) not found\n".data(using: .utf8)!); exit(3)
        }
        let scale = 2   // capture at Retina density regardless of the display's current mode
        let w = Int(window.frame.width) * scale, h = Int(window.frame.height) * scale
        let cfg = SCStreamConfiguration()
        cfg.width = w; cfg.height = h
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.showsCursor = false
        cfg.capturesAudio = false
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        // Transparent ground: the panel is a floating glass window, so anything behind it on
        // the real desktop must not bleed into the frame.
        cfg.backgroundColor = .clear
        cfg.scalesToFit = false

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let rec = try Recorder(url: outURL, width: w, height: h)
        let stream = SCStream(filter: filter, configuration: cfg, delegate: rec)
        try stream.addStreamOutput(rec, type: .screen, sampleHandlerQueue: DispatchQueue(label: "cap"))
        try await stream.startCapture()
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        try? await stream.stopCapture()
        rec.finish {
            print("wrote \(outURL.path) \(w)x\(h) @\(fps)fps frames=\(rec.frames)")
            finished = true
        }
    } catch {
        FileHandle.standardError.write("capture failed: \(error)\n".data(using: .utf8)!)
        exit(4)
    }
}
while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
