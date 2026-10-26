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
    nonisolated(unsafe) private var isCancelled: Bool = false

    public func cancel() {
        isCancelled = true
        state = .idle
    }

    public init() {
        // Ensure HubApi always uses huggingface.co directly instead of an environment mirror
        // (e.g. hf-mirror.com) whose 308 cross-host redirects omit ETag/X-Repo-Commit headers.
        setenv("HF_ENDPOINT", "https://huggingface.co", 1)

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

        try await Self.ensureLocalTokenizerFiles(in: modelFolderURL, variantID: modelOption.id)

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

    /// Ensures `config.json`, `tokenizer_config.json`, and `tokenizer.json` are present inside `modelFolderURL`
    /// so `WhisperKit` loads the tokenizer directly from disk without relying on `HubApi.snapshot` metadata headers.
    nonisolated private static func ensureLocalTokenizerFiles(in modelFolderURL: URL, variantID: String) async throws {
        let requiredFiles = ["config.json", "tokenizer_config.json", "tokenizer.json"]
        let missingFiles = requiredFiles.filter { fileName in
            let fileURL = modelFolderURL.appendingPathComponent(fileName)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                  let size = attrs[.size] as? NSNumber else {
                return true
            }
            return size.intValue == 0
        }

        guard !missingFiles.isEmpty else { return }

        let repoID = tokenizerRepoID(for: variantID)
        try FileManager.default.createDirectory(at: modelFolderURL, withIntermediateDirectories: true)

        for fileName in missingFiles {
            let destinationURL = modelFolderURL.appendingPathComponent(fileName)
            let remoteURL = URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(fileName)")!
            var request = URLRequest(url: remoteURL)
            request.timeoutInterval = 30

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw NSError(domain: "WhisperSub", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to download tokenizer file \(fileName) from \(repoID) (HTTP \(code))."
                ])
            }
            try data.write(to: destinationURL, options: .atomic)
        }
    }

    nonisolated private static func tokenizerRepoID(for variantID: String) -> String {
        let lower = variantID.lowercased()
        if lower.contains("large-v3") {
            return "openai/whisper-large-v3"
        } else if lower.contains("large-v2") {
            return "openai/whisper-large-v2"
        } else if lower.contains("large") {
            return "openai/whisper-large"
        } else if lower.contains("medium.en") {
            return "openai/whisper-medium.en"
        } else if lower.contains("medium") {
            return "openai/whisper-medium"
        } else if lower.contains("small.en") {
            return "openai/whisper-small.en"
        } else if lower.contains("small") {
            return "openai/whisper-small"
        } else if lower.contains("base.en") {
            return "openai/whisper-base.en"
        } else if lower.contains("base") {
            return "openai/whisper-base"
        } else if lower.contains("tiny.en") {
            return "openai/whisper-tiny.en"
        } else if lower.contains("tiny") {
            return "openai/whisper-tiny"
        }
        return "openai/whisper-base"
    }

    /// Transcribes (or translates speech-to-English) a video file on the Apple Neural Engine and returns formatted `SubtitleCue`s.
    public func transcribeVideo(
        videoURL: URL,
        modelOption: WhisperModelOption,
        translateToEnglish: Bool = false,
        onPartialCues: (@Sendable ([SubtitleCue]) -> Void)? = nil
    ) async throws -> [SubtitleCue] {
        isCancelled = false
        do {
            try Task.checkCancellation()
            try await prepareModel(modelOption)
            try Task.checkCancellation()
            if isCancelled { throw CancellationError() }

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

            try Task.checkCancellation()
            if isCancelled { throw CancellationError() }

            state = .transcribing(liveText: "Detecting spoken language on Apple Neural Engine…")

            nonisolated(unsafe) let unsafePipe = pipe
            let segmentLock = NSLock()
            nonisolated(unsafe) var discoveredSegments: [TranscriptionSegment] = []

            unsafePipe.segmentDiscoveryCallback = { [weak self] newSegments in
                guard let self, !self.isCancelled, !Task.isCancelled else { return }
                let adjusted: [TranscriptionSegment] = newSegments.map { seg in
                    let seekTime = Float(seg.seek) / Float(WhisperKit.sampleRate)
                    // In VAD chunked mode, seg.seek holds the chunk's sample offset while seg.start is chunk-relative (0..<30s).
                    if seekTime > 0 && seg.start < 31.0 && seg.start + 0.5 < seekTime {
                        return TranscriptionUtilities.updateSegmentTimings(segment: seg, seekTime: seekTime)
                    }
                    return seg
                }
                segmentLock.lock()
                discoveredSegments.append(contentsOf: adjusted)
                let snapshot = discoveredSegments
                segmentLock.unlock()

                let partialCues = Self.buildSubtitleCues(fromSegments: snapshot)
                if !partialCues.isEmpty {
                    onPartialCues?(partialCues)
                }
            }
            defer {
                unsafePipe.segmentDiscoveryCallback = nil
            }

            let results: [TranscriptionResult] = try await Task.detached { [weak self] in
                try Task.checkCancellation()
                if self?.isCancelled == true { throw CancellationError() }

                let detectedLanguage = (try? await unsafePipe.detectLanguage(audioPath: audioURL.path))?.language
                try Task.checkCancellation()
                if self?.isCancelled == true { throw CancellationError() }

                await MainActor.run { [weak self] in
                    guard let self, !self.isCancelled else { return }
                    if translateToEnglish {
                        self.state = .transcribing(liveText: "Translating speech (\(detectedLanguage ?? "auto") → en) on Apple Neural Engine…")
                    } else {
                        self.state = .transcribing(liveText: "Listening and decoding (\(detectedLanguage ?? "auto")) on Apple Neural Engine…")
                    }
                }

                let decodeOptions = DecodingOptions(
                    verbose: false,
                    task: translateToEnglish ? .translate : .transcribe,
                    language: detectedLanguage,
                    temperature: 0.0,
                    temperatureFallbackCount: 3,
                    usePrefillPrompt: true,
                    usePrefillCache: true,
                    detectLanguage: detectedLanguage == nil,
                    skipSpecialTokens: true,
                    withoutTimestamps: false,
                    wordTimestamps: true,
                    suppressBlank: true,
                    chunkingStrategy: .vad
                )

                return try await unsafePipe.transcribe(
                    audioPath: audioURL.path,
                    decodeOptions: decodeOptions,
                    callback: { progress in
                        if Task.isCancelled || self?.isCancelled == true {
                            return false
                        }
                        let cleaned = SRTFormatter.cleanWhisperText(progress.text)
                        if !cleaned.isEmpty {
                            Task { @MainActor [weak self] in
                                guard let self, !self.isCancelled else { return }
                                self.state = .transcribing(liveText: cleaned)
                            }
                        }
                        return nil
                    }
                )
            }.value

            try Task.checkCancellation()
            if isCancelled { throw CancellationError() }

            let cues = Self.buildSubtitleCues(from: results)
            let speedFactor = results.first?.timings.speedFactor ?? 0.0
            state = .completed(cueCount: cues.count, speedFactor: speedFactor)
            return cues
        } catch {
            if error is CancellationError || Task.isCancelled || isCancelled {
                state = .idle
                throw CancellationError()
            }
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Converts WhisperKit `TranscriptionResult` segments into clean, voice-aligned `SubtitleCue`s with per-word DTW timings.
    nonisolated private static func buildSubtitleCues(from results: [TranscriptionResult]) -> [SubtitleCue] {
        buildSubtitleCues(fromSegments: results.flatMap { $0.segments })
    }

    nonisolated private static func buildSubtitleCues(fromSegments segments: [TranscriptionSegment]) -> [SubtitleCue] {
        let allSegments = segments.sorted { $0.start < $1.start }

        var rawCues: [SubtitleCue] = []

        for segment in allSegments {
            let cleaned = SRTFormatter.cleanWhisperText(segment.text)
            guard !cleaned.isEmpty else { continue }

            let segStart = max(0, TimeInterval(segment.start))
            let segEnd = max(segStart + 0.20, TimeInterval(segment.end))

            let extractedWords = extractCleanWordTimings(from: segment.words)
            if !extractedWords.isEmpty {
                let phraseChunks = splitWordsIntoVoiceAlignedPhrases(extractedWords, segmentEnd: segEnd)
                for chunk in phraseChunks {
                    rawCues.append(
                        SubtitleCue(
                            id: rawCues.count + 1,
                            startTime: chunk.start,
                            endTime: chunk.end,
                            text: chunk.text,
                            wordTimings: chunk.words
                        )
                    )
                }
            } else {
                let subSegments = splitLongCaption(text: cleaned, start: segStart, end: segEnd, maxChars: 56)
                for sub in subSegments {
                    let synthesized = SubtitleCue.synthesizeWordTimings(
                        for: sub.text,
                        startTime: sub.start,
                        endTime: sub.end
                    )
                    rawCues.append(
                        SubtitleCue(
                            id: rawCues.count + 1,
                            startTime: sub.start,
                            endTime: sub.end,
                            text: sub.text,
                            wordTimings: synthesized
                        )
                    )
                }
            }
        }

        // Prevent any cue's reading-hold tail from overlapping the next cue's spoken onset
        if rawCues.count >= 2 {
            for i in 0..<(rawCues.count - 1) {
                let nextStart = rawCues[i + 1].startTime
                if rawCues[i].endTime > nextStart && nextStart > rawCues[i].startTime + 0.06 {
                    rawCues[i].endTime = nextStart
                    if let timings = rawCues[i].wordTimings {
                        rawCues[i].wordTimings = SubtitleCue.normalizeWordTimings(
                            timings,
                            cueStart: rawCues[i].startTime,
                            cueEnd: rawCues[i].endTime
                        )
                    }
                }
            }
        }

        return rawCues
    }

    nonisolated private static func containsCJK(_ text: String) -> Bool {
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

    nonisolated private static func needsLeadingSpace(after prev: String, before curr: String) -> Bool {
        guard let prevLast = prev.unicodeScalars.last,
              let currFirst = curr.unicodeScalars.first else {
            return false
        }
        if CharacterSet.whitespacesAndNewlines.contains(prevLast) || CharacterSet.whitespacesAndNewlines.contains(currFirst) {
            return false
        }
        // Do not insert space before closing/clause punctuation or apostrophes
        let noSpaceBefore = CharacterSet(charactersIn: ",.;:!?)]}'’\"”»，。；：！？、）》」』】")
        if noSpaceBefore.contains(currFirst) {
            return false
        }
        // Do not insert space between CJK characters
        let prevIsCJK = (0x3000...0x9FFF).contains(prevLast.value) || (0xAC00...0xD7AF).contains(prevLast.value) || (0xFF00...0xFFEF).contains(prevLast.value)
        let currIsCJK = (0x3000...0x9FFF).contains(currFirst.value) || (0xAC00...0xD7AF).contains(currFirst.value) || (0xFF00...0xFFEF).contains(currFirst.value)
        if prevIsCJK && currIsCJK {
            return false
        }
        return CharacterSet.alphanumerics.contains(prevLast) || CharacterSet.punctuationCharacters.contains(prevLast)
    }

    nonisolated private static func extractCleanWordTimings(from rawWords: [WordTiming]?) -> [SubtitleWordTiming] {
        guard let rawWords, !rawWords.isEmpty else { return [] }
        var cleanedWords: [SubtitleWordTiming] = []
        cleanedWords.reserveCapacity(rawWords.count)

        for item in rawWords {
            let hadLeadingSpace = item.word.unicodeScalars.first.map { CharacterSet.whitespaces.contains($0) } ?? false
            let cleanedToken = SRTFormatter.cleanWhisperText(item.word)
            guard !cleanedToken.isEmpty else { continue }

            let start = max(0, TimeInterval(item.start))
            let end = max(start + 0.02, TimeInterval(item.end))

            // If token is standalone punctuation, attach it to the previous word
            let isPurePunct = cleanedToken.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
            if isPurePunct, !cleanedWords.isEmpty {
                cleanedWords[cleanedWords.count - 1].word += cleanedToken
                cleanedWords[cleanedWords.count - 1].endTime = max(cleanedWords[cleanedWords.count - 1].endTime, end)
                continue
            }

            let formattedWord: String
            if cleanedWords.isEmpty {
                formattedWord = cleanedToken
            } else if hadLeadingSpace || needsLeadingSpace(after: cleanedWords[cleanedWords.count - 1].word, before: cleanedToken) {
                formattedWord = " " + cleanedToken
            } else {
                formattedWord = cleanedToken
            }

            cleanedWords.append(SubtitleWordTiming(word: formattedWord, startTime: start, endTime: end))
        }

        return cleanedWords
    }

    nonisolated private static func splitWordsIntoVoiceAlignedPhrases(
        _ words: [SubtitleWordTiming],
        segmentEnd: TimeInterval
    ) -> [(start: TimeInterval, end: TimeInterval, text: String, words: [SubtitleWordTiming])] {
        guard !words.isEmpty else { return [] }

        var groups: [[SubtitleWordTiming]] = []
        var current: [SubtitleWordTiming] = []

        for i in 0..<words.count {
            current.append(words[i])
            guard i + 1 < words.count else { break }

            let curr = words[i]
            let next = words[i + 1]
            let pauseGap = next.startTime - curr.endTime
            let joinedText = current.map(\.word).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            let isCJK = containsCJK(joinedText)
            let maxChars = isCJK ? 26 : 54
            let maxWords = isCJK ? 14 : 9

            let trimmedCurr = curr.word.trimmingCharacters(in: .whitespacesAndNewlines)
            let endsWithSentencePunct = trimmedCurr.last.map { ".!?。！？…".contains($0) } ?? false
            let endsWithClausePunct = trimmedCurr.last.map { ",;:—，；：、".contains($0) } ?? false

            let shouldSplitOnPause = pauseGap >= 0.48
            let shouldSplitOnSentence = endsWithSentencePunct && (pauseGap >= 0.10 || joinedText.count >= (isCJK ? 8 : 16))
            let shouldSplitOnClause = endsWithClausePunct && (pauseGap >= 0.20 || joinedText.count >= (isCJK ? 13 : 28))
            let shouldSplitOnLength = (joinedText.count + next.word.count > maxChars) || (current.count >= maxWords)

            if shouldSplitOnPause || shouldSplitOnSentence || shouldSplitOnClause || shouldSplitOnLength {
                groups.append(current)
                current = []
            }
        }
        if !current.isEmpty {
            groups.append(current)
        }

        var output: [(start: TimeInterval, end: TimeInterval, text: String, words: [SubtitleWordTiming])] = []
        output.reserveCapacity(groups.count)

        for (gIdx, group) in groups.enumerated() {
            guard let first = group.first, let last = group.last else { continue }
            var normalizedWords = group
            normalizedWords[0].word = normalizedWords[0].word.trimmingCharacters(in: .whitespacesAndNewlines)
            let phraseText = normalizedWords.map(\.word).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phraseText.isEmpty else { continue }

            let phraseStart = max(0, first.startTime)
            let nextPhraseStart = (gIdx + 1 < groups.count) ? groups[gIdx + 1].first?.startTime : nil
            let naturalTail = min(segmentEnd, last.endTime + 0.10)
            let cappedEnd = nextPhraseStart.map { min(naturalTail, max(last.endTime, $0 - 0.02)) } ?? naturalTail
            let phraseEnd = max(phraseStart + 0.20, last.endTime, cappedEnd)

            let finalizedWords = SubtitleCue.normalizeWordTimings(
                normalizedWords,
                cueStart: phraseStart,
                cueEnd: phraseEnd
            )
            output.append((start: phraseStart, end: phraseEnd, text: phraseText, words: finalizedWords))
        }

        return output
    }

    nonisolated private static func splitLongCaption(
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
