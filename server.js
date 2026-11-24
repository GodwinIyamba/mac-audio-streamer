#!/usr/bin/env node
'use strict';

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');

const PORT = Number(process.env.PORT || process.argv.find((a) => /^\d+$/.test(a)) || 8765);
const PUBLIC_DIR = path.join(__dirname, 'public');
const CAPTURE_BIN = path.join(__dirname, 'capture', 'audio_tap');
const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

const MIME_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
};

// MARK: - Minimal RFC 6455 WebSocket Implementation (zero dependencies)

function encodeWsFrame(opcode, payloadBuf) {
  const payload = Buffer.isBuffer(payloadBuf) ? payloadBuf : Buffer.from(payloadBuf);
  const len = payload.length;
  let header;

  if (len < 126) {
    header = Buffer.allocUnsafe(2);
    header[0] = 0x80 | opcode;
    header[1] = len;
  } else if (len < 65536) {
    header = Buffer.allocUnsafe(4);
    header[0] = 0x80 | opcode;
    header[1] = 126;
    header.writeUInt16BE(len, 2);
  } else {
    header = Buffer.allocUnsafe(10);
    header[0] = 0x80 | opcode;
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(len), 2);
  }

  return Buffer.concat([header, payload]);
}

class WsClient {
  constructor(socket, remoteAddress) {
    this.socket = socket;
    this.remoteAddress = remoteAddress;
    this.closed = false;
    this.recvBuf = Buffer.alloc(0);
    this.onMessage = null;
    this.onClose = null;

    socket.setNoDelay(true);
    socket.on('data', (chunk) => this._onData(chunk));
    socket.on('close', () => this._handleClose());
    socket.on('error', () => this._handleClose());
  }

  sendJSON(obj) {
    if (this.closed || this.socket.destroyed) return;
    const frame = encodeWsFrame(0x1, Buffer.from(JSON.stringify(obj), 'utf8'));
    this.socket.write(frame);
  }

  sendBinaryFrame(preEncodedFrame) {
    if (this.closed || this.socket.destroyed) return;
    // Drop frame for slow clients rather than building latency backlog
    if (this.socket.writableLength > 65536) return;
    this.socket.write(preEncodedFrame);
  }

  close(code = 1000) {
    if (this.closed) return;
    this.closed = true;
    if (!this.socket.destroyed) {
      const payload = Buffer.allocUnsafe(2);
      payload.writeUInt16BE(code, 0);
      try {
        this.socket.end(encodeWsFrame(0x8, payload));
      } catch {}
    }
  }

  _handleClose() {
    if (this.closed) return;
    this.closed = true;
    if (this.onClose) this.onClose();
  }

  _onData(chunk) {
    this.recvBuf = this.recvBuf.length ? Buffer.concat([this.recvBuf, chunk]) : chunk;

    while (this.recvBuf.length >= 2) {
      const b0 = this.recvBuf[0];
      const b1 = this.recvBuf[1];
      const opcode = b0 & 0x0f;
      const masked = (b1 & 0x80) !== 0;
      let payloadLen = b1 & 0x7f;
      let offset = 2;

      if (payloadLen === 126) {
        if (this.recvBuf.length < 4) return;
        payloadLen = this.recvBuf.readUInt16BE(2);
        offset = 4;
      } else if (payloadLen === 127) {
        if (this.recvBuf.length < 10) return;
        payloadLen = Number(this.recvBuf.readBigUInt64BE(2));
        offset = 10;
      }

      const maskLen = masked ? 4 : 0;
      if (this.recvBuf.length < offset + maskLen + payloadLen) return;

      let maskKey = null;
      if (masked) {
        maskKey = this.recvBuf.subarray(offset, offset + 4);
        offset += 4;
      }

      const payload = Buffer.from(this.recvBuf.subarray(offset, offset + payloadLen));
      this.recvBuf = this.recvBuf.subarray(offset + payloadLen);

      if (masked && maskKey) {
        for (let i = 0; i < payload.length; i++) {
          payload[i] ^= maskKey[i & 3];
        }
      }

      if (opcode === 0x8) {
        this.close(1000);
        this._handleClose();
        return;
      } else if (opcode === 0x9) {
        if (!this.socket.destroyed) {
          this.socket.write(encodeWsFrame(0xA, payload));
        }
      } else if (opcode === 0x1) {
        if (this.onMessage) this.onMessage(payload.toString('utf8'));
      }
    }
  }
}

// MARK: - Native Audio Tap Process Manager

const clients = new Set();
let tapProc = null;
let stopTimer = null;
let muteMac = true;
let seq = 0;

let audioConfig = {
  sampleRate: 48000,
  channels: 2,
  framesPerChunk: 960,
  mutedMac: muteMac,
  capturing: false,
  error: null,
  warning: null,
};

let pcmRemainder = Buffer.alloc(0);

function broadcastJSON(obj) {
  for (const client of clients) {
    client.sendJSON(obj);
  }
}

