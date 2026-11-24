import CoreAudio
import Foundation

// MARK: - JSON stderr logging

func logJSON(_ dict: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: dict),
       var line = String(data: data, encoding: .utf8) {
        line.append("\n")
        if let bytes = line.data(using: .utf8) {
            FileHandle.standardError.write(bytes)
        }
    }
}

func logError(_ message: String, status: OSStatus? = nil) {
    var payload: [String: Any] = ["type": "error", "message": message]
    if let status {
        payload["status"] = Int(status)
    }
    logJSON(payload)
}

// MARK: - CoreAudio helpers

func getDefaultOutputDeviceID() -> AudioDeviceID? {
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &size,
        &deviceID
    )
    guard status == noErr, deviceID != kAudioObjectUnknown else {
        return nil
    }
    return deviceID
}

func getDeviceUID(_ deviceID: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var uid: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
    guard status == noErr, let cfStr = uid?.takeRetainedValue() else {
        return nil
    }
    return cfStr as String
}

func getTapFormat(_ tapID: AudioObjectID) -> AudioStreamBasicDescription? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var asbd = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
    guard status == noErr else {
        return nil
    }
    return asbd
}

func getProcessObjectID(for pid: pid_t) -> AudioObjectID? {
    var targetPID = pid
    var objID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        UInt32(MemoryLayout<pid_t>.size),
        &targetPID,
        &size,
        &objID
    )
    guard status == noErr, objID != kAudioObjectUnknown else {
        return nil
    }
    return objID
}

func hasOtherActiveOutputProcess() -> Bool {
    let myPID = getpid()
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
          size > 0 else {
        return false
    }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var procs = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &procs) == noErr else {
        return false
    }

    var runningAddr = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyIsRunningOutput,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var pidAddr = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyPID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    for proc in procs {
        var running: UInt32 = 0
        var rSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(proc, &runningAddr, 0, nil, &rSize, &running) == noErr,
              running != 0 else {
            continue
        }
        var pid: pid_t = 0
        var pSize = UInt32(MemoryLayout<pid_t>.size)
        if AudioObjectGetPropertyData(proc, &pidAddr, 0, nil, &pSize, &pid) == noErr, pid != myPID {
            return true
        }
    }
    return false
}

// MARK: - Tap Capture Controller

