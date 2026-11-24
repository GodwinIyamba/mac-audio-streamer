import AppKit
import SwiftUI

final class MacAudioSpeakerDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppController.shared.shutdownSynchronously()
        }
    }
}

@main
struct MacAudioSpeakerApp: App {
    @NSApplicationDelegateAdaptor(MacAudioSpeakerDelegate.self) private var appDelegate
    @StateObject private var controller = AppController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(controller: controller) {
                NSApp.terminate(nil)
            }
            .onAppear {
                controller.refreshNetworkAddresses()
            }
        } label: {
            if controller.listenerCount > 0 {
                Label("\(controller.listenerCount)", systemImage: controller.menuBarSymbol)
                    .labelStyle(.titleAndIcon)
            } else {
                Image(systemName: controller.menuBarSymbol)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
