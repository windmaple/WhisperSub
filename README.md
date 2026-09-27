# WhisperSub

A native macOS app that transcribes videos using **OpenAI Whisper on the Apple Neural Engine** (via [WhisperKit](https://github.com/argmaxinc/WhisperKit) CoreML), generates `.srt` subtitle files, and burns `.srt` captions directly into the video.

## Features

- **Apple Neural Engine Acceleration**: Runs Whisper `AudioEncoder` and `TextDecoder` CoreML models on `.cpuAndNeuralEngine` for fast, low-power local transcription.
- **In-App Model Selector**: Choose and download model sizes directly in the app (`Whisper Tiny`, `Whisper Base` default, `Whisper Small`, `Whisper Large v3 Turbo`). Models and tokenizers are cached locally in `~/Library/Application Support/WhisperSub`.
- **Simple 3-Step Workflow**:
  1. **Drop Video** (`.mp4`, `.mov`, `.m4v`, `.avi`) and preview with live synchronized captions.
  2. **Transcribe & Save `.SRT`**: Automatically formats timestamps (`HH:MM:SS,mmm --> HH:MM:SS,mmm`) and exports `.srt` files (or load an existing `.srt`).
  3. **Burn `.SRT` into Video**: Hardware-accelerated native `AVFoundation` + `CoreImage` compositor burns crisp, styled subtitles directly into an `.mp4` video.
- **CLI Mode**: Also supports headless batch execution:
  ```bash
  ./WhisperSub.app/Contents/MacOS/WhisperSub --cli input.mp4 --srt output.srt --burn output_subtitled.mp4
  ```

## Building & Running

```bash
./build_app.sh
open WhisperSub.app
```
