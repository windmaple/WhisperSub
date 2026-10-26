import Foundation
import NaturalLanguage

public struct SubtitleWordTiming: Codable, Equatable, Hashable, Sendable {
    public var word: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval

    public init(word: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.word = word
        self.startTime = max(0, startTime)
        self.endTime = max(self.startTime + 0.02, endTime)
    }
}

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
    public var wordTimings: [SubtitleWordTiming]?
    /// Optional full-phrase original text used to keep the on-screen subtitle box width and layout static during word-by-word reveal.
    public var fullLayoutText: String?
    /// Optional full-phrase translated text used to keep the on-screen subtitle box width and layout static during word-by-word reveal.
    public var fullLayoutTranslatedText: String?

    public init(
        id: Int,
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        translatedText: String? = nil,
        preReviewTranslatedText: String? = nil,
        isReviewedByGemma: Bool = false,
        wordTimings: [SubtitleWordTiming]? = nil,
        fullLayoutText: String? = nil,
        fullLayoutTranslatedText: String? = nil
    ) {
        self.id = id
        self.startTime = max(0, startTime)
        self.endTime = max(self.startTime + 0.04, endTime)
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTranslation = translatedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.translatedText = (trimmedTranslation?.isEmpty == false) ? trimmedTranslation : nil
        let trimmedPreReview = preReviewTranslatedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.preReviewTranslatedText = (trimmedPreReview?.isEmpty == false) ? trimmedPreReview : nil
        self.isReviewedByGemma = isReviewedByGemma
        self.wordTimings = (wordTimings?.isEmpty == false) ? wordTimings : nil
        let trimmedFullOrig = fullLayoutText?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fullLayoutText = (trimmedFullOrig?.isEmpty == false) ? trimmedFullOrig : nil
        let trimmedFullTrans = fullLayoutTranslatedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fullLayoutTranslatedText = (trimmedFullTrans?.isEmpty == false) ? trimmedFullTrans : nil
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

    public func fullLayoutDisplayText(for mode: SubtitleDisplayMode) -> String {
        let baseOrig = (fullLayoutText ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseTrans = (fullLayoutTranslatedText ?? translatedText)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !baseTrans.isEmpty else {
            return baseOrig
        }
        switch mode {
        case .originalOnly:
            return baseOrig
        case .translatedOnly:
            return baseTrans
        case .bilingual:
            if baseTrans == baseOrig || baseOrig.hasSuffix("\n" + baseTrans) {
                return baseOrig
            }
            return "\(baseOrig)\n\(baseTrans)"
        }
    }

    public var formattedTimeRange: String {
        "\(SRTFormatter.formatTimestamp(startTime)) --> \(SRTFormatter.formatTimestamp(endTime))"
    }

    public var shortTimeRange: String {
        "\(SRTFormatter.formatShortTimestamp(startTime)) – \(SRTFormatter.formatShortTimestamp(endTime))"
    }

    // MARK: - Word-by-Word Voice Alignment & Progressive Reveal

    /// Resolved word-level timings for `text` (original language).
    /// Uses Whisper DTW cross-attention `wordTimings` when they match `text`, or synthesizes voice-aligned word timings anchored to `wordTimings`.
    public var resolvedOriginalWordTimings: [SubtitleWordTiming] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let stored = wordTimings, !stored.isEmpty {
            let joinedStored = stored.map(\.word).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.normalizedComparisonString(joinedStored) == Self.normalizedComparisonString(trimmed) {
                return Self.normalizeWordTimings(stored, cueStart: startTime, cueEnd: endTime)
            }
            return Self.synthesizeWordTimings(
                for: trimmed,
                startTime: startTime,
                endTime: endTime,
                referenceTimings: Self.normalizeWordTimings(stored, cueStart: startTime, cueEnd: endTime)
            )
        }

        return Self.synthesizeWordTimings(
            for: trimmed,
            startTime: startTime,
            endTime: endTime,
            referenceTimings: nil
        )
    }

    /// Resolved word-level timings for `translatedText`, mapped onto the spoken voice cadence of `resolvedOriginalWordTimings`.
    public var resolvedTranslatedWordTimings: [SubtitleWordTiming]? {
        guard let translated = translatedText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !translated.isEmpty else {
            return nil
        }
        let origTimings = resolvedOriginalWordTimings
        return Self.synthesizeWordTimings(
            for: translated,
            startTime: startTime,
            endTime: endTime,
            referenceTimings: origTimings
        )
    }

    /// Returns the index of the currently active word in `resolvedOriginalWordTimings` at `timeSeconds`.
    public func activeOriginalWordIndex(at timeSeconds: TimeInterval) -> Int? {
        let words = resolvedOriginalWordTimings
        guard !words.isEmpty else { return nil }
        var activeIdx = 0
        for (idx, w) in words.enumerated() {
            if timeSeconds + 0.008 >= w.startTime {
                activeIdx = idx
            } else {
                break
            }
        }
        return activeIdx
    }

    /// Returns the cumulative original text spoken up to `timeSeconds` (at least the first word once the cue starts).
    public func progressiveOriginalText(at timeSeconds: TimeInterval) -> String {
        let words = resolvedOriginalWordTimings
        guard !words.isEmpty else { return text }
        let count = visibleWordCount(in: words, at: timeSeconds)
        return words.prefix(count).map(\.word).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns the cumulative translated text spoken up to `timeSeconds` (at least the first word once the cue starts).
    public func progressiveTranslatedText(at timeSeconds: TimeInterval) -> String? {
        guard let transWords = resolvedTranslatedWordTimings, !transWords.isEmpty else {
            return translatedText
        }
        let count = visibleWordCount(in: transWords, at: timeSeconds)
        return transWords.prefix(count).map(\.word).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns the progressive display string at `timeSeconds` for the specified `SubtitleDisplayMode`.
    public func progressiveDisplayText(at timeSeconds: TimeInterval, for mode: SubtitleDisplayMode) -> String {
        let progOrig = progressiveOriginalText(at: timeSeconds)
        guard let progTrans = progressiveTranslatedText(at: timeSeconds)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !progTrans.isEmpty else {
            return progOrig
        }
        switch mode {
        case .originalOnly:
            return progOrig
        case .translatedOnly:
            return progTrans
        case .bilingual:
            if progTrans == progOrig || progOrig.hasSuffix("\n" + progTrans) {
                return progOrig
            }
            return "\(progOrig)\n\(progTrans)"
        }
    }

    private func visibleWordCount(in words: [SubtitleWordTiming], at timeSeconds: TimeInterval) -> Int {
        guard !words.isEmpty else { return 0 }
        var count = 1
        for (idx, w) in words.enumerated() {
            if timeSeconds + 0.008 >= w.startTime {
                count = idx + 1
            } else {
                break
            }
        }
        return min(words.count, max(1, count))
    }

    private static func normalizedComparisonString(_ str: String) -> String {
        str.components(separatedBy: .whitespacesAndNewlines).joined().lowercased()
    }

    /// Normalizes a sequence of word timings so timestamps are monotonically increasing within `[cueStart, cueEnd]`
    /// and any simultaneous DTW tokens are smoothly spaced across their active span.
    public static func normalizeWordTimings(
        _ timings: [SubtitleWordTiming],
        cueStart: TimeInterval,
        cueEnd: TimeInterval
    ) -> [SubtitleWordTiming] {
        guard !timings.isEmpty else { return [] }
        let safeStart = max(0, cueStart)
        let safeEnd = max(safeStart + 0.04, cueEnd)
        let count = timings.count

        if count == 1 {
            return [SubtitleWordTiming(word: timings[0].word, startTime: safeStart, endTime: safeEnd)]
        }

        var starts = timings.map { min(safeEnd, max(safeStart, $0.startTime)) }
        var ends = timings.map { min(safeEnd, max(safeStart, $0.endTime)) }
        starts[0] = safeStart
        ends[count - 1] = max(ends[count - 1], safeEnd)

        // Ensure non-decreasing start times
        for i in 1..<count {
            if starts[i] < starts[i - 1] {
                starts[i] = starts[i - 1]
            }
        }

        // Smooth out runs of words that received identical or near-identical (< 0.035s) start timestamps from DTW
        let minStep: TimeInterval = min(0.04, (safeEnd - safeStart) / Double(max(1, count)))
        var idx = 0
        while idx < count {
            var runEndIdx = idx
            while runEndIdx + 1 < count && (starts[runEndIdx + 1] - starts[runEndIdx]) < minStep * 0.85 {
                runEndIdx += 1
            }
            if runEndIdx > idx {
                let runStart = starts[idx]
                let rawLimit = (runEndIdx + 1 < count) ? starts[runEndIdx + 1] : safeEnd
                let maxEndInRun = ends[idx...runEndIdx].max() ?? runStart
                let spanEnd = min(safeEnd, max(rawLimit, maxEndInRun, runStart + minStep * Double(runEndIdx - idx + 1)))
                let runSlice = Array(timings[idx...runEndIdx])
                let weights = runSlice.map { speakingWeight(for: $0.word) }
                let totalWeight = max(0.01, weights.reduce(0, +))
                var accum = 0.0
                for offset in 0..<runSlice.count {
                    starts[idx + offset] = runStart + (spanEnd - runStart) * (accum / totalWeight)
                    accum += weights[offset]
                }
            }
            idx = runEndIdx + 1
        }

        // Final forward/backward clamp so every word has a distinct startTime in [safeStart, safeEnd)
        starts[0] = safeStart
        for i in (0..<(count - 1)).reversed() {
            let latestAllowed = safeEnd - minStep * Double(count - i)
            if starts[i] > latestAllowed {
                starts[i] = max(safeStart, latestAllowed)
            }
        }
        for i in 1..<count {
            if starts[i] < starts[i - 1] + minStep * 0.9 {
                starts[i] = min(safeEnd - minStep * 0.5, starts[i - 1] + minStep * 0.9)
            }
        }

        var result: [SubtitleWordTiming] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let wStart = starts[i]
            let nextStart = (i + 1 < count) ? starts[i + 1] : safeEnd
            let wEnd = min(nextStart, max(wStart + 0.02, ends[i]))
            result.append(SubtitleWordTiming(word: timings[i].word, startTime: wStart, endTime: max(wStart + 0.02, wEnd)))
        }
        return result
    }

    /// Partitions `rawText` into natural word/morpheme slices whose concatenation equals `rawText` (trimmed).
    /// Preserves leading spaces on subsequent words and attaches trailing punctuation to its word.
    public static func partitionIntoWordSlices(_ rawText: String) -> [String] {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = trimmed

        var rawRanges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
            rawRanges.append(range)
            return true
        }

        guard !rawRanges.isEmpty else {
            return [trimmed]
        }

        // Merge contractions and hyphenated compounds (e.g. "don't", "we're", "word-by-word") into single words
        let joiners = CharacterSet(charactersIn: "'’`-")
        var mergedRanges: [Range<String.Index>] = [rawRanges[0]]
        for range in rawRanges.dropFirst() {
            let prev = mergedRanges[mergedRanges.count - 1]
            let gap = trimmed[prev.upperBound..<range.lowerBound]
            if !gap.isEmpty && gap.unicodeScalars.allSatisfy({ joiners.contains($0) }) {
                mergedRanges[mergedRanges.count - 1] = prev.lowerBound..<range.upperBound
            } else {
                mergedRanges.append(range)
            }
        }

        let openingChars = CharacterSet(charactersIn: "([{\u{201C}\u{2018}「『《【（")
        var slices: [String] = []
        slices.reserveCapacity(mergedRanges.count)

        var sliceStart = trimmed.startIndex
        for i in 0..<mergedRanges.count {
            let sliceEnd: String.Index
            if i == mergedRanges.count - 1 {
                sliceEnd = trimmed.endIndex
            } else {
                let nextWordStart = mergedRanges[i + 1].lowerBound
                var cursor = mergedRanges[i].upperBound
                while cursor < nextWordStart {
                    let scalar = trimmed.unicodeScalars[cursor]
                    if CharacterSet.whitespacesAndNewlines.contains(scalar) || openingChars.contains(scalar) {
                        break
                    }
                    cursor = trimmed.index(after: cursor)
                }
                sliceEnd = cursor
            }
            let slice = String(trimmed[sliceStart..<sliceEnd])
            if !slice.isEmpty {
                slices.append(slice)
            }
            sliceStart = sliceEnd
        }

        return slices.isEmpty ? [trimmed] : slices
    }

    private static func speakingWeight(for wordSlice: String) -> Double {
        let trimmed = wordSlice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 1.0 }
        var charWeight = 0.0
        for scalar in trimmed.unicodeScalars {
            if (0x4E00...0x9FFF).contains(scalar.value) ||
               (0x3400...0x4DBF).contains(scalar.value) ||
               (0x3040...0x30FF).contains(scalar.value) ||
               (0xAC00...0xD7AF).contains(scalar.value) {
                charWeight += 2.2
            } else if CharacterSet.alphanumerics.contains(scalar) {
                charWeight += 0.45
            }
        }
        var weight = max(0.8, 1.0 + charWeight)
        if let last = trimmed.last, ",.;:!?，。；：！？、…".contains(last) {
            weight += 0.7
        }
        return weight
    }

    /// Synthesizes `[SubtitleWordTiming]` for `rawText` across `[startTime, endTime]`,
    /// optionally following the spoken voice cadence and pauses of `referenceTimings`.
    public static func synthesizeWordTimings(
        for rawText: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        referenceTimings: [SubtitleWordTiming]? = nil
    ) -> [SubtitleWordTiming] {
        let slices = partitionIntoWordSlices(rawText)
        let safeStart = max(0, startTime)
        let safeEnd = max(safeStart + 0.04, endTime)
        guard !slices.isEmpty else { return [] }

        if slices.count == 1 {
            return [SubtitleWordTiming(word: slices[0], startTime: safeStart, endTime: safeEnd)]
        }

        // If referenceTimings has the exact same word count, map 1-to-1 directly onto the reference word timings
        if let ref = referenceTimings, ref.count == slices.count {
            let normalizedRef = normalizeWordTimings(ref, cueStart: safeStart, cueEnd: safeEnd)
            return zip(slices, normalizedRef).map { slice, timing in
                SubtitleWordTiming(word: slice, startTime: timing.startTime, endTime: timing.endTime)
            }
        }

        let weights = slices.map { speakingWeight(for: $0) }
        let totalWeight = max(0.01, weights.reduce(0, +))

        func mapProgressToTime(_ progress: Double) -> TimeInterval {
            let clamped = min(1.0, max(0.0, progress))
            guard let ref = referenceTimings, ref.count >= 2 else {
                return safeStart + clamped * (safeEnd - safeStart)
            }
            if clamped <= 0.0001 { return ref[0].startTime }
            if clamped >= 0.9999 { return max(ref[ref.count - 1].endTime, safeEnd) }

            let scaled = clamped * Double(ref.count)
            let idx = min(ref.count - 1, max(0, Int(floor(scaled))))
            let frac = scaled - Double(idx)
            let wStart = ref[idx].startTime
            let wEnd = max(wStart + 0.02, ref[idx].endTime)
            return wStart + frac * (wEnd - wStart)
        }

        var accum = 0.0
        var rawTimings: [SubtitleWordTiming] = []
        rawTimings.reserveCapacity(slices.count)

        for slice in slices {
            let wWeight = speakingWeight(for: slice)
            let pStart = accum / totalWeight
            accum += wWeight
            let pEnd = accum / totalWeight
            let tStart = mapProgressToTime(pStart)
            let tEnd = mapProgressToTime(pEnd)
            rawTimings.append(SubtitleWordTiming(word: slice, startTime: tStart, endTime: max(tStart + 0.02, tEnd)))
        }

        return normalizeWordTimings(rawTimings, cueStart: safeStart, cueEnd: safeEnd)
    }

    /// Expands an array of phrase `SubtitleCue`s into progressive word-by-word `SubtitleCue` steps
    /// so video subtitle burning and `.SRT` export reveal words one by one in lockstep with the voice.
    public static func expandedWordByWordCues(
        from cues: [SubtitleCue],
        displayMode: SubtitleDisplayMode
    ) -> [SubtitleCue] {
        guard !cues.isEmpty else { return [] }
        var expanded: [SubtitleCue] = []
        let minStepDuration: TimeInterval = 0.04

        for cue in cues {
            let origWords = cue.resolvedOriginalWordTimings
            let transWords = cue.resolvedTranslatedWordTimings

            // Collect candidate transition timestamps according to the active display mode
            var candidateTimes: [TimeInterval] = [cue.startTime]
            switch displayMode {
            case .originalOnly:
                candidateTimes.append(contentsOf: origWords.map(\.startTime))
            case .translatedOnly:
                if let transWords, !transWords.isEmpty {
                    candidateTimes.append(contentsOf: transWords.map(\.startTime))
                } else {
                    candidateTimes.append(contentsOf: origWords.map(\.startTime))
                }
            case .bilingual:
                candidateTimes.append(contentsOf: origWords.map(\.startTime))
                if let transWords, !transWords.isEmpty {
                    candidateTimes.append(contentsOf: transWords.map(\.startTime))
                }
            }

            let sortedTimes = candidateTimes
                .map { min(cue.endTime, max(cue.startTime, $0)) }
                .sorted()

            // Coalesce transition timestamps that are within 42ms of each other
            var distinctStarts: [TimeInterval] = []
            for t in sortedTimes {
                if t >= cue.endTime - minStepDuration * 0.5 {
                    continue
                }
                if let last = distinctStarts.last {
                    if t - last >= minStepDuration {
                        distinctStarts.append(t)
                    }
                } else {
                    distinctStarts.append(t)
                }
            }
            if distinctStarts.isEmpty {
                distinctStarts = [cue.startTime]
            }

            var cueSteps: [SubtitleCue] = []
            for idx in 0..<distinctStarts.count {
                let stepStart = distinctStarts[idx]
                let stepEnd = (idx + 1 < distinctStarts.count) ? distinctStarts[idx + 1] : cue.endTime
                guard stepEnd > stepStart + 0.01 else { continue }

                let probeTime = stepStart + 0.01
                let progOrig = cue.progressiveOriginalText(at: probeTime)
                let progTrans = cue.progressiveTranslatedText(at: probeTime)

                if let lastStep = cueSteps.last,
                   lastStep.text == progOrig,
                   lastStep.translatedText == progTrans {
                    cueSteps[cueSteps.count - 1].endTime = stepEnd
                } else {
                    cueSteps.append(
                        SubtitleCue(
                            id: expanded.count + cueSteps.count + 1,
                            startTime: stepStart,
                            endTime: stepEnd,
                            text: progOrig,
                            translatedText: progTrans,
                            preReviewTranslatedText: nil,
                            isReviewedByGemma: cue.isReviewedByGemma,
                            wordTimings: nil,
                            fullLayoutText: cue.text,
                            fullLayoutTranslatedText: cue.translatedText
                        )
                    )
                }
            }

            if cueSteps.isEmpty {
                expanded.append(
                    SubtitleCue(
                        id: expanded.count + 1,
                        startTime: cue.startTime,
                        endTime: cue.endTime,
                        text: cue.text,
                        translatedText: cue.translatedText,
                        preReviewTranslatedText: cue.preReviewTranslatedText,
                        isReviewedByGemma: cue.isReviewedByGemma,
                        wordTimings: nil,
                        fullLayoutText: cue.text,
                        fullLayoutTranslatedText: cue.translatedText
                    )
                )
            } else {
                expanded.append(contentsOf: cueSteps)
            }
        }

        for i in expanded.indices {
            expanded[i] = SubtitleCue(
                id: i + 1,
                startTime: expanded[i].startTime,
                endTime: expanded[i].endTime,
                text: expanded[i].text,
                translatedText: expanded[i].translatedText,
                preReviewTranslatedText: expanded[i].preReviewTranslatedText,
                isReviewedByGemma: expanded[i].isReviewedByGemma,
                wordTimings: nil,
                fullLayoutText: expanded[i].fullLayoutText,
                fullLayoutTranslatedText: expanded[i].fullLayoutTranslatedText
            )
        }
        return expanded
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
    public static func format(
        cues: [SubtitleCue],
        displayMode: SubtitleDisplayMode = .translatedOnly,
        wordByWord: Bool = false
    ) -> String {
        guard !cues.isEmpty else { return "" }
        let targetCues = wordByWord ? SubtitleCue.expandedWordByWordCues(from: cues, displayMode: displayMode) : cues
        return targetCues.enumerated().map { index, cue in
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
                translatedText: nil,
                wordTimings: cue.wordTimings
            )
        }
    }

    /// Collapses cumulative word-by-word `.srt` cues (where consecutive contiguous blocks are growing prefixes of the same line)
    /// back into phrase `SubtitleCue`s while reconstructing their `wordTimings`.
    public static func collapseWordByWordCues(_ rawCues: [SubtitleCue]) -> [SubtitleCue] {
        guard rawCues.count >= 2 else { return rawCues }

        func isCumulativeExtension(prev: String, next: String) -> Bool {
            let pLines = prev.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            let nLines = next.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            guard pLines.count == nLines.count, !pLines.isEmpty else { return false }
            var anyStrictExtension = false
            for (p, n) in zip(pLines, nLines) {
                guard !p.isEmpty, n.hasPrefix(p) else { return false }
                if n.count > p.count {
                    anyStrictExtension = true
                }
            }
            return anyStrictExtension
        }

        // Check if the input actually contains cumulative sequences before collapsing
        var cumulativePairs = 0
        for i in 0..<(rawCues.count - 1) {
            let gap = abs(rawCues[i + 1].startTime - rawCues[i].endTime)
            if gap <= 0.06 && isCumulativeExtension(prev: rawCues[i].text, next: rawCues[i + 1].text) {
                cumulativePairs += 1
            }
        }
        guard cumulativePairs > 0 else { return rawCues }

        var collapsed: [SubtitleCue] = []
        var i = 0
        while i < rawCues.count {
            var group: [SubtitleCue] = [rawCues[i]]
            while i + 1 < rawCues.count {
                let curr = group[group.count - 1]
                let next = rawCues[i + 1]
                let gap = abs(next.startTime - curr.endTime)
                if gap <= 0.06 && isCumulativeExtension(prev: curr.text, next: next.text) {
                    group.append(next)
                    i += 1
                } else {
                    break
                }
            }

            if group.count == 1 {
                var single = group[0]
                single = SubtitleCue(
                    id: collapsed.count + 1,
                    startTime: single.startTime,
                    endTime: single.endTime,
                    text: single.text,
                    translatedText: single.translatedText,
                    preReviewTranslatedText: single.preReviewTranslatedText,
                    isReviewedByGemma: single.isReviewedByGemma,
                    wordTimings: single.wordTimings
                )
                collapsed.append(single)
            } else {
                let first = group[0]
                let last = group[group.count - 1]
                var extractedTimings: [SubtitleWordTiming] = []
                var prevFirstLine = ""
                for step in group {
                    let firstLine = step.text.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? step.text
                    if firstLine.hasPrefix(prevFirstLine) {
                        let delta = String(firstLine.dropFirst(prevFirstLine.count))
                        if !delta.isEmpty {
                            extractedTimings.append(
                                SubtitleWordTiming(word: delta, startTime: step.startTime, endTime: step.endTime)
                            )
                        } else if !extractedTimings.isEmpty {
                            extractedTimings[extractedTimings.count - 1].endTime = step.endTime
                        }
                    }
                    prevFirstLine = firstLine
                }

                collapsed.append(
                    SubtitleCue(
                        id: collapsed.count + 1,
                        startTime: first.startTime,
                        endTime: last.endTime,
                        text: last.text,
                        translatedText: last.translatedText,
                        preReviewTranslatedText: last.preReviewTranslatedText,
                        isReviewedByGemma: last.isReviewedByGemma,
                        wordTimings: extractedTimings.isEmpty ? nil : extractedTimings
                    )
                )
            }
            i += 1
        }
        return collapsed
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
