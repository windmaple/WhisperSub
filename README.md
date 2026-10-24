<p align="center">
  <img src="assets/icon.png" width="128" height="128" alt="WhisperSub Icon">
</p>

<h1 align="center">🎬 WhisperSub — AI Video Subtitles on Apple Neural Engine</h1>

A native macOS app and headless CLI that transcribes videos using **OpenAI Whisper on the Apple Neural Engine** (via [WhisperKit](https://github.com/argmaxinc/WhisperKit) CoreML), translates subtitles into **18+ languages**, contextually reviews and polishes translations using **Gemma 4 E4B / E2B on the Apple Neural Engine** (via `CoreMLLLM`), provides **real-time inline subtitle editing**, and burns crisp single-language or bilingual `.srt` captions directly into `.mp4` video.

## 📸 Screenshots

<p align="center">
  <img src="assets/screenshot-workspace.png" width="94%" alt="WhisperSub Main Workspace & Subtitle Cues">
</p>

<p align="center">
  <img src="assets/screenshot-burning.png" width="94%" alt="WhisperSub Raw SRT Inspector & Hardware-Accelerated Subtitle Burning">
</p>

## ✨ Features

- **100% On-Device Apple Neural Engine Acceleration**:
  - **Whisper Transcription (`WhisperKit` CoreML)**: Runs `AudioEncoder` and `TextDecoder` on `.cpuAndNeuralEngine` for fast, low-power local speech-to-text transcription.
  - **Gemma 4 E4B / E2B Subtitle Review (`CoreMLLLM` CoreML)**: Runs `mlboydaisuke/gemma-4-E4B-coreml` (`~5.5 GB`) or `mlboydaisuke/gemma-4-E2B-coreml` (`~4.4 GB`) natively on the **Apple Neural Engine (`.cpuAndNeuralEngine`)** with zero external servers, MLX, or `llama.cpp` dependencies.
- **In-App Model Selectors & Local Cache**:
  - Choose and download Whisper models directly in the app (`Whisper Tiny`, `Whisper Base` default, `Whisper Small`, `Whisper Large v3 Turbo`) and Gemma 4 CoreML review models (`Gemma 4 E4B (ANE)` default, `Gemma 4 E2B (ANE)`).
  - Models and tokenizers are cached locally in `~/Library/Application Support/WhisperSub`.
- **End-to-End Subtitle Workflow**:
  1. **Drop Any Video** (`.mp4`, `.mov`, `.m4v`, `.avi`, `.webm`, `.mkv`): Automatically prepares a cached, clean (unburned) playable `.mp4` preview for `.webm` / `.mkv` (4K AV1/VP9) containers so `AVPlayer` plays smoothly with a single live subtitle overlay.
  2. **Optional Video Clipping (`Start` / `End` Time)**: Specify start and end timestamps (or set from playhead) to clip the video before transcription so no compute is wasted on unneeded sections.
  3. **Transcribe with Live Streaming Updates**: Watch subtitle cues stream into the right-hand inspector in real time as each audio window completes, or stop processing at any time with the unified **Stop Processing** button while keeping all completed cues.
  4. **Translate Subtitles (18+ Languages & Bilingual Mode)**: Translate subtitle cues into Chinese (Simplified/Traditional), English, Japanese, Korean, Spanish, French, German, Portuguese, Russian, Arabic, Hindi, Italian, Dutch, Turkish, Vietnamese, Thai, and Indonesian, or use Whisper's native speech-to-English (`Audio→EN`) task. Toggle seamlessly between **Bilingual (Original + Translated)**, **Translated Only**, and **Original Only**.
  5. **Gemma 4 E4B / E2B Contextual Review & Revision (ANE)**: Polish machine-translated cues for natural phrasing, technical terminology, and cross-line continuity on the Apple Neural Engine. Add custom domain instructions, inspect per-cue `✨ Gemma Revised` diffs against the draft translation, and revert individual cues or all revisions with one click.
  6. **Inline Subtitle & Timing Editor + Live Working-Copy Sync**:
     - Click any cue in **Subtitle Cues** to seek the video player accurately (`+0.02s` frame-aligned seek) or click the pencil icon (or double-click text) to edit original text, translated text, and start/end timestamps (`±0.2s` steppers or direct timestamp input), insert new cues, or delete cues.
     - Switch to **Raw `.SRT`** to edit raw SubRip text directly with live parsing and debounced auto-save.
     - Every transcription window, translation batch, Gemma review batch, and manual edit automatically synchronizes `<video>.srt`, `<video>_<lang>.srt`, `<video>_bilingual_<lang>.srt`, and the working-copy snapshot on disk.
  7. **Hardware-Accelerated Subtitle Burn-In**: Burns crisp, high-contrast single-language or stacked two-line bilingual captions into `.mp4` using native `AVFoundation` + `CoreImage` or hardware-accelerated `h264_videotoolbox` for `.webm` / `.mkv` videos.

## ⌨️ Keyboard Shortcuts

| Action | Shortcut |
| :--- | :--- |
| Open Video File… | `⌘O` |
| Load Existing `.SRT` File… | `⇧⌘I` |
| Clip Video to Start–End Range | `⌘K` |
| Transcribe Video on Apple Neural Engine | `⌘T` |
| Translate Subtitles | `⌘L` |
| Review & Revise with Gemma 4 (ANE) | `⇧⌘L` |
| Save `.SRT` Subtitle File… | `⌘S` |
| Burn Subtitles into Video… | `⌘B` |

## 🖥️ Headless CLI Mode

`WhisperSub` includes a full-featured headless `--cli` mode for batch scripting and automation:

```bash
./WhisperSub.app/Contents/MacOS/WhisperSub --cli input.mp4 \
  --start 00:10 \
  --end 00:45 \
  --translate zh-CN \
  --bilingual \
  --gemma-review \
  --gemma-model e4b \
  --gemma-prompt "Keep product names like Stripe in English" \
  --srt output_bilingual_zh-CN.srt \
  --burn output_subtitled_bilingual_zh-CN.mp4
```

### CLI Options

- `--start <time>` / `--end <time>`: Optional clip start/end time (`MM:SS`, `HH:MM:SS.mmm`, or seconds)
- `--clip-out <clip.mp4>`: Output path for the clipped video
- `--model <model_id>`: WhisperKit model (`openai_whisper-tiny`, `openai_whisper-base`, `openai_whisper-small`, `openai_whisper-large-v3_turbo`)
- `--translate <lang>`: Target language code or name (e.g. `zh-CN`, `zh-TW`, `ja`, `ko`, `es`, `fr`, `de`, `en`)
- `--bilingual`: Format exported `.srt` and burned video with stacked `Original + Translated` lines
- `--whisper-translate`: Use Whisper's direct speech-to-English audio translation
- `--gemma-review`: Polish translated subtitles using Gemma 4 on the Apple Neural Engine
- `--gemma-model <e4b|e2b>`: Select Gemma 4 E4B (`mlboydaisuke/gemma-4-E4B-coreml`) or E2B (`mlboydaisuke/gemma-4-E2B-coreml`)
- `--gemma-prompt <notes>`: Optional custom instructions/terminology notes for Gemma 4 review
- `--srt <out.srt>`: Output `.srt` file path
- `--burn <out.mp4>`: Burn subtitles into an `.mp4` output file
- `--burn-only`: Skip transcription and burn an existing `.srt` file into the video

## 🛠️ Building & Running from Source

Requires macOS 14.0+ (Sonoma or newer) on Apple Silicon (`arm64`) and Xcode / Swift 6 toolchain:

```bash
./build_app.sh
open WhisperSub.app
```