function startCaptureIfNeeded() {
  if (stopTimer) {
    clearTimeout(stopTimer);
    stopTimer = null;
  }
  if (tapProc) return;

  if (!fs.existsSync(CAPTURE_BIN)) {
    const msg = 'Audio capture helper not compiled. Run: npm run build:capture';
    console.error(`[error] ${msg}`);
    audioConfig.error = msg;
    broadcastJSON({ type: 'error', message: msg });
    return;
  }

  audioConfig.error = null;
  audioConfig.warning = null;
  pcmRemainder = Buffer.alloc(0);
  const args = [muteMac ? '--mute-mac' : '--unmute-mac'];

  console.log(`[tap] Starting macOS system audio capture (muteMac=${muteMac})...`);
  const proc = spawn(CAPTURE_BIN, args, { stdio: ['pipe', 'pipe', 'pipe'] });
  tapProc = proc;

  let stderrBuf = '';
  proc.stderr.on('data', (chunk) => {
    stderrBuf += chunk.toString('utf8');
    const lines = stderrBuf.split('\n');
    stderrBuf = lines.pop() || '';
    for (const line of lines) {
      if (!line.trim()) continue;
      try {
        const msg = JSON.parse(line);
        if (msg.type === 'ready') {
          audioConfig = {
            sampleRate: msg.sampleRate || 48000,
            channels: msg.channels || 2,
            framesPerChunk: msg.framesPerChunk || 960,
            mutedMac: Boolean(msg.mutedMac),
            capturing: true,
            error: null,
            warning: null,
          };
          console.log(
            `[tap] Streaming ${audioConfig.sampleRate} Hz, ${audioConfig.channels}ch (${audioConfig.framesPerChunk} frames/chunk), Mac speakers ${audioConfig.mutedMac ? 'muted' : 'active'}`
          );
          broadcastJSON({ type: 'config', ...audioConfig });
        } else if (msg.type === 'muteState') {
          audioConfig.mutedMac = Boolean(msg.mutedMac);
          muteMac = audioConfig.mutedMac;
          console.log(
            `[tap] Mac speakers ${audioConfig.mutedMac ? 'muted' : 'active'}`
          );
          broadcastJSON({ type: 'muteState', mutedMac: audioConfig.mutedMac });
        } else if (msg.type === 'warning') {
          audioConfig.warning = msg.message || null;
          if (audioConfig.warning) {
            console.warn(`[tap warning] ${audioConfig.warning}`);
          } else {
            console.log('[tap] Audio signal detected.');
          }
          broadcastJSON({ type: 'warning', message: audioConfig.warning });
        } else if (msg.type === 'error') {
          audioConfig.error = msg.message;
          if (msg.fatal !== false) {
            audioConfig.capturing = false;
          }
          console.error(`[tap error] ${msg.message} (status=${msg.status ?? 'n/a'})`);
          broadcastJSON({ type: 'error', message: msg.message, status: msg.status });
        }
      } catch {
        console.error(`[tap stderr] ${line}`);
      }
    }
  });

  proc.stdout.on('data', (chunk) => {
    if (clients.size === 0) return;

    const bytesPerChunk = audioConfig.framesPerChunk * audioConfig.channels * 2;
    let combined = pcmRemainder.length ? Buffer.concat([pcmRemainder, chunk]) : chunk;

    while (combined.length >= bytesPerChunk) {
      const pcmSlice = combined.subarray(0, bytesPerChunk);
      combined = combined.subarray(bytesPerChunk);

      const packet = Buffer.allocUnsafe(4 + bytesPerChunk);
      packet.writeUInt32LE(seq >>> 0, 0);
      pcmSlice.copy(packet, 4);
      seq = (seq + 1) >>> 0;

      const wsFrame = encodeWsFrame(0x2, packet);
      for (const client of clients) {
        client.sendBinaryFrame(wsFrame);
      }
    }

    pcmRemainder = combined.length ? Buffer.from(combined) : Buffer.alloc(0);
  });

  proc.on('exit', (code, signal) => {
    if (tapProc === proc) {
      tapProc = null;
      audioConfig.capturing = false;
      console.log(`[tap] Stopped (code=${code}, signal=${signal})`);
    }
  });
}

function scheduleStopCapture() {
  if (clients.size > 0 || !tapProc) return;
  if (stopTimer) clearTimeout(stopTimer);
  stopTimer = setTimeout(() => {
    stopTimer = null;
    if (clients.size === 0 && tapProc) {
      console.log('[tap] No listeners connected — stopping capture & restoring Mac speakers.');
      stopCaptureNow();
    }
  }, 1500);
}

function stopCaptureNow() {
  if (!tapProc) return;
  const proc = tapProc;
  tapProc = null;
  audioConfig.capturing = false;
  try {
    proc.stdin.write('quit\n');
    proc.stdin.end();
  } catch {}
  setTimeout(() => {
    try {
      proc.kill('SIGTERM');
    } catch {}
  }, 300);
}

