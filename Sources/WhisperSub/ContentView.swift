import SwiftUI
import AVKit
import UniformTypeIdentifiers

public struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var transcriptionService: WhisperTranscriptionService
    @ObservedObject var translationService: SubtitleTranslationService
    @ObservedObject var gemmaReviewService: GemmaReviewService

    @State private var isDropTargeted: Bool = false
    @State private var inspectorMode: InspectorMode = .cues

    enum InspectorMode: String, CaseIterable, Identifiable {
        case cues = "Subtitle Cues"
        case rawSRT = "Raw .SRT"
        var id: String { rawValue }
    }

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        self.transcriptionService = viewModel.transcriptionService
        self.translationService = viewModel.translationService
        self.gemmaReviewService = viewModel.gemmaReviewService
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            HSplitView {
                leftVideoWorkspace
                    .frame(minWidth: 480, idealWidth: 580)
                rightSubtitleInspector
                    .frame(minWidth: 340, idealWidth: 420)
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Top Header Bar

    private var headerBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor, Color.purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 34, height: 34)
                    Image(systemName: "captions.bubble.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("WhisperSub")
                            .font(.system(size: 16, weight: .bold))
                        neuralEngineBadge
                    }
                    Text("Transcribe video, generate .SRT & burn subtitles on Apple Neural Engine")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Whisper Model Selector
            HStack(spacing: 8) {
                Label("Whisper Model:", systemImage: "cpu")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                Picker("", selection: $viewModel.selectedModel) {
                    ForEach(WhisperModelOption.availableModels) { option in
                        let isCached = transcriptionService.cachedModelIDs.contains(option.id)
                        Text("\(option.displayName) (\(option.sizeDescription))\(isCached ? " ✓" : "")")
                            .tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 290)
                .disabled(viewModel.isBusy)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private var neuralEngineBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 9, weight: .bold))
            Text("Apple Neural Engine")
                .font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Color.green.opacity(0.16))
        .foregroundStyle(Color.green)
        .clipShape(Capsule())
    }

    // MARK: - Left Pane: Video Drop Zone, Player & Actions

    private var leftVideoWorkspace: some View {
        VStack(spacing: 12) {
            if let _ = viewModel.videoURL, let player = viewModel.player {
                videoPlayerCard(player: player)
                videoMetadataBar
            } else {
                videoDropZone
            }

            videoClipBar

            subtitleTranslationBar

            workflowActionBar

            statusAndProgressCard
        }
        .padding(16)
    }

    private var videoDropZone: some View {
        Button {
            viewModel.openVideoPicker()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                        style: StrokeStyle(lineWidth: isDropTargeted ? 2.5 : 1.5, dash: [8, 6])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(isDropTargeted ? Color.accentColor.opacity(0.08) : Color(NSColor.controlBackgroundColor))
                    )

                VStack(spacing: 12) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(Color.accentColor)

                    Text("Drop a Video Here or Click to Browse")
                        .font(.system(size: 16, weight: .semibold))

                    Text("Supports .mp4, .mov, .m4v • Runs Whisper on Apple Neural Engine")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleFileDrop(providers: providers)
        }
    }

    private func videoPlayerCard(player: AVPlayer) -> some View {
        ZStack(alignment: .bottom) {
            VideoPlayer(player: player)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )

            if viewModel.videoMetadata?.isNativelyPlayable == false && !viewModel.hasPlayablePreview {
                VStack(spacing: 8) {
                    if viewModel.isPreparingPreview {
                        ProgressView()
                            .controlSize(.regular)
                            .tint(.white)
                    } else {
                        Image(systemName: "film.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(Color.accentColor)
                    }
                    Text(viewModel.videoURL?.lastPathComponent ?? "WebM / MKV Video")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    if let meta = viewModel.videoMetadata {
                        Text("\(meta.formattedResolution) • \(meta.formattedDuration) • \(meta.formattedFileSize)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    Text(viewModel.isPreparingPreview ? "Preparing clean preview player for WebM/AV1…" : "WebM/AV1 container loaded • Ready to Transcribe & Burn to MP4")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.75))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }

            if let cue = viewModel.activeSubtitleCue, !viewModel.isPlayingBurnedVideo {
                Group {
                    if viewModel.subtitleDisplayMode == .bilingual,
                       let translated = cue.translatedText,
                       !translated.isEmpty,
                       translated != cue.text {
                        VStack(spacing: 3) {
                            Text(cue.text)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white.opacity(0.86))
                                .multilineTextAlignment(.center)
                            Text(translated)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                        }
                    } else {
                        Text(cue.displayText(for: viewModel.subtitleDisplayMode))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.78))
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 42)
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleFileDrop(providers: providers)
        }
    }

    private var videoMetadataBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "video.fill")
                .foregroundStyle(Color.accentColor)

            Text(viewModel.videoURL?.lastPathComponent ?? "")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            if let meta = viewModel.videoMetadata {
                Text("•")
                    .foregroundStyle(.tertiary)
                Text(meta.formattedResolution)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("•")
                    .foregroundStyle(.tertiary)
                Text(meta.formattedDuration)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("•")
                    .foregroundStyle(.tertiary)
                Text(meta.formattedFileSize)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Change Video…") {
                viewModel.openVideoPicker()
            }
            .controlSize(.small)
            .disabled(viewModel.isBusy)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    // MARK: - Video Clip / Trim Bar

    private var videoClipBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "scissors")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(viewModel.isClipped || viewModel.hasCustomClipRange ? Color.accentColor : .secondary)
                Text("Clip Video:")
                    .font(.system(size: 12, weight: .semibold))
            }

            HStack(spacing: 5) {
                Text("Start")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("00:00.0", text: $viewModel.clipStartText)
                    .font(.system(size: 11, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                    .disabled(viewModel.videoURL == nil || viewModel.isBusy)

                Button {
                    viewModel.setClipStartToPlayhead()
                } label: {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 10, weight: .semibold))
                }
                .controlSize(.small)
                .help("Set Start time to current playhead")
                .disabled(viewModel.videoURL == nil || viewModel.isBusy)
            }

            HStack(spacing: 5) {
                Text("End")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField(viewModel.originalVideoMetadata?.formattedDuration ?? "End", text: $viewModel.clipEndText)
                    .font(.system(size: 11, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                    .disabled(viewModel.videoURL == nil || viewModel.isBusy)

                Button {
                    viewModel.setClipEndToPlayhead()
                } label: {
                    Image(systemName: "arrow.up.to.line")
                        .font(.system(size: 10, weight: .semibold))
                }
                .controlSize(.small)
                .help("Set End time to current playhead")
                .disabled(viewModel.videoURL == nil || viewModel.isBusy)
            }

            if let range = viewModel.appliedClipRange, !viewModel.hasUnappliedClipChanges {
                Text("Clipped (\(SRTFormatter.formatShortTimestamp(range.end - range.start)))")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(Capsule())
            }

            Spacer()

            Button {
                viewModel.clipCurrentVideo()
            } label: {
                Label("Clip Video", systemImage: "scissors")
                    .font(.system(size: 11, weight: .medium))
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .disabled(viewModel.videoURL == nil || viewModel.isBusy || !viewModel.hasUnappliedClipChanges)
            .help("Clip the video to Start–End time now (also happens automatically before transcription)")

            if viewModel.isClipped || viewModel.hasCustomClipRange {
                Button("Reset") {
                    viewModel.resetClipRange()
                }
                .controlSize(.small)
                .disabled(viewModel.isBusy)
                .help("Reset to the full original video")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    // MARK: - Subtitle Translation & Gemma 4 Review Bar

    private var subtitleTranslationBar: some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    Image(systemName: "globe")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(viewModel.hasTranslatedCues || viewModel.autoTranslateOnTranscribe ? Color.accentColor : .secondary)
                    Text("Translate:")
                        .font(.system(size: 12, weight: .semibold))
                }

                Picker("", selection: $viewModel.targetLanguage) {
                    ForEach(TranslationLanguage.availableLanguages) { lang in
                        Text(lang.fullDisplayName).tag(lang)
                    }
                }
                .labelsHidden()
                .frame(width: 175)
                .disabled(viewModel.isBusy)
                .help("Target language for subtitle translation")

                Picker("", selection: $viewModel.subtitleDisplayMode) {
                    ForEach(SubtitleDisplayMode.allCases) { mode in
                        Text(mode.compactLabel).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 195)
                .disabled(viewModel.isBusy)
                .help("Toggle between Translated Only, Bilingual (Original + Translated stacked), or Original Only")

                Toggle("Auto", isOn: $viewModel.autoTranslateOnTranscribe)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11, weight: .medium))
                    .disabled(viewModel.isBusy)
                    .help("Automatically translate subtitles after Whisper transcription completes")

                if viewModel.targetLanguage.id == "en" && viewModel.subtitleDisplayMode == .translatedOnly {
                    Toggle("Whisper Audio→EN", isOn: $viewModel.useWhisperDirectAudioTranslate)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                        .disabled(viewModel.isBusy)
                        .help("Use Whisper's on-device speech-to-English task during transcription")
                }

                Spacer()

                Button {
                    viewModel.translateCurrentSubtitles()
                } label: {
                    Label("Translate", systemImage: "character.bubble.fill")
                        .font(.system(size: 11, weight: .medium))
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(viewModel.cues.isEmpty || viewModel.isBusy)
                .help("Translate current subtitle cues into \(viewModel.targetLanguage.displayName)")

                if viewModel.hasTranslatedCues {
                    Button("Clear") {
                        viewModel.clearTranslations()
                    }
                    .controlSize(.small)
                    .disabled(viewModel.isBusy)
                    .help("Remove translations and revert to original subtitles")
                }
            }

            Divider()
                .opacity(0.5)

            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(viewModel.hasGemmaReviewedCues || viewModel.autoReviewWithGemma ? Color.indigo : .secondary)
                    Text("Gemma 4 Review:")
                        .font(.system(size: 12, weight: .semibold))
                }

                Picker("", selection: $viewModel.selectedGemmaModel) {
                    ForEach(GemmaModelOption.availableModels) { option in
                        let isCached = gemmaReviewService.cachedModelIDs.contains(option.id)
                        Text("\(option.displayName) (\(option.sizeDescription))\(isCached ? " ✓" : "")")
                            .tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 265)
                .disabled(viewModel.isBusy)
                .help("Choose Gemma 4 CoreML model (runs natively on Apple Neural Engine)")

                TextField("Style / terminology notes (optional)…", text: $viewModel.gemmaCustomInstructions)
                    .font(.system(size: 11))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 120, maxWidth: 220)
                    .disabled(viewModel.isBusy)
                    .help("Optional domain, glossary, or tone instructions for Gemma 4 subtitle review")

                Toggle("Auto", isOn: $viewModel.autoReviewWithGemma)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11, weight: .medium))
                    .disabled(viewModel.isBusy)
                    .help("Automatically review and revise translations with Gemma 4 after translation completes")

                Spacer()

                Button {
                    viewModel.reviewSubtitlesWithGemma()
                } label: {
                    Label("Review & Revise", systemImage: "sparkles")
                        .font(.system(size: 11, weight: .medium))
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .disabled(viewModel.cues.isEmpty || viewModel.isBusy)
                .help("Use \(viewModel.selectedGemmaModel.displayName) to review and revise subtitle translations for accuracy, phrasing, and subtitle conciseness")

                if viewModel.hasGemmaRevisions {
                    Button("Revert") {
                        viewModel.revertGemmaRevisions()
                    }
                    .controlSize(.small)
                    .disabled(viewModel.isBusy)
                    .help("Revert Gemma 4 revisions back to the initial draft translation")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    // MARK: - Workflow Action Bar

    private var transcribeButtonTitle: String {
        let willClip = viewModel.hasUnappliedClipChanges && viewModel.hasCustomClipRange
        let willTranslate = viewModel.autoTranslateOnTranscribe || viewModel.autoReviewWithGemma || (viewModel.useWhisperDirectAudioTranslate && viewModel.targetLanguage.id == "en" && viewModel.subtitleDisplayMode == .translatedOnly)
        switch (willClip, willTranslate, viewModel.autoReviewWithGemma) {
        case (true, _, true):
            return "1. Clip, Transcribe & Gemma Review"
        case (false, _, true):
            return "1. Transcribe, Translate & Gemma Review"
        case (true, true, false):
            return "1. Clip, Transcribe & Translate"
        case (true, false, false):
            return "1. Clip & Transcribe"
        case (false, true, false):
            return "1. Transcribe & Translate"
        case (false, false, false):
            return "1. Transcribe Video"
        }
    }

    private var workflowActionBar: some View {
        HStack(spacing: 10) {
            if viewModel.isProcessingStoppableTask {
                Button {
                    viewModel.stopCurrentProcessing()
                } label: {
                    Label(
                        "Stop Processing",
                        systemImage: "stop.circle.fill"
                    )
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .help("Stop current transcription, translation, or Gemma 4 review")
            } else {
                Button {
                    viewModel.transcribeCurrentVideo()
                } label: {
                    Label(
                        transcribeButtonTitle,
                        systemImage: "waveform.badge.mic"
                    )
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(viewModel.videoURL == nil || viewModel.isBusy)
            }

            Button {
                viewModel.saveSRTFile()
            } label: {
                Label("2. Save .SRT…", systemImage: "doc.badge.arrow.up")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(viewModel.cues.isEmpty || viewModel.isBusy)

            Button {
                viewModel.burnSubtitlesIntoVideo()
            } label: {
                Label("3. Burn into Video…", systemImage: "flame.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.large)
            .disabled(viewModel.videoURL == nil || viewModel.cues.isEmpty || viewModel.isBusy)
        }
    }

    // MARK: - Status & Progress Card

    private var statusAndProgressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                statusLeadingIcon
                Text(viewModel.statusMessage)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                Spacer()

                if let clippedURL = viewModel.lastClippedVideoURL {
                    Button {
                        viewModel.revealInFinder(clippedURL)
                    } label: {
                        Label("Reveal Clip", systemImage: "scissors")
                            .font(.system(size: 11))
                    }
                    .controlSize(.small)
                }

                if let srtURL = viewModel.lastSavedSRTURL {
                    Button {
                        viewModel.revealInFinder(srtURL)
                    } label: {
                        Label("Reveal .SRT", systemImage: "folder")
                            .font(.system(size: 11))
                    }
                    .controlSize(.small)
                }

                if let burnedURL = viewModel.lastBurnedVideoURL {
                    Button {
                        viewModel.revealInFinder(burnedURL)
                    } label: {
                        Label("Reveal Burned Video", systemImage: "play.rectangle.fill")
                            .font(.system(size: 11))
                    }
                    .controlSize(.small)
                }
            }

            if viewModel.isClipping {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Clipping video to selected time range…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int((viewModel.clipProgress * 100).rounded()))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: viewModel.clipProgress, total: 1.0)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                }
            }

            // Detailed state indicators
            switch transcriptionService.state {
            case .downloadingModel(let progress, let modelName):
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Downloading \(modelName) CoreML weights…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: progress, total: 1.0)
                        .progressViewStyle(.linear)
                }

            case .loadingModel(let modelName):
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Specializing & loading \(modelName) onto Apple Neural Engine…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

            case .extractingAudio:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Extracting 16 kHz PCM audio track from video…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

            case .transcribing(let liveText):
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(liveText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

            case .completed(let count, let speed) where !viewModel.isBurning && !viewModel.isClipping && !viewModel.isTranslating:
                if speed > 0 {
                    Text("Neural Engine decoded \(count) segments at \(String(format: "%.1f×", speed)) real-time speed.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

            default:
                EmptyView()
            }

            if viewModel.isTranslating {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        if case .translating(let completed, let total, let lang) = translationService.state {
                            Text("Translating subtitles to \(lang)… (\(completed)/\(total))")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Translating subtitles to \(viewModel.targetLanguage.displayName)…")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(Int((viewModel.translationProgress * 100).rounded()))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: viewModel.translationProgress, total: 1.0)
                        .progressViewStyle(.linear)
                        .tint(.purple)
                }
            }

            switch gemmaReviewService.state {
            case .downloadingModel(let progress, let modelName, let detail):
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Downloading \(modelName) (\(detail))…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: progress, total: 1.0)
                        .progressViewStyle(.linear)
                        .tint(.indigo)
                }

            case .loadingModel(let modelName):
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading \(modelName) onto Apple Neural Engine…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

            case .reviewing(let completed, let total, let modelName):
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("✨ \(modelName) reviewing & revising translations… (\(completed)/\(total))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int((viewModel.gemmaReviewProgress * 100).rounded()))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: viewModel.gemmaReviewProgress, total: 1.0)
                        .progressViewStyle(.linear)
                        .tint(.indigo)
                }

            default:
                if viewModel.isReviewingWithGemma {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("✨ \(viewModel.selectedGemmaModel.shortName) reviewing & revising translations…")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int((viewModel.gemmaReviewProgress * 100).rounded()))%")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: viewModel.gemmaReviewProgress, total: 1.0)
                            .progressViewStyle(.linear)
                            .tint(.indigo)
                    }
                }
            }

            if viewModel.isBurning {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Rendering & encoding burned-in subtitles…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int((viewModel.burnProgress * 100).rounded()))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: viewModel.burnProgress, total: 1.0)
                        .progressViewStyle(.linear)
                        .tint(.orange)
                }
            }

            if let error = viewModel.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    @ViewBuilder
    private var statusLeadingIcon: some View {
        if viewModel.isBusy {
            ProgressView()
                .controlSize(.small)
        } else if viewModel.errorMessage != nil {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        } else if !viewModel.cues.isEmpty {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Right Pane: Subtitle Cues & Raw .SRT Inspector

    private var rightSubtitleInspector: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $inspectorMode) {
                    ForEach(InspectorMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 210)

                if let lang = viewModel.translatedLanguage, viewModel.hasTranslatedCues {
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                            .font(.system(size: 9, weight: .bold))
                        Text("\(lang.id) • \(viewModel.subtitleDisplayMode.compactLabel)")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.purple.opacity(0.15))
                    .foregroundStyle(Color.purple)
                    .clipShape(Capsule())
                }

                if viewModel.hasGemmaReviewedCues {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9, weight: .bold))
                        Text("Gemma 4 (\(viewModel.lastGemmaRevisedCount) revised)")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.indigo.opacity(0.15))
                    .foregroundStyle(Color.indigo)
                    .clipShape(Capsule())
                }

                Spacer()

                Button {
                    viewModel.addCue(after: viewModel.activeSubtitleCue?.id)
                } label: {
                    Label("Add Cue", systemImage: "plus")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
                .disabled(viewModel.isBusy)
                .help("Insert a new subtitle cue after the selected cue")

                Button {
                    viewModel.importSRTFile()
                } label: {
                    Label("Load .SRT…", systemImage: "square.and.arrow.down")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
                .disabled(viewModel.isBusy)

                Button {
                    viewModel.copySRTToClipboard()
                } label: {
                    Label("Copy .SRT", systemImage: "doc.on.doc")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
                .disabled(viewModel.cues.isEmpty)
            }
            .padding(12)

            Divider()

            if viewModel.cues.isEmpty {
                emptySubtitlesPlaceholder
            } else {
                switch inspectorMode {
                case .cues:
                    cueListView
                case .rawSRT:
                    EditableRawSRTView(viewModel: viewModel)
                }
            }
        }
        .background(Color(NSColor.underPageBackgroundColor).opacity(0.4))
    }

    private var emptySubtitlesPlaceholder: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "text.bubble")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No Subtitles Yet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Click \"1. Transcribe Video\" to generate .SRT subtitles on the Neural Engine, or load an existing .SRT file.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var cueListView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(viewModel.cues) { cue in
                    let isActive = viewModel.activeSubtitleCue?.id == cue.id
                    EditableSubtitleCueRow(
                        cue: cue,
                        isActive: isActive,
                        displayMode: viewModel.subtitleDisplayMode,
                        viewModel: viewModel
                    )
                }
            }
            .padding(12)
        }
    }

    // MARK: - Drag and Drop Handler

    private func handleFileDrop(providers: [NSItemProvider]) -> Bool {
        guard !viewModel.isBusy, let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil)
            else { return }

            let ext = url.pathExtension.lowercased()
            Task { @MainActor in
                if ext == "srt" {
                    try? viewModel.applyImportedSRTFile(url: url)
                } else {
                    viewModel.loadVideo(url: url)
                }
            }
        }
        return true
    }
}

