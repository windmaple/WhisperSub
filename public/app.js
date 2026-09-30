/* ==========================================================================
   WhisperSub Static Website — Interactive Workbench, Model Explorer & CLI
   ========================================================================== */

(function () {
  'use strict';

  /* ------------------------------------------------------------------------
     1. Screenshot Showcase Switcher
     ------------------------------------------------------------------------ */
  const btnShowWorkspace = document.getElementById('btn-show-workspace');
  const btnShowBurning = document.getElementById('btn-show-burning');
  const imgWorkspace = document.getElementById('img-showcase-workspace');
  const imgBurning = document.getElementById('img-showcase-burning');
  const captionText = document.getElementById('showcase-caption-text');

  function setShowcaseMode(mode) {
    if (mode === 'burning') {
      btnShowWorkspace.classList.remove('active');
      btnShowWorkspace.setAttribute('aria-selected', 'false');
      btnShowBurning.classList.add('active');
      btnShowBurning.setAttribute('aria-selected', 'true');
      imgWorkspace.classList.add('hidden');
      imgBurning.classList.remove('hidden');
      captionText.textContent =
        'Raw .SRT text inspector with hardware-accelerated AVFoundation + CoreImage subtitle burning progress.';
    } else {
      btnShowBurning.classList.remove('active');
      btnShowBurning.setAttribute('aria-selected', 'false');
      btnShowWorkspace.classList.add('active');
      btnShowWorkspace.setAttribute('aria-selected', 'true');
      imgBurning.classList.add('hidden');
      imgWorkspace.classList.remove('hidden');
      captionText.textContent =
        'Synchronized video preview, start/end range clipping, and interactive cue list on macOS.';
    }
  }

  if (btnShowWorkspace && btnShowBurning) {
    btnShowWorkspace.addEventListener('click', () => setShowcaseMode('workspace'));
    btnShowBurning.addEventListener('click', () => setShowcaseMode('burning'));
  }

  /* ------------------------------------------------------------------------
     2. Interactive Subtitle Cue & Raw .SRT Workbench
     ------------------------------------------------------------------------ */
  const initialCues = [
    {
      id: 1,
      startTime: 0.0,
      endTime: 3.42,
      text: "Hello everyone, and thank you for joining today's session."
    },
    {
      id: 2,
      startTime: 3.42,
      endTime: 7.85,
      text: 'Welcome to our deep dive into Apple Neural Engine acceleration.'
    },
    {
      id: 3,
      startTime: 7.85,
      endTime: 12.3,
      text: 'With WhisperKit CoreML, AudioEncoder and TextDecoder run locally.'
    },
    {
      id: 4,
      startTime: 12.3,
      endTime: 17.12,
      text: 'You can clip any start and end range before transcribing your video.'
    },
    {
      id: 5,
      startTime: 17.12,
      endTime: 22.4,
      text: 'Then export a standard .SRT file or burn styled captions into MP4.'
    }
  ];

  let cues = initialCues.map((c) => ({ ...c }));
  let activeCueIndex = 1; // Default to #2 matching the screenshot

  const cueListEl = document.getElementById('demo-cue-list');
  const rawPaneEl = document.getElementById('demo-raw-pane');
  const rawTextareaEl = document.getElementById('demo-raw-textarea');
  const tabBtnCues = document.getElementById('tab-btn-cues');
  const tabBtnRaw = document.getElementById('tab-btn-raw');
  const captionOverlayEl = document.getElementById('demo-caption-overlay');
  const timecodeCurrentEl = document.getElementById('demo-timecode-current');
  const scrubberFillEl = document.getElementById('demo-scrubber-fill');
  const scrubberTrackEl = document.getElementById('demo-scrubber-track');
  const btnCycleCue = document.getElementById('btn-demo-cycle');
  const btnCopySrt = document.getElementById('btn-copy-srt');
  const btnDemoTranscribe = document.getElementById('btn-demo-transcribe');
  const btnDemoDownloadSrt = document.getElementById('btn-demo-download-srt');
  const btnDemoBurn = document.getElementById('btn-demo-burn');
  const statusTextEl = document.getElementById('demo-status-text');

  function formatSRTTimestamp(seconds) {
    const clamped = Math.max(0, seconds);
    const totalMs = Math.round(clamped * 1000);
    const ms = totalMs % 1000;
    const totalSec = Math.floor(totalMs / 1000);
    const s = totalSec % 60;
    const totalMin = Math.floor(totalSec / 60);
    const m = totalMin % 60;
    const h = Math.floor(totalMin / 60);
    const pad2 = (n) => String(n).padStart(2, '0');
    const pad3 = (n) => String(n).padStart(3, '0');
    return `${pad2(h)}:${pad2(m)}:${pad2(s)},${pad3(ms)}`;
  }

  function formatShortTimestamp(seconds) {
    const clamped = Math.max(0, seconds);
    const totalTenths = Math.round(clamped * 10);
    const tenths = totalTenths % 10;
    const totalSec = Math.floor(totalTenths / 10);
    const s = totalSec % 60;
    const m = Math.floor(totalSec / 60);
    const pad2 = (n) => String(n).padStart(2, '0');
    return `${pad2(m)}:${pad2(s)}.${tenths}`;
  }

  function formatCuesToSRT(cueArray) {
    return (
      cueArray
        .map((cue, idx) => {
          const seq = idx + 1;
          const start = formatSRTTimestamp(cue.startTime);
          const end = formatSRTTimestamp(cue.endTime);
          return `${seq}\n${start} --> ${end}\n${cue.text.trim()}`;
        })
        .join('\n\n') + '\n'
    );
  }

  function parseTimestampToSeconds(raw) {
    const clean = raw.trim().replace(',', '.');
    const parts = clean.split(':');
    if (parts.length !== 3) return null;
    const h = parseFloat(parts[0]);
    const m = parseFloat(parts[1]);
    const s = parseFloat(parts[2]);
    if (Number.isNaN(h) || Number.isNaN(m) || Number.isNaN(s)) return null;
    return h * 3600 + m * 60 + s;
  }

  function parseSRTToCues(srtString) {
    const blocks = srtString.replace(/\r\n/g, '\n').split('\n\n');
    const parsed = [];
    for (const block of blocks) {
      const lines = block
        .split('\n')
        .map((l) => l.trim())
        .filter(Boolean);
      if (lines.length < 2) continue;
      const timeIdx = lines.findIndex((l) => l.includes('-->'));
      if (timeIdx === -1) continue;
      const parts = lines[timeIdx].split('-->');
      if (parts.length !== 2) continue;
      const start = parseTimestampToSeconds(parts[0]);
      const end = parseTimestampToSeconds(parts[1]);
      if (start === null || end === null) continue;
      const text = lines.slice(timeIdx + 1).join('\n').trim();
      if (!text) continue;
      parsed.push({
        id: parsed.length + 1,
        startTime: start,
        endTime: Math.max(start + 0.05, end),
        text
      });
    }
    return parsed;
  }

  function renderCues() {
    if (!cueListEl) return;
    cueListEl.innerHTML = '';
    cues.forEach((cue, index) => {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'cue-item' + (index === activeCueIndex ? ' active' : '');
      btn.id = `demo-cue-item-${cue.id}`;
      const rangeStr = `${formatSRTTimestamp(cue.startTime)} --> ${formatSRTTimestamp(cue.endTime)}`;
      btn.innerHTML = `
        <div class="cue-item-top">
          <span class="cue-id">#${cue.id}</span>
          <span class="cue-time">${rangeStr}</span>
        </div>
        <div class="cue-text"></div>
      `;
      btn.querySelector('.cue-text').textContent = cue.text;
      btn.addEventListener('click', () => selectCue(index));
      cueListEl.appendChild(btn);
    });

    if (rawTextareaEl) {
      rawTextareaEl.value = formatCuesToSRT(cues);
    }
    updatePlayerFromActiveCue();
  }

  function updatePlayerFromActiveCue() {
    const cue = cues[activeCueIndex] || cues[0];
    if (!cue) return;
    if (captionOverlayEl) {
      captionOverlayEl.textContent = cue.text;
    }
    const midTime = (cue.startTime + cue.endTime) / 2;
    if (timecodeCurrentEl) {
      timecodeCurrentEl.textContent = formatShortTimestamp(midTime);
    }
    if (scrubberFillEl) {
      const pct = Math.min(100, Math.max(6, (cue.endTime / 24.0) * 100));
      scrubberFillEl.style.width = `${pct.toFixed(1)}%`;
    }
  }

  function selectCue(index) {
    activeCueIndex = Math.max(0, Math.min(cues.length - 1, index));
    renderCues();
  }

  if (btnCycleCue) {
    btnCycleCue.addEventListener('click', () => {
      const next = (activeCueIndex + 1) % cues.length;
      selectCue(next);
    });
  }

  if (scrubberTrackEl) {
    scrubberTrackEl.addEventListener('click', (e) => {
      const rect = scrubberTrackEl.getBoundingClientRect();
      const ratio = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
      const idx = Math.min(cues.length - 1, Math.floor(ratio * cues.length));
      selectCue(idx);
    });
  }

  if (tabBtnCues && tabBtnRaw) {
    tabBtnCues.addEventListener('click', () => {
      const updated = parseSRTToCues(rawTextareaEl.value);
      if (updated.length > 0) {
        cues = updated;
        if (activeCueIndex >= cues.length) activeCueIndex = 0;
      }
      tabBtnCues.classList.add('active');
      tabBtnCues.setAttribute('aria-selected', 'true');
      tabBtnRaw.classList.remove('active');
      tabBtnRaw.setAttribute('aria-selected', 'false');
      cueListEl.style.display = 'flex';
      rawPaneEl.classList.remove('visible');
      renderCues();
    });

    tabBtnRaw.addEventListener('click', () => {
      rawTextareaEl.value = formatCuesToSRT(cues);
      tabBtnRaw.classList.add('active');
      tabBtnRaw.setAttribute('aria-selected', 'true');
      tabBtnCues.classList.remove('active');
      tabBtnCues.setAttribute('aria-selected', 'false');
      cueListEl.style.display = 'none';
      rawPaneEl.classList.add('visible');
    });
  }

  if (rawTextareaEl) {
    rawTextareaEl.addEventListener('input', () => {
      const updated = parseSRTToCues(rawTextareaEl.value);
      if (updated.length > 0) {
        cues = updated;
        updatePlayerFromActiveCue();
      }
    });
  }

  if (btnCopySrt) {
    btnCopySrt.addEventListener('click', async () => {
      const srt = formatCuesToSRT(cues);
      try {
        await navigator.clipboard.writeText(srt);
        const orig = btnCopySrt.textContent;
        btnCopySrt.textContent = 'Copied .SRT ✓';
        setTimeout(() => {
          btnCopySrt.textContent = orig;
        }, 1600);
      } catch (_) {
        statusTextEl.textContent = '📋 Ready to copy from Raw .SRT inspector tab.';
      }
    });
  }

  if (btnDemoDownloadSrt) {
    btnDemoDownloadSrt.addEventListener('click', () => {
      const srt = formatCuesToSRT(cues);
      const blob = new Blob([srt], { type: 'text/plain;charset=utf-8' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = 'keynote_demo.srt';
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      URL.revokeObjectURL(url);
      statusTextEl.textContent = '📝 Exported keynote_demo.srt (standard SubRip UTF-8 format).';
    });
  }

  if (btnDemoTranscribe) {
    btnDemoTranscribe.addEventListener('click', () => {
      statusTextEl.textContent = '🧠 Extracting 16 kHz mono WAV & decoding on Apple Neural Engine…';
      setTimeout(() => {
        statusTextEl.textContent = '🧠 Detecting spoken language (en) with VAD chunking strategy…';
      }, 450);
      setTimeout(() => {
        selectCue(0);
        statusTextEl.textContent =
          '✅ Transcription complete! Neural Engine decoded ' +
          cues.length +
          ' subtitle cues at 14.8× real-time speed.';
      }, 1050);
    });
  }

  if (btnDemoBurn) {
    btnDemoBurn.addEventListener('click', () => {
      let pct = 18;
      statusTextEl.textContent =
        '🔥 Rendering & encoding burned-in subtitles via AVFoundation + CoreImage… 18%';
      const timer = setInterval(() => {
        pct += 28;
        if (pct < 100) {
          statusTextEl.textContent = `🔥 Rendering & encoding burned-in subtitles via AVFoundation + CoreImage… ${pct}%`;
        } else {
          clearInterval(timer);
          statusTextEl.textContent =
            '✅ Exported burned video to keynote_demo_subtitled.mp4 (H.264 + AAC).';
        }
      }, 280);
    });
  }

  renderCues();

  /* ------------------------------------------------------------------------
     3. CoreML Model Explorer & Neural Engine Time Estimator
     ------------------------------------------------------------------------ */
  const modelData = {
    tiny: {
      title: 'Whisper Tiny',
      id: 'openai_whisper-tiny',
      size: '~75 MB on disk',
      speedFactor: 26.0,
      useCase: 'Ultra-fast drafts, quick timestamp previews, and low-storage devices'
    },
    base: {
      title: 'Whisper Base (Default)',
      id: 'openai_whisper-base',
      size: '~145 MB on disk',
      speedFactor: 14.8,
      useCase: 'Everyday lectures, product demos, and balanced .SRT generation'
    },
    small: {
      title: 'Whisper Small',
      id: 'openai_whisper-small',
      size: '~485 MB on disk',
      speedFactor: 7.4,
      useCase: 'Multi-speaker interviews, technical terminology, and accented speech'
    },
    large: {
      title: 'Whisper Large v3 Turbo',
      id: 'openai_whisper-large-v3_turbo',
      size: '~950 MB on disk',
      speedFactor: 4.2,
      useCase: 'Studio-grade broadcast captions, multilingual audio, and noisy recordings'
    }
  };

  let currentModelKey = 'base';
  const modelButtons = document.querySelectorAll('.model-option-btn');
  const selectedModelTitle = document.getElementById('selected-model-title');
  const selectedModelId = document.getElementById('selected-model-id');
  const selectedModelUsecase = document.getElementById('selected-model-usecase');
  const durationSlider = document.getElementById('video-duration-slider');
  const sliderDurationLabel = document.getElementById('slider-duration-label');
  const estimatedTimeEl = document.getElementById('estimated-transcribe-time');

  function updateModelEstimator() {
    const info = modelData[currentModelKey];
    const minutes = durationSlider ? parseInt(durationSlider.value, 10) : 10;
    if (sliderDurationLabel) {
      sliderDurationLabel.textContent = `${minutes} minute${minutes === 1 ? '' : 's'}`;
    }
    if (selectedModelTitle) selectedModelTitle.textContent = info.title;
    if (selectedModelId) selectedModelId.textContent = `Variant ID: ${info.id} • ${info.size}`;
    if (selectedModelUsecase) selectedModelUsecase.textContent = info.useCase;

    const totalVideoSec = minutes * 60;
    const estSec = Math.max(2, Math.round(totalVideoSec / info.speedFactor));
    let formattedEst = '';
    if (estSec < 60) {
      formattedEst = `~${estSec} sec (${info.speedFactor}×)`;
    } else {
      const m = Math.floor(estSec / 60);
      const s = estSec % 60;
      formattedEst = `~${m}m ${s}s (${info.speedFactor}×)`;
    }
    if (estimatedTimeEl) {
      estimatedTimeEl.textContent = formattedEst;
    }
  }

  modelButtons.forEach((btn) => {
    btn.addEventListener('click', () => {
      const key = btn.getAttribute('data-model');
      if (!key || !modelData[key]) return;
      currentModelKey = key;
      modelButtons.forEach((b) => b.classList.remove('active'));
      btn.classList.add('active');
      updateModelEstimator();
    });
  });

  if (durationSlider) {
    durationSlider.addEventListener('input', updateModelEstimator);
  }

  updateModelEstimator();

  /* ------------------------------------------------------------------------
     4. Interactive CLI Command Builder
     ------------------------------------------------------------------------ */
  const cliInputVideo = document.getElementById('cli-input-video');
  const cliStartTime = document.getElementById('cli-start-time');
  const cliEndTime = document.getElementById('cli-end-time');
  const cliSrtOut = document.getElementById('cli-srt-out');
  const cliBurnOut = document.getElementById('cli-burn-out');
  const cliModelSelect = document.getElementById('cli-model-select');
  const cliEnableClip = document.getElementById('cli-enable-clip');
  const cliEnableBurn = document.getElementById('cli-enable-burn');
  const cliBurnOnly = document.getElementById('cli-burn-only');
  const cliCommandOutput = document.getElementById('cli-command-output');
  const cliTerminalLog = document.getElementById('cli-terminal-log');
  const btnCopyCli = document.getElementById('btn-copy-cli');

  function updateCliBuilder() {
    if (!cliCommandOutput) return;
    const inputPath = (cliInputVideo.value || 'input.mp4').trim();
    const startVal = (cliStartTime.value || '').trim();
    const endVal = (cliEndTime.value || '').trim();
    const srtVal = (cliSrtOut.value || 'output.srt').trim();
    const burnVal = (cliBurnOut.value || 'output_subtitled.mp4').trim();
    const modelVal = cliModelSelect.value;

    const parts = ['./WhisperSub.app/Contents/MacOS/WhisperSub', '--cli', inputPath];

    if (cliEnableClip.checked) {
      if (startVal) parts.push('--start', startVal);
      if (endVal) parts.push('--end', endVal);
    }

    if (srtVal) {
      parts.push('--srt', srtVal);
    }

    if (cliEnableBurn.checked && burnVal) {
      parts.push('--burn', burnVal);
    }

    if (cliBurnOnly.checked) {
      parts.push('--burn-only');
    }

    if (modelVal) {
      parts.push('--model', modelVal);
    }

    cliCommandOutput.textContent = parts.join(' ');

    // Update simulated CLI stdout log
    const logs = [];
    logs.push(`<div>🎬 Inspecting video: ${inputPath}</div>`);
    logs.push(`<div>&nbsp;&nbsp;&nbsp;Resolution: 1920×1080, Duration: 01:15.0</div>`);
    if (cliEnableClip.checked && (startVal || endVal)) {
      logs.push(
        `<div>✂️ Clipping video from ${startVal || '00:00.0'} to ${endVal || '01:15.0'} -&gt; clipped.mp4</div>`
      );
    }
    if (cliBurnOnly.checked) {
      logs.push(`<div>📝 Loaded 18 existing subtitle segment(s) from: ${srtVal}</div>`);
    } else {
      const mId = modelVal || 'openai_whisper-base';
      logs.push(`<div>🧠 Transcribing on Apple Neural Engine using ${mId}...</div>`);
      logs.push(`<div>✅ Transcribed 18 subtitle segment(s).</div>`);
      logs.push(`<div>📝 Saved .SRT file to: ${srtVal}</div>`);
    }
    if (cliEnableBurn.checked && burnVal) {
      logs.push(`<div>🔥 Burning subtitles into video: ${burnVal}</div>`);
      logs.push(`<div>✅ Exported burned video to: ${burnVal}</div>`);
    }
    if (cliTerminalLog) {
      cliTerminalLog.innerHTML = logs.join('');
    }
  }

  [
    cliInputVideo,
    cliStartTime,
    cliEndTime,
    cliSrtOut,
    cliBurnOut,
    cliModelSelect,
    cliEnableClip,
    cliEnableBurn,
    cliBurnOnly
  ].forEach((el) => {
    if (el) {
      el.addEventListener('input', updateCliBuilder);
      el.addEventListener('change', updateCliBuilder);
    }
  });

  if (btnCopyCli) {
    btnCopyCli.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(cliCommandOutput.textContent);
        const orig = btnCopyCli.textContent;
        btnCopyCli.textContent = 'Copied ✓';
        setTimeout(() => {
          btnCopyCli.textContent = orig;
        }, 1600);
      } catch (_) {}
    });
  }

  /* ------------------------------------------------------------------------
     5. Copy Build Script Button
     ------------------------------------------------------------------------ */
  const btnCopyBuild = document.getElementById('btn-copy-build');
  const buildCodeBlock = document.getElementById('build-code-block');
  if (btnCopyBuild && buildCodeBlock) {
    btnCopyBuild.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(buildCodeBlock.innerText.trim());
        const orig = btnCopyBuild.textContent;
        btnCopyBuild.textContent = 'Copied ✓';
        setTimeout(() => {
          btnCopyBuild.textContent = orig;
        }, 1600);
      } catch (_) {}
    });
  }
})();