function setMuteMac(nextMuted) {
  const desired = Boolean(nextMuted);
  const changed = desired !== muteMac;
  muteMac = desired;
  audioConfig.mutedMac = desired;
  if (tapProc && tapProc.stdin.writable) {
    if (changed) {
      tapProc.stdin.write(desired ? 'mute\n' : 'unmute\n');
    } else {
      broadcastJSON({ type: 'muteState', mutedMac: desired });
    }
  } else {
    broadcastJSON({ type: 'muteState', mutedMac: desired });
  }
}

// MARK: - HTTP + WebSocket Server

function getLanAddresses() {
  const nets = os.networkInterfaces();
  const preferred = [];
  const others = [];
  for (const [name, addrs] of Object.entries(nets)) {
    if (!addrs) continue;
    for (const info of addrs) {
      if (info.family === 'IPv4' && !info.internal) {
        if (name === 'en0' || name === 'en1') preferred.push(info.address);
        else others.push(info.address);
      }
    }
  }
  return [...preferred, ...others];
}

const server = http.createServer((req, res) => {
  const urlPath = (req.url || '/').split('?')[0];

  if (urlPath === '/api/info') {
    const ips = getLanAddresses();
    res.writeHead(200, {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-store',
    });
    res.end(
      JSON.stringify({
        hostname: os.hostname(),
        ips,
        port: PORT,
        clients: clients.size,
        ...audioConfig,
      })
    );
    return;
  }

  let filePath = path.join(PUBLIC_DIR, urlPath === '/' ? 'index.html' : urlPath);
  const resolved = path.resolve(filePath);
  if (!resolved.startsWith(PUBLIC_DIR)) {
    res.writeHead(403);
    res.end('Forbidden');
    return;
  }

  fs.readFile(resolved, (err, content) => {
    if (err) {
      res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('Not found');
      return;
    }
    const ext = path.extname(resolved);
    res.writeHead(200, {
      'Content-Type': MIME_TYPES[ext] || 'application/octet-stream',
      'Cache-Control': 'no-store',
    });
    res.end(content);
  });
});

server.on('upgrade', (req, socket) => {
  const urlPath = (req.url || '/').split('?')[0];
  if (urlPath !== '/ws' || (req.headers.upgrade || '').toLowerCase() !== 'websocket') {
    socket.destroy();
    return;
  }

  const key = req.headers['sec-websocket-key'];
  if (!key) {
    socket.destroy();
    return;
  }

  const accept = crypto.createHash('sha1').update(key + WS_GUID).digest('base64');
  socket.write(
    [
      'HTTP/1.1 101 Switching Protocols',
      'Upgrade: websocket',
      'Connection: Upgrade',
      `Sec-WebSocket-Accept: ${accept}`,
      '',
      '',
    ].join('\r\n')
  );

  const client = new WsClient(socket, req.socket.remoteAddress || 'unknown');
  clients.add(client);
  console.log(`[ws] Listener connected (${client.remoteAddress}) — active listeners: ${clients.size}`);

  client.onMessage = (text) => {
    try {
      const msg = JSON.parse(text);
      if (msg.type === 'ping') {
        client.sendJSON({ type: 'pong', t: msg.t });
      } else if (msg.type === 'setMuteMac') {
        setMuteMac(Boolean(msg.muted));
      }
    } catch {}
  };

  client.onClose = () => {
    clients.delete(client);
    console.log(`[ws] Listener disconnected — active listeners: ${clients.size}`);
    scheduleStopCapture();
  };

  // Start system audio capture when first listener joins
  startCaptureIfNeeded();
  client.sendJSON({ type: 'config', ...audioConfig });
});

function cleanupAndExit() {
  console.log('\n[server] Shutting down...');
  for (const client of clients) {
    client.close(1001);
  }
  clients.clear();
  stopCaptureNow();
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 600);
}

process.on('SIGINT', cleanupAndExit);
process.on('SIGTERM', cleanupAndExit);

server.listen(PORT, '0.0.0.0', () => {
  const ips = getLanAddresses();
  const primaryIp = ips[0] || 'localhost';
  console.log('\n======================================================');
  console.log('  Mac → iPhone Audio Streamer');
  console.log('======================================================');
  console.log(`  Open this URL in iPhone Safari (same Wi-Fi):`);
  console.log(`  → http://${primaryIp}:${PORT}`);
  if (ips.length > 1) {
    for (const ip of ips.slice(1)) {
      console.log(`    (alt) http://${ip}:${PORT}`);
    }
  }
  console.log(`  Local test: http://localhost:${PORT}`);
  console.log('------------------------------------------------------');
  console.log('  Mac speakers stay normal until you tap Play on iPhone.');
  console.log('  Press Ctrl+C to stop.');
  console.log('======================================================\n');
});
