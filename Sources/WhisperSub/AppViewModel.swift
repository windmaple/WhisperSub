import Foundation
import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers

@MainActor
public final class AppViewModel: ObservableObject {
    @Published public var selectedModel: WhisperModelOption = WhisperModelOption.defaultModel
    @Published public var originalVideoURL: URL?
    @Published public var originalVideoMetadata: VideoMetadata?
    @Published public var videoURL: URL?
    @Published public var videoMetadata: VideoMetadata?
    @Published public var player: AVPlayer?
    @Published public var currentPlaybackTime: TimeInterval = 0

    @Published public var clipStartText: String = "00:00.0"
    @Published public var clipEndText: String = ""
    @Published public var isClipping: Bool = false
    @Published public var clipProgress: Double = 0.0
    @Published public var appliedClipRange: (start: TimeInterval, end: TimeInterval)?
    @Published public var lastClippedVideoURL: URL?

    @Published public var cues: [SubtitleCue] = []
    @Published public var srtText: String = ""

    @Published public var isBusy: Bool = false
    @Published public var isBurning: Bool = false
    @Published public var burnProgress: Double = 0.0

    @Published public var statusMessage: String = "Drop a video file to begin."
    @Published public var errorMessage: String?
    @Published public var lastSavedSRTURL: URL?
    @Published public var lastBurnedVideoURL: URL?

    public let transcriptionService = WhisperTranscriptionService()
    private var timeObserverToken: Any?
    private weak var observedPlayer: AVPlayer?

    public init() {}

    public var activeSubtitleCue: SubtitleCue? {
        for cue in cues {
            if currentPlaybackTime >= cue.startTime && currentPlaybackTime <= cue.endTime {
                return cue
            }
            if cue.startTime > currentPlaybackTime {
                break
            }
        }
        return nil
    }

    public var sourceVideoDuration: TimeInterval {
        originalVideoMetadata?.duration ?? videoMetadata?.duration ?? 0
    }

    public var isClipped: Bool {
        appliedClipRange != nil
    }

    // MARK: - Video Selection

