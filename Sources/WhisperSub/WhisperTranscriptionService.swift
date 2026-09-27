import Foundation
import CoreML
import WhisperKit

@MainActor
public final class WhisperTranscriptionService: ObservableObject {
    public enum ServiceState: Equatable {
        case idle
        case downloadingModel(progress: Double, modelName: String)
        case loadingModel(modelName: String)
        case extractingAudio
        case transcribing(liveText: String)
        case completed(cueCount: Int, speedFactor: Double)
        case failed(String)
    }

    @Published public private(set) var state: ServiceState = .idle
    @Published public private(set) var loadedModelID: String?
    @Published public private(set) var cachedModelIDs: Set<String> = []

    private var whisperKit: WhisperKit?
    private let storageBaseURL: URL

    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.storageBaseURL = appSupport.appendingPathComponent("WhisperSub", isDirectory: true)
        try? FileManager.default.createDirectory(at: storageBaseURL, withIntermediateDirectories: true)
        refreshCachedModels()
    }

    private func localModelFolder(for variantID: String) -> URL? {
        let folderURL = storageBaseURL
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(variantID, isDirectory: true)

        let required = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
        for name in required {
            if !FileManager.default.fileExists(atPath: folderURL.appendingPathComponent(name).path) {
                return nil
            }
        }
        return folderURL
    }

    /// Checks which WhisperKit models are already downloaded on disk.
    public func refreshCachedModels() {
        var found: Set<String> = []
        for option in WhisperModelOption.availableModels {
            if localModelFolder(for: option.id) != nil {
                found.insert(option.id)
            }
        }
        cachedModelIDs = found
    }

    /// Downloads (if needed) and loads the selected Whisper model onto the Apple Neural Engine.
    public func prepareModel(_ modelOption: WhisperModelOption) async throws {
        if loadedModelID == modelOption.id, let whisperKit, whisperKit.modelState == .loaded {
            return
        }

        if let existing = whisperKit {
            await existing.unloadModels()
            self.whisperKit = nil
            self.loadedModelID = nil
        }

        let baseURL = self.storageBaseURL
        let modelFolderURL: URL

        if let cachedFolder = localModelFolder(for: modelOption.id) {
            modelFolderURL = cachedFolder
        } else {
            state = .downloadingModel(progress: 0.0, modelName: modelOption.displayName)
            modelFolderURL = try await Task.detached { [weak self] in
                try await WhisperKit.download(
                    variant: modelOption.id,
                    downloadBase: baseURL,
                    useBackgroundSession: false,
                    from: "argmaxinc/whisperkit-coreml",
                    progressCallback: { progress in
                        let fraction = max(0.0, min(1.0, progress.fractionCompleted))
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            if case .downloadingModel = self.state {
                                self.state = .downloadingModel(progress: fraction, modelName: modelOption.displayName)
                            }
                        }
                    }
                )
            }.value
            refreshCachedModels()
        }

        state = .loadingModel(modelName: modelOption.displayName)

        let instance = try await Task.detached {
            let computeOptions = ModelComputeOptions(
                melCompute: .cpuAndGPU,
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine,
                prefillCompute: .cpuOnly
            )

            let config = WhisperKitConfig(
                model: modelOption.id,
                downloadBase: baseURL,
                modelFolder: modelFolderURL.path,
                tokenizerFolder: baseURL,
                computeOptions: computeOptions,
                verbose: false,
                logLevel: .error,
                prewarm: false,
                load: true,
                download: false
            )

            return try await WhisperKit(config)
        }.value

        self.whisperKit = instance
        self.loadedModelID = modelOption.id
    }

    /// Transcribes a video file on the Apple Neural Engine and returns formatted `SubtitleCue`s.
    public func transcribeVideo(
        videoURL: URL,
        modelOption: WhisperModelOption
    ) async throws -> [SubtitleCue] {
        do {
            try await prepareModel(modelOption)
            guard let pipe = whisperKit else {
                throw NSError(domain: "WhisperSub", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "WhisperKit failed to initialize."
                ])
            }

            state = .extractingAudio
            let audioURL = try await VideoSubtitleBurner.extractAudioToTempWAV(from: videoURL)
            defer {
                if audioURL != videoURL {
                    try? FileManager.default.removeItem(at: audioURL)
                }
            }

            state = .transcribing(liveText: "Detecting spoken language on Apple Neural Engine…")

            nonisolated(unsafe) let unsafePipe = pipe
            let results: [TranscriptionResult] = try await Task.detached { [weak self] in
                let detectedLanguage = (try? await unsafePipe.detectLanguage(audioPath: audioURL.path))?.language
                await MainActor.run { [weak self] in
                    self?.state = .transcribing(liveText: "Listening and decoding (\(detectedLanguage ?? "auto")) on Apple Neural Engine…")
                }

                let decodeOptions = DecodingOptions(
                    verbose: false,
                    task: .transcribe,
                    language: detectedLanguage,
                    temperature: 0.0,
                    temperatureFallbackCount: 3,
                    usePrefillPrompt: true,
                    usePrefillCache: true,
                    detectLanguage: detectedLanguage == nil,
                    skipSpecialTokens: true,
                    withoutTimestamps: false,
                    wordTimestamps: false,
                    suppressBlank: true,
                    chunkingStrategy: .vad
                )

                return try await unsafePipe.transcribe(
                    audioPath: audioURL.path,
                    decodeOptions: decodeOptions,
                    callback: { progress in
                        let cleaned = SRTFormatter.cleanWhisperText(progress.text)
                        if !cleaned.isEmpty {
                            Task { @MainActor [weak self] in
                                self?.state = .transcribing(liveText: cleaned)
                            }
                        }
                        return nil
                    }
                )
            }.value

            let cues = Self.buildSubtitleCues(from: results)
            let speedFactor = results.first?.timings.speedFactor ?? 0.0
            state = .completed(cueCount: cues.count, speedFactor: speedFactor)
            return cues
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Converts WhisperKit `TranscriptionResult` segments into clean, well-timed `SubtitleCue`s.
    private static func buildSubtitleCues(from results: [TranscriptionResult]) -> [SubtitleCue] {
        let allSegments = results.flatMap { $0.segments }
            .sorted { $0.start < $1.start }

        var rawCues: [SubtitleCue] = []

        for segment in allSegments {
            let cleaned = SRTFormatter.cleanWhisperText(segment.text)
            guard !cleaned.isEmpty else { continue }

            let start = TimeInterval(segment.start)
            let end = max(start + 0.25, TimeInterval(segment.end))

            let subSegments = splitLongCaption(text: cleaned, start: start, end: end, maxChars: 88)
            for sub in subSegments {
                rawCues.append(
                    SubtitleCue(
                        id: rawCues.count + 1,
                        startTime: sub.start,
                        endTime: sub.end,
                        text: sub.text
                    )
                )
            }
        }

        return rawCues
    }

    private static func splitLongCaption(
        text: String,
        start: TimeInterval,
        end: TimeInterval,
        maxChars: Int
    ) -> [(start: TimeInterval, end: TimeInterval, text: String)] {
        guard text.count > maxChars, end > start + 0.8 else {
            return [(start, end, text)]
        }

        let words = text.split(separator: " ").map(String.init)
        guard words.count >= 4 else {
            return [(start, end, text)]
        }

        var chunks: [String] = []
        var currentWords: [String] = []
        var currentLen = 0

        for word in words {
            let addition = currentWords.isEmpty ? word.count : word.count + 1
            if currentLen + addition > maxChars && !currentWords.isEmpty {
                chunks.append(currentWords.joined(separator: " "))
                currentWords = [word]
                currentLen = word.count
            } else {
                currentWords.append(word)
                currentLen += addition
            }
        }
        if !currentWords.isEmpty {
            chunks.append(currentWords.joined(separator: " "))
        }

        let totalChars = max(1, chunks.reduce(0) { $0 + $1.count })
        let totalDuration = end - start
        var cursor = start
        var output: [(start: TimeInterval, end: TimeInterval, text: String)] = []

        for (idx, chunk) in chunks.enumerated() {
            let fraction = Double(chunk.count) / Double(totalChars)
            let segEnd = (idx == chunks.count - 1) ? end : (cursor + totalDuration * fraction)
            output.append((cursor, segEnd, chunk))
            cursor = segEnd
        }

        return output
    }
}
