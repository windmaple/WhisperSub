import CoreML
import CoreMLLLM
import Foundation

public enum GemmaReviewError: LocalizedError {
    case noTranslatedSubtitles
    case runtimeUnavailable(String)
    case downloadFailed(String)
    case inferenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noTranslatedSubtitles:
            return "Translate subtitles first before running Gemma 4 review and revision."
        case .runtimeUnavailable(let detail):
            return "Gemma 4 CoreML ANE runtime unavailable: \(detail)"
        case .downloadFailed(let detail):
            return "Failed to download Gemma 4 CoreML model: \(detail)"
        case .inferenceFailed(let detail):
            return "Gemma 4 review failed: \(detail)"
        }
    }
}

@MainActor
public final class GemmaReviewService: ObservableObject {
    public enum ServiceState: Equatable {
        case idle
        case downloadingModel(progress: Double, modelName: String, detail: String)
        case loadingModel(modelName: String)
        case reviewing(completed: Int, total: Int, modelName: String)
        case completed(revisedCount: Int, totalCount: Int, modelName: String)
        case failed(String)
    }

    @Published public private(set) var state: ServiceState = .idle
    @Published public private(set) var cachedModelIDs: Set<String> = []

    private let appStorageBaseURL: URL

    /// Cached CoreML ANE model instance so repeated reviews reuse the warm Neural Engine session.
    private var loadedCoreMLModelID: String?
    private var loadedCoreMLLLM: CoreMLLLM?
    private var activeDownloadSession: URLSession?

    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let rootURL = appSupport.appendingPathComponent("WhisperSub", isDirectory: true)
        self.appStorageBaseURL = rootURL.appendingPathComponent("models", isDirectory: true)

