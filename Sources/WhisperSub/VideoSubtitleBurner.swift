import Foundation
import AVFoundation
import CoreImage
import CoreGraphics
import AppKit

public struct VideoMetadata: Sendable {
    public let url: URL
    public let duration: TimeInterval
    public let size: CGSize
    public let frameRate: Float
    public let fileSizeBytes: Int64
    public let isNativelyPlayable: Bool

    public var formattedDuration: String {
        SRTFormatter.formatShortTimestamp(duration)
    }

    public var formattedResolution: String {
        "\(Int(size.width))×\(Int(size.height))"
    }

    public var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }
}

public enum VideoSubtitleBurnerError: LocalizedError {
    case noVideoTrack
    case invalidClipRange(String)
    case clipFailed(String)
    case audioExtractionFailed(String)
    case exportSessionCreationFailed
    case exportFailed(String)
    case exportCancelled

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "The selected file does not contain a valid video track."
        case .invalidClipRange(let reason):
            return "Invalid clip time range: \(reason)"
        case .clipFailed(let reason):
            return "Failed to clip video: \(reason)"
        case .audioExtractionFailed(let reason):
            return "Could not extract audio from video: \(reason)"
        case .exportSessionCreationFailed:
            return "Could not create export session for burning subtitles."
        case .exportFailed(let reason):
            return "Failed to burn subtitles into video: \(reason)"
        case .exportCancelled:
            return "Video subtitle burn export was cancelled."
        }
    }
}

public final class SubtitleOverlayCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [Int: CIImage] = [:]
    private let cues: [SubtitleCue]
    private let renderSize: CGSize

    public init(cues: [SubtitleCue], renderSize: CGSize) {
        self.cues = cues
        self.renderSize = renderSize
    }

    public func activeCue(at timeSeconds: TimeInterval) -> SubtitleCue? {
        for cue in cues {
            if timeSeconds >= cue.startTime && timeSeconds <= cue.endTime {
                return cue
            }
            if cue.startTime > timeSeconds {
                break
            }
        }
        return nil
    }

    public func overlayImage(for cue: SubtitleCue) -> CIImage? {
        lock.lock()
        if let existing = cache[cue.id] {
            lock.unlock()
            return existing
        }
        lock.unlock()

        guard let rendered = Self.renderCueImage(text: cue.text, renderSize: renderSize) else {
            return nil
        }

        lock.lock()
        cache[cue.id] = rendered
        lock.unlock()
        return rendered
    }

    private static func renderCueImage(text: String, renderSize: CGSize) -> CIImage? {
        let width = max(1, Int(renderSize.width.rounded()))
        let height = max(1, Int(renderSize.height.rounded()))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let cgContext = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        cgContext.clear(CGRect(x: 0, y: 0, width: width, height: height))

        let nsContext = NSGraphicsContext(cgContext: cgContext, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        defer {
            NSGraphicsContext.restoreGraphicsState()
        }

        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return nil }

        let minDimension = min(CGFloat(width), CGFloat(height))
        let fontSize = max(18.0, min(72.0, round(minDimension * 0.044)))
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.lineSpacing = max(2.0, round(fontSize * 0.12))

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
        shadow.shadowBlurRadius = 3.0
        shadow.shadowOffset = NSSize(width: 0, height: -1.5)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraphStyle,
            .shadow: shadow
        ]

        let attrString = NSAttributedString(string: cleanText, attributes: attributes)

        let maxBoxWidth = CGFloat(width) * 0.84
        let boundingRect = attrString.boundingRect(
            with: NSSize(width: maxBoxWidth, height: CGFloat(height) * 0.45),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )

        let textWidth = ceil(boundingRect.width)
        let textHeight = ceil(boundingRect.height)

        let horizontalPadding = max(16.0, round(fontSize * 0.65))
        let verticalPadding = max(10.0, round(fontSize * 0.36))

        let pillWidth = min(CGFloat(width) * 0.92, textWidth + horizontalPadding * 2.0)
        let pillHeight = textHeight + verticalPadding * 2.0

        let bottomMargin = max(24.0, round(CGFloat(height) * 0.065))
        let pillX = round((CGFloat(width) - pillWidth) / 2.0)
        let pillY = bottomMargin

        let pillRect = NSRect(x: pillX, y: pillY, width: pillWidth, height: pillHeight)
        let cornerRadius = min(14.0, round(pillHeight * 0.25))

        let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor(calibratedWhite: 0.04, alpha: 0.76).setFill()
        pillPath.fill()

        NSColor(calibratedWhite: 1.0, alpha: 0.14).setStroke()
        pillPath.lineWidth = 1.0
        pillPath.stroke()

        let textRect = NSRect(
            x: round(pillX + (pillWidth - textWidth) / 2.0),
            y: round(pillY + (pillHeight - textHeight) / 2.0),
            width: textWidth,
            height: textHeight
        )
        attrString.draw(
            with: textRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )

        guard let cgImage = cgContext.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }
}

