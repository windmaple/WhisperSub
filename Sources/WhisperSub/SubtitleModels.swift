import Foundation

public enum SubtitleDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case translatedOnly = "Translated Only"
    case bilingual = "Bilingual (Original + Translated)"
    case originalOnly = "Original Only"

    public var id: String { rawValue }

    public var compactLabel: String {
        switch self {
        case .translatedOnly: return "Translated"
        case .bilingual: return "Bilingual"
        case .originalOnly: return "Original"
        }
    }
}

public struct TranslationLanguage: Identifiable, Equatable, Hashable, Sendable {
    public let id: String          // BCP-47 / ISO language code (e.g. "zh-CN", "en", "es", "ja")
    public let displayName: String // English name
    public let nativeName: String  // Native script name

    public var fullDisplayName: String {
        if displayName == nativeName {
            return displayName
        }
        return "\(displayName) • \(nativeName)"
    }

    public static let availableLanguages: [TranslationLanguage] = [
        TranslationLanguage(id: "zh-CN", displayName: "Chinese (Simplified)", nativeName: "简体中文"),
        TranslationLanguage(id: "zh-TW", displayName: "Chinese (Traditional)", nativeName: "繁體中文"),
        TranslationLanguage(id: "en", displayName: "English", nativeName: "English"),
        TranslationLanguage(id: "ja", displayName: "Japanese", nativeName: "日本語"),
        TranslationLanguage(id: "ko", displayName: "Korean", nativeName: "한국어"),
        TranslationLanguage(id: "es", displayName: "Spanish", nativeName: "Español"),
        TranslationLanguage(id: "fr", displayName: "French", nativeName: "Français"),
        TranslationLanguage(id: "de", displayName: "German", nativeName: "Deutsch"),
        TranslationLanguage(id: "pt", displayName: "Portuguese", nativeName: "Português"),
        TranslationLanguage(id: "ru", displayName: "Russian", nativeName: "Русский"),
        TranslationLanguage(id: "ar", displayName: "Arabic", nativeName: "العربية"),
        TranslationLanguage(id: "hi", displayName: "Hindi", nativeName: "हिन्दी"),
        TranslationLanguage(id: "it", displayName: "Italian", nativeName: "Italiano"),
        TranslationLanguage(id: "nl", displayName: "Dutch", nativeName: "Nederlands"),
        TranslationLanguage(id: "tr", displayName: "Turkish", nativeName: "Türkçe"),
        TranslationLanguage(id: "vi", displayName: "Vietnamese", nativeName: "Tiếng Việt"),
        TranslationLanguage(id: "th", displayName: "Thai", nativeName: "ไทย"),
        TranslationLanguage(id: "id", displayName: "Indonesian", nativeName: "Bahasa Indonesia")
    ]

    public static let defaultLanguage = availableLanguages[0] // Chinese (Simplified)

    /// Resolves a language code or name (e.g. "zh", "zh-CN", "en", "japanese", "spanish") to a `TranslationLanguage`.
    public static func resolve(_ query: String) -> TranslationLanguage? {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }

        if normalized == "zh" || normalized == "zh-hans" || normalized == "cn" || normalized == "chinese" {
            return availableLanguages.first { $0.id == "zh-CN" }
        }
        if normalized == "zh-hant" || normalized == "tw" || normalized == "hk" {
            return availableLanguages.first { $0.id == "zh-TW" }
        }

        if let exact = availableLanguages.first(where: {
            $0.id.lowercased() == normalized ||
            $0.displayName.lowercased() == normalized ||
            $0.nativeName.lowercased() == normalized
        }) {
            return exact
        }

        return availableLanguages.first(where: {
            $0.displayName.lowercased().contains(normalized) ||
            $0.id.lowercased().hasPrefix(normalized)
        })
    }
}

