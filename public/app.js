'use strict';

(() => {
  const appShell = document.querySelector('.app-shell');
  const macNameEl = document.getElementById('mac-name');
  const stageTrigger = document.getElementById('stage-trigger');
  const playBtn = document.getElementById('play-btn');
  const playIcon = document.getElementById('play-icon');
  const playLabel = document.getElementById('play-label');
  const statusBadge = document.getElementById('status-badge');
  const statusText = document.getElementById('status-text');
  const errorBanner = document.getElementById('error-banner');
  const errorText = document.getElementById('error-text');
  const statBuffer = document.getElementById('stat-buffer');
  const statPing = document.getElementById('stat-ping');
  const statFormat = document.getElementById('stat-format');
  const volumeSlider = document.getElementById('volume-slider');
  const volumeScrubberWrap = document.getElementById('volume-scrubber-wrap');
  const volumeOutput = document.getElementById('volume-output');
  const bufferSlider = document.getElementById('buffer-slider');
  const bufferOutput = document.getElementById('buffer-output');
  const segmentBtns = Array.from(document.querySelectorAll('.segment-btn'));
  const segmentedThumb = document.getElementById('segmented-thumb');
  const muteMacToggle = document.getElementById('mute-mac-toggle');
  const meterCanvas = document.getElementById('meter-canvas');
  const meterCtx = meterCanvas.getContext('2d');

  const PLAY_SVG =
    '<svg viewBox="0 0 20 20"><path d="M5.5 3.6c0-.85.94-1.36 1.66-.9l9.6 6.1c.66.42.66 1.38 0 1.8l-9.6 6.1c-.72.46-1.66-.05-1.66-.9V3.6z" fill="currentColor"/></svg>';
  const STOP_SVG =
    '<svg viewBox="0 0 20 20"><rect x="4.5" y="4.5" width="11" height="11" rx="2.4" fill="currentColor"/></svg>';

  const prefersReducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const PRESET_VALUES = [40, 60, 110];

  let ws = null;
  let audioCtx = null;
  let gainNode = null;
  let analyserNode = null;
  let silentKeepAliveAudio = null;
  let wakeLock = null;

  let isListening = false;
  let reconnectTimer = null;
  let pingTimer = null;
  let rafId = null;

  let sampleRate = 48000;
  let channels = 2;
  let targetBufferMs = Number(bufferSlider.value) || 60;
  let nextPlayTime = 0;
  let activeSources = new Set();
  let lastSeq = null;
  let smoothEnergy = 0;

  // MARK: - Hydrate Mac Hostname & Initial State

  fetch('/api/info', { cache: 'no-store' })
    .then((r) => (r.ok ? r.json() : null))
    .then((info) => {
      if (!info) return;
      if (info.hostname) {
        macNameEl.textContent = info.hostname.replace(/\.local$/i, '');
      }
      if (typeof info.mutedMac === 'boolean') {
        muteMacToggle.checked = info.mutedMac;
      }
      if (info.sampleRate && info.channels) {
        sampleRate = info.sampleRate;
        channels = info.channels;
        updateFormatLabel();
      }
    })
    .catch(() => {});

  function updateFormatLabel() {
    const khz = (sampleRate / 1000).toFixed(sampleRate % 1000 ? 1 : 0);
    const chLabel = channels === 2 ? 'Stereo' : channels === 1 ? 'Mono' : `${channels}ch`;
    statFormat.textContent = `${khz} kHz ${chLabel}`;
  }

  // MARK: - Slider & Segmented Control Sync

  function syncRangeProgress(slider) {
    const min = Number(slider.min) || 0;
    const max = Number(slider.max) || 100;
    const val = Number(slider.value);
    const pct = Math.max(0, Math.min(100, ((val - min) / (max - min)) * 100));
    slider.style.setProperty('--progress', `${pct}%`);
  }

  function syncVolumeUI() {
    syncRangeProgress(volumeSlider);
    volumeOutput.textContent = `${volumeSlider.value}%`;
    volumeSlider.setAttribute('aria-valuetext', `${volumeSlider.value} percent`);
  }

  function syncBufferUI() {
    const ms = Number(bufferSlider.value);
    targetBufferMs = ms;
    syncRangeProgress(bufferSlider);
    bufferOutput.textContent = `${ms} ms`;
    bufferSlider.setAttribute('aria-valuetext', `${ms} milliseconds`);

    const presetIndex = PRESET_VALUES.indexOf(ms);
    if (presetIndex >= 0) {
      segmentedThumb.style.opacity = '1';
      segmentedThumb.style.transform = `translateX(${presetIndex * 100}%)`;
    } else {
      segmentedThumb.style.opacity = '0';
    }
    segmentBtns.forEach((btn, idx) => {
      btn.setAttribute('aria-checked', idx === presetIndex ? 'true' : 'false');
    });
  }

  syncVolumeUI();
  syncBufferUI();

  volumeSlider.addEventListener('input', () => {
    syncVolumeUI();
    if (gainNode && audioCtx) {
      gainNode.gain.setTargetAtTime(Number(volumeSlider.value) / 100, audioCtx.currentTime, 0.015);
    }
  });

  volumeSlider.addEventListener('pointerdown', () => {
    volumeScrubberWrap.classList.add('scrubbing');
  });
  const endScrub = () => volumeScrubberWrap.classList.remove('scrubbing');
  volumeSlider.addEventListener('pointerup', endScrub);
  volumeSlider.addEventListener('pointercancel', endScrub);

  bufferSlider.addEventListener('input', syncBufferUI);

  segmentBtns.forEach((btn) => {
    btn.addEventListener('click', () => {
      bufferSlider.value = btn.dataset.ms;
      syncBufferUI();
    });
  });

  muteMacToggle.addEventListener('change', () => {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'setMuteMac', muted: muteMacToggle.checked }));
    }
  });

  // MARK: - UI State Helpers

  function setStatus(state, text) {
    statusBadge.dataset.state = state;
    appShell.dataset.state = state;
    document.body.dataset.state = state;
    statusText.textContent = text;
  }

  function showError(msg) {
    if (!msg) {
      errorBanner.hidden = true;
      errorText.textContent = '';
      return;
    }
    errorBanner.hidden = false;
    errorText.textContent = msg;
  }

  function updateButtonUI() {
    playBtn.dataset.active = isListening ? 'true' : 'false';
    playIcon.innerHTML = isListening ? STOP_SVG : PLAY_SVG;
    playLabel.textContent = isListening ? 'Stop Listening' : 'Start Listening';
    stageTrigger.setAttribute('aria-label', isListening ? 'Stop listening' : 'Start listening');
  }

  // MARK: - iOS Safari Silent-Switch Audio Session Unlocker

  function createSilentWavBlobUrl() {
    const numSamples = 2000;
    const buffer = new ArrayBuffer(44 + numSamples);
    const view = new DataView(buffer);
    const writeStr = (offset, str) => {
      for (let i = 0; i < str.length; i++) view.setUint8(offset + i, str.charCodeAt(i));
    };
    writeStr(0, 'RIFF');
    view.setUint32(4, 36 + numSamples, true);
    writeStr(8, 'WAVE');
    writeStr(12, 'fmt ');
    view.setUint32(16, 16, true);
    view.setUint16(20, 1, true);
    view.setUint16(22, 1, true);
    view.setUint32(24, 8000, true);
    view.setUint32(28, 8000, true);
    view.setUint16(32, 1, true);
    view.setUint16(34, 8, true);
    writeStr(36, 'data');
    view.setUint32(40, numSamples, true);
    new Uint8Array(buffer, 44).fill(128);
    return URL.createObjectURL(new Blob([buffer], { type: 'audio/wav' }));
  }

  function startIosPlaybackSession() {
    if (typeof navigator !== 'undefined' && 'audioSession' in navigator) {
      try {
        navigator.audioSession.type = 'playback';
        return;
      } catch {}
    }

    if (!silentKeepAliveAudio) {
      silentKeepAliveAudio = document.createElement('audio');
      silentKeepAliveAudio.src = createSilentWavBlobUrl();
      silentKeepAliveAudio.loop = true;
      silentKeepAliveAudio.playsInline = true;
      silentKeepAliveAudio.setAttribute('playsinline', '');
      silentKeepAliveAudio.volume = 0.01;
    }
    silentKeepAliveAudio.play().catch(() => {});
  }

  function stopIosPlaybackSession() {
    if (silentKeepAliveAudio) {
      silentKeepAliveAudio.pause();
    }
  }

  async function requestWakeLock() {
    try {
      if ('wakeLock' in navigator && !wakeLock) {
        wakeLock = await navigator.wakeLock.request('screen');
        wakeLock.addEventListener('release', () => {
          wakeLock = null;
        });
      }
    } catch {}
  }

  function releaseWakeLock() {
    if (wakeLock) {
      wakeLock.release().catch(() => {});
      wakeLock = null;
    }
  }

  // MARK: - Web Audio PCM Jitter-Buffered Playback

  function unlockAudioContext() {
    if (!audioCtx) return;
    try {
      const silentBuf = audioCtx.createBuffer(1, 1, audioCtx.sampleRate || 48000);
      const src = audioCtx.createBufferSource();
      src.buffer = silentBuf;
      src.connect(audioCtx.destination);
      src.start(0);
    } catch {}
  }

  function ensureAudioContext(fromGesture = false) {
    const AudioCtx = window.AudioContext || window.webkitAudioContext;
    if (!audioCtx) {
      audioCtx = new AudioCtx({ latencyHint: 'interactive' });
      gainNode = audioCtx.createGain();
      gainNode.gain.value = Number(volumeSlider.value) / 100;

      analyserNode = audioCtx.createAnalyser();
      analyserNode.fftSize = 256;
      analyserNode.smoothingTimeConstant = 0.78;

      gainNode.connect(analyserNode);
      analyserNode.connect(audioCtx.destination);

      audioCtx.addEventListener('statechange', () => {
        if (!isListening || !audioCtx) return;
        if (audioCtx.state === 'running') {
          if (errorText.textContent === 'iPhone audio paused — tap anywhere to resume.') {
            showError('');
          }
        } else if (audioCtx.state === 'suspended' || audioCtx.state === 'interrupted') {
          audioCtx.resume().catch(() => {});
        }
      });
    }

    if (fromGesture) {
      unlockAudioContext();
    }

    if (audioCtx.state !== 'running') {
      audioCtx.resume().catch(() => {});
    }
  }

  function stopAllAudioSources() {
    for (const src of activeSources) {
      try {
        src.stop();
        src.disconnect();
      } catch {}
    }
    activeSources.clear();
    nextPlayTime = 0;
    lastSeq = null;
  }

  function handlePcmPacket(arrayBuffer) {
    if (!isListening || !audioCtx) return;
    if (audioCtx.state !== 'running') {
      statBuffer.textContent = 'Paused';
      audioCtx.resume().catch(() => {});
      if (errorBanner.hidden) {
        showError('iPhone audio paused — tap anywhere to resume.');
      }
      return;
    }
    if (arrayBuffer.byteLength <= 4) return;

    const headerView = new DataView(arrayBuffer, 0, 4);
    const seq = headerView.getUint32(0, true);
    lastSeq = seq;

    const int16 = new Int16Array(arrayBuffer, 4);
    const frameCount = Math.floor(int16.length / channels);
    if (frameCount <= 0) return;

    const audioBuffer = audioCtx.createBuffer(channels, frameCount, sampleRate);
    const invScale = 1 / 32768;

    if (channels === 2) {
      const left = audioBuffer.getChannelData(0);
      const right = audioBuffer.getChannelData(1);
      for (let i = 0, j = 0; i < frameCount; i++, j += 2) {
        left[i] = int16[j] * invScale;
        right[i] = int16[j + 1] * invScale;
      }
    } else {
      for (let ch = 0; ch < channels; ch++) {
        const chData = audioBuffer.getChannelData(ch);
        for (let i = 0; i < frameCount; i++) {
          chData[i] = int16[i * channels + ch] * invScale;
        }
      }
    }

    const now = audioCtx.currentTime;
    const targetSec = targetBufferMs / 1000;
    let bufferedSec = nextPlayTime - now;

    let needsFadeIn = false;
    if (nextPlayTime === 0 || bufferedSec < 0.004 || bufferedSec > targetSec + 0.14) {
      nextPlayTime = now + targetSec;
      bufferedSec = targetSec;
      needsFadeIn = true;
    }

    if (needsFadeIn) {
      const fadeFrames = Math.min(frameCount, Math.floor(sampleRate * 0.004));
      for (let ch = 0; ch < channels; ch++) {
        const chData = audioBuffer.getChannelData(ch);
        for (let i = 0; i < fadeFrames; i++) {
          chData[i] *= i / fadeFrames;
        }
      }
    }

    const drift = bufferedSec - targetSec;
    let playbackRate = 1.0;
    if (Math.abs(drift) > 0.012) {
      playbackRate = Math.max(0.985, Math.min(1.015, 1.0 + drift * 0.12));
    }

    const source = audioCtx.createBufferSource();
    source.buffer = audioBuffer;
    source.playbackRate.value = playbackRate;
    source.connect(gainNode);
    source.start(nextPlayTime);

    activeSources.add(source);
    source.onended = () => {
      activeSources.delete(source);
      source.disconnect();
    };

    nextPlayTime += audioBuffer.duration / playbackRate;
    statBuffer.textContent = `${Math.max(0, Math.round((nextPlayTime - audioCtx.currentTime) * 1000))} ms`;
  }

  // MARK: - Radial Acoustic Stage Visualizer

  function drawMeter() {
    const w = meterCanvas.width;
    const h = meterCanvas.height;
    const cx = w / 2;
    const cy = h / 2;
    meterCtx.clearRect(0, 0, w, h);

    const isDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
    const accentRGB = isDark ? '10, 132, 255' : '0, 122, 255';
    const liveRGB = isDark ? '48, 209, 88' : '52, 199, 89';

    let bins = null;
    let avgEnergy = 0;
    if (isListening && analyserNode) {
      bins = new Uint8Array(analyserNode.frequencyBinCount);
      analyserNode.getByteFrequencyData(bins);
      let sum = 0;
      const sampleEnd = Math.min(bins.length, 48);
      for (let i = 0; i < sampleEnd; i++) sum += bins[i];
      avgEnergy = sum / (sampleEnd * 255);
    }

    smoothEnergy += (avgEnergy - smoothEnergy) * 0.18;
    if (!prefersReducedMotion) {
      document.documentElement.style.setProperty('--audio-energy', smoothEnergy.toFixed(3));
    }

    // Concentric acoustic halos
    const baseRadius = w * 0.24;
    for (let rIdx = 0; rIdx < 3; rIdx++) {
      const expand = prefersReducedMotion ? 0 : smoothEnergy * (22 + rIdx * 16);
      const radius = baseRadius + 30 + rIdx * 36 + expand;
      const alpha = isListening
        ? Math.max(0.04, (0.22 - rIdx * 0.055) + smoothEnergy * 0.22)
        : 0.09 - rIdx * 0.024;
      meterCtx.beginPath();
      meterCtx.arc(cx, cy, radius, 0, Math.PI * 2);
      meterCtx.strokeStyle = `rgba(${isListening && smoothEnergy > 0.05 ? liveRGB : accentRGB}, ${alpha.toFixed(3)})`;
      meterCtx.lineWidth = rIdx === 0 ? 2.2 : 1.5;
      meterCtx.stroke();
    }

    // 48-spoke radial audio ticks around medallion
    const spokeCount = 48;
    const innerR = baseRadius + 14;
    const maxLen = w * 0.16;

    meterCtx.lineCap = 'round';
    for (let i = 0; i < spokeCount; i++) {
      const angle = (i / spokeCount) * Math.PI * 2 - Math.PI / 2;
      let mag = 0.06;
      if (bins) {
        // Mirror spectrum cleanly left/right for balanced symmetry
        const mirrorIdx = i < spokeCount / 2 ? i : spokeCount - 1 - i;
        const binIdx = Math.min(bins.length - 1, Math.floor((mirrorIdx / (spokeCount / 2)) * (bins.length * 0.55)));
        mag = Math.max(0.06, Math.pow(bins[binIdx] / 255, 1.15));
      }
      const len = prefersReducedMotion ? 10 : 8 + mag * maxLen;
      const x1 = cx + Math.cos(angle) * innerR;
      const y1 = cy + Math.sin(angle) * innerR;
      const x2 = cx + Math.cos(angle) * (innerR + len);
      const y2 = cy + Math.sin(angle) * (innerR + len);

      const active = isListening && mag > 0.1;
      const opacity = active ? Math.min(0.95, 0.35 + mag * 0.65) : (isDark ? 0.14 : 0.12);
      meterCtx.strokeStyle = active
        ? `rgba(${accentRGB}, ${opacity.toFixed(3)})`
        : `rgba(${isDark ? '255, 255, 255' : '0, 0, 0'}, ${opacity.toFixed(3)})`;
      meterCtx.lineWidth = 4.2;
      meterCtx.beginPath();
      meterCtx.moveTo(x1, y1);
      meterCtx.lineTo(x2, y2);
      meterCtx.stroke();
    }

    if (isListening) {
      rafId = requestAnimationFrame(drawMeter);
    } else {
      rafId = null;
      document.documentElement.style.setProperty('--audio-energy', '0');
    }
  }

  drawMeter();

  // MARK: - WebSocket Connection Management

  function connectWebSocket() {
    if (!isListening) return;
    clearTimeout(reconnectTimer);

    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    setStatus('connecting', 'Connecting…');
    showError('');

    const socket = new WebSocket(`${proto}//${location.host}/ws`);
    socket.binaryType = 'arraybuffer';
    ws = socket;

    socket.addEventListener('open', () => {
      if (ws !== socket) return;
      setStatus('live', 'Live');
      socket.send(JSON.stringify({ type: 'setMuteMac', muted: muteMacToggle.checked }));

      clearInterval(pingTimer);
      const sendPing = () => {
        if (socket.readyState === WebSocket.OPEN) {
          socket.send(JSON.stringify({ type: 'ping', t: performance.now() }));
        }
      };
      sendPing();
      pingTimer = setInterval(sendPing, 2000);
    });

    socket.addEventListener('message', (event) => {
      if (ws !== socket) return;
      if (event.data instanceof ArrayBuffer) {
        handlePcmPacket(event.data);
        return;
      }
      try {
        const msg = JSON.parse(event.data);
        if (msg.type === 'config') {
          if (msg.sampleRate) sampleRate = msg.sampleRate;
          if (msg.channels) channels = msg.channels;
          if (typeof msg.mutedMac === 'boolean') muteMacToggle.checked = msg.mutedMac;
          updateFormatLabel();
          if (msg.error) {
            showError(msg.error);
            setStatus('error', 'Permission Needed');
          } else if (msg.warning) {
            showError(msg.warning);
            setStatus('error', 'Permission Needed');
          }
        } else if (msg.type === 'warning') {
          if (msg.message) {
            showError(msg.message);
            setStatus('error', 'Permission Needed');
          } else {
            showError('');
            if (isListening) setStatus('live', 'Live');
          }
        } else if (msg.type === 'muteState') {
          muteMacToggle.checked = Boolean(msg.mutedMac);
        } else if (msg.type === 'pong') {
          const rtt = Math.max(1, Math.round(performance.now() - msg.t));
          statPing.textContent = `${rtt} ms`;
        } else if (msg.type === 'error') {
          showError(msg.message || 'Mac audio capture error.');
          setStatus('error', 'Capture Error');
        }
      } catch {}
    });

    socket.addEventListener('close', () => {
      if (ws !== socket) return;
      ws = null;
      clearInterval(pingTimer);
      stopAllAudioSources();
      statBuffer.textContent = '-- ms';
      statPing.textContent = '-- ms';

      if (isListening) {
        setStatus('connecting', 'Reconnecting…');
        reconnectTimer = setTimeout(connectWebSocket, 1200);
      } else {
        setStatus('idle', 'Ready');
      }
    });

    socket.addEventListener('error', () => {
      if (ws !== socket) return;
      socket.close();
    });
  }

  // MARK: - Start / Stop Controls

  function startListening() {
    isListening = true;
    updateButtonUI();
    startIosPlaybackSession();
    ensureAudioContext(true);
    requestWakeLock();
    connectWebSocket();
    if (!rafId) drawMeter();
  }

  function stopListening() {
    isListening = false;
    clearTimeout(reconnectTimer);
    clearInterval(pingTimer);
    updateButtonUI();
    stopAllAudioSources();
    stopIosPlaybackSession();
    releaseWakeLock();

    if (ws) {
      const s = ws;
      ws = null;
      s.close(1000);
    }

    setStatus('idle', 'Ready');
    showError('');
    statBuffer.textContent = '-- ms';
    statPing.textContent = '-- ms';
    smoothEnergy = 0;
    drawMeter();
  }

  const toggleListening = () => {
    if (isListening) stopListening();
    else startListening();
  };

  playBtn.addEventListener('click', toggleListening);
  stageTrigger.addEventListener('click', toggleListening);

  document.addEventListener('pointerdown', () => {
    if (isListening && audioCtx && audioCtx.state !== 'running') {
      startIosPlaybackSession();
      ensureAudioContext(true);
    }
  });

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible' && isListening) {
      ensureAudioContext(false);
      requestWakeLock();
    }
  });
})();