public enum VideoSubtitleBurner {
    /// Locates a CLI tool (`ffmpeg` or `ffprobe`) across standard Homebrew and system paths.
    public static func findExecutable(named name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Inspects a video URL (`.mp4`, `.mov`, `.webm`, `.mkv`, etc.) and extracts resolution, duration, frame rate, and file size.
    public static func inspectVideo(url: URL) async throws -> VideoMetadata {
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0

        let asset = AVURLAsset(url: url)
        if let tracks = try? await asset.loadTracks(withMediaType: .video),
           let videoTrack = tracks.first,
           let durationCM = try? await asset.load(.duration),
           let naturalSize = try? await videoTrack.load(.naturalSize),
           let preferredTransform = try? await videoTrack.load(.preferredTransform) {
            let nominalFrameRate = (try? await videoTrack.load(.nominalFrameRate)) ?? 30.0
            let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
            let width = abs(transformedRect.width)
            let height = abs(transformedRect.height)
            let displaySize = CGSize(
                width: width > 0 ? width : naturalSize.width,
                height: height > 0 ? height : naturalSize.height
            )
            let duration = max(0, CMTimeGetSeconds(durationCM))
            if displaySize.width > 0 && duration > 0 {
                return VideoMetadata(
                    url: url,
                    duration: duration,
                    size: displaySize,
                    frameRate: nominalFrameRate > 0 ? nominalFrameRate : 30.0,
                    fileSizeBytes: fileSize,
                    isNativelyPlayable: true
                )
            }
        }

        // Fallback to ffprobe for .webm / .mkv / AV1 / VP9 containers not supported by AVURLAsset
        if let ffprobePath = findExecutable(named: "ffprobe") {
            return try await inspectWithFFprobe(ffprobePath: ffprobePath, url: url, fileSize: fileSize)
        }

        throw VideoSubtitleBurnerError.noVideoTrack
    }

    private static func inspectWithFFprobe(ffprobePath: String, url: URL, fileSize: Int64) async throws -> VideoMetadata {
        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffprobePath)
            process.arguments = [
                "-v", "error",
                "-select_streams", "v:0",
                "-show_entries", "stream=width,height,r_frame_rate:format=duration",
                "-of", "default=noprint_wrappers=1",
                url.path
            ]

            let pipe = Pipe()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8)
            else {
                throw VideoSubtitleBurnerError.noVideoTrack
            }

            var width: Double = 0
            var height: Double = 0
            var duration: Double = 0
            var frameRate: Float = 30.0

            for line in output.components(separatedBy: .newlines) {
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let val = parts[1].trimmingCharacters(in: .whitespaces)
                switch key {
                case "width":
                    width = Double(val) ?? width
                case "height":
                    height = Double(val) ?? height
                case "duration":
                    duration = Double(val) ?? duration
                case "r_frame_rate":
                    let frac = val.split(separator: "/")
                    if frac.count == 2, let num = Float(frac[0]), let den = Float(frac[1]), den > 0 {
                        frameRate = num / den
                    } else if let fps = Float(val) {
                        frameRate = fps
                    }
                default:
                    break
                }
            }

            guard width > 0 && height > 0 else {
                throw VideoSubtitleBurnerError.noVideoTrack
            }

