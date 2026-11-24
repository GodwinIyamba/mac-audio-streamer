# Mac Audio Speaker

Stream your Mac's system audio straight to your iPhone over local WiFi. No iPhone app, no cables, and no virtual audio drivers like BlackHole needed.

I built this so I can play music or videos on my Mac and listen on my iPhone speaker with low latency, while automatically muting the Mac speakers when the phone connects (and restoring them the moment I stop).

## How it works

* **Mac menu bar app** (`dist/Mac Audio Speaker.app`): A standalone native Swift app that captures system audio using macOS's native Core Audio Process Tap and serves everything over your local WiFi. No Node.js needed once built.
* **iPhone web player** (`public/`): Opens right in Safari with a native iOS style interface featuring a reactive audio visualizer, volume scrubber, mute toggle, and sync latency presets (`Tight`, `Balanced`, `Stable`). Works even when your iPhone's Silent switch is on.
* **CLI mode** (`server.js` + `capture/audio_tap`): Lightweight Node.js fallback if you'd rather run it from your terminal.

## Requirements

* macOS 14.2 or newer (for Core Audio Process Taps)
* iPhone on the same WiFi network

## Using the Mac menu bar app

Build and launch the app:

```bash
npm run build:app
npm run app
```

1. Drag `dist/Mac Audio Speaker.app` into `/Applications` (recommended so macOS keeps your audio permission and Launch at Login working properly).
2. Click the AirPlay Audio icon in your menu bar.
3. Point your iPhone Camera at the QR code (or type the local URL into Safari) and tap **Start Listening**.
4. Tip: in Safari, tap **Share → Add to Home Screen** if you want it to open fullscreen like a native app.

> Make sure you stop `npm start` first if you were testing CLI mode, since both use port `8765`.

## Permission note (if you hear silence)

macOS doesn't always throw an error when **System Audio Recording** permission is missing. Instead, it just quietly streams silence. If music is playing on your Mac and you don't hear anything on your iPhone:

1. Open **System Settings → Privacy & Security → Screen & System Audio Recording**.
2. Scroll down to **System Audio Recording Only**.
3. Add and enable **Mac Audio Speaker** (or your terminal/IDE if you're using CLI mode).
4. Quit and reopen the app.

## Running from the terminal (CLI mode)

If you prefer running it directly with Node instead of the menu bar app:

```bash
npm start
```

Open the LAN URL printed in your terminal on your iPhone Safari and tap **Start Listening**.

If you edit `capture/audio_tap.swift`, rebuild the helper with:

```bash
npm run build:capture
```

## Project layout

* `macos/`: Native Swift menu bar app (`AudioTapEngine`, `LANAudioServer`, SwiftUI popover, icon generator, and build script)
* `public/`: iPhone Safari UI (`index.html`, `styles.css`, `app.js`)
* `server.js` & `capture/audio_tap.swift`: Optional Node.js CLI server and standalone capture binary
