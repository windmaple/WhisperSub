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
            fputs("Usage: WhisperSub --cli <input-video> [--srt <out.srt>] [--burn <out.mp4>] [--burn-only] [--model <model_id>]\n", stderr)
            exit(1)
        }

        let inputURL = URL(fileURLWithPath: inputPath)
        var srtOutURL = inputURL.deletingPathExtension().appendingPathExtension("srt")
        var burnOutURL: URL?
        var modelOption = WhisperModelOption.defaultModel
        var burnOnly = false

        var i = 1
        while i < args.count {
            switch args[i] {
            case "--srt":
                if i + 1 < args.count {
                    srtOutURL = URL(fileURLWithPath: args[i + 1])
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

        do {
            print("🎬 Inspecting video: \(inputURL.path)")
            let meta = try await VideoSubtitleBurner.inspectVideo(url: inputURL)
            print("   Resolution: \(meta.formattedResolution), Duration: \(meta.formattedDuration)")

            let cues: [SubtitleCue]
            if burnOnly, FileManager.default.fileExists(atPath: srtOutURL.path) {
                let raw = try String(contentsOf: srtOutURL, encoding: .utf8)
                cues = SRTFormatter.parse(raw)
                print("📝 Loaded \(cues.count) existing subtitle segment(s) from: \(srtOutURL.path)")
            } else {
                let service = WhisperTranscriptionService()
                print("🧠 Transcribing on Apple Neural Engine using \(modelOption.displayName) (\(modelOption.id))...")
                cues = try await service.transcribeVideo(videoURL: inputURL, modelOption: modelOption)
                print("✅ Transcribed \(cues.count) subtitle segment(s).")

                let srtContent = SRTFormatter.format(cues: cues)
                try srtContent.write(to: srtOutURL, atomically: true, encoding: .utf8)
                print("📝 Saved .SRT file to: \(srtOutURL.path)")
            }

            if let burnURL = burnOutURL {
                print("🔥 Burning subtitles into video: \(burnURL.path)")
                try await VideoSubtitleBurner.burnSubtitles(
                    sourceURL: inputURL,
                    outputURL: burnURL,
                    cues: cues,
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
                            viewModel.lastBurnedVideoURL = burnedURL
                            viewModel.player = AVPlayer(url: burnedURL)
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

                Button("Transcribe Video") {
                    viewModel.transcribeCurrentVideo()
                }
                .keyboardShortcut("t", modifiers: [.command])
                .disabled(viewModel.videoURL == nil || viewModel.isBusy)

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