            return VideoMetadata(
                url: url,
                duration: duration,
                size: CGSize(width: width, height: height),
                frameRate: frameRate,
                fileSizeBytes: fileSize,
                isNativelyPlayable: false
            )
        }.value
    }

    /// Extracts a 16kHz mono WAV file from a video URL into a temporary file for fast Whisper transcription.
    public static func extractAudioToTempWAV(from videoURL: URL) async throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("whispersub_\(UUID().uuidString).wav")

        // Prefer ffmpeg when available because it supports .webm (Opus/Vorbis), .mkv, .mp4, .mov, etc. at high speed
        if let ffmpegPath = findExecutable(named: "ffmpeg") {
            let success = await Task.detached { () -> Bool in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ffmpegPath)
                process.arguments = [
                    "-nostdin",
                    "-loglevel", "error",
                    "-y",
                    "-i", videoURL.path,
                    "-vn",
                    "-ac", "1",
                    "-ar", "16000",
                    "-c:a", "pcm_s16le",
                    tempURL.path
                ]
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: tempURL.path)
                } catch {
                    return false
                }
            }.value

            if success {
                return tempURL
            }
        }

        // Native AVFoundation fallback for standard QuickTime/MP4 containers
        let asset = AVURLAsset(url: videoURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            throw VideoSubtitleBurnerError.audioExtractionFailed("No readable audio track found in \(videoURL.lastPathComponent).")
        }

        let reader = try AVAssetReader(asset: asset)
        let readerOutputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: readerOutputSettings)
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            return videoURL
        }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: tempURL, fileType: .wav)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: readerOutputSettings)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            return videoURL
        }
        writer.add(writerInput)

        guard reader.startReading(), writer.startWriting() else {
            return videoURL
        }
        writer.startSession(atSourceTime: .zero)

        nonisolated(unsafe) let unsafeReaderOutput = readerOutput
        nonisolated(unsafe) let unsafeWriterInput = writerInput
        nonisolated(unsafe) let unsafeWriter = writer

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let queue = DispatchQueue(label: "com.whispersub.audioextract")
            unsafeWriterInput.requestMediaDataWhenReady(on: queue) {
                while unsafeWriterInput.isReadyForMoreMediaData {
                    if let sampleBuffer = unsafeReaderOutput.copyNextSampleBuffer() {
                        unsafeWriterInput.append(sampleBuffer)
                    } else {
                        unsafeWriterInput.markAsFinished()
                        unsafeWriter.finishWriting {
                            continuation.resume()
                        }
                        return
                    }
                }
            }
        }

        if reader.status == .completed && writer.status == .completed {
            return tempURL
        } else {
            return videoURL
        }
    }

    /// Creates an `AVVideoComposition` that dynamically renders and caches burned-in subtitle cues.
    public static func makeVideoComposition(
        for asset: AVAsset,
        cues: [SubtitleCue]
    ) async throws -> AVMutableVideoComposition {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else {
            throw VideoSubtitleBurnerError.noVideoTrack
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let renderSize = CGSize(
            width: max(2, abs(transformedRect.width).rounded()),
            height: max(2, abs(transformedRect.height).rounded())
        )

        let sortedCues = cues.sorted { $0.startTime < $1.startTime }
        let overlayCache = SubtitleOverlayCache(cues: sortedCues, renderSize: renderSize)

        let composition = try await AVMutableVideoComposition.videoComposition(
            with: asset,
            applyingCIFiltersWithHandler: { request in
                let source = request.sourceImage
                let timeSeconds = CMTimeGetSeconds(request.compositionTime)

                guard let activeCue = overlayCache.activeCue(at: timeSeconds),
                      var overlay = overlayCache.overlayImage(for: activeCue)
                else {
                    request.finish(with: source, context: nil)
                    return
                }

                let extent = source.extent
                if extent.origin != .zero {
                    overlay = overlay.transformed(
                        by: CGAffineTransform(translationX: extent.origin.x, y: extent.origin.y)
                    )
                }

                let composited = overlay.composited(over: source).cropped(to: extent)
                request.finish(with: composited, context: nil)
            }
        )

        return composition
    }

    /// Burns `cues` into the video at `sourceURL` and writes an `.mp4` file to `outputURL`, reporting progress `0.0...1.0`.
    public static func burnSubtitles(
        sourceURL: URL,
        outputURL: URL,
        cues: [SubtitleCue],
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let asset = AVURLAsset(url: sourceURL)
        let nativeVideoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []

        // If AVFoundation cannot natively read the container (e.g., .webm / .mkv / AV1), use ffmpeg with VideoToolbox hardware encoding
        if nativeVideoTracks.isEmpty {
            guard let ffmpegPath = findExecutable(named: "ffmpeg") else {
                throw VideoSubtitleBurnerError.noVideoTrack
            }
            let meta = try await inspectVideo(url: sourceURL)
            try await burnSubtitlesWithFFmpeg(
                ffmpegPath: ffmpegPath,
                sourceURL: sourceURL,
                outputURL: outputURL,
                cues: cues,
                totalDuration: meta.duration,
                progressHandler: progressHandler
            )
            return
        }

        let videoComposition = try await makeVideoComposition(for: asset, cues: cues)

        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw VideoSubtitleBurnerError.exportSessionCreationFailed
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true
        exportSession.videoComposition = videoComposition

        let progressTask = Task {
            while !Task.isCancelled {
                let currentProgress = Double(exportSession.progress)
                progressHandler(min(0.99, max(0.0, currentProgress)))
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }

        await exportSession.export()
        progressTask.cancel()

        switch exportSession.status {
        case .completed:
            progressHandler(1.0)
        case .cancelled:
            throw VideoSubtitleBurnerError.exportCancelled
        case .failed:
            let message = exportSession.error?.localizedDescription ?? "Unknown AVAssetExportSession error"
            throw VideoSubtitleBurnerError.exportFailed(message)
        default:
            let message = exportSession.error?.localizedDescription ?? "Export ended with status \(exportSession.status.rawValue)"
            throw VideoSubtitleBurnerError.exportFailed(message)
        }
    }

    private static func burnSubtitlesWithFFmpeg(
        ffmpegPath: String,
        sourceURL: URL,
        outputURL: URL,
        cues: [SubtitleCue],
        totalDuration: TimeInterval,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let tempSRTName = "whispersub_burn_\(UUID().uuidString).srt"
        let tempSRTURL = tempDir.appendingPathComponent(tempSRTName)
        let srtContent = SRTFormatter.format(cues: cues)
        try srtContent.write(to: tempSRTURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: tempSRTURL)
        }

        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            process.currentDirectoryURL = tempDir

            let style = "FontName=PingFang SC,FontSize=16,PrimaryColour=&H00FFFFFF,OutlineColour=&H99000000,BackColour=&H99000000,BorderStyle=4,Outline=1,Shadow=0,MarginV=24,Alignment=2"
            process.arguments = [
                "-nostdin",
                "-loglevel", "error",
                "-y",
                "-i", sourceURL.path,
                "-vf", "subtitles=\(tempSRTName):force_style='\(style)'",
                "-c:v", "h264_videotoolbox",
                "-q:v", "65",
                "-c:a", "aac",
                "-b:a", "192k",
                "-movflags", "+faststart",
                "-progress", "pipe:1",
                "-nostats",
                outputURL.path
            ]

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = outPipe
            process.standardError = errPipe

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                for line in chunk.components(separatedBy: .newlines) {
                    if line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms=") {
                        let valStr = line.components(separatedBy: "=").last ?? ""
                        if let micros = Double(valStr), totalDuration > 0 {
                            let fraction = min(0.99, max(0.0, (micros / 1_000_000.0) / totalDuration))
                            progressHandler(fraction)
                        }
                    }
                }
            }

            try process.run()
            process.waitUntilExit()
            outPipe.fileHandleForReading.readabilityHandler = nil

            if process.terminationStatus != 0 {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errString = String(data: errData, encoding: .utf8) ?? "ffmpeg exited with code \(process.terminationStatus)"
                throw VideoSubtitleBurnerError.exportFailed(errString)
            }
            progressHandler(1.0)
        }.value
    }

    /// Clips the video at `sourceURL` from `startTime` to `endTime` and writes an `.mp4` file to `outputURL`, reporting progress `0.0...1.0`.
    public static func clipVideo(
        sourceURL: URL,
        outputURL: URL,
        startTime: TimeInterval,
        endTime: TimeInterval,
        progressHandler: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let clampedStart = max(0, startTime)
        guard endTime > clampedStart + 0.05 else {
            throw VideoSubtitleBurnerError.invalidClipRange("End time (\(SRTFormatter.formatShortTimestamp(endTime))) must be greater than start time (\(SRTFormatter.formatShortTimestamp(clampedStart))).")
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let clipDuration = endTime - clampedStart
        let asset = AVURLAsset(url: sourceURL)
        let nativeVideoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []

        if nativeVideoTracks.isEmpty {
            guard let ffmpegPath = findExecutable(named: "ffmpeg") else {
                throw VideoSubtitleBurnerError.noVideoTrack
            }
            try await clipVideoWithFFmpeg(
                ffmpegPath: ffmpegPath,
                sourceURL: sourceURL,
                outputURL: outputURL,
                startTime: clampedStart,
                duration: clipDuration,
                progressHandler: progressHandler
            )
            return
        }

        do {
            let composition = AVMutableComposition()
            let startCM = CMTime(seconds: clampedStart, preferredTimescale: 600)
            let durationCM = CMTime(seconds: clipDuration, preferredTimescale: 600)
            let timeRange = CMTimeRange(start: startCM, duration: durationCM)

            guard let sourceVideoTrack = nativeVideoTracks.first,
                  let compVideoTrack = composition.addMutableTrack(
                      withMediaType: .video,
                      preferredTrackID: kCMPersistentTrackID_Invalid
                  )
            else {
                throw VideoSubtitleBurnerError.noVideoTrack
            }

            try compVideoTrack.insertTimeRange(timeRange, of: sourceVideoTrack, at: .zero)
            if let preferredTransform = try? await sourceVideoTrack.load(.preferredTransform) {
                compVideoTrack.preferredTransform = preferredTransform
            }

            let nativeAudioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            if let sourceAudioTrack = nativeAudioTracks.first,
               let compAudioTrack = composition.addMutableTrack(
                   withMediaType: .audio,
                   preferredTrackID: kCMPersistentTrackID_Invalid
               ) {
                try? compAudioTrack.insertTimeRange(timeRange, of: sourceAudioTrack, at: .zero)
            }

            guard let exportSession = AVAssetExportSession(
                asset: composition,
                presetName: AVAssetExportPresetHighestQuality
            ) else {
                throw VideoSubtitleBurnerError.exportSessionCreationFailed
            }

            exportSession.outputURL = outputURL
            exportSession.outputFileType = .mp4
            exportSession.shouldOptimizeForNetworkUse = true

            let progressTask = Task {
                while !Task.isCancelled {
                    let currentProgress = Double(exportSession.progress)
                    progressHandler(min(0.99, max(0.0, currentProgress)))
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }

            await exportSession.export()
            progressTask.cancel()

            switch exportSession.status {
            case .completed:
                progressHandler(1.0)
                return
            case .cancelled:
                throw VideoSubtitleBurnerError.exportCancelled
            default:
                let message = exportSession.error?.localizedDescription ?? "Unknown AVAssetExportSession error"
                throw VideoSubtitleBurnerError.clipFailed(message)
            }
        } catch {
            if let ffmpegPath = findExecutable(named: "ffmpeg") {
                try? FileManager.default.removeItem(at: outputURL)
                try await clipVideoWithFFmpeg(
                    ffmpegPath: ffmpegPath,
                    sourceURL: sourceURL,
                    outputURL: outputURL,
                    startTime: clampedStart,
                    duration: clipDuration,
                    progressHandler: progressHandler
                )
                return
            }
            throw error
        }
    }

    private static func clipVideoWithFFmpeg(
        ffmpegPath: String,
        sourceURL: URL,
        outputURL: URL,
        startTime: TimeInterval,
        duration: TimeInterval,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            process.arguments = [
                "-nostdin",
                "-loglevel", "error",
                "-y",
                "-ss", String(format: "%.3f", startTime),
                "-i", sourceURL.path,
                "-t", String(format: "%.3f", duration),
                "-c:v", "h264_videotoolbox",
                "-q:v", "65",
                "-c:a", "aac",
                "-b:a", "192k",
                "-movflags", "+faststart",
                "-progress", "pipe:1",
                "-nostats",
                outputURL.path
            ]

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = outPipe
            process.standardError = errPipe

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                for line in chunk.components(separatedBy: .newlines) {
                    if line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms=") {
                        let valStr = line.components(separatedBy: "=").last ?? ""
                        if let micros = Double(valStr), duration > 0 {
                            let fraction = min(0.99, max(0.0, (micros / 1_000_000.0) / duration))
                            progressHandler(fraction)
                        }
                    }
                }
            }

            try process.run()
            process.waitUntilExit()
            outPipe.fileHandleForReading.readabilityHandler = nil

            if process.terminationStatus != 0 {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errString = String(data: errData, encoding: .utf8) ?? "ffmpeg exited with code \(process.terminationStatus)"
                throw VideoSubtitleBurnerError.clipFailed(errString)
            }
            progressHandler(1.0)
        }.value
    }
}
