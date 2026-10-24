import Foundation

public enum SubtitleTranslationError: LocalizedError {
    case emptySubtitles
    case networkError(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .emptySubtitles:
            return "There are no subtitle cues to translate."
        case .networkError(let reason):
            return "Subtitle translation network error: \(reason)"
        case .invalidResponse:
            return "Received an unexpected response from the translation service."
        }
    }
}

@MainActor
public final class SubtitleTranslationService: ObservableObject {
    public enum ServiceState: Equatable {
        case idle
        case translating(completed: Int, total: Int, targetLanguage: String)
        case completed(cueCount: Int, targetLanguage: String, detectedSourceLanguage: String?)
        case failed(String)
    }

    @Published public private(set) var state: ServiceState = .idle

    public init() {}

    public func resetState() {
        state = .idle
    }

    /// Translates an array of `SubtitleCue`s into `targetLanguage`, populating `translatedText` on each cue while preserving `text` (original).
    public func translateCues(
        _ cues: [SubtitleCue],
        to targetLanguage: TranslationLanguage,
        progressHandler: (@Sendable (Int, Int, [SubtitleCue]) -> Void)? = nil
    ) async throws -> [SubtitleCue] {
        guard !cues.isEmpty else {
            throw SubtitleTranslationError.emptySubtitles
        }

        let total = cues.count
        var workingCues: [SubtitleCue] = cues.map { cue in
            SubtitleCue(
                id: cue.id,
                startTime: cue.startTime,
                endTime: cue.endTime,
                text: cue.text,
                translatedText: nil,
                preReviewTranslatedText: nil,
                isReviewedByGemma: false
            )
        }

        state = .translating(completed: 0, total: total, targetLanguage: targetLanguage.displayName)
        progressHandler?(0, total, workingCues)

        do {
            let batches = Self.makeBatches(from: workingCues, maxCuesPerBatch: 10, maxCharsPerBatch: 1100)

            var completed = 0
            var detectedSource: String?

            for batch in batches {
                try Task.checkCancellation()
                let (translatedBatch, batchSource) = try await Self.translateBatch(
                    batch,
                    targetLanguageCode: targetLanguage.id
                )
                try Task.checkCancellation()
                if detectedSource == nil, let batchSource, !batchSource.isEmpty {
                    detectedSource = batchSource
                }

                for (offset, item) in translatedBatch.enumerated() {
                    let targetIndex = completed + offset
                    if targetIndex < workingCues.count {
                        workingCues[targetIndex] = item
                    }
                }
                completed += translatedBatch.count

                state = .translating(
                    completed: completed,
                    total: total,
                    targetLanguage: targetLanguage.displayName
                )
                progressHandler?(completed, total, workingCues)
            }

            state = .completed(
                cueCount: workingCues.count,
                targetLanguage: targetLanguage.displayName,
                detectedSourceLanguage: detectedSource
            )
            return workingCues
        } catch {
            if error is CancellationError || (error as NSError).code == NSURLErrorCancelled || Task.isCancelled {
                state = .idle
                throw CancellationError()
            }
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    // MARK: - Batching & Execution

    private nonisolated static func makeBatches(
        from cues: [SubtitleCue],
        maxCuesPerBatch: Int,
        maxCharsPerBatch: Int
    ) -> [[SubtitleCue]] {
        var batches: [[SubtitleCue]] = []
        var currentBatch: [SubtitleCue] = []
        var currentChars = 0

        for cue in cues {
            let len = cue.text.count
            if !currentBatch.isEmpty && (currentBatch.count >= maxCuesPerBatch || currentChars + len > maxCharsPerBatch) {
                batches.append(currentBatch)
                currentBatch = [cue]
                currentChars = len
            } else {
                currentBatch.append(cue)
                currentChars += len
            }
        }

        if !currentBatch.isEmpty {
            batches.append(currentBatch)
        }

        return batches
    }

    private nonisolated static func translateBatch(
        _ batch: [SubtitleCue],
        targetLanguageCode: String
    ) async throws -> ([SubtitleCue], String?) {
        guard !batch.isEmpty else { return ([], nil) }

        if batch.count == 1 {
            let cue = batch[0]
            let cleanedSource = Self.singleLineSource(cue.text)
            let (translated, sourceLang) = try await translateText(cleanedSource, targetLanguageCode: targetLanguageCode)
            var updated = cue
            updated.translatedText = translated.trimmingCharacters(in: .whitespacesAndNewlines)
            return ([updated], sourceLang)
        }

        // Join multiple cues with a language-neutral pipe delimiter
        let cleanedSources = batch.map { Self.singleLineSource($0.text) }
        let joinedPayload = cleanedSources.joined(separator: "\n|||\n")

        if let (rawTranslated, sourceLang) = try? await translateText(joinedPayload, targetLanguageCode: targetLanguageCode) {
            let normalized = rawTranslated
                .replacingOccurrences(of: "｜｜｜", with: "|||")
                .replacingOccurrences(of: "| | |", with: "|||")
            let parts = normalized
                .components(separatedBy: "|||")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

            if parts.count == batch.count && parts.allSatisfy({ !$0.isEmpty }) {
                let result: [SubtitleCue] = zip(batch, parts).map { cue, translated in
                    var updated = cue
                    updated.translatedText = translated
                    return updated
                }
                return (result, sourceLang)
            }
        }

        // Fallback: translate each cue in the batch concurrently to guarantee 1-to-1 alignment
        return try await withThrowingTaskGroup(of: (Int, SubtitleCue, String?).self) { group in
            for (idx, cue) in batch.enumerated() {
                group.addTask {
                    let cleanedSource = Self.singleLineSource(cue.text)
                    let (translated, sourceLang) = try await translateText(cleanedSource, targetLanguageCode: targetLanguageCode)
                    var updated = cue
                    updated.translatedText = translated.trimmingCharacters(in: .whitespacesAndNewlines)
                    return (idx, updated, sourceLang)
                }
            }

            var indexedResults: [(Int, SubtitleCue, String?)] = []
            indexedResults.reserveCapacity(batch.count)
            for try await item in group {
                indexedResults.append(item)
            }
            indexedResults.sort { $0.0 < $1.0 }

            let cues = indexedResults.map { $0.1 }
            let detected = indexedResults.compactMap { $0.2 }.first
            return (cues, detected)
        }
    }

    private nonisolated static func singleLineSource(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "|||", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func translateText(
        _ text: String,
        targetLanguageCode: String
    ) async throws -> (String, String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", nil) }

        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")
        components?.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: targetLanguageCode),
            URLQueryItem(name: "dt", value: "t")
        ]

        guard let url = components?.url else {
            throw SubtitleTranslationError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko)",
            forHTTPHeaderField: "User-Agent"
        )

        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encodedQuery = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        request.httpBody = "q=\(encodedQuery)".data(using: .utf8)

        var lastError: Error?
        for attempt in 0..<3 {
            try Task.checkCancellation()
            if attempt > 0 {
                try await Task.sleep(nanoseconds: UInt64(attempt) * 350_000_000)
            }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw SubtitleTranslationError.networkError("HTTP \(http.statusCode)")
                }

                guard let root = try JSONSerialization.jsonObject(with: data) as? [Any],
                      let sentences = root.first as? [Any]
                else {
                    throw SubtitleTranslationError.invalidResponse
                }

                var translatedFragments: [String] = []
                for item in sentences {
                    if let segment = item as? [Any],
                       let piece = segment.first as? String {
                        translatedFragments.append(piece)
                    }
                }

                let fullTranslated = translatedFragments.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !fullTranslated.isEmpty else {
                    throw SubtitleTranslationError.invalidResponse
                }

                let detectedSource = (root.count > 2) ? (root[2] as? String) : nil
                return (fullTranslated, detectedSource)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? SubtitleTranslationError.networkError("Request timed out.")
    }
}
