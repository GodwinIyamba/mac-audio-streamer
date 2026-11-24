'use strict';

(() => {
  const chassis = document.querySelector('.chassis');
  const macNameEl = document.getElementById('mac-name');
  const stageTrigger = document.getElementById('stage-trigger');
  const playBtn = document.getElementById('play-btn');
  const playIcon = document.getElementById('play-icon');
  const playLabel = document.getElementById('play-label');
  const playSub = document.getElementById('play-sub');
  const statusBadge = document.getElementById('status-badge');
  const statusText = document.getElementById('status-text');
  const errorBanner = document.getElementById('error-banner');
  const errorText = document.getElementById('error-text');
  const statBuffer = document.getElementById('stat-buffer');
  const statPing = document.getElementById('stat-ping');
  const statFormat = document.getElementById('stat-format');
  const oledRouteState = document.getElementById('oled-route-state');
  const volumeSlider = document.getElementById('volume-slider');
  const volumeOutput = document.getElementById('volume-output');
  const bufferSlider = document.getElementById('buffer-slider');
  const bufferOutput = document.getElementById('buffer-output');
  const presetBtns = Array.from(document.querySelectorAll('.preset-key'));
  const muteMacToggle = document.getElementById('mute-mac-toggle');
  const muteSub = document.getElementById('mute-sub');
  const meterCanvas = document.getElementById('meter-canvas');
  const meterCtx = meterCanvas.getContext('2d');

  const PLAY_SVG =
    '<svg viewBox="0 0 18 18"><path d="M5 3.3l9.8 5.7L5 14.7V3.3z" fill="currentColor"/></svg>';
  const STOP_SVG =
    '<svg viewBox="0 0 18 18"><rect x="4" y="4" width="10" height="10" rx="1.5" fill="currentColor"/></svg>';

  const prefersReducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const BAR_COUNT = 36;
  const peakHold = new Float32Array(BAR_COUNT);

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
        syncMuteUI();
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
    statFormat.textContent = `${khz} kHz · ${channels}CH`;
  }

  // MARK: - Tactile Controls Sync

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

    presetBtns.forEach((btn) => {
      btn.setAttribute('aria-checked', Number(btn.dataset.ms) === ms ? 'true' : 'false');
    });
  }

  function syncMuteUI() {
    const muted = muteMacToggle.checked;
    muteSub.textContent = muted ? 'Speakers off' : 'Speakers on';
    if (isListening) {
      oledRouteState.textContent = muted ? 'MAC SPEAKERS MUTED' : 'MAC + IPHONE ACTIVE';
    } else {
      oledRouteState.textContent = muted ? 'MAC MUTED ON CONNECT' : 'DUAL OUTPUT ON CONNECT';
    }
  }

  syncVolumeUI();
  syncBufferUI();
  syncMuteUI();

  volumeSlider.addEventListener('input', () => {
    syncVolumeUI();
    if (gainNode && audioCtx) {
      gainNode.gain.setTargetAtTime(Number(volumeSlider.value) / 100, audioCtx.currentTime, 0.015);
    }
  });

  bufferSlider.addEventListener('input', syncBufferUI);

  presetBtns.forEach((btn) => {
    btn.addEventListener('click', () => {
      bufferSlider.value = btn.dataset.ms;
      syncBufferUI();
    });
  });

  muteMacToggle.addEventListener('change', () => {
    syncMuteUI();
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'setMuteMac', muted: muteMacToggle.checked }));
    }
  });

  // MARK: - UI State Helpers

  function setStatus(state, text) {
    statusBadge.dataset.state = state;
    chassis.dataset.state = state;
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
    playLabel.textContent = isListening ? 'Stop' : 'Listen';
    playSub.textContent = isListening ? 'Streaming live' : 'Connect to Mac';
    stageTrigger.setAttribute('aria-label', isListening ? 'Stop listening' : 'Start listening');
    syncMuteUI();
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
      analyserNode.smoothingTimeConstant = 0.72;

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
      statBuffer.textContent = 'PAUSED';
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

  // MARK: - Crisp Monochrome OLED Spectrum + Peak Hold

  function drawMeter() {
    const w = meterCanvas.width;
    const h = meterCanvas.height;
    meterCtx.clearRect(0, 0, w, h);

    // Subtle precision OLED grid hairlines
    meterCtx.strokeStyle = 'rgba(243, 243, 239, 0.08)';
    meterCtx.lineWidth = 1;
    for (let row = 1; row <= 3; row++) {
      const y = Math.round((h / 4) * row) + 0.5;
      meterCtx.beginPath();
      meterCtx.moveTo(0, y);
      meterCtx.lineTo(w, y);
      meterCtx.stroke();
    }

    let bins = null;
    if (isListening && analyserNode) {
      bins = new Uint8Array(analyserNode.frequencyBinCount);
      analyserNode.getByteFrequencyData(bins);
    }

    const padX = 4;
    const gap = 6;
    const barW = Math.floor((w - padX * 2 - gap * (BAR_COUNT - 1)) / BAR_COUNT);
    const totalW = barW * BAR_COUNT + gap * (BAR_COUNT - 1);
    const startX = Math.floor((w - totalW) / 2);
    const baselineY = h - 10;
    const maxBarH = h - 28;
    const segH = 8;
    const segGap = 4;

    for (let i = 0; i < BAR_COUNT; i++) {
      let level = 0;
      if (bins) {
        const idx = Math.min(bins.length - 1, Math.floor((i / BAR_COUNT) * (bins.length * 0.62)));
        level = bins[idx] / 255;
      }

      if (level > peakHold[i]) {
        peakHold[i] = level;
      } else {
        peakHold[i] = Math.max(0, peakHold[i] - 0.014);
      }

      const x = startX + i * (barW + gap);

      // Floor baseline dot
      meterCtx.fillStyle = isListening ? 'rgba(243, 243, 239, 0.22)' : 'rgba(243, 243, 239, 0.14)';
      meterCtx.fillRect(x, baselineY, barW, 3);

      if (!isListening || prefersReducedMotion) continue;

      // Crisp segmented OLED meter bars
      const activeH = Math.round(level * maxBarH);
      const segments = Math.floor(activeH / (segH + segGap));
      meterCtx.fillStyle = '#f3f3ef';
      for (let s = 0; s < segments; s++) {
        const sy = baselineY - (s + 1) * (segH + segGap);
        meterCtx.fillRect(x, sy, barW, segH);
      }

      // Single crisp Braun Signal-Orange peak-hold cap (zero glow)
      if (peakHold[i] > 0.06) {
        const peakY = Math.max(8, baselineY - Math.round(peakHold[i] * maxBarH) - segH);
        meterCtx.fillStyle = '#ff4f17';
        meterCtx.fillRect(x, peakY, barW, 4);
      }
    }

    if (isListening) {
      rafId = requestAnimationFrame(drawMeter);
    } else {
      peakHold.fill(0);
      rafId = null;
    }
  }

  drawMeter();

  // MARK: - WebSocket Connection Management

  function connectWebSocket() {
    if (!isListening) return;
    clearTimeout(reconnectTimer);

    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    setStatus('connecting', 'Syncing');
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
          if (typeof msg.mutedMac === 'boolean') {
            muteMacToggle.checked = msg.mutedMac;
            syncMuteUI();
          }
          updateFormatLabel();
          if (msg.error) {
            showError(msg.error);
            setStatus('error', 'Error');
          } else if (msg.warning) {
            showError(msg.warning);
            setStatus('error', 'Check Mac');
          }
        } else if (msg.type === 'warning') {
          if (msg.message) {
            showError(msg.message);
            setStatus('error', 'Check Mac');
          } else {
            showError('');
            if (isListening) setStatus('live', 'Live');
          }
        } else if (msg.type === 'muteState') {
          muteMacToggle.checked = Boolean(msg.mutedMac);
          syncMuteUI();
        } else if (msg.type === 'pong') {
          const rtt = Math.max(1, Math.round(performance.now() - msg.t));
          statPing.textContent = `${rtt} ms`;
        } else if (msg.type === 'error') {
          showError(msg.message || 'Mac audio capture error.');
          setStatus('error', 'Error');
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
        setStatus('connecting', 'Syncing');
        reconnectTimer = setTimeout(connectWebSocket, 1200);
      } else {
        setStatus('idle', 'Standby');
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

    setStatus('idle', 'Standby');
    showError('');
    statBuffer.textContent = '-- ms';
    statPing.textContent = '-- ms';
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
