import AppKit
import CoreAudio
import Foundation

struct AudioSourceInfo: Equatable, Sendable {
    var app: String
    var title: String?
    var artist: String?
    var apps: [String]

    var dictionary: [String: Any] {
        var dict: [String: Any] = [
            "app": app,
            "apps": apps
        ]
        if let title, !title.isEmpty { dict["title"] = title }
        if let artist, !artist.isEmpty { dict["artist"] = artist }
        return dict
    }

    var compactSummary: String {
        if let title, !title.isEmpty {
            if let artist, !artist.isEmpty {
                return "\(app) · \(title) · \(artist)"
            }
            return "\(app) · \(title)"
        }
        return app
    }
}

final class AudioSourceTracker {
    private let queue = DispatchQueue(label: "com.audiostreamer.source.tracker", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastReported: AudioSourceInfo?
    private var deniedBundleIDs = Set<String>()

    var onSourceChanged: ((AudioSourceInfo?) -> Void)?

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: .seconds(2), leeway: .milliseconds(250))
            t.setEventHandler { [weak self] in
                self?.pollOnce()
            }
            self.timer = t
            t.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
            self.lastReported = nil
        }
    }

    func snapshotNow() -> AudioSourceInfo? {
        queue.sync {
            let active = detectActiveOutputApps()
            return buildSourceInfo(from: active)
        }
    }

    // MARK: - Polling

    private func pollOnce() {
        let active = detectActiveOutputApps()
        guard let primary = active.first else {
            if lastReported != nil {
                lastReported = nil
                onSourceChanged?(nil)
            }
            return
        }

        // Emit app name immediately when switching apps so UI never waits on Automation prompts
        let appNames = active.map(\.name)
        if lastReported?.app != primary.name {
            let quick = AudioSourceInfo(app: primary.name, title: nil, artist: nil, apps: appNames)
            lastReported = quick
            onSourceChanged?(quick)
        }

        let enriched = buildSourceInfo(from: active)
        if enriched != lastReported {
            lastReported = enriched
            onSourceChanged?(enriched)
        }
    }

    private struct ActiveApp {
        let name: String
        let bundleID: String
    }

    private func detectActiveOutputApps() -> [ActiveApp] {
        let myPID = getpid()
        let myBundleID = Bundle.main.bundleIdentifier ?? "com.audiostreamer.MacAudioSpeaker"

        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddr,
            0,
            nil,
            &size
        ) == noErr, size > 0 else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var procs = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddr,
            0,
            nil,
            &size,
            &procs
        ) == noErr else {
            return []
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
        var bundleAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var results: [ActiveApp] = []
        var seenNames = Set<String>()

        for proc in procs {
            var running: UInt32 = 0
            var rSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(proc, &runningAddr, 0, nil, &rSize, &running) == noErr,
                  running != 0 else {
                continue
            }

            var pid: pid_t = 0
            var pSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(proc, &pidAddr, 0, nil, &pSize, &pid) == noErr,
                  pid != myPID else {
                continue
            }

            var cfBundle: Unmanaged<CFString>?
            var bSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            _ = AudioObjectGetPropertyData(proc, &bundleAddr, 0, nil, &bSize, &cfBundle)
            let rawBundle = (cfBundle?.takeRetainedValue() as String?) ?? ""

            if rawBundle == myBundleID { continue }

            let runningApp = NSRunningApplication(processIdentifier: pid)
            let rawName = runningApp?.localizedName ?? ""
            let bundle = rawBundle.isEmpty ? (runningApp?.bundleIdentifier ?? "") : rawBundle

            let normalized = normalizeApp(name: rawName, bundleID: bundle)
            guard !normalized.name.isEmpty, !seenNames.contains(normalized.name) else {
                continue
            }
            seenNames.insert(normalized.name)
            results.append(normalized)
        }

        return results
    }

    private func normalizeApp(name: String, bundleID: String) -> ActiveApp {
        let lowerBundle = bundleID.lowercased()

        // Normalize browser / WebKit helper processes cleanly to parent app
        if lowerBundle.hasPrefix("com.google.chrome") {
            return ActiveApp(name: "Google Chrome", bundleID: "com.google.Chrome")
        }
        if lowerBundle.hasPrefix("com.apple.webkit") || lowerBundle.hasPrefix("com.apple.safari") {
            return ActiveApp(name: "Safari", bundleID: "com.apple.Safari")
        }
        if lowerBundle.hasPrefix("company.thebrowser") {
            return ActiveApp(name: "Arc", bundleID: "company.thebrowser.Browser")
        }
        if lowerBundle.hasPrefix("com.brave.browser") {
            return ActiveApp(name: "Brave", bundleID: "com.brave.Browser")
        }
        if lowerBundle.hasPrefix("com.microsoft.edgemac") {
            return ActiveApp(name: "Edge", bundleID: "com.microsoft.edgemac")
        }
        if lowerBundle.hasPrefix("org.mozilla.firefox") {
            return ActiveApp(name: "Firefox", bundleID: "org.mozilla.firefox")
        }
        if lowerBundle == "com.spotify.client" {
            return ActiveApp(name: "Spotify", bundleID: "com.spotify.client")
        }
        if lowerBundle == "com.apple.music" {
            return ActiveApp(name: "Music", bundleID: "com.apple.Music")
        }
        if lowerBundle == "org.videolan.vlc" {
            return ActiveApp(name: "VLC", bundleID: "org.videolan.vlc")
        }
        if lowerBundle == "com.apple.quicktimeplayerx" {
            return ActiveApp(name: "QuickTime", bundleID: "com.apple.QuickTimePlayerX")
        }

        var cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let helperRange = cleanedName.range(of: " Helper") {
            cleanedName = String(cleanedName[..<helperRange.lowerBound])
        }
        if cleanedName.isEmpty, let lastPart = bundleID.split(separator: ".").last {
            cleanedName = String(lastPart).capitalized
        }
        return ActiveApp(name: cleanedName, bundleID: bundleID)
    }

    private func buildSourceInfo(from activeApps: [ActiveApp]) -> AudioSourceInfo? {
        guard let primary = activeApps.first else {
            return nil
        }

        let appNames = activeApps.map(\.name)
        var title: String?
        var artist: String?

        // Query track/tab metadata only for the primary active audio app
        if let meta = fetchTrackMetadata(for: primary) {
            title = meta.title
            artist = meta.artist
        }

        return AudioSourceInfo(
            app: primary.name,
            title: title,
            artist: artist,
            apps: appNames
        )
    }

    private func fetchTrackMetadata(for app: ActiveApp) -> (title: String?, artist: String?)? {
        guard !app.bundleID.isEmpty, !deniedBundleIDs.contains(app.bundleID) else {
            return nil
        }

        let scriptSource: String?
        let isBrowser: Bool

        switch app.bundleID {
        case "com.spotify.client":
            isBrowser = false
            scriptSource = """
            tell application "Spotify"
                if player state is playing then
                    return (name of current track as text) & "|||" & (artist of current track as text)
                end if
            end tell
            """
        case "com.apple.Music":
            isBrowser = false
            scriptSource = """
            tell application "Music"
                if player state is playing then
                    return (name of current track as text) & "|||" & (artist of current track as text)
                end if
            end tell
            """
        case "com.google.Chrome":
            isBrowser = true
            scriptSource = """
            tell application "Google Chrome"
                if (count of windows) > 0 then
                    return (title of active tab of front window as text)
                end if
            end tell
            """
        case "com.apple.Safari":
            isBrowser = true
            scriptSource = """
            tell application "Safari"
                if (count of windows) > 0 then
                    return (name of current tab of front window as text)
                end if
            end tell
            """
        case "company.thebrowser.Browser":
            isBrowser = true
            scriptSource = """
            tell application "Arc"
                if (count of windows) > 0 then
                    return (title of active tab of front window as text)
                end if
            end tell
            """
        case "com.brave.Browser":
            isBrowser = true
            scriptSource = """
            tell application "Brave Browser"
                if (count of windows) > 0 then
                    return (title of active tab of front window as text)
                end if
            end tell
            """
        case "com.microsoft.edgemac":
            isBrowser = true
            scriptSource = """
            tell application "Microsoft Edge"
                if (count of windows) > 0 then
                    return (title of active tab of front window as text)
                end if
            end tell
            """
        case "org.videolan.vlc":
            isBrowser = false
            scriptSource = """
            tell application "VLC"
                if playing then
                    return (name of current item as text)
                end if
            end tell
            """
        case "com.apple.QuickTimePlayerX":
            isBrowser = false
            scriptSource = """
            tell application "QuickTime Player"
                if (count of documents) > 0 then
                    return (name of front document as text)
                end if
            end tell
            """
        default:
            isBrowser = false
            scriptSource = nil
        }

        guard let scriptSource, let script = NSAppleScript(source: scriptSource) else {
            return nil
        }

        var errorDict: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorDict)
        if let errorDict {
            // -1743 = errAEEventNotPermitted (user denied Automation permission)
            if let errNum = errorDict[NSAppleScript.errorNumber] as? Int, errNum == -1743 {
                deniedBundleIDs.insert(app.bundleID)
            }
            return nil
        }

        guard let raw = descriptor.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        if raw.contains("|||") {
            let parts = raw.components(separatedBy: "|||")
            let t = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines)
            let a = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : nil
            return (t, a)
        }

        if isBrowser {
            return cleanBrowserTitle(raw)
        }

        return (raw, nil)
    }

    private func cleanBrowserTitle(_ raw: String) -> (String?, String?) {
        let suffixes: [(String, String)] = [
            (" - YouTube", "YouTube"),
            (" - YouTube Music", "YouTube Music"),
            (" - SoundCloud", "SoundCloud"),
            (" - Netflix", "Netflix"),
            (" - Twitch", "Twitch"),
            (" - Vimeo", "Vimeo"),
            (" - Spotify", "Spotify Web")
        ]
        for (suffix, site) in suffixes {
            if raw.hasSuffix(suffix) {
                let cleaned = String(raw.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return (cleaned.isEmpty ? raw : cleaned, site)
            }
        }
        return (raw, nil)
    }
}
