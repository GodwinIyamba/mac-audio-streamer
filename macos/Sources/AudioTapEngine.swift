import CoreAudio
import Foundation

struct AudioFormatConfig: Sendable, Equatable {
    var sampleRate: Int = 48_000
    var channels: Int = 2
    var framesPerChunk: Int = 960
}

final class AudioTapEngine {
    private let stateQueue = DispatchQueue(label: "com.audiostreamer.tap.state")
    private let ioQueue = DispatchQueue(label: "com.audiostreamer.tap.io", qos: .userInteractive)

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var tapDescription: CATapDescription?
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false

    private var pcmBuffer: [Int16] = []
    private var targetSamplesPerChunk: Int = 960 * 2
    private var currentConfig = AudioFormatConfig()
    private var muteMac: Bool = true

    private var hasReceivedSignal = false
    private var silentChunks = 0
    private var sentSilenceWarning = false

    var onPCMChunk: ((Data, Float) -> Void)?
    var onReady: ((AudioFormatConfig, Bool) -> Void)?
    var onMuteChanged: ((Bool) -> Void)?
    var onWarning: ((String?) -> Void)?
    var onError: ((String) -> Void)?

    // MARK: - Public Controls

    func start(muteMac: Bool) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.muteMac = muteMac
            if self.isRunning { return }
            _ = self.startLocked(emitReady: true)
        }
    }

    func stop() {
        stateQueue.async { [weak self] in
            self?.stopLocked()
        }
    }

    func stopSynchronously() {
        stateQueue.sync {
            self.stopLocked()
        }
    }

    func setMuteMac(_ muted: Bool) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            if muted == self.muteMac {
                self.onMuteChanged?(muted)
                return
            }

            if !self.isRunning {
                self.muteMac = muted
                self.onMuteChanged?(muted)
                return
            }

            // First try live mutation of kAudioTapPropertyDescription.
            if self.tapID != kAudioObjectUnknown, let desc = self.tapDescription {
                let previousBehavior = desc.muteBehavior
                desc.muteBehavior = muted ? .mutedWhenTapped : .unmuted
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioTapPropertyDescription,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var unmanagedDesc: Unmanaged<CATapDescription> = Unmanaged.passUnretained(desc)
                let size = UInt32(MemoryLayout<Unmanaged<CATapDescription>>.size)
                let status = AudioObjectSetPropertyData(self.tapID, &address, 0, nil, size, &unmanagedDesc)
                if status == noErr {
                    self.muteMac = muted
                    self.onMuteChanged?(muted)
                    return
                }
                desc.muteBehavior = previousBehavior
            }

            // macOS often rejects live kAudioTapPropertyDescription updates with '!hog'.
            // Recreate the tap cleanly with the new muteBehavior.
            let previousMute = self.muteMac
            self.muteMac = muted
            self.stopLocked()
            if self.startLocked(emitReady: false) {
                self.onMuteChanged?(muted)
            } else {
                self.muteMac = previousMute
                _ = self.startLocked(emitReady: false)
                self.onError?("Failed to update Mac speaker mute state.")
            }
        }
    }

    // MARK: - CoreAudio Lifecycle (called on stateQueue)

    private func startLocked(emitReady: Bool) -> Bool {
        guard let outputDeviceID = Self.getDefaultOutputDeviceID(),
              let outputUID = Self.getDeviceUID(outputDeviceID) else {
            onError?("Could not find default macOS audio output device.")
            return false
        }

        let excludedProcesses: [AudioObjectID] = Self.getProcessObjectID(for: getpid()).map { [$0] } ?? []
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedProcesses)
        let tapUUID = UUID()
        desc.uuid = tapUUID
        desc.name = "Mac Audio Speaker Tap"
        desc.isPrivate = true
        desc.muteBehavior = muteMac ? .mutedWhenTapped : .unmuted
        self.tapDescription = desc

        var createdTapID: AudioObjectID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(desc, &createdTapID)
        guard tapStatus == noErr, createdTapID != kAudioObjectUnknown else {
            onError?(
                "Audio tap permission needed (status \(tapStatus)). Enable Mac Audio Speaker in System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only."
            )
            return false
        }
        self.tapID = createdTapID

        guard let tapFormat = Self.getTapFormat(createdTapID) else {
            onError?("Failed to read Core Audio tap format.")
            stopLocked()
            return false
        }

        let sampleRate = tapFormat.mSampleRate > 0 ? tapFormat.mSampleRate : 48_000.0
        let channels = max(1, Int(tapFormat.mChannelsPerFrame))
        let framesPerChunk = max(256, Int((sampleRate * 0.02).rounded())) // ~20ms
        let newConfig = AudioFormatConfig(
            sampleRate: Int(sampleRate.rounded()),
            channels: channels,
            framesPerChunk: framesPerChunk
        )

        ioQueue.sync {
            self.targetSamplesPerChunk = framesPerChunk * channels
            self.pcmBuffer.removeAll(keepingCapacity: true)
            self.pcmBuffer.reserveCapacity(self.targetSamplesPerChunk * 2)
            self.hasReceivedSignal = false
            self.silentChunks = 0
            self.sentSilenceWarning = false
        }

        let aggregateDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mac Audio Speaker Aggregate",
            kAudioAggregateDeviceUIDKey: "com.audiostreamer.app.aggregate.\(UUID().uuidString)",
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
            onError?("Failed to create Core Audio aggregate device (status \(aggStatus)).")
            stopLocked()
            return false
        }
        self.aggregateDeviceID = aggID

        let isFloat = (tapFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        var procID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, ioQueue) { [weak self] _, inInputData, _, _, _ in
            self?.handleInput(
                inInputData,
                isFloat: isFloat,
                isNonInterleaved: isNonInterleaved,
                channels: channels
            )
        }
        guard procStatus == noErr, let procID else {
            onError?("Failed to attach audio capture callback (status \(procStatus)).")
            stopLocked()
            return false
        }
        self.ioProcID = procID

        let startStatus = AudioDeviceStart(aggID, procID)
        guard startStatus == noErr else {
            onError?("Failed to start audio capture (status \(startStatus)).")
            stopLocked()
            return false
        }

        self.isRunning = true
        let formatChanged = newConfig != currentConfig
        self.currentConfig = newConfig
        if emitReady || formatChanged {
            onReady?(newConfig, muteMac)
        }
        return true
    }

    private func stopLocked() {
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
            hasReceivedSignal = false
            silentChunks = 0
            sentSilenceWarning = false
        }
    }

    // MARK: - Audio Callback (called on ioQueue)

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
            let buf = bufferList[0]
            guard let raw = buf.mData else { return }
            let sampleCount = Int(buf.mDataByteSize) / MemoryLayout<Int16>.size
            let ints = raw.assumingMemoryBound(to: Int16.self)
            pcmBuffer.append(contentsOf: UnsafeBufferPointer(start: ints, count: sampleCount))
        }

        while pcmBuffer.count >= targetSamplesPerChunk {
            let chunkCount = targetSamplesPerChunk
            var maxAbsSample: Int32 = 0
            for i in 0..<chunkCount {
                let v = abs(Int32(pcmBuffer[i]))
                if v > maxAbsSample { maxAbsSample = v }
            }

            if !hasReceivedSignal {
                if maxAbsSample > 0 {
                    hasReceivedSignal = true
                    if sentSilenceWarning {
                        sentSilenceWarning = false
                        onWarning?(nil)
                    }
                } else {
                    silentChunks += 1
                    if !sentSilenceWarning && silentChunks >= 100 && silentChunks % 100 == 0 {
                        if Self.hasOtherActiveOutputProcess() {
                            sentSilenceWarning = true
                            onWarning?(
                                "Mac is capturing silence while audio is playing. Grant System Audio Recording permission to Mac Audio Speaker in System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only, then relaunch."
                            )
                        }
                    }
                }
            }

            let byteCount = chunkCount * MemoryLayout<Int16>.size
            let chunkData = pcmBuffer.withUnsafeBytes { rawBuf -> Data in
                guard let base = rawBuf.baseAddress else { return Data() }
                return Data(bytes: base, count: byteCount)
            }
            pcmBuffer.removeFirst(chunkCount)

            let normalizedPeak = min(1.0, Float(maxAbsSample) / 32767.0)
            onPCMChunk?(chunkData, normalizedPeak)
        }
    }

    // MARK: - CoreAudio Helpers

    private static func getDefaultOutputDeviceID() -> AudioDeviceID? {
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

    private static func getDeviceUID(_ deviceID: AudioDeviceID) -> String? {
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

    private static func getTapFormat(_ tapID: AudioObjectID) -> AudioStreamBasicDescription? {
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

    private static func getProcessObjectID(for pid: pid_t) -> AudioObjectID? {
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

    private static func hasOtherActiveOutputProcess() -> Bool {
        let myPID = getpid()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr, size > 0 else {
            return false
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var procs = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &procs
        ) == noErr else {
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
}
