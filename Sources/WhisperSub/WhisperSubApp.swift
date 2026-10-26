import SwiftUI
import AppKit
import AVFoundation

@main
struct WhisperSubMain {
    static func main() {
        let args = CommandLine.arguments
        if let cliIndex = args.firstIndex(of: "--cli") {
            let cliArgs = Array(args.suffix(from: cliIndex + 1))
            Task { @MainActor in
                await runCLIMode(args: cliArgs)
                exit(0)
            }
            RunLoop.main.run()
            return
        }

        NSApplication.shared.setActivationPolicy(.regular)
        WhisperSubGUIApp.main()
    }

    @MainActor
    private static func runCLIMode(args: [String]) async {
        guard let inputPath = args.first else {
            fputs("Usage: WhisperSub --cli <input-video> [--start <time>] [--end <time>] [--shorts|--aspect 9:16] [--crop-focus <0..1>] [--clip-out <clip.mp4>] [--translate <lang>] [--bilingual] [--word-by-word|--no-word-by-word] [--whisper-translate] [--gemma-review] [--gemma-model <e4b|e2b>] [--gemma-prompt <notes>] [--srt <out.srt>] [--burn <out.mp4>] [--burn-only] [--model <model_id>]\n", stderr)
            exit(1)
        }

        let inputURL = URL(fileURLWithPath: inputPath)
        var srtOutURL = inputURL.deletingPathExtension().appendingPathExtension("srt")
        var explicitSRT = false
        var burnOutURL: URL?
        var clipOutURL: URL?
        var clipStartArg: String?
        var clipEndArg: String?
        var aspectRatioMode: VideoAspectRatioMode = .original
        var horizontalFocus: Double = 0.5
        var translateLangArg: String?
        var bilingualMode = false
        var wordByWord = true
        var whisperDirectTranslate = false
        var gemmaReviewEnabled = false
        var gemmaModelOption = GemmaModelOption.defaultModel
        var gemmaCustomPrompt = ""
        var modelOption = WhisperModelOption.defaultModel
        var burnOnly = false

        var i = 1
        while i < args.count {
            switch args[i] {
            case "--start":
                if i + 1 < args.count {
                    clipStartArg = args[i + 1]
                    i += 1
                }
            case "--end":
                if i + 1 < args.count {
                    clipEndArg = args[i + 1]
                    i += 1
                }
            case "--shorts", "--9:16", "--vertical":
                aspectRatioMode = .vertical9x16
            case "--aspect":
                if i + 1 < args.count {
                    let val = args[i + 1].lowercased()
                    if val.contains("9:16") || val.contains("9x16") || val.contains("short") || val.contains("vertical") {
                        aspectRatioMode = .vertical9x16
                    } else {
                        aspectRatioMode = .original
                    }
                    i += 1
                }
            case "--crop-focus":
                if i + 1 < args.count, let parsed = Double(args[i + 1]) {
                    horizontalFocus = min(1.0, max(0.0, parsed))
                    i += 1
                }
            case "--clip-out":
                if i + 1 < args.count {
                    clipOutURL = URL(fileURLWithPath: args[i + 1])
                    i += 1
                }
            case "--translate":
                if i + 1 < args.count {
                    translateLangArg = args[i + 1]
                    i += 1
                }
            case "--bilingual":
                bilingualMode = true
            case "--word-by-word":
                wordByWord = true
            case "--no-word-by-word", "--full-line":
                wordByWord = false
            case "--whisper-translate":
                whisperDirectTranslate = true
            case "--gemma-review":
                gemmaReviewEnabled = true
            case "--gemma-model":
                gemmaReviewEnabled = true
                if i + 1 < args.count {
                    if let resolved = GemmaModelOption.resolve(args[i + 1]) {
                        gemmaModelOption = resolved
                    }
                    i += 1
                }
            case "--gemma-prompt":
                gemmaReviewEnabled = true
                if i + 1 < args.count {
                    gemmaCustomPrompt = args[i + 1]
                    i += 1
                }
            case "--srt":
                if i + 1 < args.count {
                    srtOutURL = URL(fileURLWithPath: args[i + 1])
                    explicitSRT = true
                    i += 1
                }
            case "--burn":
                if i + 1 < args.count {
                    burnOutURL = URL(fileURLWithPath: args[i + 1])
                    i += 1
                }
            case "--burn-only":
                burnOnly = true
            case "--model":
                if i + 1 < args.count {
                    let requested = args[i + 1]
                    if let match = WhisperModelOption.availableModels.first(where: { $0.id == requested || $0.id.hasSuffix(requested) }) {
                        modelOption = match
                    }
                    i += 1
                }
            default:
                break
            }
            i += 1
        }

        let displayMode: SubtitleDisplayMode = bilingualMode ? .bilingual : .translatedOnly

        do {
            print("🎬 Inspecting video: \(inputURL.path)")
            let meta = try await VideoSubtitleBurner.inspectVideo(url: inputURL)
            print("   Resolution: \(meta.formattedResolution), Duration: \(meta.formattedDuration)")

            var activeVideoURL = inputURL
            if clipStartArg != nil || clipEndArg != nil || clipOutURL != nil || (aspectRatioMode != .original && burnOutURL == nil) {
                let startSec: TimeInterval
                if let rawStart = clipStartArg {
                    guard let parsed = SRTFormatter.parseFlexibleTimestamp(rawStart) else {
                        throw VideoSubtitleBurnerError.invalidClipRange("Could not parse --start time \"\(rawStart)\".")
                    }
                    startSec = parsed
                } else {
                    startSec = 0.0
                }

                let endSec: TimeInterval
                if let rawEnd = clipEndArg {
                    guard let parsed = SRTFormatter.parseFlexibleTimestamp(rawEnd) else {
                        throw VideoSubtitleBurnerError.invalidClipRange("Could not parse --end time \"\(rawEnd)\".")
                    }
                    endSec = min(parsed, meta.duration)
                } else {
                    endSec = meta.duration
                }

                let defaultSuffix = aspectRatioMode == .vertical9x16 ? "_shorts.mp4" : "_clipped.mp4"
                let targetClipURL = clipOutURL
                    ?? inputURL.deletingLastPathComponent().appendingPathComponent("\(inputURL.deletingPathExtension().lastPathComponent)\(defaultSuffix)")

                let aspectNote = aspectRatioMode == .vertical9x16 ? " (9:16 Shorts)" : ""
                print("✂️ Cutting video from \(SRTFormatter.formatShortTimestamp(startSec)) to \(SRTFormatter.formatShortTimestamp(endSec))\(aspectNote) -> \(targetClipURL.path)")
                try await VideoSubtitleBurner.clipVideo(
                    sourceURL: inputURL,
                    outputURL: targetClipURL,
                    startTime: startSec,
                    endTime: endSec,
                    aspectRatioMode: aspectRatioMode,
                    horizontalFocus: horizontalFocus
                )
                activeVideoURL = targetClipURL
                let clippedMeta = try await VideoSubtitleBurner.inspectVideo(url: activeVideoURL)
                print("✅ Cut video: \(clippedMeta.formattedResolution), duration: \(clippedMeta.formattedDuration)")
            }

            var cues: [SubtitleCue]
            if burnOnly, FileManager.default.fileExists(atPath: srtOutURL.path) {
                let raw = try String(contentsOf: srtOutURL, encoding: .utf8)
                cues = SRTFormatter.collapseWordByWordCues(SRTFormatter.parse(raw))
                print("📝 Loaded \(cues.count) existing subtitle segment(s) from: \(srtOutURL.path)")
            } else {
                let service = WhisperTranscriptionService()
                let directAudioTranslate = whisperDirectTranslate && !bilingualMode && (translateLangArg == nil || translateLangArg?.lowercased() == "en")
                if directAudioTranslate {
                    print("🧠 Translating speech-to-English on Apple Neural Engine using \(modelOption.displayName) (\(modelOption.id))...")
                } else {
                    print("🧠 Transcribing on Apple Neural Engine using \(modelOption.displayName) (\(modelOption.id))...")
                }
                cues = try await service.transcribeVideo(
                    videoURL: activeVideoURL,
                    modelOption: modelOption,
                    translateToEnglish: directAudioTranslate
                )
                print("✅ Transcribed \(cues.count) subtitle segment(s).")
            }

            let effectiveTranslateLang = translateLangArg ?? (gemmaReviewEnabled ? TranslationLanguage.defaultLanguage.id : nil)
            if let rawLang = effectiveTranslateLang {
                let targetLang = TranslationLanguage.resolve(rawLang)
                    ?? TranslationLanguage(id: rawLang, displayName: rawLang, nativeName: rawLang)
                let directAudioTranslate = whisperDirectTranslate && !bilingualMode && targetLang.id.lowercased() == "en" && !burnOnly
                if !directAudioTranslate {
                    print("🌐 Translating \(cues.count) subtitle segment(s) to \(targetLang.fullDisplayName) (\(displayMode.compactLabel))...")
                    let translator = SubtitleTranslationService()
                    cues = try await translator.translateCues(cues, to: targetLang)
                    print("✅ Translated \(cues.count) subtitle segment(s) to \(targetLang.displayName).")
                }

                if gemmaReviewEnabled {
                    print("✨ Reviewing & revising \(cues.count) subtitle translation(s) with \(gemmaModelOption.displayName)...")
                    let reviewer = GemmaReviewService()
                    let reviewResult = try await reviewer.reviewAndReviseCues(
                        cues,
                        targetLanguage: targetLang,
                        modelOption: gemmaModelOption,
                        customInstructions: gemmaCustomPrompt
                    )
                    cues = reviewResult.cues
                    print("✅ \(gemmaModelOption.shortName) reviewed \(cues.count) cues and revised \(reviewResult.revisedCount) segment(s).")
                }

                if !explicitSRT && !burnOnly {
                    let base = inputURL.deletingPathExtension()
                    let suffix = bilingualMode ? "bilingual_\(targetLang.id)" : targetLang.id
                    srtOutURL = base.deletingLastPathComponent().appendingPathComponent("\(base.lastPathComponent)_\(suffix).srt")
                }
            }

            if !burnOnly || effectiveTranslateLang != nil {
                let srtContent = SRTFormatter.format(cues: cues, displayMode: displayMode, wordByWord: wordByWord)
                try srtContent.write(to: srtOutURL, atomically: true, encoding: .utf8)
                print("📝 Saved .SRT file (\(displayMode.compactLabel)\(wordByWord ? ", word-by-word" : "")) to: \(srtOutURL.path)")
            }

            if let burnURL = burnOutURL {
                let aspectNote = aspectRatioMode == .vertical9x16 ? ", 9:16 Shorts" : ""
                print("🔥 Burning subtitles (\(displayMode.compactLabel)\(wordByWord ? ", word-by-word" : "")\(aspectNote)) into video: \(burnURL.path)")
                try await VideoSubtitleBurner.burnSubtitles(
                    sourceURL: activeVideoURL,
                    outputURL: burnURL,
                    cues: cues,
                    displayMode: displayMode,
                    wordByWord: wordByWord,
                    aspectRatioMode: aspectRatioMode,
                    horizontalFocus: horizontalFocus,
                    progressHandler: { _ in }
                )
                print("✅ Exported burned video to: \(burnURL.path)")
            }
        } catch {
            fputs("❌ Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

struct WhisperSubGUIApp: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup("WhisperSub — Neural Engine Video Subtitler") {
            ContentView(viewModel: viewModel)
                .onAppear {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    let args = Array(CommandLine.arguments.dropFirst())
                    if let firstPath = args.first(where: { !$0.hasPrefix("-") }),
                       FileManager.default.fileExists(atPath: firstPath) {
                        let url = URL(fileURLWithPath: firstPath)
                        viewModel.loadVideo(url: url)
                        if let burnedPath = args.dropFirst().first(where: { !$0.hasPrefix("-") && $0.hasSuffix(".mp4") }),
                           FileManager.default.fileExists(atPath: burnedPath) {
                            let burnedURL = URL(fileURLWithPath: burnedPath)
                            viewModel.attachBurnedPreviewPlayer(url: burnedURL)
                        }
                        if args.contains("--auto-transcribe") {
                            viewModel.transcribeCurrentVideo()
                        }
                    }
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 980, height: 660)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Video…") {
                    viewModel.openVideoPicker()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Load .SRT File…") {
                    viewModel.importSRTFile()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Divider()

                Button("Clip Video to Start–End Range") {
                    viewModel.clipCurrentVideo()
                }
                .keyboardShortcut("k", modifiers: [.command])
                .disabled(viewModel.videoURL == nil || viewModel.isBusy || !viewModel.hasUnappliedClipChanges)

                Button("Transcribe Video") {
                    viewModel.transcribeCurrentVideo()
                }
                .keyboardShortcut("t", modifiers: [.command])
                .disabled(viewModel.videoURL == nil || viewModel.isBusy)

                Button("Translate Subtitles") {
                    viewModel.translateCurrentSubtitles()
                }
                .keyboardShortcut("l", modifiers: [.command])
                .disabled(viewModel.cues.isEmpty || viewModel.isBusy)

                Button("Review & Revise with Gemma 4") {
                    viewModel.reviewSubtitlesWithGemma()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(viewModel.cues.isEmpty || viewModel.isBusy)

                Button("Save .SRT File…") {
                    viewModel.saveSRTFile()
                }
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(viewModel.cues.isEmpty || viewModel.isBusy)

                Button("Burn Subtitles into Video…") {
                    viewModel.burnSubtitlesIntoVideo()
                }
                .keyboardShortcut("b", modifiers: [.command])
                .disabled(viewModel.videoURL == nil || viewModel.cues.isEmpty || viewModel.isBusy)
            }
        }
    }
}
