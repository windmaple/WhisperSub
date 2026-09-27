import Foundation
import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers

@MainActor
public final class AppViewModel: ObservableObject {
    @Published public var selectedModel: WhisperModelOption = WhisperModelOption.defaultModel
    @Published public var videoURL: URL?
    @Published public var videoMetadata: VideoMetadata?
    @Published public var player: AVPlayer?
    @Published public var currentPlaybackTime: TimeInterval = 0

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
        videoURL = url
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
                self.videoMetadata = metadata
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

    // MARK: - Transcription

    public func transcribeCurrentVideo() {
        guard let videoURL, !isBusy else { return }
        isBusy = true
        errorMessage = nil
        lastSavedSRTURL = nil
        lastBurnedVideoURL = nil

        let model = selectedModel
        statusMessage = "Preparing \(model.displayName) on Apple Neural Engine…"

        Task {
            defer { isBusy = false }
            do {
                let generatedCues = try await transcriptionService.transcribeVideo(
                    videoURL: videoURL,
                    modelOption: model
                )
                self.cues = generatedCues
                self.srtText = SRTFormatter.format(cues: generatedCues)

                // Auto-write a companion .srt next to the video if writable, or inform the user
                let defaultSRTURL = videoURL.deletingPathExtension().appendingPathExtension("srt")
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
