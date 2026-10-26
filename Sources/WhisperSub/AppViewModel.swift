import Foundation
import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers
import UserNotifications

public struct CompletionNotificationBanner: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let title: String
    public let message: String
    public let systemImage: String
}

public final class UserNotificationManager: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public static let shared = UserNotificationManager()

    private override init() {
        super.init()
    }

    public func configure() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    public func postNotification(title: String, body: String) {
        Task.detached(priority: .utility) {
            var deliveredViaUN = false
            if Bundle.main.bundleIdentifier != nil {
                let center = UNUserNotificationCenter.current()
                let settings = await center.notificationSettings()
                if settings.authorizationStatus == .notDetermined {
                    _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
                }
                let updatedSettings = await center.notificationSettings()
                if updatedSettings.authorizationStatus == .authorized || updatedSettings.authorizationStatus == .provisional {
                    let content = UNMutableNotificationContent()
                    content.title = "WhisperSub — \(title)"
                    content.body = body
                    content.sound = .default
                    let req = UNNotificationRequest(
                        identifier: UUID().uuidString,
                        content: content,
                        trigger: nil
                    )
                    if (try? await center.add(req)) != nil {
                        deliveredViaUN = true
                    }
                }
            }

            if !deliveredViaUN {
                let safeTitle = title
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                let safeBody = body
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                let script = "display notification \"\(safeBody)\" with title \"WhisperSub\" subtitle \"\(safeTitle)\" sound name \"Glass\""
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                proc.arguments = ["-e", script]
                proc.standardInput = FileHandle.nullDevice
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                try? proc.run()
                proc.waitUntilExit()
            }

            await MainActor.run {
                NSSound(named: NSSound.Name("Glass"))?.play()
                if NSApplication.shared.isActive == false {
                    NSApplication.shared.requestUserAttention(.informationalRequest)
                }
            }
        }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}

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
    @Published public var aspectRatioMode: VideoAspectRatioMode = .original
    @Published public var appliedAspectRatioMode: VideoAspectRatioMode = .original
    @Published public var horizontalCropFocus: Double = 0.5
    @Published public var appliedHorizontalCropFocus: Double = 0.5
    @Published public var isClipping: Bool = false
    @Published public var clipProgress: Double = 0.0
    @Published public var appliedClipRange: (start: TimeInterval, end: TimeInterval)?
    @Published public var lastClippedVideoURL: URL?

    @Published public var cues: [SubtitleCue] = []
    @Published public var srtText: String = ""
    @Published public var selectedCueID: Int?

    @Published public var targetLanguage: TranslationLanguage = TranslationLanguage.defaultLanguage
    @Published public var autoTranslateOnTranscribe: Bool = false
    @Published public var useWhisperDirectAudioTranslate: Bool = false
    @Published public var subtitleDisplayMode: SubtitleDisplayMode = .bilingual {
        didSet {
            refreshSRTText()
        }
    }
    @Published public var wordByWordSubtitles: Bool = true {
        didSet {
            refreshSRTText()
        }
    }
    @Published public var isTranslating: Bool = false
    @Published public var translationProgress: Double = 0.0
    @Published public var translatedLanguage: TranslationLanguage?

    @Published public var selectedGemmaModel: GemmaModelOption = GemmaModelOption.defaultModel
    @Published public var autoReviewWithGemma: Bool = false
    @Published public var gemmaCustomInstructions: String = ""
    @Published public var isReviewingWithGemma: Bool = false
    @Published public var gemmaReviewProgress: Double = 0.0
    @Published public var lastGemmaRevisedCount: Int = 0

    @Published public var isBusy: Bool = false
    @Published public var isTranscribing: Bool = false
    @Published public var isBurning: Bool = false
    @Published public var burnProgress: Double = 0.0

    @Published public var statusMessage: String = "Drop a video file to begin."
    @Published public var errorMessage: String?
    @Published public var lastSavedSRTURL: URL?
    @Published public var lastBurnedVideoURL: URL?
    @Published public var hasPlayablePreview: Bool = false
    @Published public var isPlayingBurnedVideo: Bool = false
    @Published public var isPreparingPreview: Bool = false
    @Published public var activeNotificationBanner: CompletionNotificationBanner?

    public let transcriptionService = WhisperTranscriptionService()
    public let translationService = SubtitleTranslationService()
    public let gemmaReviewService = GemmaReviewService()
    private var timeObserverToken: Any?
    private weak var observedPlayer: AVPlayer?
    private var activeProcessingTask: Task<Void, Never>?
    private var debouncedSaveTask: Task<Void, Never>?
    private var notificationDismissTask: Task<Void, Never>?
    private var lastManualSeekDate: Date?

    public init() {
        UserNotificationManager.shared.configure()
    }

    public func postCompletionNotification(title: String, message: String, systemImage: String) {
        let banner = CompletionNotificationBanner(title: title, message: message, systemImage: systemImage)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            activeNotificationBanner = banner
        }
        UserNotificationManager.shared.postNotification(title: title, body: message)

        notificationDismissTask?.cancel()
        notificationDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.activeNotificationBanner?.id == banner.id {
                withAnimation(.easeOut(duration: 0.25)) {
                    self.activeNotificationBanner = nil
                }
            }
        }
    }

    public func dismissNotificationBanner() {
        notificationDismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            activeNotificationBanner = nil
        }
    }

    public var isProcessingStoppableTask: Bool {
        isTranscribing || isTranslating || isReviewingWithGemma
    }

    public func stopCurrentProcessing() {
        activeProcessingTask?.cancel()
        activeProcessingTask = nil
        transcriptionService.cancel()
        translationService.resetState()
        gemmaReviewService.cancel()
        isTranscribing = false
        isTranslating = false
        isReviewingWithGemma = false
        isClipping = false
        isBusy = false
        errorMessage = nil
        statusMessage = "Processing stopped."
    }

    public var hasTranslatedCues: Bool {
        cues.contains(where: { $0.hasTranslation })
    }

    public var hasGemmaReviewedCues: Bool {
        cues.contains(where: { $0.isReviewedByGemma })
    }

    public var hasGemmaRevisions: Bool {
        cues.contains(where: { $0.wasRevisedByGemma })
    }

    public var activeSubtitleCue: SubtitleCue? {
        if let selectedID = selectedCueID,
           let selected = cues.first(where: { $0.id == selectedID }) {
            let isPaused = (player?.rate ?? 0) == 0
            if isPaused || (currentPlaybackTime >= selected.startTime - 0.12 && currentPlaybackTime < selected.endTime) {
                return selected
            }
        }

        // Prefer half-open interval [startTime, endTime) so exact boundary timestamps (where cue[i].endTime == cue[i+1].startTime)
        // highlight cue[i+1] instead of cue[i].
        for cue in cues {
            if currentPlaybackTime >= cue.startTime && currentPlaybackTime < cue.endTime {
                return cue
            }
            if cue.startTime > currentPlaybackTime {
                break
            }
        }
        return cues.last(where: { currentPlaybackTime >= $0.startTime && currentPlaybackTime <= $0.endTime })
    }

    public var sourceVideoDuration: TimeInterval {
        originalVideoMetadata?.duration ?? videoMetadata?.duration ?? 0
    }

    public var isClipped: Bool {
        appliedClipRange != nil || appliedAspectRatioMode != .original
    }

    public var isShowingShortsPreviewGuide: Bool {
        guard aspectRatioMode == .vertical9x16,
              let meta = videoMetadata else {
            return false
        }
        return aspectRatioMode.needsCrop(for: meta.size)
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
        appliedAspectRatioMode = .original
        appliedHorizontalCropFocus = 0.5
        originalVideoURL = url
        originalVideoMetadata = nil
        videoURL = url
        videoMetadata = nil
        clipStartText = "00:00.0"
        clipEndText = ""
        cues = []
        srtText = ""
        selectedCueID = nil
        translatedLanguage = nil
        lastGemmaRevisedCount = 0
        translationService.resetState()
        gemmaReviewService.resetState()
        currentPlaybackTime = 0

        let isAlreadyBurnedFile = url.deletingPathExtension().lastPathComponent.lowercased().contains("_subtitled")
        hasPlayablePreview = false
        isPlayingBurnedVideo = isAlreadyBurnedFile
        isPreparingPreview = false

        let newPlayer = AVPlayer(url: url)
        self.player = newPlayer
        setupTimeObserver(for: newPlayer)

        if loadCompanionSubtitles(for: url) {
            self.statusMessage = "Loaded \"\(url.lastPathComponent)\" and \(self.cues.count) cues from \(self.lastSavedSRTURL?.lastPathComponent ?? "working copy")."
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
                if metadata.isNativelyPlayable {
                    self.hasPlayablePreview = true
                } else {
                    self.isPreparingPreview = true
                    let previewURL = await VideoSubtitleBurner.preparePlayablePreviewURL(for: url)
                    self.isPreparingPreview = false
                    if let previewURL, self.videoURL == url {
                        let savedTime = self.currentPlaybackTime
                        self.cleanupTimeObserver()
                        let previewPlayer = AVPlayer(url: previewURL)
                        self.player = previewPlayer
                        self.setupTimeObserver(for: previewPlayer)
                        self.hasPlayablePreview = true
                        self.isPlayingBurnedVideo = isAlreadyBurnedFile
                        if savedTime > 0.01 {
                            let target = CMTime(seconds: savedTime, preferredTimescale: 600)
                            _ = await previewPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                        }
                    }
                }
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    public func attachBurnedPreviewPlayer(url: URL) {
        cleanupTimeObserver()
        lastBurnedVideoURL = url
        hasPlayablePreview = true
        isPlayingBurnedVideo = true
        let burnedPlayer = AVPlayer(url: url)
        player = burnedPlayer
        setupTimeObserver(for: burnedPlayer)
    }

    public func selectAndSeek(to cue: SubtitleCue) {
        selectedCueID = cue.id
        lastManualSeekDate = Date()
        currentPlaybackTime = cue.startTime
        guard let player else { return }
        // Nudge seek target slightly inside the cue (+0.02s) so video frame rounding does not land on the preceding cue's end frame.
        let seekTargetSeconds = min(cue.endTime - 0.01, cue.startTime + 0.02)
        let target = CMTime(seconds: max(0, seekTargetSeconds), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func seekToWord(_ wordTiming: SubtitleWordTiming, in cue: SubtitleCue) {
        selectedCueID = cue.id
        lastManualSeekDate = Date()
        let clampedTime = min(cue.endTime - 0.005, max(cue.startTime, wordTiming.startTime + 0.01))
        currentPlaybackTime = clampedTime
        guard let player else { return }
        let target = CMTime(seconds: max(0, clampedTime), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func seekPlayer(to seconds: TimeInterval) {
        lastManualSeekDate = Date()
        currentPlaybackTime = seconds
        guard let player else { return }
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func setupTimeObserver(for player: AVPlayer) {
        let interval = CMTime(seconds: 0.025, preferredTimescale: 600)
        let token = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak player] time in
            let secs = CMTimeGetSeconds(time)
            if secs.isFinite {
                Task { @MainActor [weak self, weak player] in
                    guard let self else { return }
                    let isPlaying = (player?.rate ?? 0) != 0
                    if !isPlaying {
                        if let manualDate = self.lastManualSeekDate,
                           Date().timeIntervalSince(manualDate) < 0.35 {
                            return
                        }
                    } else if let selectedID = self.selectedCueID,
                              let selected = self.cues.first(where: { $0.id == selectedID }),
                              (secs < selected.startTime - 0.1 || secs >= selected.endTime) {
                        self.selectedCueID = nil
                    }
                    self.currentPlaybackTime = secs
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
        (((try? resolveClipRange()) ?? nil) != nil) || (aspectRatioMode != .original)
    }

    public var hasUnappliedClipChanges: Bool {
        if aspectRatioMode != appliedAspectRatioMode {
            return true
        }
        if aspectRatioMode == .vertical9x16 && abs(horizontalCropFocus - appliedHorizontalCropFocus) > 0.01 {
            return true
        }
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
        aspectRatioMode = .original
        appliedAspectRatioMode = .original
        horizontalCropFocus = 0.5
        appliedHorizontalCropFocus = 0.5
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

        if loadCompanionSubtitles(for: origURL) {
            statusMessage = "Reset to full video \"\(origURL.lastPathComponent)\" (\(cues.count) cues restored)."
        } else {
            statusMessage = "Reset to full video \"\(origURL.lastPathComponent)\"."
        }
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
                let shortsLabel = appliedAspectRatioMode == .vertical9x16 ? " • 9:16 Shorts" : ""
                if let range = appliedClipRange, let meta = videoMetadata {
                    statusMessage = "Clipped video to \(SRTFormatter.formatShortTimestamp(range.start)) – \(SRTFormatter.formatShortTimestamp(range.end)) (\(meta.formattedResolution), \(meta.formattedDuration)\(shortsLabel)) → \(clippedURL.lastPathComponent)."
                } else if appliedAspectRatioMode != .original, let meta = videoMetadata {
                    statusMessage = "Cut video to \(appliedAspectRatioMode.compactLabel) (\(meta.formattedResolution), \(meta.formattedDuration)) → \(clippedURL.lastPathComponent)."
                } else {
                    statusMessage = "Full video range active (\(clippedURL.lastPathComponent))."
                }
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Failed to clip video."
            }
        }
    }

    private func clippedOutputURL(for sourceURL: URL, aspect: VideoAspectRatioMode) -> URL {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let suffix: String
        if aspect == .vertical9x16 {
            suffix = baseName.hasSuffix("_shorts") ? "_9x16" : "_shorts"
        } else {
            suffix = baseName.hasSuffix("_clipped") ? "_trim" : "_clipped"
        }
        let fileName = "\(baseName)\(suffix).mp4"
        let parentDir = sourceURL.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: parentDir.path) {
            let candidate = parentDir.appendingPathComponent(fileName)
            if candidate != sourceURL {
                return candidate
            }
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
    }

    /// Clips the original video if a custom start/end time range or 9:16 Shorts aspect ratio is specified and not yet applied.
    private func performClipIfNeeded(forceIfCustom: Bool = false) async throws -> URL {
        guard let sourceURL = originalVideoURL ?? videoURL else {
            throw VideoSubtitleBurnerError.noVideoTrack
        }

        let requestedRange = try resolveClipRange()
        let requestedAspect = aspectRatioMode
        let requestedFocus = horizontalCropFocus

        if requestedRange == nil && requestedAspect == .original {
            if appliedClipRange != nil || appliedAspectRatioMode != .original {
                cleanupTimeObserver()
                appliedClipRange = nil
                appliedAspectRatioMode = .original
                appliedHorizontalCropFocus = 0.5
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
                _ = loadCompanionSubtitles(for: sourceURL)
            }
            return videoURL ?? sourceURL
        }

        let fullDur = max(0.1, sourceVideoDuration)
        let effectiveRange = requestedRange ?? (start: 0.0, end: fullDur)

        let isRangeUnchanged: Bool = {
            if let req = requestedRange, let app = appliedClipRange {
                return abs(req.start - app.start) <= 0.05 && abs(req.end - app.end) <= 0.05
            }
            return requestedRange == nil && appliedClipRange == nil
        }()
        let isAspectUnchanged = (requestedAspect == appliedAspectRatioMode) &&
            (requestedAspect == .original || abs(requestedFocus - appliedHorizontalCropFocus) <= 0.01)

        if !forceIfCustom,
           isRangeUnchanged,
           isAspectUnchanged,
           let currentURL = videoURL,
           FileManager.default.fileExists(atPath: currentURL.path) {
            return currentURL
        }

        let outURL = clippedOutputURL(for: sourceURL, aspect: requestedAspect)
        let previousCues = self.cues
        let previousOffset = self.appliedClipRange?.start ?? 0.0
        isClipping = true
        clipProgress = 0.0
        let aspectNote = requestedAspect == .vertical9x16 ? " (9:16 YouTube Shorts)" : ""
        statusMessage = "Cutting video \(SRTFormatter.formatShortTimestamp(effectiveRange.start)) – \(SRTFormatter.formatShortTimestamp(effectiveRange.end))\(aspectNote)…"

        try await VideoSubtitleBurner.clipVideo(
            sourceURL: sourceURL,
            outputURL: outURL,
            startTime: effectiveRange.start,
            endTime: effectiveRange.end,
            aspectRatioMode: requestedAspect,
            horizontalFocus: requestedFocus,
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
        self.appliedClipRange = requestedRange
        self.appliedAspectRatioMode = requestedAspect
        self.appliedHorizontalCropFocus = requestedFocus
        self.lastSavedSRTURL = nil
        self.lastBurnedVideoURL = nil
        self.currentPlaybackTime = 0

        if !previousCues.isEmpty {
            let clipDuration = max(0.1, effectiveRange.end - effectiveRange.start)
            var sliced: [SubtitleCue] = []
            for cue in previousCues {
                let absStart = cue.startTime + previousOffset
                let absEnd = cue.endTime + previousOffset
                guard absEnd > effectiveRange.start + 0.05, absStart < effectiveRange.end - 0.05 else { continue }
                let shiftedStart = max(0, absStart - effectiveRange.start)
                let shiftedEnd = min(clipDuration, absEnd - effectiveRange.start)
                guard shiftedEnd > shiftedStart + 0.05 else { continue }
                let shiftedWordTimings: [SubtitleWordTiming]? = cue.wordTimings?.compactMap { wt in
                    let absWStart = wt.startTime + previousOffset
                    let absWEnd = wt.endTime + previousOffset
                    guard absWEnd > effectiveRange.start + 0.01, absWStart < effectiveRange.end - 0.01 else { return nil }
                    let wStart = max(shiftedStart, absWStart - effectiveRange.start)
                    let wEnd = min(shiftedEnd, max(wStart + 0.02, absWEnd - effectiveRange.start))
                    return SubtitleWordTiming(word: wt.word, startTime: wStart, endTime: wEnd)
                }
                sliced.append(
                    SubtitleCue(
                        id: sliced.count + 1,
                        startTime: shiftedStart,
                        endTime: shiftedEnd,
                        text: cue.text,
                        translatedText: cue.translatedText,
                        preReviewTranslatedText: cue.preReviewTranslatedText,
                        isReviewedByGemma: cue.isReviewedByGemma,
                        wordTimings: shiftedWordTimings
                    )
                )
            }
            self.cues = sliced
            self.refreshSRTText()
            if !sliced.isEmpty {
                _ = self.saveWorkingSubtitlesToDisk(for: outURL)
            }
        } else {
            self.cues = []
            self.srtText = ""
        }

        let newPlayer = AVPlayer(url: outURL)
        self.player = newPlayer
        setupTimeObserver(for: newPlayer)

        isClipping = false
        clipProgress = 1.0
        return outURL
    }

    // MARK: - Transcription & Translation

    public func refreshSRTText() {
        srtText = SRTFormatter.format(
            cues: cues,
            displayMode: subtitleDisplayMode,
            wordByWord: wordByWordSubtitles
        )
        if let activeVideo = videoURL, !cues.isEmpty {
            let candidate = companionSRTURL(for: activeVideo)
            if FileManager.default.fileExists(atPath: candidate.path) {
                lastSavedSRTURL = candidate
            }
        }
    }

    /// Updates the in-memory right-pane working copy (`cues` + `srtText`) immediately and optionally persists it to disk.
    private func applyWorkingCues(
        _ latestCues: [SubtitleCue],
        translatedLanguage: TranslationLanguage?,
        revisedCount: Int? = nil,
        switchToBilingualIfOriginalOnly: Bool = false,
        saveForVideo videoURL: URL? = nil
    ) {
        self.cues = latestCues
        self.translatedLanguage = translatedLanguage
        if let revisedCount {
            self.lastGemmaRevisedCount = revisedCount
        }
        if switchToBilingualIfOriginalOnly && self.subtitleDisplayMode == .originalOnly {
            self.subtitleDisplayMode = .bilingual
        } else {
            self.refreshSRTText()
        }
        if let videoURL, !latestCues.isEmpty {
            _ = self.saveWorkingSubtitlesToDisk(for: videoURL)
        }
    }

    public func transcribeCurrentVideo() {
        guard videoURL != nil, !isBusy else { return }
        isBusy = true
        isTranscribing = true
        errorMessage = nil
        lastSavedSRTURL = nil
        lastBurnedVideoURL = nil
        translatedLanguage = nil
        lastGemmaRevisedCount = 0
        translationService.resetState()
        gemmaReviewService.resetState()

        let model = selectedModel
        let shouldAutoTranslate = autoTranslateOnTranscribe
        let shouldAutoGemmaReview = autoReviewWithGemma
        let gemmaModel = selectedGemmaModel
        let gemmaNotes = gemmaCustomInstructions
        let targetLang = targetLanguage
        let useDirectWhisperTranslate = useWhisperDirectAudioTranslate && targetLang.id == "en" && subtitleDisplayMode == .translatedOnly

        activeProcessingTask = Task { [self] in
            defer {
                isBusy = false
                isTranscribing = false
                isClipping = false
                isTranslating = false
                isReviewingWithGemma = false
                activeProcessingTask = nil
            }
            do {
                let targetVideoURL = try await performClipIfNeeded()
                try Task.checkCancellation()

                // Clear stale subtitles so the right pane reflects the live working transcription
                self.cues = []
                self.srtText = ""
                statusMessage = "Preparing \(model.displayName) on Apple Neural Engine…"

                var generatedCues = try await transcriptionService.transcribeVideo(
                    videoURL: targetVideoURL,
                    modelOption: model,
                    translateToEnglish: useDirectWhisperTranslate,
                    onPartialCues: { partialCues in
                        Task { @MainActor [weak self] in
                            guard let self, self.isTranscribing, !Task.isCancelled else { return }
                            self.applyWorkingCues(
                                partialCues,
                                translatedLanguage: useDirectWhisperTranslate ? targetLang : nil
                            )
                        }
                    }
                )
                isTranscribing = false
                try Task.checkCancellation()

                // Immediately update right pane and save transcribed cues before starting translation/review
                self.applyWorkingCues(
                    generatedCues,
                    translatedLanguage: useDirectWhisperTranslate ? targetLang : nil,
                    revisedCount: 0,
                    saveForVideo: targetVideoURL
                )
                self.postCompletionNotification(
                    title: "Transcription Complete",
                    message: "Transcribed \(generatedCues.count) subtitle cues from \(targetVideoURL.lastPathComponent).",
                    systemImage: "waveform.badge.checkmark"
                )

                if !useDirectWhisperTranslate && shouldAutoTranslate && !generatedCues.isEmpty {
                    isTranslating = true
                    translationProgress = 0.0
                    statusMessage = "Translating \(generatedCues.count) subtitle segments to \(targetLang.displayName)…"
                    generatedCues = try await translationService.translateCues(
                        generatedCues,
                        to: targetLang,
                        progressHandler: { completed, total, partialCues in
                            Task { @MainActor [weak self] in
                                guard let self, total > 0, !Task.isCancelled else { return }
                                self.translationProgress = Double(completed) / Double(total)
                                if completed > 0 {
                                    self.applyWorkingCues(
                                        partialCues,
                                        translatedLanguage: targetLang,
                                        revisedCount: 0,
                                        switchToBilingualIfOriginalOnly: true
                                    )
                                }
                            }
                        }
                    )
                    isTranslating = false
                    translationProgress = 1.0
                    try Task.checkCancellation()

                    // Immediately update right pane and save translated working copy before Gemma review
                    self.applyWorkingCues(
                        generatedCues,
                        translatedLanguage: targetLang,
                        revisedCount: 0,
                        switchToBilingualIfOriginalOnly: true,
                        saveForVideo: targetVideoURL
                    )

                    if shouldAutoGemmaReview {
                        isReviewingWithGemma = true
                        gemmaReviewProgress = 0.0
                        statusMessage = "Reviewing & revising \(generatedCues.count) cues with \(gemmaModel.shortName)…"
                        let reviewResult = try await gemmaReviewService.reviewAndReviseCues(
                            generatedCues,
                            targetLanguage: targetLang,
                            modelOption: gemmaModel,
                            customInstructions: gemmaNotes,
                            progressHandler: { completed, total, partialCues, revisedSoFar in
                                Task { @MainActor [weak self] in
                                    guard let self, total > 0, !Task.isCancelled else { return }
                                    self.gemmaReviewProgress = Double(completed) / Double(total)
                                    if completed > 0 {
                                        self.applyWorkingCues(
                                            partialCues,
                                            translatedLanguage: targetLang,
                                            revisedCount: revisedSoFar,
                                            switchToBilingualIfOriginalOnly: true,
                                            saveForVideo: targetVideoURL
                                        )
                                    }
                                }
                            }
                        )
                        generatedCues = reviewResult.cues
                        self.lastGemmaRevisedCount = reviewResult.revisedCount
                        isReviewingWithGemma = false
                        gemmaReviewProgress = 1.0
                        self.postCompletionNotification(
                            title: "Gemma 4 Revision Complete",
                            message: "Reviewed \(reviewResult.cues.count) cues and revised \(reviewResult.revisedCount) segment(s) with \(gemmaModel.shortName).",
                            systemImage: "sparkles"
                        )
                    }
                }

                try Task.checkCancellation()
                self.applyWorkingCues(
                    generatedCues,
                    translatedLanguage: (useDirectWhisperTranslate || shouldAutoTranslate) ? targetLang : nil,
                    revisedCount: self.lastGemmaRevisedCount,
                    switchToBilingualIfOriginalOnly: shouldAutoTranslate && !useDirectWhisperTranslate,
                    saveForVideo: targetVideoURL
                )

                if let savedURL = self.lastSavedSRTURL {
                    if let lang = self.translatedLanguage {
                        if shouldAutoGemmaReview && self.hasGemmaReviewedCues {
                            self.statusMessage = "Transcribed, translated & Gemma-revised (\(self.lastGemmaRevisedCount) refined, \(lang.displayName)) → \(savedURL.lastPathComponent)."
                        } else {
                            self.statusMessage = "Transcribed & translated \(generatedCues.count) segments (\(lang.displayName)) → \(savedURL.lastPathComponent)."
                        }
                    } else {
                        self.statusMessage = "Transcribed \(generatedCues.count) subtitle segments and saved \(savedURL.lastPathComponent)."
                    }
                } else {
                    self.statusMessage = "Transcribed \(generatedCues.count) subtitle segments. Click \"Save .SRT\" to export."
                }
            } catch is CancellationError {
                self.errorMessage = nil
                self.refreshSRTText()
                if let activeVideo = self.videoURL, !self.cues.isEmpty {
                    _ = self.saveWorkingSubtitlesToDisk(for: activeVideo)
                }
                self.statusMessage = "Processing stopped (\(self.cues.count) working cues kept)."
            } catch {
                if Task.isCancelled || (error as NSError).code == NSURLErrorCancelled {
                    self.errorMessage = nil
                    self.refreshSRTText()
                    if let activeVideo = self.videoURL, !self.cues.isEmpty {
                        _ = self.saveWorkingSubtitlesToDisk(for: activeVideo)
                    }
                    self.statusMessage = "Processing stopped (\(self.cues.count) working cues kept)."
                } else {
                    self.errorMessage = error.localizedDescription
                    self.statusMessage = "Transcription failed."
                }
            }
        }
    }

    public func translateCurrentSubtitles() {
        guard !cues.isEmpty, !isBusy else { return }
        isBusy = true
        isTranslating = true
        translationProgress = 0.0
        lastGemmaRevisedCount = 0
        errorMessage = nil

        let sourceCues = cues
        let targetLang = targetLanguage
        let shouldAutoGemma = autoReviewWithGemma
        let gemmaModel = selectedGemmaModel
        let gemmaNotes = gemmaCustomInstructions
        let activeVideoURL = videoURL

        activeProcessingTask = Task { [self] in
            defer {
                isBusy = false
                isTranslating = false
                isReviewingWithGemma = false
                activeProcessingTask = nil
            }
            do {
                statusMessage = "Translating \(sourceCues.count) subtitle segments to \(targetLang.displayName)…"
                var translatedCues = try await translationService.translateCues(
                    sourceCues,
                    to: targetLang,
                    progressHandler: { completed, total, partialCues in
                        Task { @MainActor [weak self] in
                            guard let self, total > 0, !Task.isCancelled else { return }
                            self.translationProgress = Double(completed) / Double(total)
                            self.applyWorkingCues(
                                partialCues,
                                translatedLanguage: targetLang,
                                revisedCount: 0,
                                switchToBilingualIfOriginalOnly: true
                            )
                        }
                    }
                )
                self.isTranslating = false
                self.translationProgress = 1.0
                try Task.checkCancellation()

                // Immediately update right pane and save translated working copy before Gemma review
                self.applyWorkingCues(
                    translatedCues,
                    translatedLanguage: targetLang,
                    revisedCount: 0,
                    switchToBilingualIfOriginalOnly: true,
                    saveForVideo: activeVideoURL
                )

                if shouldAutoGemma {
                    self.isReviewingWithGemma = true
                    self.gemmaReviewProgress = 0.0
                    self.statusMessage = "Reviewing & revising \(translatedCues.count) cues with \(gemmaModel.shortName)…"
                    let reviewResult = try await gemmaReviewService.reviewAndReviseCues(
                        translatedCues,
                        targetLanguage: targetLang,
                        modelOption: gemmaModel,
                        customInstructions: gemmaNotes,
                        progressHandler: { completed, total, partialCues, revisedSoFar in
                            Task { @MainActor [weak self] in
                                guard let self, total > 0, !Task.isCancelled else { return }
                                self.gemmaReviewProgress = Double(completed) / Double(total)
                                if completed > 0 {
                                    self.applyWorkingCues(
                                        partialCues,
                                        translatedLanguage: targetLang,
                                        revisedCount: revisedSoFar,
                                        switchToBilingualIfOriginalOnly: true,
                                        saveForVideo: activeVideoURL
                                    )
                                }
                            }
                        }
                    )
                    translatedCues = reviewResult.cues
                    self.lastGemmaRevisedCount = reviewResult.revisedCount
                    self.isReviewingWithGemma = false
                    self.gemmaReviewProgress = 1.0
                    self.postCompletionNotification(
                        title: "Gemma 4 Revision Complete",
                        message: "Reviewed \(reviewResult.cues.count) cues and revised \(reviewResult.revisedCount) segment(s) with \(gemmaModel.shortName).",
                        systemImage: "sparkles"
                    )
                }

                try Task.checkCancellation()
                self.applyWorkingCues(
                    translatedCues,
                    translatedLanguage: targetLang,
                    revisedCount: self.lastGemmaRevisedCount,
                    switchToBilingualIfOriginalOnly: true,
                    saveForVideo: activeVideoURL
                )

                let gemmaSummary = shouldAutoGemma ? ", Gemma revised \(self.lastGemmaRevisedCount)" : ""

                if let outSRT = self.lastSavedSRTURL {
                    self.statusMessage = "Translated \(translatedCues.count) cues to \(targetLang.displayName) (\(subtitleDisplayMode.compactLabel)\(gemmaSummary)) → \(outSRT.lastPathComponent)."
                } else {
                    self.statusMessage = "Translated \(translatedCues.count) subtitle cues to \(targetLang.displayName) (\(subtitleDisplayMode.compactLabel)\(gemmaSummary))."
                }
            } catch is CancellationError {
                self.errorMessage = nil
                self.refreshSRTText()
                if let activeVideo = self.videoURL, !self.cues.isEmpty {
                    _ = self.saveWorkingSubtitlesToDisk(for: activeVideo)
                }
                self.statusMessage = "Processing stopped (latest working copy kept)."
            } catch {
                if Task.isCancelled || (error as NSError).code == NSURLErrorCancelled {
                    self.errorMessage = nil
                    self.refreshSRTText()
                    if let activeVideo = self.videoURL, !self.cues.isEmpty {
                        _ = self.saveWorkingSubtitlesToDisk(for: activeVideo)
                    }
                    self.statusMessage = "Processing stopped (latest working copy kept)."
                } else {
                    self.errorMessage = error.localizedDescription
                    self.statusMessage = "Subtitle translation failed."
                }
            }
        }
    }

    public func reviewSubtitlesWithGemma() {
        guard !cues.isEmpty, !isBusy else { return }
        isBusy = true
        errorMessage = nil

        let targetLang = targetLanguage
        let gemmaModel = selectedGemmaModel
        let gemmaNotes = gemmaCustomInstructions
        let needsInitialTranslation = !hasTranslatedCues || translatedLanguage != targetLang
        let activeVideoURL = videoURL

        activeProcessingTask = Task { [self] in
            defer {
                isBusy = false
                isTranslating = false
                isReviewingWithGemma = false
                activeProcessingTask = nil
            }
            do {
                var workingCues = self.cues

                if needsInitialTranslation {
                    isTranslating = true
                    translationProgress = 0.0
                    statusMessage = "Translating \(workingCues.count) subtitle segments to \(targetLang.displayName) before Gemma 4 review…"
                    workingCues = try await translationService.translateCues(
                        workingCues,
                        to: targetLang,
                        progressHandler: { completed, total, partialCues in
                            Task { @MainActor [weak self] in
                                guard let self, total > 0, !Task.isCancelled else { return }
                                self.translationProgress = Double(completed) / Double(total)
                                self.applyWorkingCues(
                                    partialCues,
                                    translatedLanguage: targetLang,
                                    revisedCount: 0,
                                    switchToBilingualIfOriginalOnly: true
                                )
                            }
                        }
                    )
                    isTranslating = false
                    translationProgress = 1.0
                    try Task.checkCancellation()

                    self.applyWorkingCues(
                        workingCues,
                        translatedLanguage: targetLang,
                        revisedCount: 0,
                        switchToBilingualIfOriginalOnly: true,
                        saveForVideo: activeVideoURL
                    )
                }

                isReviewingWithGemma = true
                gemmaReviewProgress = 0.0
                statusMessage = "Reviewing & revising \(workingCues.count) translated cues with \(gemmaModel.shortName)…"

                let reviewResult = try await gemmaReviewService.reviewAndReviseCues(
                    workingCues,
                    targetLanguage: targetLang,
                    modelOption: gemmaModel,
                    customInstructions: gemmaNotes,
                    progressHandler: { completed, total, partialCues, revisedSoFar in
                        Task { @MainActor [weak self] in
                            guard let self, total > 0, !Task.isCancelled else { return }
                            self.gemmaReviewProgress = Double(completed) / Double(total)
                            if completed > 0 {
                                self.applyWorkingCues(
                                    partialCues,
                                    translatedLanguage: targetLang,
                                    revisedCount: revisedSoFar,
                                    switchToBilingualIfOriginalOnly: true,
                                    saveForVideo: activeVideoURL
                                )
                            }
                        }
                    }
                )
                try Task.checkCancellation()

                self.applyWorkingCues(
                    reviewResult.cues,
                    translatedLanguage: targetLang,
                    revisedCount: reviewResult.revisedCount,
                    switchToBilingualIfOriginalOnly: true,
                    saveForVideo: activeVideoURL
                )
                self.gemmaReviewProgress = 1.0

                if let outSRT = self.lastSavedSRTURL {
                    self.statusMessage = "✨ \(gemmaModel.shortName) reviewed \(reviewResult.cues.count) cues (revised \(reviewResult.revisedCount)) → \(outSRT.lastPathComponent)."
                } else {
                    self.statusMessage = "✨ \(gemmaModel.shortName) reviewed \(reviewResult.cues.count) cues and revised \(reviewResult.revisedCount) segment(s)."
                }
                self.postCompletionNotification(
                    title: "Gemma 4 Revision Complete",
                    message: "Reviewed \(reviewResult.cues.count) cues and revised \(reviewResult.revisedCount) segment(s) with \(gemmaModel.shortName).",
                    systemImage: "sparkles"
                )
            } catch is CancellationError {
                self.errorMessage = nil
                self.refreshSRTText()
                if let activeVideo = self.videoURL, !self.cues.isEmpty {
                    _ = self.saveWorkingSubtitlesToDisk(for: activeVideo)
                }
                self.statusMessage = "Processing stopped (latest working copy kept)."
            } catch {
                if Task.isCancelled || (error as NSError).code == NSURLErrorCancelled {
                    self.errorMessage = nil
                    self.refreshSRTText()
                    if let activeVideo = self.videoURL, !self.cues.isEmpty {
                        _ = self.saveWorkingSubtitlesToDisk(for: activeVideo)
                    }
                    self.statusMessage = "Processing stopped (latest working copy kept)."
                } else {
                    self.errorMessage = error.localizedDescription
                    self.statusMessage = "Gemma 4 review failed."
                }
            }
        }
    }

    public func revertGemmaRevisions() {
        guard hasGemmaRevisions, !isBusy else { return }
        let restoredCues = cues.map { cue in
            let restored = cue.preReviewTranslatedText ?? cue.translatedText
            return SubtitleCue(
                id: cue.id,
                startTime: cue.startTime,
                endTime: cue.endTime,
                text: cue.text,
                translatedText: restored,
                preReviewTranslatedText: nil,
                isReviewedByGemma: false,
                wordTimings: cue.wordTimings
            )
        }
        gemmaReviewService.resetState()
        applyWorkingCues(
            restoredCues,
            translatedLanguage: translatedLanguage,
            revisedCount: 0,
            saveForVideo: videoURL
        )
        statusMessage = "Reverted Gemma 4 revisions back to initial draft translation."
    }

    public func clearTranslations() {
        guard hasTranslatedCues, !isBusy else { return }
        let clearedCues = cues.map { cue in
            SubtitleCue(
                id: cue.id,
                startTime: cue.startTime,
                endTime: cue.endTime,
                text: cue.text,
                translatedText: nil,
                wordTimings: cue.wordTimings
            )
        }
        translationService.resetState()
        gemmaReviewService.resetState()
        applyWorkingCues(
            clearedCues,
            translatedLanguage: nil,
            revisedCount: 0,
            saveForVideo: videoURL
        )
        statusMessage = "Cleared translated subtitles (showing original)."
    }

    // MARK: - Inline Subtitle Editing

    public func updateCueOriginalText(id: Int, newText: String) {
        guard let idx = cues.firstIndex(where: { $0.id == id }) else { return }
        if cues[idx].text != newText {
            cues[idx].text = newText
            refreshSRTText()
            scheduleDebouncedSave()
        }
    }

    public func updateCueTranslatedText(id: Int, newText: String) {
        guard let idx = cues.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved: String? = trimmed.isEmpty ? nil : newText
        if cues[idx].translatedText != resolved {
            cues[idx].translatedText = resolved
            if translatedLanguage == nil && resolved != nil {
                translatedLanguage = targetLanguage
            }
            refreshSRTText()
            scheduleDebouncedSave()
        }
    }

    @discardableResult
    public func updateCueTimestamps(id: Int, startString: String, endString: String) -> Bool {
        guard let idx = cues.firstIndex(where: { $0.id == id }),
              let parsedStart = SRTFormatter.parseTimestamp(startString) ?? SRTFormatter.parseFlexibleTimestamp(startString),
              let parsedEnd = SRTFormatter.parseTimestamp(endString) ?? SRTFormatter.parseFlexibleTimestamp(endString),
              parsedEnd > parsedStart + 0.05
        else {
            return false
        }
        let oldStart = cues[idx].startTime
        let oldEnd = cues[idx].endTime
        let oldSpan = max(0.05, oldEnd - oldStart)
        let newStart = max(0, parsedStart)
        let newEnd = parsedEnd
        let newSpan = max(0.05, newEnd - newStart)
        if let existingWords = cues[idx].wordTimings, !existingWords.isEmpty {
            cues[idx].wordTimings = existingWords.map { wt in
                let relStart = min(1.0, max(0.0, (wt.startTime - oldStart) / oldSpan))
                let relEnd = min(1.0, max(relStart, (wt.endTime - oldStart) / oldSpan))
                let scaledStart = newStart + relStart * newSpan
                let scaledEnd = max(scaledStart + 0.02, newStart + relEnd * newSpan)
                return SubtitleWordTiming(word: wt.word, startTime: scaledStart, endTime: min(newEnd, scaledEnd))
            }
        }
        cues[idx].startTime = newStart
        cues[idx].endTime = newEnd
        refreshSRTText()
        scheduleDebouncedSave()
        return true
    }

    public func deleteCue(id: Int) {
        guard let idx = cues.firstIndex(where: { $0.id == id }) else { return }
        cues.remove(at: idx)
        for i in cues.indices {
            cues[i] = SubtitleCue(
                id: i + 1,
                startTime: cues[i].startTime,
                endTime: cues[i].endTime,
                text: cues[i].text,
                translatedText: cues[i].translatedText,
                preReviewTranslatedText: cues[i].preReviewTranslatedText,
                isReviewedByGemma: cues[i].isReviewedByGemma,
                wordTimings: cues[i].wordTimings
            )
        }
        if selectedCueID == id {
            selectedCueID = nil
        }
        refreshSRTText()
        if let activeVideo = videoURL {
            _ = saveWorkingSubtitlesToDisk(for: activeVideo)
        }
        statusMessage = "Deleted cue #\(id) (\(cues.count) cues remaining)."
    }

    public func addCue(after cueID: Int? = nil) {
        let insertIndex: Int
        let start: TimeInterval
        let end: TimeInterval

        if let cueID, let idx = cues.firstIndex(where: { $0.id == cueID }) {
            insertIndex = idx + 1
            start = cues[idx].endTime
            let nextStart = (idx + 1 < cues.count) ? cues[idx + 1].startTime : (start + 2.0)
            end = max(start + 0.5, min(start + 2.0, nextStart))
        } else {
            insertIndex = cues.count
            start = cues.last?.endTime ?? currentPlaybackTime
            end = start + 2.0
        }

        let placeholderTrans: String? = (translatedLanguage != nil || hasTranslatedCues) ? "New translated subtitle…" : nil
        let newCue = SubtitleCue(
            id: insertIndex + 1,
            startTime: start,
            endTime: end,
            text: "New subtitle…",
            translatedText: placeholderTrans
        )
        cues.insert(newCue, at: insertIndex)
        for i in cues.indices {
            cues[i] = SubtitleCue(
                id: i + 1,
                startTime: cues[i].startTime,
                endTime: cues[i].endTime,
                text: cues[i].text,
                translatedText: cues[i].translatedText,
                preReviewTranslatedText: cues[i].preReviewTranslatedText,
                isReviewedByGemma: cues[i].isReviewedByGemma,
                wordTimings: cues[i].wordTimings
            )
        }
        selectedCueID = insertIndex + 1
        refreshSRTText()
        if let activeVideo = videoURL {
            _ = saveWorkingSubtitlesToDisk(for: activeVideo)
        }
        statusMessage = "Added cue #\(insertIndex + 1)."
    }

    public func applyRawSRTEdits(_ rawContent: String) {
        let parsed = SRTFormatter.collapseWordByWordCues(SRTFormatter.parse(rawContent))
        guard !parsed.isEmpty else { return }

        let oldByID = Dictionary(uniqueKeysWithValues: cues.map { ($0.id, $0) })
        let updated: [SubtitleCue] = parsed.map { block in
            let prev = oldByID[block.id]
            let resolvedWordTimings = block.wordTimings ?? prev?.wordTimings
            switch subtitleDisplayMode {
            case .bilingual:
                let (orig, trans) = Self.splitBilingualCueText(
                    block.text,
                    knownOriginal: prev?.text,
                    knownTranslated: prev?.translatedText,
                    isBilingualFile: true
                )
                return SubtitleCue(
                    id: block.id,
                    startTime: block.startTime,
                    endTime: block.endTime,
                    text: orig,
                    translatedText: trans,
                    preReviewTranslatedText: prev?.preReviewTranslatedText,
                    isReviewedByGemma: prev?.isReviewedByGemma ?? false,
                    wordTimings: resolvedWordTimings
                )
            case .translatedOnly:
                if hasTranslatedCues || translatedLanguage != nil {
                    return SubtitleCue(
                        id: block.id,
                        startTime: block.startTime,
                        endTime: block.endTime,
                        text: prev?.text ?? block.text,
                        translatedText: block.text,
                        preReviewTranslatedText: prev?.preReviewTranslatedText,
                        isReviewedByGemma: prev?.isReviewedByGemma ?? false,
                        wordTimings: resolvedWordTimings
                    )
                } else {
                    return block
                }
            case .originalOnly:
                return SubtitleCue(
                    id: block.id,
                    startTime: block.startTime,
                    endTime: block.endTime,
                    text: block.text,
                    translatedText: prev?.translatedText,
                    preReviewTranslatedText: prev?.preReviewTranslatedText,
                    isReviewedByGemma: prev?.isReviewedByGemma ?? false,
                    wordTimings: resolvedWordTimings
                )
            }
        }

        self.cues = updated
        if updated.contains(where: { $0.hasTranslation }) && translatedLanguage == nil {
            translatedLanguage = targetLanguage
        }
        refreshSRTText()
        if let activeVideo = videoURL {
            _ = saveWorkingSubtitlesToDisk(for: activeVideo)
        }
        statusMessage = "Applied edits from Raw .SRT (\(updated.count) cues updated)."
    }

    private func scheduleDebouncedSave() {
        debouncedSaveTask?.cancel()
        debouncedSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled, let activeVideo = self.videoURL, !self.cues.isEmpty else { return }
            _ = self.saveWorkingSubtitlesToDisk(for: activeVideo)
        }
    }

    // MARK: - Working Copy Persistence & Companion .SRT Sync

    private struct WorkingSubtitleSnapshot: Codable {
        let videoPath: String
        let savedAt: Date
        let translatedLanguageID: String?
        let lastGemmaRevisedCount: Int
        let cues: [SubtitleCue]
    }

    private func workingCopySnapshotURL(for videoURL: URL) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = appSupport
            .appendingPathComponent("WhisperSub", isDirectory: true)
            .appendingPathComponent("working_copies", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safeKey = Data(videoURL.standardizedFileURL.path.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return folder.appendingPathComponent("\(safeKey.suffix(96)).json")
    }

    private func companionSRTURL(for videoURL: URL) -> URL {
        let base = videoURL.deletingPathExtension()
        if let lang = translatedLanguage, hasTranslatedCues, subtitleDisplayMode != .originalOnly {
            let suffix = subtitleDisplayMode == .bilingual ? "bilingual_\(lang.id)" : lang.id
            return base.deletingLastPathComponent().appendingPathComponent("\(base.lastPathComponent)_\(suffix).srt")
        }
        return base.appendingPathExtension("srt")
    }

    /// Writes the latest working subtitles to all companion `.srt` files (`<base>.srt`, `<base>_<lang>.srt`, `<base>_bilingual_<lang>.srt`)
    /// as well as the local working-copy snapshot so no companion `.srt` on disk is ever left stale.
    @discardableResult
    private func saveWorkingSubtitlesToDisk(for videoURL: URL) -> URL? {
        guard !cues.isEmpty else { return nil }
        let base = videoURL.deletingPathExtension()
        let parentDir = base.deletingLastPathComponent()
        let baseName = base.lastPathComponent

        let snapshot = WorkingSubtitleSnapshot(
            videoPath: videoURL.standardizedFileURL.path,
            savedAt: Date(),
            translatedLanguageID: hasTranslatedCues ? translatedLanguage?.id : nil,
            lastGemmaRevisedCount: lastGemmaRevisedCount,
            cues: cues
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: workingCopySnapshotURL(for: videoURL), options: .atomic)
        }

        let origSRTURL = base.appendingPathExtension("srt")
        let origContent = SRTFormatter.format(cues: cues, displayMode: .originalOnly)
        var wroteAny = false
        if (try? origContent.write(to: origSRTURL, atomically: true, encoding: .utf8)) != nil {
            wroteAny = true
        }

        if let lang = translatedLanguage, hasTranslatedCues {
            let transOnlyURL = parentDir.appendingPathComponent("\(baseName)_\(lang.id).srt")
            let bilingualURL = parentDir.appendingPathComponent("\(baseName)_bilingual_\(lang.id).srt")
            let transOnlyContent = SRTFormatter.format(cues: cues, displayMode: .translatedOnly)
            let bilingualContent = SRTFormatter.format(cues: cues, displayMode: .bilingual)
            if (try? transOnlyContent.write(to: transOnlyURL, atomically: true, encoding: .utf8)) != nil {
                wroteAny = true
            }
            if (try? bilingualContent.write(to: bilingualURL, atomically: true, encoding: .utf8)) != nil {
                wroteAny = true
            }
        }

        if wroteAny {
            let activeURL = companionSRTURL(for: videoURL)
            self.lastSavedSRTURL = activeURL
            return activeURL
        }
        return nil
    }

    /// Loads the most recent working subtitles for `url` by comparing the working-copy snapshot and all companion `.srt` files on disk.
    @discardableResult
    private func loadCompanionSubtitles(for url: URL) -> Bool {
        let base = url.deletingPathExtension()
        let parentDir = base.deletingLastPathComponent()
        let baseName = base.lastPathComponent

        let companionSRT = base.appendingPathExtension("srt")
        let translatedSRT = parentDir.appendingPathComponent("\(baseName)_\(targetLanguage.id).srt")
        let bilingualSRT = parentDir.appendingPathComponent("\(baseName)_bilingual_\(targetLanguage.id).srt")

        func mtime(_ fileURL: URL) -> Date? {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            return (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }

        let companionDate = mtime(companionSRT)
        let transDate = mtime(translatedSRT)
        let bilingualDate = mtime(bilingualSRT)
        let newestDiskDate = [companionDate, transDate, bilingualDate].compactMap { $0 }.max()

        // 1. Check working copy snapshot if it is at least as fresh as the files on disk
        let snapshotURL = workingCopySnapshotURL(for: url)
        if let data = try? Data(contentsOf: snapshotURL),
           let snapshot = try? JSONDecoder().decode(WorkingSubtitleSnapshot.self, from: data),
           !snapshot.cues.isEmpty {
            let isSnapshotFresh = newestDiskDate == nil || snapshot.savedAt.addingTimeInterval(2.0) >= newestDiskDate!
            if isSnapshotFresh {
                self.cues = snapshot.cues
                if let langID = snapshot.translatedLanguageID,
                   let lang = TranslationLanguage.resolve(langID) {
                    self.translatedLanguage = lang
                } else {
                    self.translatedLanguage = nil
                }
                self.lastGemmaRevisedCount = snapshot.lastGemmaRevisedCount
                self.refreshSRTText()
                let candidateURL = companionSRTURL(for: url)
                if FileManager.default.fileExists(atPath: candidateURL.path) {
                    self.lastSavedSRTURL = candidateURL
                } else if FileManager.default.fileExists(atPath: companionSRT.path) {
                    self.lastSavedSRTURL = companionSRT
                }
                return true
            }
        }

        // 2. Otherwise, load from the freshest companion .srt files on disk
        var baseCues: [SubtitleCue] = []
        if let rawOrig = try? String(contentsOf: companionSRT, encoding: .utf8) {
            baseCues = SRTFormatter.collapseWordByWordCues(SRTFormatter.parse(rawOrig))
        }

        // Pick whichever translation file (_bilingual_<lang>.srt vs _<lang>.srt) was modified more recently
        let chosenTranslationSource: (url: URL, isBilingual: Bool, date: Date)? = {
            switch (bilingualDate, transDate) {
            case let (bDate?, tDate?):
                if bDate >= tDate {
                    return (bilingualSRT, true, bDate)
                } else {
                    return (translatedSRT, false, tDate)
                }
            case let (bDate?, nil):
                return (bilingualSRT, true, bDate)
            case let (nil, tDate?):
                return (translatedSRT, false, tDate)
            case (nil, nil):
                return nil
            }
        }()

        if let transSource = chosenTranslationSource,
           let rawTrans = try? String(contentsOf: transSource.url, encoding: .utf8) {
            let transParsed = SRTFormatter.collapseWordByWordCues(SRTFormatter.parse(rawTrans))

            // Only apply translation file if baseCues is empty OR its cue count matches baseCues
            // (and if baseCues is newer than transSource by > 10s with different cues, prefer fresh baseCues)
            let isTransCompatibleWithBase = baseCues.isEmpty || (
                transParsed.count == baseCues.count &&
                (companionDate == nil || transSource.date.addingTimeInterval(10.0) >= companionDate!)
            )

            if isTransCompatibleWithBase && !transParsed.isEmpty {
                if baseCues.isEmpty {
                    baseCues = transParsed.map { cue in
                        let (orig, trans) = Self.splitBilingualCueText(cue.text, knownOriginal: nil, isBilingualFile: transSource.isBilingual)
                        return SubtitleCue(
                            id: cue.id,
                            startTime: cue.startTime,
                            endTime: cue.endTime,
                            text: orig,
                            translatedText: trans,
                            wordTimings: cue.wordTimings
                        )
                    }
                } else {
                    let transMap = Dictionary(uniqueKeysWithValues: transParsed.map { ($0.id, $0.text) })
                    for idx in baseCues.indices {
                        if let rawCueText = transMap[baseCues[idx].id], !rawCueText.isEmpty {
                            let (_, trans) = Self.splitBilingualCueText(
                                rawCueText,
                                knownOriginal: baseCues[idx].text,
                                isBilingualFile: transSource.isBilingual
                            )
                            baseCues[idx].translatedText = trans ?? rawCueText
                        }
                    }
                }
                self.translatedLanguage = targetLanguage
                self.cues = baseCues
                self.refreshSRTText()
                // Synchronize all companion .srt files on disk with this loaded working copy
                _ = self.saveWorkingSubtitlesToDisk(for: url)
                self.lastSavedSRTURL = transSource.url
                return true
            }
        }

        if !baseCues.isEmpty {
            self.translatedLanguage = nil
            self.cues = baseCues
            self.refreshSRTText()
            self.lastSavedSRTURL = companionSRT
            return true
        }

        return false
    }

    private static func containsCJK(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if (0x4E00...0x9FFF).contains(scalar.value) ||
               (0x3400...0x4DBF).contains(scalar.value) ||
               (0x3040...0x30FF).contains(scalar.value) ||
               (0xAC00...0xD7AF).contains(scalar.value) {
                return true
            }
        }
        return false
    }

    private static func splitBilingualCueText(
        _ rawText: String,
        knownOriginal: String?,
        knownTranslated: String? = nil,
        isBilingualFile: Bool
    ) -> (original: String, translated: String?) {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let orig = knownOriginal?.trimmingCharacters(in: .whitespacesAndNewlines), !orig.isEmpty {
            if trimmed.hasPrefix(orig) {
                let remainder = trimmed.dropFirst(orig.count).trimmingCharacters(in: .whitespacesAndNewlines)
                if !remainder.isEmpty {
                    return (orig, remainder)
                }
            }
            if !isBilingualFile {
                return (orig, trimmed)
            }
        }

        if let trans = knownTranslated?.trimmingCharacters(in: .whitespacesAndNewlines), !trans.isEmpty {
            if trimmed.hasSuffix(trans) {
                let leading = trimmed.dropLast(trans.count).trimmingCharacters(in: .whitespacesAndNewlines)
                if !leading.isEmpty {
                    return (leading, trans)
                }
            }
        }

        let lines = trimmed
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if isBilingualFile && lines.count >= 2 {
            if let orig = knownOriginal?.trimmingCharacters(in: .whitespacesAndNewlines), !orig.isEmpty {
                let origLineCount = orig.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
                let dropCount = min(max(1, origLineCount), lines.count - 1)
                let trans = lines.dropFirst(dropCount).joined(separator: "\n")
                return (orig, trans)
            }
            if lines.count >= 3 {
                if let firstCJKIndex = lines.indices.dropFirst().first(where: { Self.containsCJK(lines[$0]) }) {
                    let orig = lines[..<firstCJKIndex].joined(separator: "\n")
                    let trans = lines[firstCJKIndex...].joined(separator: "\n")
                    return (orig, trans)
                }
                let orig = lines.dropLast().joined(separator: "\n")
                let trans = lines.last!
                return (orig, trans)
            }
            let orig = lines.first!
            let trans = lines.dropFirst().joined(separator: "\n")
            return (orig, trans)
        }

        if let orig = knownOriginal {
            return (orig, trimmed)
        }
        return (trimmed, nil)
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
        if let lang = translatedLanguage, hasTranslatedCues, subtitleDisplayMode != .originalOnly {
            let suffix = subtitleDisplayMode == .bilingual ? "bilingual_\(lang.id)" : lang.id
            panel.nameFieldStringValue = "\(baseName)_\(suffix).srt"
        } else {
            panel.nameFieldStringValue = "\(baseName).srt"
        }

        if panel.runModal() == .OK, let targetURL = panel.url {
            do {
                let content = SRTFormatter.format(
                    cues: cues,
                    displayMode: subtitleDisplayMode,
                    wordByWord: wordByWordSubtitles
                )
                try content.write(to: targetURL, atomically: true, encoding: .utf8)
                lastSavedSRTURL = targetURL
                statusMessage = "Saved subtitles (\(subtitleDisplayMode.compactLabel)\(wordByWordSubtitles ? ", word-by-word" : "")) to \(targetURL.lastPathComponent)."
            } catch {
                errorMessage = "Could not save .srt file: \(error.localizedDescription)"
            }
        }
    }

    public func applyImportedSRTFile(url: URL) throws {
        let raw = try String(contentsOf: url, encoding: .utf8)
        let parsed = SRTFormatter.collapseWordByWordCues(SRTFormatter.parse(raw))
        let fileNameLower = url.deletingPathExtension().lastPathComponent.lowercased()
        let isBilingualFile = fileNameLower.contains("_bilingual")

        var detectedLang: TranslationLanguage?
        for lang in TranslationLanguage.availableLanguages {
            if fileNameLower.hasSuffix("_\(lang.id.lowercased())") {
                detectedLang = lang
                break
            }
        }

        let resolvedCues: [SubtitleCue]
        if isBilingualFile {
            resolvedCues = parsed.map { cue in
                let (orig, trans) = Self.splitBilingualCueText(cue.text, knownOriginal: nil, isBilingualFile: true)
                return SubtitleCue(
                    id: cue.id,
                    startTime: cue.startTime,
                    endTime: cue.endTime,
                    text: orig,
                    translatedText: trans,
                    wordTimings: cue.wordTimings
                )
            }
        } else {
            resolvedCues = parsed
        }

        self.cues = resolvedCues
        self.translatedLanguage = isBilingualFile ? (detectedLang ?? targetLanguage) : nil
        self.lastGemmaRevisedCount = 0
        self.translationService.resetState()
        self.gemmaReviewService.resetState()
        self.refreshSRTText()
        self.lastSavedSRTURL = url
        self.statusMessage = "Loaded \(resolvedCues.count) subtitle cues from \(url.lastPathComponent)."
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
                try applyImportedSRTFile(url: url)
            } catch {
                self.errorMessage = "Failed to read .srt file: \(error.localizedDescription)"
            }
        }
    }

    public func copySRTToClipboard() {
        guard !srtText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(srtText, forType: .string)
        statusMessage = "Copied .SRT content (\(cues.count) cues, \(subtitleDisplayMode.compactLabel)\(wordByWordSubtitles ? ", word-by-word" : "")) to clipboard."
    }

    // MARK: - Burn Subtitles into Video

    public func burnSubtitlesIntoVideo() {
        guard let videoURL, !cues.isEmpty, !isBusy else { return }

        let panel = NSSavePanel()
        panel.title = "Export Video with Burned-In Subtitles"
        panel.allowedContentTypes = [.mpeg4Movie]
        let baseName = videoURL.deletingPathExtension().lastPathComponent
        let shortsTag = (aspectRatioMode == .vertical9x16 && !baseName.lowercased().contains("shorts")) ? "_shorts" : ""
        if let lang = translatedLanguage, hasTranslatedCues, subtitleDisplayMode != .originalOnly {
            let suffix = subtitleDisplayMode == .bilingual ? "bilingual_\(lang.id)" : lang.id
            panel.nameFieldStringValue = "\(baseName)\(shortsTag)_subtitled_\(suffix).mp4"
        } else {
            panel.nameFieldStringValue = "\(baseName)\(shortsTag)_subtitled.mp4"
        }

        guard panel.runModal() == .OK, let outputURL = panel.url else { return }

        isBusy = true
        isBurning = true
        burnProgress = 0.0
        errorMessage = nil
        let currentCues = self.cues
        let currentDisplayMode = self.subtitleDisplayMode
        let currentWordByWord = self.wordByWordSubtitles
        let currentAspect = self.aspectRatioMode
        let currentFocus = self.horizontalCropFocus
        let modeNote = "\(currentDisplayMode.compactLabel)\(currentWordByWord ? ", word-by-word" : "")\(currentAspect == .vertical9x16 ? ", 9:16 Shorts" : "")"
        statusMessage = "Burning \(cues.count) subtitles (\(modeNote)) into video…"

        Task { [self] in
            defer {
                isBusy = false
                isBurning = false
            }
            do {
                try await VideoSubtitleBurner.burnSubtitles(
                    sourceURL: videoURL,
                    outputURL: outputURL,
                    cues: currentCues,
                    displayMode: currentDisplayMode,
                    wordByWord: currentWordByWord,
                    aspectRatioMode: currentAspect,
                    horizontalFocus: currentFocus,
                    progressHandler: { progress in
                        Task { @MainActor [weak self] in
                            self?.burnProgress = progress
                        }
                    }
                )
                self.burnProgress = 1.0
                self.lastBurnedVideoURL = outputURL
                self.statusMessage = "Burned subtitles (\(modeNote)) into \(outputURL.lastPathComponent)!"
                self.postCompletionNotification(
                    title: "Subtitle Burn Complete",
                    message: "Burned \(currentCues.count) subtitles (\(modeNote)) into \(outputURL.lastPathComponent).",
                    systemImage: "flame.fill"
                )
                if !self.hasPlayablePreview {
                    let burnedPlayer = AVPlayer(url: outputURL)
                    self.player = burnedPlayer
                    self.hasPlayablePreview = true
                    self.isPlayingBurnedVideo = true
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
