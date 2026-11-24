import AppKit
import Combine
import Foundation
import ServiceManagement

@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    @Published var isServerRunning: Bool = false
    @Published var isStreaming: Bool = false
    @Published var listenerCount: Int = 0
    @Published var muteMac: Bool = true
    @Published var port: UInt16 = 8765
    @Published var lanAddresses: [LANAddress] = []
    @Published var selectedIP: String = ""
    @Published var formatConfig: AudioFormatConfig = AudioFormatConfig()
    @Published var audioLevel: Double = 0.0
    @Published var currentSource: AudioSourceInfo?
    @Published var warningMessage: String?
    @Published var errorMessage: String?
    @Published var copiedURL: Bool = false
    @Published var launchAtLogin: Bool = false

    private let tapEngine = AudioTapEngine()
    private let sourceTracker = AudioSourceTracker()
    private let server: LANAudioServer
    private var lastLevelUpdateTime: CFTimeInterval = 0
    private var levelDecayTimer: Timer?
    private var copiedResetWorkItem: DispatchWorkItem?

    var primaryURLString: String {
        let host = selectedIP.isEmpty ? (lanAddresses.first?.ip ?? "localhost") : selectedIP
        return "http://\(host):\(port)"
    }

    var formatSummary: String {
        let khz = Double(formatConfig.sampleRate) / 1000.0
        let khzText = formatConfig.sampleRate % 1000 == 0 ? String(format: "%.0f", khz) : String(format: "%.1f", khz)
        return "\(khzText) kHz · \(formatConfig.channels)ch"
    }

    var menuBarSymbol: String {
        if !isServerRunning {
            return "speaker.slash"
        }
        if errorMessage != nil || warningMessage != nil {
            return "exclamationmark.triangle"
        }
        return "airplayaudio"
    }

    var onStatusAppearanceChanged: (() -> Void)?

    init() {
        let publicDir = Self.resolvePublicDirectory()
        self.server = LANAudioServer(publicDir: publicDir)

        if let savedMute = UserDefaults.standard.object(forKey: "muteMac") as? Bool {
            self.muteMac = savedMute
        }
        if let envPortStr = ProcessInfo.processInfo.environment["PORT"],
           let envPort = Int(envPortStr),
           envPort >= 1024 && envPort <= 65535 {
            self.port = UInt16(envPort)
        } else {
            let savedPort = UserDefaults.standard.integer(forKey: "serverPort")
            if savedPort >= 1024 && savedPort <= 65535 {
                self.port = UInt16(savedPort)
            }
        }

        self.launchAtLogin = (SMAppService.mainApp.status == .enabled)

        wireCallbacks()
        refreshNetworkAddresses()
        startLevelDecayTimer()
        startServer()
    }

    // MARK: - Wiring

    private func wireCallbacks() {
        tapEngine.onPCMChunk = { [weak self] pcmData, peak in
            guard let self else { return }
            self.server.broadcastPCMChunk(pcmData)

            let now = CACurrentMediaTime()
            if now - self.lastLevelUpdateTime >= 0.05 { // ~20 fps UI meter
                self.lastLevelUpdateTime = now
                // Perceptual boost so normal music fills the meter nicely
                let boosted = min(1.0, pow(Double(peak), 0.6))
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.audioLevel = max(boosted, self.audioLevel * 0.65)
                }
            }
        }

        tapEngine.onReady = { [weak self] format, muted in
            guard let self else { return }
            self.server.updateCaptureReady(format: format, mutedMac: muted)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.formatConfig = format
                self.muteMac = muted
                self.isStreaming = true
                self.errorMessage = nil
                self.onStatusAppearanceChanged?()
            }
        }

        tapEngine.onMuteChanged = { [weak self] muted in
            guard let self else { return }
            self.server.updateMuteState(muted)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.muteMac = muted
                UserDefaults.standard.set(muted, forKey: "muteMac")
            }
        }

        tapEngine.onWarning = { [weak self] warning in
            guard let self else { return }
            self.server.updateWarning(warning)
            DispatchQueue.main.async { [weak self] in
                self?.warningMessage = warning
                self?.onStatusAppearanceChanged?()
            }
        }

        tapEngine.onError = { [weak self] message in
            guard let self else { return }
            self.server.updateError(message)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.errorMessage = message
                self.isStreaming = false
                self.audioLevel = 0
                self.onStatusAppearanceChanged?()
            }
        }

        server.onServerStateChanged = { [weak self] running, error in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isServerRunning = running
                if let error {
                    self.errorMessage = error
                } else if running {
                    self.errorMessage = nil
                }
                self.onStatusAppearanceChanged?()
            }
        }

        server.onListenerCountChanged = { [weak self] count in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.listenerCount = count
                if count == 0 {
                    self.audioLevel = 0
                }
                self.onStatusAppearanceChanged?()
            }
        }

        server.onNeedStartCapture = { [weak self] muted in
            self?.tapEngine.start(muteMac: muted)
            self?.sourceTracker.start()
        }

        server.onNeedStopCapture = { [weak self] in
            self?.tapEngine.stop()
            self?.sourceTracker.stop()
            self?.server.updateSource(nil)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isStreaming = false
                self.audioLevel = 0
                self.currentSource = nil
                self.warningMessage = nil
                self.onStatusAppearanceChanged?()
            }
        }

        sourceTracker.onSourceChanged = { [weak self] source in
            guard let self else { return }
            self.server.updateSource(source)
            DispatchQueue.main.async { [weak self] in
                self?.currentSource = source
            }
        }

        server.onClientSetMuteMac = { [weak self] desired in
            self?.tapEngine.setMuteMac(desired)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.muteMac = desired
                UserDefaults.standard.set(desired, forKey: "muteMac")
            }
        }
    }

    // MARK: - User Actions

    func startServer() {
        refreshNetworkAddresses()
        errorMessage = nil
        warningMessage = nil
        server.start(port: port, muteMac: muteMac)
    }

    func stopServer() {
        server.stop()
        tapEngine.stop()
        sourceTracker.stop()
        isServerRunning = false
        isStreaming = false
        listenerCount = 0
        audioLevel = 0
        currentSource = nil
        warningMessage = nil
        onStatusAppearanceChanged?()
    }

    func toggleServer(_ enabled: Bool) {
        if enabled {
            startServer()
        } else {
            stopServer()
        }
    }

    func setMuteMac(_ muted: Bool) {
        muteMac = muted
        UserDefaults.standard.set(muted, forKey: "muteMac")
        tapEngine.setMuteMac(muted)
        server.updateMuteState(muted)
    }

    func refreshNetworkAddresses() {
        let addresses = NetworkInfo.getLANAddresses()
        lanAddresses = addresses
        if !addresses.contains(where: { $0.ip == selectedIP }) {
            selectedIP = addresses.first?.ip ?? ""
        }
    }

    func copyURLToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(primaryURLString, forType: .string)
        copiedURL = true

        copiedResetWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.copiedURL = false
        }
        copiedResetWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    func openInBrowser() {
        if let url = URL(string: primaryURLString) {
            NSWorkspace.shared.open(url)
        }
    }

    func openSystemAudioPermissions() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ]
        for str in urls {
            if let url = URL(string: str), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        } catch {
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
            warningMessage = "Move Mac Audio Speaker.app to /Applications to enable Launch at Login."
        }
    }

    func shutdownSynchronously() {
        levelDecayTimer?.invalidate()
        levelDecayTimer = nil
        sourceTracker.stop()
        server.stopSynchronously()
        tapEngine.stopSynchronously()
    }

    // MARK: - Helpers

    private func startLevelDecayTimer() {
        levelDecayTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.isStreaming || self.listenerCount == 0 {
                    if self.audioLevel > 0 { self.audioLevel = 0 }
                    return
                }
                if CACurrentMediaTime() - self.lastLevelUpdateTime > 0.12 {
                    self.audioLevel = max(0, self.audioLevel * 0.72 - 0.01)
                }
            }
        }
    }

    private static func resolvePublicDirectory() -> URL {
        // 1. Inside .app bundle Resources/public
        if let resURL = Bundle.main.resourceURL {
            let bundled = resURL.appendingPathComponent("public", isDirectory: true)
            if FileManager.default.fileExists(atPath: bundled.appendingPathComponent("index.html").path) {
                return bundled
            }
        }
        // 2. Fallback to repo working directory public/
        let cwdPublic = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("public", isDirectory: true)
        return cwdPublic
    }
}