public struct SubtitleCue: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: Int
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var text: String
    public var translatedText: String?
    public var preReviewTranslatedText: String?
    public var isReviewedByGemma: Bool

    public init(
        id: Int,
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        translatedText: String? = nil,
        preReviewTranslatedText: String? = nil,
        isReviewedByGemma: Bool = false
    ) {
        self.id = id
        self.startTime = max(0, startTime)
        self.endTime = max(self.startTime + 0.05, endTime)
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTranslation = translatedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.translatedText = (trimmedTranslation?.isEmpty == false) ? trimmedTranslation : nil
        let trimmedPreReview = preReviewTranslatedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.preReviewTranslatedText = (trimmedPreReview?.isEmpty == false) ? trimmedPreReview : nil
        self.isReviewedByGemma = isReviewedByGemma
    }

    public var hasTranslation: Bool {
        guard let t = translatedText?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !t.isEmpty
    }

    public var wasRevisedByGemma: Bool {
        guard isReviewedByGemma,
              let pre = preReviewTranslatedText?.trimmingCharacters(in: .whitespacesAndNewlines),
              let cur = translatedText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pre.isEmpty,
              !cur.isEmpty
        else {
            return false
        }
        return pre != cur
    }

    public func displayText(for mode: SubtitleDisplayMode) -> String {
        guard let translated = translatedText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !translated.isEmpty else {
            return text
        }
        switch mode {
        case .originalOnly:
            return text
        case .translatedOnly:
            return translated
        case .bilingual:
            if translated == text || text.hasSuffix("\n" + translated) {
                return text
            }
            return "\(text)\n\(translated)"
        }
    }

    public var formattedTimeRange: String {
        "\(SRTFormatter.formatTimestamp(startTime)) --> \(SRTFormatter.formatTimestamp(endTime))"
    }

    public var shortTimeRange: String {
        "\(SRTFormatter.formatShortTimestamp(startTime)) – \(SRTFormatter.formatShortTimestamp(endTime))"
    }
}

public struct GemmaModelOption: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let shortName: String
    public let sizeDescription: String
    public let repoID: String

    public static let availableModels: [GemmaModelOption] = [
        GemmaModelOption(
            id: "gemma-4-e4b-ane",
            displayName: "Gemma 4 E4B (CoreML • ANE)",
            shortName: "Gemma 4 E4B (ANE)",
            sizeDescription: "~5.5 GB • Apple Neural Engine",
            repoID: "mlboydaisuke/gemma-4-E4B-coreml"
        ),
        GemmaModelOption(
            id: "gemma-4-e2b-ane",
            displayName: "Gemma 4 E2B (CoreML • ANE)",
            shortName: "Gemma 4 E2B (ANE)",
            sizeDescription: "~4.4 GB • Fast Apple Neural Engine",
            repoID: "mlboydaisuke/gemma-4-E2B-coreml"
        )
    ]

    public static let defaultModel = availableModels[0] // Gemma 4 E4B (CoreML • ANE)

    public static func resolve(_ query: String) -> GemmaModelOption? {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        if let exact = availableModels.first(where: {
            $0.id.lowercased() == normalized ||
            $0.repoID.lowercased() == normalized
        }) {
            return exact
        }
        if normalized.contains("e2b") {
            return availableModels.first { $0.id == "gemma-4-e2b-ane" }
        }
        if normalized.contains("e4b") || normalized.contains("ane") || normalized.contains("coreml") {
            return availableModels.first { $0.id == "gemma-4-e4b-ane" }
        }
        return nil
    }
}

public struct WhisperModelOption: Identifiable, Equatable, Hashable, Sendable {
    public let id: String          // WhisperKit model variant identifier
    public let displayName: String
    public let sizeDescription: String
    public let badge: String

    public static let availableModels: [WhisperModelOption] = [
        WhisperModelOption(
            id: "openai_whisper-tiny",
            displayName: "Whisper Tiny",
            sizeDescription: "~75 MB • Fastest",
            badge: "Fastest"
        ),
        WhisperModelOption(
            id: "openai_whisper-base",
            displayName: "Whisper Base",
            sizeDescription: "~145 MB • Balanced",
            badge: "Default"
        ),
        WhisperModelOption(
            id: "openai_whisper-small",
            displayName: "Whisper Small",
            sizeDescription: "~485 MB • High Accuracy",
            badge: "Accurate"
        ),
        WhisperModelOption(
            id: "openai_whisper-large-v3_turbo",
            displayName: "Whisper Large v3 Turbo",
            sizeDescription: "~950 MB • Studio Quality",
            badge: "Best"
        )
    ]

    public static let defaultModel = availableModels[1] // openai_whisper-base
}

public enum SRTFormatter {
    /// Formats a TimeInterval (seconds) into standard SRT timestamp `HH:MM:SS,mmm`.
    public static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        let totalMilliseconds = Int((clamped * 1000).rounded())
        let ms = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        let s = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let m = totalMinutes % 60
        let h = totalMinutes / 60
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    /// Formats a TimeInterval (seconds) into a compact `MM:SS.d` string for the UI list.
    public static func formatShortTimestamp(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        let totalTenths = Int((clamped * 10).rounded())
        let tenths = totalTenths % 10
        let totalSeconds = totalTenths / 10
        let s = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let m = totalMinutes % 60
        let h = totalMinutes / 60
        if h > 0 {
            return String(format: "%d:%02d:%02d.%d", h, m, s, tenths)
        } else {
            return String(format: "%02d:%02d.%d", m, s, tenths)
        }
    }