    public func openVideoPicker() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Video to Transcribe"
        var types: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie, .avi]
        if let webm = UTType(filenameExtension: "webm") { types.append(webm) }
        if let mkv = UTType(filenameExtension: "mkv") { types.append(mkv) }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            loadVideo(url: url)
        }
    }

    public func loadVideo(url: URL) {
        cleanupTimeObserver()
        errorMessage = nil
        lastSavedSRTURL = nil
        lastBurnedVideoURL = nil
        lastClippedVideoURL = nil
        appliedClipRange = nil
        originalVideoURL = url
        originalVideoMetadata = nil
        videoURL = url
        videoMetadata = nil
        clipStartText = "00:00.0"
        clipEndText = ""
        cues = []
        srtText = ""
        currentPlaybackTime = 0

        let newPlayer = AVPlayer(url: url)
        self.player = newPlayer
        setupTimeObserver(for: newPlayer)

        let companionSRT = url.deletingPathExtension().appendingPathExtension("srt")
        if FileManager.default.fileExists(atPath: companionSRT.path),
           let rawSRT = try? String(contentsOf: companionSRT, encoding: .utf8) {
            let parsed = SRTFormatter.parse(rawSRT)
            if !parsed.isEmpty {
                self.cues = parsed
                self.srtText = SRTFormatter.format(cues: parsed)
                self.lastSavedSRTURL = companionSRT
                self.statusMessage = "Loaded \"\(url.lastPathComponent)\" and \(parsed.count) cues from \(companionSRT.lastPathComponent)."
            } else {
                self.statusMessage = "Loaded \"\(url.lastPathComponent)\". Ready to transcribe on Apple Neural Engine."
            }
        } else {
            self.statusMessage = "Loaded \"\(url.lastPathComponent)\". Ready to transcribe on Apple Neural Engine."
        }

        Task {
            do {
                let metadata = try await VideoSubtitleBurner.inspectVideo(url: url)
                self.originalVideoMetadata = metadata
                if self.appliedClipRange == nil {
                    self.videoMetadata = metadata
                    if self.clipEndText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.clipEndText = SRTFormatter.formatShortTimestamp(metadata.duration)
                    }
                }
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    public func seekPlayer(to seconds: TimeInterval) {
        guard let player else { return }
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        currentPlaybackTime = seconds
    }

    private func setupTimeObserver(for player: AVPlayer) {
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        let token = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let secs = CMTimeGetSeconds(time)
            if secs.isFinite {
                Task { @MainActor [weak self] in
                    self?.currentPlaybackTime = secs
                }
            }
        }
        self.timeObserverToken = token
        self.observedPlayer = player
    }

    private func cleanupTimeObserver() {
        if let token = timeObserverToken, let observedPlayer {
            observedPlayer.removeTimeObserver(token)
        }
        timeObserverToken = nil
        observedPlayer = nil
        player?.pause()
    }

    // MARK: - Video Clipping (Start / End Time)

    /// Resolves the user-entered Start and End text fields into a `(start, end)` range in seconds, or returns `nil` if the full video is selected.
    public func resolveClipRange() throws -> (start: TimeInterval, end: TimeInterval)? {
        let startTrimmed = clipStartText.trimmingCharacters(in: .whitespacesAndNewlines)
        let endTrimmed = clipEndText.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxDur = sourceVideoDuration

        let start: TimeInterval
        if startTrimmed.isEmpty {
            start = 0.0
        } else if let parsedStart = SRTFormatter.parseFlexibleTimestamp(startTrimmed) {
            start = parsedStart
        } else {
            throw VideoSubtitleBurnerError.invalidClipRange("Could not parse start time \"\(startTrimmed)\". Use MM:SS, HH:MM:SS, or seconds.")
        }

        if maxDur > 0 && start >= maxDur - 0.05 {
            throw VideoSubtitleBurnerError.invalidClipRange("Start time (\(SRTFormatter.formatShortTimestamp(start))) must be less than video duration (\(SRTFormatter.formatShortTimestamp(maxDur))).")
        }

        let end: TimeInterval
        if endTrimmed.isEmpty {
            guard maxDur > 0 else { return nil }
            end = maxDur
        } else if let parsedEnd = SRTFormatter.parseFlexibleTimestamp(endTrimmed) {
            end = maxDur > 0 ? min(parsedEnd, maxDur) : parsedEnd
        } else {
            throw VideoSubtitleBurnerError.invalidClipRange("Could not parse end time \"\(endTrimmed)\". Use MM:SS, HH:MM:SS, or seconds.")
        }

        guard end > start + 0.05 else {
            throw VideoSubtitleBurnerError.invalidClipRange("End time (\(SRTFormatter.formatShortTimestamp(end))) must be greater than start time (\(SRTFormatter.formatShortTimestamp(start))).")
        }

        let isCustomStart = start > 0.05
        let isCustomEnd = maxDur > 0 ? (end < maxDur - 0.15) : !endTrimmed.isEmpty
        if !isCustomStart && !isCustomEnd {
            return nil
        }

        return (start: start, end: end)
    }

    public var hasCustomClipRange: Bool {
        ((try? resolveClipRange()) ?? nil) != nil
    }

    public var hasUnappliedClipChanges: Bool {
        do {
            if let requested = try resolveClipRange() {
                if let applied = appliedClipRange {
                    return abs(requested.start - applied.start) > 0.05 || abs(requested.end - applied.end) > 0.05
                }
                return true
            } else {
                return appliedClipRange != nil
            }
        } catch {
            return true
        }
    }

    public func setClipStartToPlayhead() {
        let baseOffset = appliedClipRange?.start ?? 0
        let timeInSource = max(0, baseOffset + currentPlaybackTime)
        clipStartText = SRTFormatter.formatShortTimestamp(timeInSource)
    }

    public func setClipEndToPlayhead() {
        let baseOffset = appliedClipRange?.start ?? 0
        let timeInSource = max(0, baseOffset + currentPlaybackTime)
        clipEndText = SRTFormatter.formatShortTimestamp(timeInSource)
    }

    public func resetClipRange() {
        guard let origURL = originalVideoURL, !isBusy else { return }
        cleanupTimeObserver()
        errorMessage = nil
        appliedClipRange = nil
        lastClippedVideoURL = nil
        videoURL = origURL
        videoMetadata = originalVideoMetadata
        clipStartText = "00:00.0"
        if let dur = originalVideoMetadata?.duration {
            clipEndText = SRTFormatter.formatShortTimestamp(dur)
        } else {
            clipEndText = ""
        }
        cues = []
        srtText = ""
        lastSavedSRTURL = nil
        lastBurnedVideoURL = nil
        currentPlaybackTime = 0

        let newPlayer = AVPlayer(url: origURL)
        self.player = newPlayer
        setupTimeObserver(for: newPlayer)
        statusMessage = "Reset to full video \"\(origURL.lastPathComponent)\"."
    }

    public func clipCurrentVideo() {
        guard originalVideoURL != nil || videoURL != nil, !isBusy else { return }
        isBusy = true
        errorMessage = nil

        Task {
            defer {
                isBusy = false
                isClipping = false
            }
            do {
                let clippedURL = try await performClipIfNeeded(forceIfCustom: true)
                if let range = appliedClipRange, let meta = videoMetadata {
                    statusMessage = "Clipped video to \(SRTFormatter.formatShortTimestamp(range.start)) – \(SRTFormatter.formatShortTimestamp(range.end)) (\(meta.formattedDuration)) → \(clippedURL.lastPathComponent)."
                } else {
                    statusMessage = "Full video range active (\(clippedURL.lastPathComponent))."
                }
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Failed to clip video."
            }
        }
    }

    private func clippedOutputURL(for sourceURL: URL) -> URL {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let fileName = baseName.hasSuffix("_clipped") ? "\(baseName)_trim.mp4" : "\(baseName)_clipped.mp4"
        let parentDir = sourceURL.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: parentDir.path) {
            let candidate = parentDir.appendingPathComponent(fileName)
            if candidate != sourceURL {
                return candidate
            }
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
    }

    /// Clips the original video if a custom start/end time range is specified and not yet applied.
    private func performClipIfNeeded(forceIfCustom: Bool = false) async throws -> URL {
        guard let sourceURL = originalVideoURL ?? videoURL else {
            throw VideoSubtitleBurnerError.noVideoTrack
        }

        let requestedRange = try resolveClipRange()

        guard let range = requestedRange else {
            if appliedClipRange != nil {
                cleanupTimeObserver()
                appliedClipRange = nil
                lastClippedVideoURL = nil
                videoURL = sourceURL
                videoMetadata = originalVideoMetadata
                cues = []
                srtText = ""
                lastSavedSRTURL = nil
                lastBurnedVideoURL = nil
                currentPlaybackTime = 0
                let newPlayer = AVPlayer(url: sourceURL)
                self.player = newPlayer
                setupTimeObserver(for: newPlayer)
            }
            return videoURL ?? sourceURL
        }

        if !forceIfCustom,
           let applied = appliedClipRange,
           let currentURL = videoURL,
           abs(range.start - applied.start) <= 0.05,
           abs(range.end - applied.end) <= 0.05,
           FileManager.default.fileExists(atPath: currentURL.path) {
            return currentURL
        }

        let outURL = clippedOutputURL(for: sourceURL)
        isClipping = true
        clipProgress = 0.0
        statusMessage = "Clipping video from \(SRTFormatter.formatShortTimestamp(range.start)) to \(SRTFormatter.formatShortTimestamp(range.end))…"

        try await VideoSubtitleBurner.clipVideo(
            sourceURL: sourceURL,
            outputURL: outURL,
            startTime: range.start,
            endTime: range.end,
            progressHandler: { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.clipProgress = progress
                }
            }
        )

        let clippedMeta = try await VideoSubtitleBurner.inspectVideo(url: outURL)

        cleanupTimeObserver()
        self.videoURL = outURL
        self.videoMetadata = clippedMeta
        self.lastClippedVideoURL = outURL
        self.appliedClipRange = range
        self.cues = []
        self.srtText = ""
        self.lastSavedSRTURL = nil
        self.lastBurnedVideoURL = nil
        self.currentPlaybackTime = 0

        let newPlayer = AVPlayer(url: outURL)
        self.player = newPlayer
        setupTimeObserver(for: newPlayer)

        isClipping = false
        clipProgress = 1.0
        return outURL
    }

    // MARK: - Transcription

    public func transcribeCurrentVideo() {
        guard videoURL != nil, !isBusy else { return }
        isBusy = true
        errorMessage = nil
        lastSavedSRTURL = nil
        lastBurnedVideoURL = nil

        let model = selectedModel

        Task {
            defer {
                isBusy = false
                isClipping = false
            }
            do {
                let targetVideoURL = try await performClipIfNeeded()
                statusMessage = "Preparing \(model.displayName) on Apple Neural Engine…"

                let generatedCues = try await transcriptionService.transcribeVideo(
                    videoURL: targetVideoURL,
                    modelOption: model
                )
                self.cues = generatedCues
                self.srtText = SRTFormatter.format(cues: generatedCues)

                // Auto-write a companion .srt next to the video if writable, or inform the user
                let defaultSRTURL = targetVideoURL.deletingPathExtension().appendingPathExtension("srt")
                if (try? self.srtText.write(to: defaultSRTURL, atomically: true, encoding: .utf8)) != nil {
                    self.lastSavedSRTURL = defaultSRTURL
                    self.statusMessage = "Transcribed \(generatedCues.count) subtitle segments and saved \(defaultSRTURL.lastPathComponent)."
                } else {
                    self.statusMessage = "Transcribed \(generatedCues.count) subtitle segments. Click \"Save .SRT\" to export."
                }
            } catch {
                self.errorMessage = error.localizedDescription
                self.statusMessage = "Transcription failed."
            }
        }
    }

    // MARK: - SRT Import / Export

    public func saveSRTFile() {
        guard !cues.isEmpty else { return }

        let panel = NSSavePanel()
        panel.title = "Save SubRip (.srt) Subtitle File"
        if let srtType = UTType(filenameExtension: "srt") {
            panel.allowedContentTypes = [srtType]
        }
        let baseName = videoURL?.deletingPathExtension().lastPathComponent ?? "subtitles"
        panel.nameFieldStringValue = "\(baseName).srt"

        if panel.runModal() == .OK, let targetURL = panel.url {
            do {
                let content = SRTFormatter.format(cues: cues)
                try content.write(to: targetURL, atomically: true, encoding: .utf8)
                lastSavedSRTURL = targetURL
                statusMessage = "Saved subtitles to \(targetURL.lastPathComponent)."
            } catch {
                errorMessage = "Could not save .srt file: \(error.localizedDescription)"
            }
        }
    }

    public func importSRTFile() {
        let panel = NSOpenPanel()
        panel.title = "Load Existing .SRT File"
        if let srtType = UTType(filenameExtension: "srt") {
            panel.allowedContentTypes = [srtType, .plainText]
        } else {
            panel.allowedContentTypes = [.plainText]
        }
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            do {
                let raw = try String(contentsOf: url, encoding: .utf8)
                let parsed = SRTFormatter.parse(raw)
                self.cues = parsed
                self.srtText = SRTFormatter.format(cues: parsed)
                self.lastSavedSRTURL = url
                self.statusMessage = "Loaded \(parsed.count) subtitle cues from \(url.lastPathComponent)."
            } catch {
                self.errorMessage = "Failed to read .srt file: \(error.localizedDescription)"
            }
        }
    }

    public func copySRTToClipboard() {
        guard !srtText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(srtText, forType: .string)
        statusMessage = "Copied .SRT content (\(cues.count) cues) to clipboard."
    }

    // MARK: - Burn Subtitles into Video

    public func burnSubtitlesIntoVideo() {
        guard let videoURL, !cues.isEmpty, !isBusy else { return }

        let panel = NSSavePanel()
        panel.title = "Export Video with Burned-In Subtitles"
        panel.allowedContentTypes = [.mpeg4Movie]
        let baseName = videoURL.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = "\(baseName)_subtitled.mp4"

        guard panel.runModal() == .OK, let outputURL = panel.url else { return }

        isBusy = true
        isBurning = true
        burnProgress = 0.0
        errorMessage = nil
        statusMessage = "Burning \(cues.count) subtitles into video…"

        let currentCues = self.cues

        Task {
            defer {
                isBusy = false
                isBurning = false
            }
            do {
                try await VideoSubtitleBurner.burnSubtitles(
                    sourceURL: videoURL,
                    outputURL: outputURL,
                    cues: currentCues,
                    progressHandler: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            self?.burnProgress = progress
                        }
                    }
                )
                self.burnProgress = 1.0
                self.lastBurnedVideoURL = outputURL
                self.statusMessage = "Burned subtitles into \(outputURL.lastPathComponent)!"
                if self.videoMetadata?.isNativelyPlayable == false {
                    let burnedPlayer = AVPlayer(url: outputURL)
                    self.player = burnedPlayer
                    self.setupTimeObserver(for: burnedPlayer)
                }
            } catch {
                self.errorMessage = error.localizedDescription
                self.statusMessage = "Failed to burn subtitles."
            }
        }
    }

    public func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