        try? FileManager.default.createDirectory(at: appStorageBaseURL, withIntermediateDirectories: true)
        refreshCachedModels()
    }

    public func resetState() {
        state = .idle
    }

    public func cancel() {
        activeDownloadSession?.invalidateAndCancel()
        activeDownloadSession = nil
        state = .idle
    }

    /// Checks which Gemma 4 CoreML ANE models are already cached in `~/Library/Application Support/WhisperSub/models`.
    public func refreshCachedModels() {
        var found: Set<String> = []
        for option in GemmaModelOption.availableModels {
            if localModelFolder(for: option) != nil {
                found.insert(option.id)
            }
        }
        cachedModelIDs = found
    }

    /// Returns the local folder containing the model's CoreML `.mlmodelc` chunks and sidecars if already downloaded.
    public nonisolated func localModelFolder(for option: GemmaModelOption) -> URL? {
        let folder = appStorageBaseURL.appendingPathComponent(option.repoID, isDirectory: true)
        let requiredFiles = [
            "chunk1.mlmodelc/weights/weight.bin",
            "chunk2.mlmodelc/weights/weight.bin",
            "chunk3.mlmodelc/weights/weight.bin",
            "chunk4.mlmodelc/weights/weight.bin",
            "embed_tokens_q8.bin",
            "embed_tokens_per_layer_q8.bin",
            "model_config.json",
            "hf_model/tokenizer.json"
        ]
        for rel in requiredFiles {
            let path = folder.appendingPathComponent(rel).path
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? NSNumber,
                  size.int64Value > 100 else {
                return nil
            }
        }
        return folder
    }

    /// Reviews and revises translated subtitle cues using the selected Gemma 4 CoreML model on the Apple Neural Engine (`.cpuAndNeuralEngine`).
    public func reviewAndReviseCues(
        _ cues: [SubtitleCue],
        targetLanguage: TranslationLanguage,
        modelOption: GemmaModelOption,
        customInstructions: String = "",
        progressHandler: (@Sendable (Int, Int, [SubtitleCue], Int) -> Void)? = nil
    ) async throws -> (cues: [SubtitleCue], revisedCount: Int) {
        let hasAnyTranslation = cues.contains(where: { $0.hasTranslation })
        guard !cues.isEmpty, hasAnyTranslation else {
            throw GemmaReviewError.noTranslatedSubtitles
        }

        do {
            try Task.checkCancellation()
            let modelFolder: URL
            if let existing = localModelFolder(for: modelOption) {
                modelFolder = existing
            } else {
                modelFolder = try await downloadCoreMLModel(modelOption)
                refreshCachedModels()
            }

            try Task.checkCancellation()
            state = .loadingModel(modelName: modelOption.shortName)
            let total = cues.count

            let llm: CoreMLLLM
            if loadedCoreMLModelID == modelOption.id, let cached = loadedCoreMLLLM {
                llm = cached
            } else {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try await CoreMLLLM.load(
                        from: modelFolder,
                        computeUnits: .cpuAndNeuralEngine
                    )
                }.value
                self.loadedCoreMLModelID = modelOption.id
                self.loadedCoreMLLLM = loaded
                llm = loaded
            }

            try Task.checkCancellation()
            state = .reviewing(completed: 0, total: total, modelName: modelOption.shortName)
            progressHandler?(0, total, cues, 0)

            let (updatedCues, revisedCount) = try await runCoreMLANEReview(
                cues: cues,
                llm: llm,
                targetLanguage: targetLanguage,
                customInstructions: customInstructions,
                onProgress: { [weak self] completed, totalCount, latestCues, revisedSoFar in
                    Task { @MainActor in
                        guard let self, !Task.isCancelled else { return }
                        self.state = .reviewing(completed: completed, total: totalCount, modelName: modelOption.shortName)
                        progressHandler?(completed, totalCount, latestCues, revisedSoFar)
                    }
                }
            )

            try Task.checkCancellation()
            state = .completed(
                revisedCount: revisedCount,
                totalCount: cues.count,
                modelName: modelOption.shortName
            )
            progressHandler?(total, total, updatedCues, revisedCount)
            return (updatedCues, revisedCount)
        } catch {
            if error is CancellationError || (error as NSError).code == NSURLErrorCancelled || Task.isCancelled {
                state = .idle
                throw CancellationError()
            }
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    // MARK: - CoreML ANE Model Downloading

    private struct RemoteFileSpec: Sendable {
        let remotePath: String
        let localPath: String
        let estimatedBytes: Int64
        let isOptional: Bool
    }

    private func downloadCoreMLModel(_ option: GemmaModelOption) async throws -> URL {
        let destFolder = appStorageBaseURL.appendingPathComponent(option.repoID, isDirectory: true)
        try FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true)

        let specs = Self.coreMLFileSpecs(for: option)
        let totalExpectedBytes = max(1, specs.reduce(Int64(0)) { $0 + $1.estimatedBytes })
        var completedBytes: Int64 = 0

        state = .downloadingModel(progress: 0.0, modelName: option.shortName, detail: "Preparing CoreML ANE bundle…")

        for (index, spec) in specs.enumerated() {
            try Task.checkCancellation()
            let fileURL = destFolder.appendingPathComponent(spec.localPath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let size = attrs[.size] as? NSNumber,
               size.int64Value > 0 {
                completedBytes += size.int64Value
                continue
            }

            let remoteURL = URL(string: "https://huggingface.co/\(option.repoID)/resolve/main/\(spec.remotePath)")!
            let isLargeFile = spec.estimatedBytes >= 5_000_000

            if !isLargeFile {
                let overallFraction = min(0.99, Double(completedBytes) / Double(totalExpectedBytes))
                state = .downloadingModel(
                    progress: overallFraction,
                    modelName: option.shortName,
                    detail: "Fetching \(spec.localPath) (\(index + 1)/\(specs.count))…"
                )
                var req = URLRequest(url: remoteURL)
                req.timeoutInterval = 90
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    if spec.isOptional {
                        continue
                    }
                    throw GemmaReviewError.downloadFailed("HTTP error downloading \(spec.remotePath)")
                }
                try data.write(to: fileURL, options: .atomic)
                completedBytes += Int64(data.count)
            } else {
                let baseCompleted = completedBytes
                try await downloadLargeFileWithOverallProgress(
                    from: remoteURL,
                    to: fileURL,
                    modelName: option.shortName,
                    fileName: spec.localPath,
                    baseCompletedBytes: baseCompleted,
                    totalExpectedBytes: totalExpectedBytes
                )
                if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                   let size = attrs[.size] as? NSNumber {
                    completedBytes += size.int64Value
                } else {
                    completedBytes += spec.estimatedBytes
                }
            }
        }

        // For E2B CoreML, prefill chunks share identical weight.bin with decode chunks
        for i in 1...4 {
            let decodeWeight = destFolder.appendingPathComponent("chunk\(i).mlmodelc/weights/weight.bin")
            let prefillCoreML = destFolder.appendingPathComponent("prefill_chunk\(i).mlmodelc/coremldata.bin")
            let prefillWeight = destFolder.appendingPathComponent("prefill_chunk\(i).mlmodelc/weights/weight.bin")
            if FileManager.default.fileExists(atPath: prefillCoreML.path),
               FileManager.default.fileExists(atPath: decodeWeight.path),
               !FileManager.default.fileExists(atPath: prefillWeight.path) {
                try? FileManager.default.createDirectory(
                    at: prefillWeight.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                do {
                    try FileManager.default.linkItem(at: decodeWeight, to: prefillWeight)
                } catch {
                    try? FileManager.default.copyItem(at: decodeWeight, to: prefillWeight)
                }
            }
        }

        return destFolder
    }

    private nonisolated static func coreMLFileSpecs(for option: GemmaModelOption) -> [RemoteFileSpec] {
        if option.id == "gemma-4-e2b-ane" {
            func swaChunk(_ i: Int, weightSize: Int64) -> [RemoteFileSpec] {
                [
                    .init(remotePath: "swa/chunk\(i).mlmodelc/weights/weight.bin", localPath: "chunk\(i).mlmodelc/weights/weight.bin", estimatedBytes: weightSize, isOptional: false),
                    .init(remotePath: "swa/chunk\(i).mlmodelc/coremldata.bin", localPath: "chunk\(i).mlmodelc/coremldata.bin", estimatedBytes: 1_000, isOptional: false),
                    .init(remotePath: "swa/chunk\(i).mlmodelc/model.mil", localPath: "chunk\(i).mlmodelc/model.mil", estimatedBytes: 450_000, isOptional: false),
                    .init(remotePath: "swa/chunk\(i).mlmodelc/analytics/coremldata.bin", localPath: "chunk\(i).mlmodelc/analytics/coremldata.bin", estimatedBytes: 250, isOptional: true)
                ]
            }
            func prefillMeta(_ i: Int) -> [RemoteFileSpec] {
                [
                    .init(remotePath: "prefill/chunk\(i).mlmodelc/coremldata.bin", localPath: "prefill_chunk\(i).mlmodelc/coremldata.bin", estimatedBytes: 1_000, isOptional: true),
                    .init(remotePath: "prefill/chunk\(i).mlmodelc/model.mil", localPath: "prefill_chunk\(i).mlmodelc/model.mil", estimatedBytes: 400_000, isOptional: true),
                    .init(remotePath: "prefill/chunk\(i).mlmodelc/analytics/coremldata.bin", localPath: "prefill_chunk\(i).mlmodelc/analytics/coremldata.bin", estimatedBytes: 250, isOptional: true)
                ]
            }
            return swaChunk(1, weightSize: 155_436_864)
                + swaChunk(2, weightSize: 133_963_968)
                + swaChunk(3, weightSize: 325_282_880)
                + swaChunk(4, weightSize: 526_874_880)
                + prefillMeta(1) + prefillMeta(2) + prefillMeta(3) + prefillMeta(4)
                + [
                    .init(remotePath: "model_config.json", localPath: "model_config.json", estimatedBytes: 500, isOptional: false),
                    .init(remotePath: "hf_model/tokenizer.json", localPath: "hf_model/tokenizer.json", estimatedBytes: 32_169_626, isOptional: false),
                    .init(remotePath: "hf_model/tokenizer_config.json", localPath: "hf_model/tokenizer_config.json", estimatedBytes: 2_100, isOptional: false),
                    .init(remotePath: "hf_model/config.json", localPath: "hf_model/config.json", estimatedBytes: 5_000, isOptional: false),
                    .init(remotePath: "hf_model/chat_template.jinja", localPath: "hf_model/chat_template.jinja", estimatedBytes: 18_569, isOptional: true),
                    .init(remotePath: "embed_tokens_q8.bin", localPath: "embed_tokens_q8.bin", estimatedBytes: 402_653_184, isOptional: false),
                    .init(remotePath: "embed_tokens_scales.bin", localPath: "embed_tokens_scales.bin", estimatedBytes: 524_288, isOptional: false),
                    .init(remotePath: "embed_tokens_per_layer_q8.bin", localPath: "embed_tokens_per_layer_q8.bin", estimatedBytes: 2_348_810_240, isOptional: false),
                    .init(remotePath: "embed_tokens_per_layer_scales.bin", localPath: "embed_tokens_per_layer_scales.bin", estimatedBytes: 524_288, isOptional: false),
                    .init(remotePath: "per_layer_projection.bin", localPath: "per_layer_projection.bin", estimatedBytes: 27_525_120, isOptional: false),
                    .init(remotePath: "per_layer_norm_weight.bin", localPath: "per_layer_norm_weight.bin", estimatedBytes: 1_024, isOptional: false),
                    .init(remotePath: "swa/cos_sliding.npy", localPath: "cos_sliding.npy", estimatedBytes: 4_194_432, isOptional: false),
                    .init(remotePath: "swa/sin_sliding.npy", localPath: "sin_sliding.npy", estimatedBytes: 16_777_344, isOptional: false),
                    .init(remotePath: "swa/cos_full.npy", localPath: "cos_full.npy", estimatedBytes: 8_388_736, isOptional: false),
                    .init(remotePath: "swa/sin_full.npy", localPath: "sin_full.npy", estimatedBytes: 8_388_736, isOptional: false)
                ]
        } else {
            // Gemma 4 E4B CoreML (`mlboydaisuke/gemma-4-E4B-coreml`)
            func e4bChunk(_ i: Int, weightSize: Int64, milSize: Int64) -> [RemoteFileSpec] {
                [
                    .init(remotePath: "chunk\(i).mlmodelc/weights/weight.bin", localPath: "chunk\(i).mlmodelc/weights/weight.bin", estimatedBytes: weightSize, isOptional: false),
                    .init(remotePath: "chunk\(i).mlmodelc/coremldata.bin", localPath: "chunk\(i).mlmodelc/coremldata.bin", estimatedBytes: 1_400, isOptional: false),
                    .init(remotePath: "chunk\(i).mlmodelc/model.mil", localPath: "chunk\(i).mlmodelc/model.mil", estimatedBytes: milSize, isOptional: false),
                    .init(remotePath: "chunk\(i).mlmodelc/analytics/coremldata.bin", localPath: "chunk\(i).mlmodelc/analytics/coremldata.bin", estimatedBytes: 250, isOptional: true)
                ]
            }
            return e4bChunk(1, weightSize: 585_970_432, milSize: 1_288_448)
                + e4bChunk(2, weightSize: 572_196_992, milSize: 1_277_032)
                + e4bChunk(3, weightSize: 412_740_736, milSize: 597_340)
                + e4bChunk(4, weightSize: 753_797_440, milSize: 608_413)
                + [
                    .init(remotePath: "model_config.json", localPath: "model_config.json", estimatedBytes: 711, isOptional: false),
                    .init(remotePath: "hf_model/tokenizer.json", localPath: "hf_model/tokenizer.json", estimatedBytes: 32_169_626, isOptional: false),
                    .init(remotePath: "hf_model/tokenizer_config.json", localPath: "hf_model/tokenizer_config.json", estimatedBytes: 2_097, isOptional: false),
                    .init(remotePath: "hf_model/config.json", localPath: "hf_model/config.json", estimatedBytes: 5_145, isOptional: false),
                    .init(remotePath: "hf_model/generation_config.json", localPath: "hf_model/generation_config.json", estimatedBytes: 208, isOptional: true),
                    .init(remotePath: "hf_model/chat_template.jinja", localPath: "hf_model/chat_template.jinja", estimatedBytes: 18_569, isOptional: true),
                    .init(remotePath: "embed_tokens_q8.bin", localPath: "embed_tokens_q8.bin", estimatedBytes: 671_088_640, isOptional: false),
                    .init(remotePath: "embed_tokens_scales.bin", localPath: "embed_tokens_scales.bin", estimatedBytes: 524_288, isOptional: false),
                    .init(remotePath: "embed_tokens_per_layer_q8.bin", localPath: "embed_tokens_per_layer_q8.bin", estimatedBytes: 2_818_572_288, isOptional: false),
                    .init(remotePath: "embed_tokens_per_layer_scales.bin", localPath: "embed_tokens_per_layer_scales.bin", estimatedBytes: 524_288, isOptional: false),
                    .init(remotePath: "per_layer_projection.bin", localPath: "per_layer_projection.bin", estimatedBytes: 55_050_240, isOptional: false),
                    .init(remotePath: "per_layer_norm_weight.bin", localPath: "per_layer_norm_weight.bin", estimatedBytes: 512, isOptional: false),
                    .init(remotePath: "cos_sliding.npy", localPath: "cos_sliding.npy", estimatedBytes: 2_097_280, isOptional: false),
                    .init(remotePath: "sin_sliding.npy", localPath: "sin_sliding.npy", estimatedBytes: 2_097_280, isOptional: false),
                    .init(remotePath: "cos_full.npy", localPath: "cos_full.npy", estimatedBytes: 4_194_432, isOptional: false),
                    .init(remotePath: "sin_full.npy", localPath: "sin_full.npy", estimatedBytes: 4_194_432, isOptional: false)
                ]
        }
    }

    private func downloadLargeFileWithOverallProgress(
        from remoteURL: URL,
        to destinationURL: URL,
        modelName: String,
        fileName: String,
        baseCompletedBytes: Int64,
        totalExpectedBytes: Int64
    ) async throws {
        let delegate = FileDownloadProgressDelegate { [weak self] written, expected in
            let currentTotal = baseCompletedBytes + written
            let fraction = min(0.99, max(0.0, Double(currentTotal) / Double(max(1, totalExpectedBytes))))
            let writtenMB = Double(written) / 1_048_576.0
            let totalMB = Double(expected) / 1_048_576.0
            let detail = expected > 0
                ? String(format: "%@ (%.0f / %.0f MB)", fileName, writtenMB, totalMB)
                : String(format: "%@ (%.0f MB)", fileName, writtenMB)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state = .downloadingModel(progress: fraction, modelName: modelName, detail: detail)
            }
        }

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        self.activeDownloadSession = session
        defer {
            if self.activeDownloadSession === session {
                self.activeDownloadSession = nil
            }
            session.finishTasksAndInvalidate()
        }

        let tempURL = try await delegate.download(using: session, from: remoteURL)
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try? FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
    }

    // MARK: - CoreML Apple Neural Engine (`.cpuAndNeuralEngine`) Runner

    private nonisolated func runCoreMLANEReview(
        cues: [SubtitleCue],
        llm: CoreMLLLM,
        targetLanguage: TranslationLanguage,
        customInstructions: String,
        onProgress: @escaping @Sendable (Int, Int, [SubtitleCue], Int) -> Void
    ) async throws -> ([SubtitleCue], Int) {
        let batchSize = 8
        let total = cues.count
        var workingCues = cues
        var revisedCount = 0

        var index = 0
        while index < total {
            try Task.checkCancellation()
            let end = min(total, index + batchSize)
            let batch = Array(workingCues[index..<end])
            let contextSliceStart = max(0, index - 2)
            let precedingContext = Array(workingCues[contextSliceStart..<index])

            let (systemPrompt, userPrompt) = Self.buildReviewPrompts(
                batch: batch,
                precedingContext: precedingContext,
                targetLanguage: targetLanguage.fullDisplayName,
                customInstructions: customInstructions
            )

            let combinedPrompt = "\(systemPrompt)\n\n\(userPrompt)"
            var rawResponse = ""
            for await token in try await llm.stream(combinedPrompt, maxTokens: 1200) {
                try Task.checkCancellation()
                rawResponse += token
            }
            try Task.checkCancellation()
            let batchRevisions = Self.parseRevisionJSON(rawResponse, fallbackBatch: batch)

            for i in index..<end {
                var updated = workingCues[i]
                let originalDraft = (updated.preReviewTranslatedText ?? updated.translatedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if let candidate = batchRevisions[updated.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !candidate.isEmpty {
                    if !originalDraft.isEmpty && candidate != originalDraft {
                        updated.preReviewTranslatedText = originalDraft
                        revisedCount += 1
                    }
                    updated.translatedText = candidate
                    updated.isReviewedByGemma = true
                } else if updated.hasTranslation {
                    updated.isReviewedByGemma = true
                }
                workingCues[i] = updated
            }

            index = end
            onProgress(index, total, workingCues, revisedCount)
        }

        return (workingCues, revisedCount)
    }

    private nonisolated static func buildReviewPrompts(
        batch: [SubtitleCue],
        precedingContext: [SubtitleCue],
        targetLanguage: String,
        customInstructions: String
    ) -> (system: String, user: String) {
        var system = """
        You are Gemma 4, an expert video subtitle localization editor. Your job is to review draft subtitle translations against the original spoken transcript and revise them so they read naturally, accurately, and concisely as on-screen captions in \(targetLanguage).
        Rules:
        1. Fix literal/awkward phrasing, mistranslations, grammar across split cues, and terminology inconsistencies.
        2. Keep each subtitle concise and natural for video viewing.
        3. Preserve the exact cue `id` numbers.
        4. Output ONLY a valid JSON array of objects: [{"id": <number>, "revised": "<string>"}] with no markdown fences and no extra commentary.
        """
        let trimmedNotes = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNotes.isEmpty {
            system += "\nAdditional style/domain instructions: \(trimmedNotes)"
        }

        var userParts: [String] = ["Target language: \(targetLanguage)"]
        if !precedingContext.isEmpty {
            let ctxItems: [[String: Any]] = precedingContext.map {
                ["id": $0.id, "original": $0.text, "translation": $0.translatedText ?? $0.text]
            }
            if let ctxData = try? JSONSerialization.data(withJSONObject: ctxItems),
               let ctxStr = String(data: ctxData, encoding: .utf8) {
                userParts.append("Preceding context (for continuity only, do not include in output):\n\(ctxStr)")
            }
        }

        let targetItems: [[String: Any]] = batch.map {
            ["id": $0.id, "original": $0.text, "draft": $0.translatedText ?? $0.text]
        }
        let targetData = (try? JSONSerialization.data(withJSONObject: targetItems)) ?? Data()
        let targetStr = String(data: targetData, encoding: .utf8) ?? "[]"
        userParts.append("Review and revise these subtitle cues (return JSON array [{\"id\": ..., \"revised\": ...}]):\n\(targetStr)")

        return (system, userParts.joined(separator: "\n\n"))
    }

    public nonisolated static func parseRevisionJSON(_ rawContent: String, fallbackBatch: [SubtitleCue]) -> [Int: String] {
        var cleaned = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip any <think>...</think>, <thought|>, or <channel|> blocks if present
        if let thinkRange = cleaned.range(of: "</think>", options: .backwards) {
            cleaned = String(cleaned[thinkRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let thoughtRange = cleaned.range(of: "<thought|>", options: .backwards) {
            cleaned = String(cleaned[thoughtRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let channelRange = cleaned.range(of: "<channel|>", options: .backwards) {
            cleaned = String(cleaned[channelRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Extract JSON array [...]
        if let startIdx = cleaned.firstIndex(of: "["),
           let endIdx = cleaned.lastIndex(of: "]"),
           startIdx <= endIdx {
            let jsonSlice = String(cleaned[startIdx...endIdx])
            if let data = jsonSlice.data(using: .utf8),
               let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                var result: [Int: String] = [:]
                for item in array {
                    let id = (item["id"] as? Int) ?? (item["id"] as? String).flatMap(Int.init)
                    let revised = (item["revised"] as? String) ?? (item["translation"] as? String) ?? (item["text"] as? String)
                    if let id, let revised = revised?.trimmingCharacters(in: .whitespacesAndNewlines), !revised.isEmpty {
                        result[id] = revised
                    }
                }
                if !result.isEmpty {
                    return result
                }
            }
        }

        var fallback: [Int: String] = [:]
        for cue in fallbackBatch {
            if let t = cue.translatedText {
                fallback[cue.id] = t
            }
        }
        return fallback
    }
}

// MARK: - URLSession File Download Progress Delegate

private final class FileDownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private let lock = NSLock()

    init(onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    func download(using session: URLSession, from url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            lock.lock()
            self.continuation = cont
            lock.unlock()
            let task = session.downloadTask(with: url)
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()

        guard let cont else { return }

        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            cont.resume(throwing: GemmaReviewError.downloadFailed("HTTP \(http.statusCode)"))
            return
        }

        let preservedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("whispersub_dl_\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: preservedURL)
            cont.resume(returning: preservedURL)
        } catch {
            cont.resume(throwing: error)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(throwing: error)
    }
}