    /// Generates a complete `.srt` file string from an array of `SubtitleCue`s using the requested `SubtitleDisplayMode`.
    public static func format(cues: [SubtitleCue], displayMode: SubtitleDisplayMode = .translatedOnly) -> String {
        guard !cues.isEmpty else { return "" }
        return cues.enumerated().map { index, cue in
            let seq = index + 1
            let start = formatTimestamp(cue.startTime)
            let end = formatTimestamp(cue.endTime)
            let cleanText = cue.displayText(for: displayMode).trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(seq)\n\(start) --> \(end)\n\(cleanText)"
        }.joined(separator: "\n\n") + "\n"
    }

    /// Returns a copy of `cues` where each cue's `text` is resolved for the specified `SubtitleDisplayMode`.
    public static func resolvedCues(_ cues: [SubtitleCue], displayMode: SubtitleDisplayMode) -> [SubtitleCue] {
        cues.map { cue in
            SubtitleCue(
                id: cue.id,
                startTime: cue.startTime,
                endTime: cue.endTime,
                text: cue.displayText(for: displayMode),
                translatedText: nil
            )
        }
    }

    /// Parses a `.srt` file string into `[SubtitleCue]`.
    public static func parse(_ srtContent: String) -> [SubtitleCue] {
        let normalized = srtContent
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let blocks = normalized.components(separatedBy: "\n\n")
        var cues: [SubtitleCue] = []

        for block in blocks {
            let lines = block
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            guard lines.count >= 2 else { continue }

            // Find the line containing "-->"
            guard let timeLineIndex = lines.firstIndex(where: { $0.contains("-->") }) else {
                continue
            }

            let timeLine = lines[timeLineIndex]
            let parts = timeLine.components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = parseTimestamp(parts[0].trimmingCharacters(in: .whitespaces)),
                  let end = parseTimestamp(parts[1].trimmingCharacters(in: .whitespaces))
            else {
                continue
            }

            let textLines = lines.suffix(from: timeLineIndex + 1)
            let text = textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            cues.append(
                SubtitleCue(
                    id: cues.count + 1,
                    startTime: start,
                    endTime: end,
                    text: text
                )
            )
        }

        return cues
    }

    /// Parses `HH:MM:SS,mmm` or `HH:MM:SS.mmm` into seconds.
    public static func parseTimestamp(_ raw: String) -> TimeInterval? {
        // Strip any trailing SRT position metadata after space
        let token = raw.components(separatedBy: .whitespaces).first ?? raw
        let normalized = token.replacingOccurrences(of: ",", with: ".")
        let components = normalized.components(separatedBy: ":")
        guard components.count == 3,
              let hours = Double(components[0]),
              let minutes = Double(components[1]),
              let seconds = Double(components[2])
        else {
            return nil
        }
        return hours * 3600.0 + minutes * 60.0 + seconds
    }

    /// Parses flexible user-entered time strings (`HH:MM:SS[.mmm]`, `MM:SS[.mmm]`, or `SS[.mmm]`) into seconds.
    public static func parseFlexibleTimestamp(_ raw: String) -> TimeInterval? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        let components = normalized.components(separatedBy: ":")

        let result: TimeInterval
        switch components.count {
        case 1:
            guard let seconds = Double(components[0]) else { return nil }
            result = seconds
        case 2:
            guard let minutes = Double(components[0]),
                  let seconds = Double(components[1]),
                  minutes >= 0, seconds >= 0
            else { return nil }
            result = minutes * 60.0 + seconds
        case 3:
            guard let hours = Double(components[0]),
                  let minutes = Double(components[1]),
                  let seconds = Double(components[2]),
                  hours >= 0, minutes >= 0, seconds >= 0
            else { return nil }
            result = hours * 3600.0 + minutes * 60.0 + seconds
        default:
            return nil
        }

        guard result.isFinite, result >= 0 else { return nil }
        return result
    }

    /// Cleans Whisper special tokens (such as `<|startoftranscript|>`, `<|0.00|>`, etc.) from segment text.
    public static func cleanWhisperText(_ raw: String) -> String {
        var result = raw
        if let regex = try? NSRegularExpression(pattern: "<\\|[^>]*\\|>", options: []) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
