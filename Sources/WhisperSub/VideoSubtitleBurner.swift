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
    private static let renderLock = NSLock()
    private let lock = NSLock()
    private var cache: [Int: CIImage] = [:]
    private let cues: [SubtitleCue]
    private let renderSize: CGSize
    private let displayMode: SubtitleDisplayMode

    public init(cues: [SubtitleCue], renderSize: CGSize, displayMode: SubtitleDisplayMode = .translatedOnly) {
        self.cues = cues
        self.renderSize = renderSize
        self.displayMode = displayMode
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
        defer { lock.unlock() }
        if let existing = cache[cue.id] {
            return existing
        }

        guard let rendered = Self.renderCueImage(cue: cue, displayMode: displayMode, renderSize: renderSize) else {
            return nil
        }

        cache[cue.id] = rendered
        return rendered
    }

    public static func renderCueImage(
        cue: SubtitleCue,
        displayMode: SubtitleDisplayMode,
        renderSize: CGSize
    ) -> CIImage? {
        guard let cgImage = renderCueCGImage(cue: cue, displayMode: displayMode, renderSize: renderSize, canvasHeight: nil) else {
            return nil
        }
        return CIImage(cgImage: cgImage)
    }

    private final class TextBlockLayout {
        let storage: NSTextStorage
        let layoutManager: NSLayoutManager
        let container: NSTextContainer
        let usedRect: NSRect

        init(attributedString: NSAttributedString, maxWidth: CGFloat) {
            storage = NSTextStorage(attributedString: attributedString)
            layoutManager = NSLayoutManager()
            container = NSTextContainer(size: NSSize(width: maxWidth, height: 10_000))
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            storage.addLayoutManager(layoutManager)
            _ = layoutManager.glyphRange(for: container)
            usedRect = layoutManager.usedRect(for: container)
        }

        func draw(at point: NSPoint) {
            let glyphRange = layoutManager.glyphRange(for: container)
            layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: point)
        }
    }

    public static func renderCueCGImage(
        cue: SubtitleCue,
        displayMode: SubtitleDisplayMode,
        renderSize: CGSize,
        canvasHeight: Int? = nil
    ) -> CGImage? {
        renderLock.lock()
        defer { renderLock.unlock() }

        let width = max(1, Int(renderSize.width.rounded()))
        let fullHeight = max(1, Int(renderSize.height.rounded()))
        let bitmapHeight = max(1, min(fullHeight, canvasHeight ?? fullHeight))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let cgContext = CGContext(
            data: nil,
            width: width,
            height: bitmapHeight,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        cgContext.clear(CGRect(x: 0, y: 0, width: width, height: bitmapHeight))

        let nsContext = NSGraphicsContext(cgContext: cgContext, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        cgContext.translateBy(x: 0, y: CGFloat(bitmapHeight))
        cgContext.scaleBy(x: 1, y: -1)
        defer {
            NSGraphicsContext.restoreGraphicsState()
        }

        let minDimension = min(CGFloat(width), CGFloat(fullHeight))
        let maxBoxWidth = round(CGFloat(width) * 0.84)

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
        shadow.shadowBlurRadius = 3.0
        shadow.shadowOffset = NSSize(width: 0, height: -1.5)

        let baseFontSize: CGFloat
        let origLayout: TextBlockLayout?
        let primaryLayout: TextBlockLayout
        let interBlockGap: CGFloat

        if displayMode == .bilingual,
           let translated = cue.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !translated.isEmpty,
           translated != cue.text {
            let origTrimmed = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            baseFontSize = max(16.0, min(60.0, round(minDimension * 0.038)))
            let originalFontSize = max(13.0, round(baseFontSize * 0.80))
            interBlockGap = max(4.0, round(baseFontSize * 0.16))

            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center
            paragraphStyle.lineBreakMode = .byWordWrapping
            paragraphStyle.lineSpacing = max(2.0, round(baseFontSize * 0.10))

            let originalAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: originalFontSize, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.86),
                .paragraphStyle: paragraphStyle,
                .shadow: shadow
            ]
            let translatedAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: baseFontSize, weight: .semibold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraphStyle,
                .shadow: shadow
            ]

            if !origTrimmed.isEmpty {
                let origAttr = NSAttributedString(string: origTrimmed, attributes: originalAttrs)
                origLayout = TextBlockLayout(attributedString: origAttr, maxWidth: maxBoxWidth)
            } else {
                origLayout = nil
            }

            let transAttr = NSAttributedString(string: translated, attributes: translatedAttrs)
            primaryLayout = TextBlockLayout(attributedString: transAttr, maxWidth: maxBoxWidth)
        } else {
            let cleanText = cue.displayText(for: displayMode).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanText.isEmpty else { return nil }

            baseFontSize = max(18.0, min(72.0, round(minDimension * 0.044)))
            interBlockGap = 0
            origLayout = nil
            let font = NSFont.systemFont(ofSize: baseFontSize, weight: .semibold)

            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center
            paragraphStyle.lineBreakMode = .byWordWrapping
            paragraphStyle.lineSpacing = max(2.0, round(baseFontSize * 0.12))

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraphStyle,
                .shadow: shadow
            ]
            let attrString = NSAttributedString(string: cleanText, attributes: attributes)
            primaryLayout = TextBlockLayout(attributedString: attrString, maxWidth: maxBoxWidth)
        }

        let origWidth = origLayout.map { ceil($0.usedRect.width) } ?? 0
        let origHeight = origLayout.map { ceil($0.usedRect.height) } ?? 0
        let primaryWidth = ceil(primaryLayout.usedRect.width)
        let primaryHeight = ceil(primaryLayout.usedRect.height)

        let textWidth = max(origWidth, primaryWidth)
        let textHeight = origLayout != nil ? (origHeight + interBlockGap + primaryHeight) : primaryHeight

        let horizontalPadding = max(16.0, round(baseFontSize * 0.65))
        let verticalPadding = max(10.0, round(baseFontSize * 0.36))

        let pillWidth = min(CGFloat(width) * 0.92, textWidth + horizontalPadding * 2.0)
        let pillHeight = textHeight + verticalPadding * 2.0

        let bottomMargin = max(24.0, round(CGFloat(fullHeight) * 0.065))
        let pillX = round((CGFloat(width) - pillWidth) / 2.0)
        // In flipped top-down coordinates (y=0 is top of bitmap, y=bitmapHeight is bottom of frame):
        let pillY = max(4.0, CGFloat(bitmapHeight) - bottomMargin - pillHeight)

        let pillRect = NSRect(x: pillX, y: pillY, width: pillWidth, height: pillHeight)
        let cornerRadius = min(14.0, round(pillHeight * 0.25))

        let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor(calibratedWhite: 0.04, alpha: 0.76).setFill()
        pillPath.fill()

        NSColor(calibratedWhite: 1.0, alpha: 0.14).setStroke()
        pillPath.lineWidth = 1.0
        pillPath.stroke()

        let containerX = round((CGFloat(width) - maxBoxWidth) / 2.0)
        var currentY = round(pillY + verticalPadding)

        if let origLayout {
            origLayout.draw(at: NSPoint(x: containerX, y: currentY))
            currentY = round(currentY + origHeight + interBlockGap)
        }
        primaryLayout.draw(at: NSPoint(x: containerX, y: currentY))

        return cgContext.makeImage()
    }

    public static func renderBlankPNGData(width: Int, height: Int) -> Data? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let cgContext = CGContext(
            data: nil,
            width: max(1, width),
            height: max(1, height),
            bitsPerComponent: 8,
            bytesPerRow: max(1, width) * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
        let cgImage = cgContext.makeImage() else {
            return nil
        }
        return pngData(from: cgImage)
    }

    public static func pngData(from cgImage: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
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

    /// Prepares a clean (unburned) natively-playable `.mp4` preview file in the user cache for non-native containers (`.webm`, `.mkv`),
    /// so `AVPlayer` can play the clean video while SwiftUI renders a single live subtitle overlay.
    public static func preparePlayablePreviewURL(for videoURL: URL) async -> URL? {
        guard let ffmpegPath = findExecutable(named: "ffmpeg") else { return nil }

        let cachesBase = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let previewDir = cachesBase.appendingPathComponent("WhisperSub/Previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)

        let attrs = try? FileManager.default.attributesOfItem(atPath: videoURL.path)
        let fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let modDate = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let rawKey = "\(videoURL.standardizedFileURL.path)|\(fileSize)|\(Int64(modDate))"
        var fnv: UInt64 = 14695981039346656037
        for byte in rawKey.utf8 {
            fnv ^= UInt64(byte)
            fnv &*= 1099511628211
        }
        let cachedURL = previewDir.appendingPathComponent(String(format: "preview_%016llx.mp4", fnv))

        if FileManager.default.fileExists(atPath: cachedURL.path),
           let cachedSize = (try? FileManager.default.attributesOfItem(atPath: cachedURL.path)[.size] as? NSNumber)?.int64Value,
           cachedSize > 1024 {
            return cachedURL
        }

        let tempURL = previewDir.appendingPathComponent("temp_\(UUID().uuidString).mp4")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        // 1. Try fast lossless video stream-copy remux into .mp4 with hardware AAC audio (works for AV1 / H.264 / HEVC in .webm / .mkv)
        let remuxSuccess = await Task.detached { () -> Bool in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            process.arguments = [
                "-nostdin",
                "-loglevel", "error",
                "-y",
                "-i", videoURL.path,
                "-c:v", "copy",
                "-c:a", "aac_at",
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

        if remuxSuccess {
            let asset = AVURLAsset(url: tempURL)
            let playable = (try? await asset.load(.isPlayable)) ?? false
            let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            if playable && !tracks.isEmpty {
                try? FileManager.default.removeItem(at: cachedURL)
                try? FileManager.default.moveItem(at: tempURL, to: cachedURL)
                return cachedURL
            }
        }

        // 2. Fallback for VP8/VP9 .webm/.mkv: transcode video using hardware VideoToolbox H.264
        try? FileManager.default.removeItem(at: tempURL)
        let transcodeSuccess = await Task.detached { () -> Bool in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            process.arguments = [
                "-nostdin",
                "-loglevel", "error",
                "-y",
                "-i", videoURL.path,
                "-vf", "scale=-2:'min(1080,ih)'",
                "-c:v", "h264_videotoolbox",
                "-q:v", "65",
                "-c:a", "aac_at",
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

        if transcodeSuccess {
            try? FileManager.default.removeItem(at: cachedURL)
            try? FileManager.default.moveItem(at: tempURL, to: cachedURL)
            return cachedURL
        }

        return nil
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
        cues: [SubtitleCue],
        displayMode: SubtitleDisplayMode = .translatedOnly
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
        let overlayCache = SubtitleOverlayCache(cues: sortedCues, renderSize: renderSize, displayMode: displayMode)

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
        displayMode: SubtitleDisplayMode = .translatedOnly,
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
                displayMode: displayMode,
                videoSize: meta.size,
                totalDuration: meta.duration,
                progressHandler: progressHandler
            )
            return
        }

        do {
            let videoComposition = try await makeVideoComposition(for: asset, cues: cues, displayMode: displayMode)

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
                return
            case .cancelled:
                throw VideoSubtitleBurnerError.exportCancelled
            case .failed:
                let message = exportSession.error?.localizedDescription ?? "Unknown AVAssetExportSession error"
                throw VideoSubtitleBurnerError.exportFailed(message)
            default:
                let message = exportSession.error?.localizedDescription ?? "Export ended with status \(exportSession.status.rawValue)"
                throw VideoSubtitleBurnerError.exportFailed(message)
            }
        } catch let error as VideoSubtitleBurnerError where error.localizedDescription == VideoSubtitleBurnerError.exportCancelled.localizedDescription {
            throw error
        } catch {
            if let ffmpegPath = findExecutable(named: "ffmpeg") {
                try? FileManager.default.removeItem(at: outputURL)
                let meta = try await inspectVideo(url: sourceURL)
                try await burnSubtitlesWithFFmpeg(
                    ffmpegPath: ffmpegPath,
                    sourceURL: sourceURL,
                    outputURL: outputURL,
                    cues: cues,
                    displayMode: displayMode,
                    videoSize: meta.size,
                    totalDuration: meta.duration,
                    progressHandler: progressHandler
                )
                return
            }
            throw error
        }
    }

    private static func burnSubtitlesWithFFmpeg(
        ffmpegPath: String,
        sourceURL: URL,
        outputURL: URL,
        cues: [SubtitleCue],
        displayMode: SubtitleDisplayMode = .translatedOnly,
        videoSize: CGSize,
        totalDuration: TimeInterval,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        let tempSubDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whispersub_burn_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempSubDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempSubDir)
        }

        // Render subtitle overlays as transparent bottom-strip PNGs via CoreGraphics/AppKit so we do not depend on libass/subtitles filter in ffmpeg
        let videoWidth = max(2, Int(videoSize.width.rounded()))
        let videoHeight = max(2, Int(videoSize.height.rounded()))
        let scaleDownFactor: CGFloat = videoWidth > 1920 ? (1920.0 / CGFloat(videoWidth)) : 1.0
        let renderWidth = max(2, Int(round(CGFloat(videoWidth) * scaleDownFactor)))
        let renderHeight = max(2, Int(round(CGFloat(videoHeight) * scaleDownFactor)))
        let bandHeight = max(180, Int(ceil(CGFloat(renderHeight) * 0.42)))
        let scaledBandHeight = max(180, Int(round(CGFloat(bandHeight) / scaleDownFactor)))
        let renderSize = CGSize(width: renderWidth, height: renderHeight)

        let blankFileName = "blank.png"
        let blankURL = tempSubDir.appendingPathComponent(blankFileName)
        guard let blankData = SubtitleOverlayCache.renderBlankPNGData(width: renderWidth, height: bandHeight) else {
            throw VideoSubtitleBurnerError.exportFailed("Could not allocate transparent overlay buffer.")
        }
        try blankData.write(to: blankURL, options: .atomic)

        let validCues = cues
            .filter { $0.endTime > $0.startTime + 0.01 }
            .sorted { $0.startTime < $1.startTime }

        var concatLines: [String] = ["ffconcat version 1.0"]
        var cursor: TimeInterval = 0.0

        for cue in validCues {
            let effectiveStart = max(cursor, cue.startTime)
            let effectiveEnd = cue.endTime
            guard effectiveEnd > effectiveStart + 0.02 else { continue }

            guard let cgImg = SubtitleOverlayCache.renderCueCGImage(
                cue: cue,
                displayMode: displayMode,
                renderSize: renderSize,
                canvasHeight: bandHeight
            ),
            let pngData = SubtitleOverlayCache.pngData(from: cgImg) else {
                continue
            }

            if effectiveStart > cursor + 0.02 {
                concatLines.append("file '\(blankFileName)'")
                concatLines.append(String(format: "duration %.3f", effectiveStart - cursor))
            }

            let cueFileName = "cue_\(cue.id).png"
            let cueFileURL = tempSubDir.appendingPathComponent(cueFileName)
            try pngData.write(to: cueFileURL)

            concatLines.append("file '\(cueFileName)'")
            concatLines.append(String(format: "duration %.3f", effectiveEnd - effectiveStart))
            cursor = effectiveEnd
        }

        let tailDuration = max(1.0, totalDuration - cursor + 1.0)
        concatLines.append("file '\(blankFileName)'")
        concatLines.append(String(format: "duration %.3f", tailDuration))
        concatLines.append("file '\(blankFileName)'")

        let concatURL = tempSubDir.appendingPathComponent("subtitles.ffconcat")
        try concatLines.joined(separator: "\n").write(to: concatURL, atomically: true, encoding: .utf8)

        let filterComplex: String
        if renderWidth == videoWidth {
            filterComplex = "[0:v][1:v]overlay=0:H-h:eof_action=pass[vout]"
        } else {
            filterComplex = "[1:v]scale=\(videoWidth):\(scaledBandHeight):flags=bilinear[sub];[0:v][sub]overlay=0:H-h:eof_action=pass[vout]"
        }

        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            process.currentDirectoryURL = tempSubDir

            process.arguments = [
                "-nostdin",
                "-loglevel", "error",
                "-y",
                "-i", sourceURL.path,
                "-f", "concat",
                "-safe", "0",
                "-i", concatURL.path,
                "-filter_complex", filterComplex,
                "-map", "[vout]",
                "-map", "0:a?",
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