final class SystemAudioTap {
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var tapDescription: CATapDescription?
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "com.audiostreamer.tap.io", qos: .userInteractive)
    private var format = AudioStreamBasicDescription()
    private var isRunning = false

    // Chunk accumulator to send consistent ~20ms packets (e.g. 960 stereo frames at 48kHz)
    private var pcmBuffer = [Int16]()
    private var targetSamplesPerChunk: Int = 960 * 2
    private var lastSampleRate: Int = 0
    private var lastChannels: Int = 0
    private var lastFramesPerChunk: Int = 0
    private var hasReceivedSignal = false
    private var silentChunks = 0
    private var sentSilenceWarning = false
    private var muteMac: Bool

    init(muteMac: Bool) {
        self.muteMac = muteMac
    }

    func start(emitReady: Bool = true) -> Bool {
        guard let outputDeviceID = getDefaultOutputDeviceID(),
              let outputUID = getDeviceUID(outputDeviceID) else {
            logError("Could not find default macOS audio output device.")
            return false
        }

        let excludedProcesses: [AudioObjectID] = getProcessObjectID(for: getpid()).map { [$0] } ?? []
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedProcesses)
        let tapUUID = UUID()
        desc.uuid = tapUUID
        desc.name = "LAN Audio Streamer Tap"
        desc.isPrivate = true
        desc.muteBehavior = muteMac ? .mutedWhenTapped : .unmuted
        self.tapDescription = desc

        var createdTapID: AudioObjectID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(desc, &createdTapID)
        guard tapStatus == noErr, createdTapID != kAudioObjectUnknown else {
            logError(
                "AudioHardwareCreateProcessTap failed (check System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only).",
                status: tapStatus
            )
            return false
        }
        self.tapID = createdTapID

        guard let tapFormat = getTapFormat(createdTapID) else {
            logError("Failed to read tap audio format.")
            stop()
            return false
        }
        self.format = tapFormat

        let sampleRate = tapFormat.mSampleRate > 0 ? tapFormat.mSampleRate : 48000.0
        let channels = max(1, Int(tapFormat.mChannelsPerFrame))
        let framesPerChunk = max(256, Int((sampleRate * 0.02).rounded())) // ~20ms
        self.targetSamplesPerChunk = framesPerChunk * channels
        self.pcmBuffer.reserveCapacity(self.targetSamplesPerChunk * 2)

        let aggregateDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LAN Audio Streamer Aggregate",
            kAudioAggregateDeviceUIDKey: "com.audiostreamer.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUID.uuidString
                ]
            ]
        ]

        var aggID: AudioObjectID = kAudioObjectUnknown
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregateDesc as CFDictionary, &aggID)
        guard aggStatus == noErr, aggID != kAudioObjectUnknown else {
            logError("AudioHardwareCreateAggregateDevice failed.", status: aggStatus)
            stop()
            return false
        }
        self.aggregateDeviceID = aggID

        let isFloat = (tapFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        var procID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, ioQueue) { [weak self] _, inInputData, _, _, _ in
            guard let self else { return }
            self.handleInput(inInputData, isFloat: isFloat, isNonInterleaved: isNonInterleaved, channels: channels)
        }
        guard procStatus == noErr, let procID else {
            logError("AudioDeviceCreateIOProcIDWithBlock failed.", status: procStatus)
            stop()
            return false
        }
        self.ioProcID = procID

        let startStatus = AudioDeviceStart(aggID, procID)
        guard startStatus == noErr else {
            logError("AudioDeviceStart failed.", status: startStatus)
            stop()
            return false
        }

        self.isRunning = true
        let roundedSampleRate = Int(sampleRate.rounded())
        let formatChanged = roundedSampleRate != lastSampleRate
            || channels != lastChannels
            || framesPerChunk != lastFramesPerChunk
        lastSampleRate = roundedSampleRate
        lastChannels = channels
        lastFramesPerChunk = framesPerChunk

        if emitReady || formatChanged {
            logJSON([
                "type": "ready",
                "sampleRate": roundedSampleRate,
                "channels": channels,
                "framesPerChunk": framesPerChunk,
                "mutedMac": muteMac
            ])
        }
        return true
    }

    func setMuteMac(_ muted: Bool) {
        if muted == self.muteMac && isRunning {
            logJSON(["type": "muteState", "mutedMac": muted])
            return
        }

        // Try updating the tap description in-place first.
        if tapID != kAudioObjectUnknown, let desc = tapDescription {
            let previousBehavior = desc.muteBehavior
            desc.muteBehavior = muted ? .mutedWhenTapped : .unmuted
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyDescription,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var unmanagedDesc: Unmanaged<CATapDescription> = Unmanaged.passUnretained(desc)
            let size = UInt32(MemoryLayout<Unmanaged<CATapDescription>>.size)
            let status = AudioObjectSetPropertyData(tapID, &address, 0, nil, size, &unmanagedDesc)
            if status == noErr {
                self.muteMac = muted
                logJSON(["type": "muteState", "mutedMac": muted])
                return
            }
            desc.muteBehavior = previousBehavior
        }

        // macOS often rejects live kAudioTapPropertyDescription updates with
        // kAudioDevicePermissionsError ('!hog' / 560492391). Recreate the tap cleanly.
        let previousMute = self.muteMac
        self.muteMac = muted
        stop()
        if start(emitReady: false) {
            logJSON(["type": "muteState", "mutedMac": muted])
        } else {
            self.muteMac = previousMute
            _ = start(emitReady: false)
            logError("Failed to update Mac mute state.")
        }
    }

    private func handleInput(
        _ inputListPtr: UnsafePointer<AudioBufferList>,
        isFloat: Bool,
        isNonInterleaved: Bool,
        channels: Int
    ) {
        let bufferList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputListPtr))
        guard !bufferList.isEmpty else { return }

        if isFloat {
            if isNonInterleaved && bufferList.count >= channels {
                guard bufferList[0].mData != nil else { return }
                let frameCount = Int(bufferList[0].mDataByteSize) / MemoryLayout<Float>.size
                var chPointers: [UnsafeMutablePointer<Float>] = []
                chPointers.reserveCapacity(channels)
                for idx in 0..<channels {
                    guard let ptr = bufferList[idx].mData?.assumingMemoryBound(to: Float.self) else {
                        return
                    }
                    chPointers.append(ptr)
                }
                for frame in 0..<frameCount {
                    for ch in 0..<channels {
                        let sample = max(-1.0, min(1.0, chPointers[ch][frame]))
                        pcmBuffer.append(Int16((sample * 32767.0).rounded()))
                    }
                }
            } else {
                // Interleaved Float32
                let buf = bufferList[0]
                guard let raw = buf.mData else { return }
                let sampleCount = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
                let floats = raw.assumingMemoryBound(to: Float.self)
                for i in 0..<sampleCount {
                    let sample = max(-1.0, min(1.0, floats[i]))
                    pcmBuffer.append(Int16((sample * 32767.0).rounded()))
                }
            }
        } else {
            // Int16 fallback
            let buf = bufferList[0]
            guard let raw = buf.mData else { return }
            let sampleCount = Int(buf.mDataByteSize) / MemoryLayout<Int16>.size
            let ints = raw.assumingMemoryBound(to: Int16.self)
            pcmBuffer.append(contentsOf: UnsafeBufferPointer(start: ints, count: sampleCount))
        }

        while pcmBuffer.count >= targetSamplesPerChunk {
            let chunkCount = targetSamplesPerChunk
            if !hasReceivedSignal {
                var chunkHasSignal = false
                for i in 0..<chunkCount where pcmBuffer[i] != 0 {
                    chunkHasSignal = true
                    break
                }
                if chunkHasSignal {
                    hasReceivedSignal = true
                    if sentSilenceWarning {
                        sentSilenceWarning = false
                        logJSON(["type": "warning", "message": NSNull()])
                    }
                } else {
                    silentChunks += 1
                    // Check every ~2 seconds (100 chunks at 20ms) if another app is playing while tap gets pure zeros.
                    if !sentSilenceWarning && silentChunks >= 100 && silentChunks % 100 == 0 {
                        if hasOtherActiveOutputProcess() {
                            sentSilenceWarning = true
                            logJSON([
                                "type": "warning",
                                "message": "Mac is capturing silence while audio is playing. Grant System Audio Recording permission to your terminal/IDE app under System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only, then restart the server."
                            ])
                        }
                    }
                }
            }
            let byteCount = chunkCount * MemoryLayout<Int16>.size
            let ok = pcmBuffer.withUnsafeBytes { rawBuf -> Bool in
                guard let base = rawBuf.baseAddress else { return false }
                var written = 0
                while written < byteCount {
                    let n = Darwin.write(STDOUT_FILENO, base.advanced(by: written), byteCount - written)
                    if n <= 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    written += n
                }
                return true
            }
            if !ok {
                // Parent pipe closed; exit cleanly
                DispatchQueue.main.async {
                    self.stop()
                    exit(0)
                }
                return
            }
            pcmBuffer.removeFirst(chunkCount)
        }
    }

    func stop() {
        if isRunning, aggregateDeviceID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            isRunning = false
        }
        if aggregateDeviceID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        tapDescription = nil
        ioQueue.sync {
            pcmBuffer.removeAll(keepingCapacity: true)
        }
    }
}

// MARK: - Main Entry Point

signal(SIGPIPE, SIG_IGN)

var muteMac = true
for arg in CommandLine.arguments.dropFirst() {
    if arg == "--unmute-mac" { muteMac = false }
    if arg == "--mute-mac" { muteMac = true }
}

let controller = SystemAudioTap(muteMac: muteMac)

let sigIntSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
signal(SIGINT, SIG_IGN)
sigIntSource.setEventHandler {
    controller.stop()
    exit(0)
}
sigIntSource.resume()

let sigTermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
signal(SIGTERM, SIG_IGN)
sigTermSource.setEventHandler {
    controller.stop()
    exit(0)
}
sigTermSource.resume()

guard controller.start() else {
    exit(1)
}

// Listen for simple commands on stdin: "mute", "unmute", "quit"
DispatchQueue.global(qos: .utility).async {
    while let line = readLine(strippingNewline: true) {
        let cmd = line.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.main.async {
            switch cmd {
            case "mute":
                controller.setMuteMac(true)
            case "unmute":
                controller.setMuteMac(false)
            case "quit":
                controller.stop()
                exit(0)
            default:
                break
            }
        }
    }
    DispatchQueue.main.async {
        controller.stop()
        exit(0)
    }
}

dispatchMain()
