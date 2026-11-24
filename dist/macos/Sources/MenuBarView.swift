import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var controller: AppController
    let onQuit: () -> Void

    private static let ciContext = CIContext()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerSection

            if let alertText = controller.errorMessage ?? controller.warningMessage {
                alertBanner(message: alertText, isError: controller.errorMessage != nil)
            }

            if controller.isServerRunning {
                connectCard
                controlsSection
            } else {
                stoppedPlaceholder
            }

            Divider()

            footerSection
        }
        .padding(16)
        .frame(width: 356)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(headerIconGradient)
                    .frame(width: 34, height: 34)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.75)
                    )
                    .shadow(color: statusColor.opacity(0.28), radius: 4, y: 1.5)
                Image(systemName: controller.isServerRunning ? "airplayaudio" : "speaker.slash.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Mac Audio Speaker")
                    .font(.system(size: 13.5, weight: .semibold))
                Text(statusLabel)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle(
                "",
                isOn: Binding(
                    get: { controller.isServerRunning },
                    set: { controller.toggleServer($0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(controller.isServerRunning ? "Stop LAN audio server" : "Start LAN audio server")
        }
    }

    private var headerIconGradient: LinearGradient {
        if controller.errorMessage != nil || controller.warningMessage != nil {
            return LinearGradient(
                colors: [Color(red: 1.0, green: 0.62, blue: 0.16), Color(red: 0.90, green: 0.42, blue: 0.05)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        if !controller.isServerRunning {
            return LinearGradient(
                colors: [Color(white: 0.58), Color(white: 0.42)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        if controller.listenerCount > 0 && controller.isStreaming {
            return LinearGradient(
                colors: [Color(red: 0.24, green: 0.85, blue: 0.46), Color(red: 0.10, green: 0.68, blue: 0.34)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: [Color(red: 0.20, green: 0.62, blue: 1.0), Color(red: 0.0, green: 0.42, blue: 0.92)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var statusColor: Color {
        if controller.errorMessage != nil || controller.warningMessage != nil {
            return .orange
        }
        if !controller.isServerRunning {
            return .secondary
        }
        if controller.listenerCount > 0 && controller.isStreaming {
            return .green
        }
        return .accentColor
    }

    private var statusLabel: String {
        if controller.errorMessage != nil {
            return "Capture Error"
        }
        if controller.warningMessage != nil {
            return "Permission Needed"
        }
        if !controller.isServerRunning {
            return "Server Stopped"
        }
        if controller.listenerCount > 0 {
            let unit = controller.listenerCount == 1 ? "iPhone" : "devices"
            return "Streaming to \(controller.listenerCount) \(unit)"
        }
        return "Ready — waiting for iPhone"
    }

    // MARK: - Alert Banner

    private func alertBanner(message: String, isError: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "lock.shield.fill")
                    .font(.system(size: 12.5))
                    .foregroundStyle(isError ? .red : .orange)
                    .padding(.top, 1)
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                controller.openSystemAudioPermissions()
            } label: {
                Label("Open System Settings", systemImage: "gearshape")
                    .font(.system(size: 11.5, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(isError ? .red : .orange)
            .controlSize(.small)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill((isError ? Color.red : Color.orange).opacity(0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder((isError ? Color.red : Color.orange).opacity(0.32), lineWidth: 1)
                )
        )
    }

    // MARK: - Connect Card (QR + LAN URL)

    private var connectCard: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                qrCodeView(for: controller.primaryURLString)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Scan on iPhone")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("Point your iPhone Camera at this code on the same Wi-Fi to open Safari.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if controller.isStreaming {
                        HStack(spacing: 4) {
                            Image(systemName: "waveform")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.green)
                            Text(controller.formatSummary)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 2)
                    }
                }
            }

            // Copyable URL row
            HStack(spacing: 6) {
                Text(controller.primaryURLString)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .textSelection(.enabled)

                Spacer(minLength: 4)

                Button {
                    controller.copyURLToClipboard()
                } label: {
                    Label(
                        controller.copiedURL ? "Copied" : "Copy",
                        systemImage: controller.copiedURL ? "checkmark" : "doc.on.doc"
                    )
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()

                Button {
                    controller.refreshNetworkAddresses()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .help("Refresh Wi-Fi IP address")
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )

            // Alternate network interface picker if more than 1 IP exists
            if controller.lanAddresses.count > 1 {
                HStack(spacing: 6) {
                    Text("Interface")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("Interface", selection: $controller.selectedIP) {
                        ForEach(controller.lanAddresses) { addr in
                            Text("\(addr.interface) (\(addr.ip))").tag(addr.ip)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                }
            }

            // Live Audio Level Meter
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(controller.currentSource?.compactSummary ?? "Live Audio Level")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(controller.currentSource != nil ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(meterStatusText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(controller.isStreaming && controller.audioLevel > 0.01 ? .green : .secondary)
                        .fixedSize()
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [.accentColor, .green],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(0, geo.size.width * controller.audioLevel))
                            .animation(.easeOut(duration: 0.08), value: controller.audioLevel)
                    }
                }
                .frame(height: 6)
            }
            .padding(.top, 2)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private var meterStatusText: String {
        if !controller.isStreaming {
            return "Idle (speakers normal)"
        }
        if controller.audioLevel > 0.01 {
            return "Streaming"
        }
        return "Silent"
    }

    @ViewBuilder
    private func qrCodeView(for text: String) -> some View {
        if let nsImage = Self.makeQRCode(from: text) {
            Image(nsImage: nsImage)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .padding(7)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white)
                )
                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
        }
    }

    private static func makeQRCode(from string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: 192, height: 192))
    }

    // MARK: - Controls

    private var controlsSection: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Mute Mac Speakers")
                        .font(.system(size: 12.5, weight: .medium))
                    Text("Silence Mac while iPhone is listening")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { controller.muteMac },
                        set: { controller.setMuteMac($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Launch at Login")
                        .font(.system(size: 12.5, weight: .medium))
                    Text("Keep ready in menu bar automatically")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { controller.launchAtLogin },
                        set: { controller.setLaunchAtLogin($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
    }

    private var stoppedPlaceholder: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.slash")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Server is paused")
                    .font(.system(size: 12.5, weight: .medium))
                Text("Flip the switch above to accept iPhone connections.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button {
                controller.openInBrowser()
            } label: {
                Label("Open in Safari", systemImage: "safari")
                    .font(.system(size: 11.5))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!controller.isServerRunning)

            Spacer()

            Button("Quit") {
                onQuit()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}