// MARK: - Editable Subtitle Cue Row

private struct EditableSubtitleCueRow: View {
    let cue: SubtitleCue
    let isActive: Bool
    let displayMode: SubtitleDisplayMode
    @ObservedObject var viewModel: AppViewModel

    @State private var originalDraft: String = ""
    @State private var translatedDraft: String = ""
    @State private var startTimestampDraft: String = ""
    @State private var endTimestampDraft: String = ""
    @State private var isEditingTiming: Bool = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case original
        case translated
        case startTime
        case endTime
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            leadingPlayColumn
            VStack(alignment: .leading, spacing: 6) {
                headerRow
                contentEditorStack
            }
        }
        .padding(10)
        .background(rowBackground)
        .overlay(rowBorder)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.selectAndSeek(to: cue)
        }
        .onAppear {
            syncDraftsFromCue()
        }
        .onChange(of: cue.text) { _, newValue in
            if originalDraft != newValue {
                originalDraft = newValue
            }
        }
        .onChange(of: cue.translatedText) { _, newValue in
            let resolved = newValue ?? ""
            if translatedDraft != resolved {
                translatedDraft = resolved
            }
        }
        .onChange(of: focusedField) { _, newFocus in
            if newFocus != nil {
                viewModel.selectAndSeek(to: cue)
            }
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isActive ? Color.accentColor.opacity(0.14) : Color(NSColor.controlBackgroundColor))
    }

    private var rowBorder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(isActive ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.06), lineWidth: 1)
    }

    private var leadingPlayColumn: some View {
        let shortStart = SRTFormatter.formatShortTimestamp(cue.startTime)
        return Button {
            viewModel.selectAndSeek(to: cue)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text("#\(cue.id)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                Image(systemName: isActive ? "play.circle.fill" : "play.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .frame(width: 34, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Seek video to cue #\(cue.id) (\(shortStart))")
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            if isEditingTiming {
                timingEditorControls
            } else {
                Button {
                    viewModel.selectAndSeek(to: cue)
                } label: {
                    Text(cue.formattedTimeRange)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(isActive ? Color.primary : .secondary)
                }
                .buttonStyle(.plain)
            }

            gemmaStatusBadge

            Spacer()

            headerActionButtons
        }
    }

    private var timingEditorControls: some View {
        HStack(spacing: 4) {
            TextField("00:00:00,000", text: $startTimestampDraft)
                .font(.system(size: 10, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .frame(width: 92)
                .focused($focusedField, equals: .startTime)
                .onSubmit { commitTimingEdits() }

            Text("-->")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)

            TextField("00:00:02,000", text: $endTimestampDraft)
                .font(.system(size: 10, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .frame(width: 92)
                .focused($focusedField, equals: .endTime)
                .onSubmit { commitTimingEdits() }

            Button("Apply") {
                commitTimingEdits()
            }
            .controlSize(.mini)
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var gemmaStatusBadge: some View {
        if cue.wasRevisedByGemma {
            HStack(spacing: 3) {
                Image(systemName: "sparkles")
                    .font(.system(size: 8, weight: .bold))
                Text("Gemma Revised")
                    .font(.system(size: 9, weight: .semibold))
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.indigo.opacity(0.16))
            .foregroundStyle(Color.indigo)
            .clipShape(Capsule())
        } else if cue.isReviewedByGemma {
            HStack(spacing: 2) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 8))
                Text("Reviewed")
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(.secondary)
        }
    }

    private var headerActionButtons: some View {
        HStack(spacing: 6) {
            Button {
                if isEditingTiming {
                    commitTimingEdits()
                } else {
                    startTimestampDraft = SRTFormatter.formatTimestamp(cue.startTime)
                    endTimestampDraft = SRTFormatter.formatTimestamp(cue.endTime)
                    isEditingTiming = true
                }
            } label: {
                Image(systemName: isEditingTiming ? "checkmark.circle.fill" : "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(isEditingTiming ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(isEditingTiming ? "Save timestamp changes" : "Edit start/end timestamps for cue #\(cue.id)")

            Button {
                viewModel.addCue(after: cue.id)
            } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isBusy)
            .help("Insert a new cue after #\(cue.id)")

            Button {
                viewModel.deleteCue(id: cue.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isBusy)
            .help("Delete cue #\(cue.id)")
        }
    }

    @ViewBuilder
    private var contentEditorStack: some View {
        switch displayMode {
        case .bilingual:
            originalEditorView(isSecondary: cue.hasTranslation)
            if cue.hasTranslation || viewModel.translatedLanguage != nil {
                translatedEditorView
            }
            if cue.wasRevisedByGemma, let draft = cue.preReviewTranslatedText {
                Text("Draft: \(draft)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .translatedOnly:
            if cue.hasTranslation || viewModel.translatedLanguage != nil {
                translatedEditorView
                originalEditorView(isSecondary: true)
            } else {
                originalEditorView(isSecondary: false)
            }
            if cue.wasRevisedByGemma, let draft = cue.preReviewTranslatedText {
                Text("Draft: \(draft)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .originalOnly:
            originalEditorView(isSecondary: false)
        }
    }

    @ViewBuilder
    private func originalEditorView(isSecondary: Bool) -> some View {
        TextField("Original subtitle…", text: $originalDraft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: isSecondary ? 11.5 : 13, weight: isActive && !isSecondary ? .semibold : .regular))
            .foregroundStyle(isSecondary ? .secondary : .primary)
            .focused($focusedField, equals: .original)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(focusedField == .original ? Color(NSColor.textBackgroundColor) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(focusedField == .original ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1)
            )
            .onChange(of: originalDraft) { _, newValue in
                if newValue != cue.text {
                    viewModel.updateCueOriginalText(id: cue.id, newText: newValue)
                }
            }
    }

    private var translatedEditorView: some View {
        TextField("Translated subtitle…", text: $translatedDraft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: isActive ? .semibold : .medium))
            .foregroundStyle(.primary)
            .focused($focusedField, equals: .translated)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(focusedField == .translated ? Color(NSColor.textBackgroundColor) : Color.purple.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(focusedField == .translated ? Color.purple.opacity(0.6) : Color.clear, lineWidth: 1)
            )
            .onChange(of: translatedDraft) { _, newValue in
                let current = cue.translatedText ?? ""
                if newValue != current {
                    viewModel.updateCueTranslatedText(id: cue.id, newText: newValue)
                }
            }
    }

    private func syncDraftsFromCue() {
        originalDraft = cue.text
        translatedDraft = cue.translatedText ?? ""
        startTimestampDraft = SRTFormatter.formatTimestamp(cue.startTime)
        endTimestampDraft = SRTFormatter.formatTimestamp(cue.endTime)
    }

    private func commitTimingEdits() {
        _ = viewModel.updateCueTimestamps(
            id: cue.id,
            startString: startTimestampDraft,
            endString: endTimestampDraft
        )
        isEditingTiming = false
        focusedField = nil
    }
}

// MARK: - Editable Raw .SRT View

private struct EditableRawSRTView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var editableSRT: String = ""
    @State private var hasUnappliedEdits: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "pencil.and.outline")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Editable .SRT (\(viewModel.subtitleDisplayMode.compactLabel))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer()

                if hasUnappliedEdits {
                    Button("Revert") {
                        editableSRT = viewModel.srtText
                        hasUnappliedEdits = false
                    }
                    .controlSize(.mini)

                    Button("Apply Edits") {
                        viewModel.applyRawSRTEdits(editableSRT)
                        hasUnappliedEdits = false
                    }
                    .controlSize(.mini)
                    .buttonStyle(.borderedProminent)
                } else {
                    Text("All changes synced")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            TextEditor(text: $editableSRT)
                .font(.system(size: 12, design: .monospaced))
                .padding(8)
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: editableSRT) { _, newValue in
                    hasUnappliedEdits = (newValue != viewModel.srtText)
                }
        }
        .onAppear {
            editableSRT = viewModel.srtText
            hasUnappliedEdits = false
        }
        .onDisappear {
            if hasUnappliedEdits {
                viewModel.applyRawSRTEdits(editableSRT)
                hasUnappliedEdits = false
            }
        }
        .onChange(of: viewModel.srtText) { _, newValue in
            if editableSRT != newValue {
                editableSRT = newValue
                hasUnappliedEdits = false
            }
        }
    }
}
